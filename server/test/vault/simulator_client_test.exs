defmodule Vault.SimulatorClientTest do
  use ExUnit.Case, async: false

  @compile {:no_warn_undefined,
            [
              Vault.Simulator.Admission,
              Vault.Simulator.Client,
              Vault.Simulator.FrameLimits,
              Vault.Simulator.Runner
            ]}

  alias Vault.Simulator.{Admission, Client, FrameLimits, Runner}
  alias Vault.Test.{FakeClock, SimulatorFixture, SimulatorTestDriver}
  alias Vault.Test.SimulatorFixture, as: F

  setup_all do
    SimulatorFixture.load_tools()
    {:ok, _} = Application.ensure_all_started(:mint_web_socket)
    :ok
  end

  setup do
    root = F.root()
    %{root: root, credentials_file: F.credentials(root)}
  end

  test "bounded incremental assembled bytes allow interleaved controls and reject at declaration" do
    limits = struct(FrameLimits)
    first = F.raw_frame(1, :binary.copy("x", 8_191), fin: false)
    <<a, b, c, d, payload::binary>> = first
    assert {:ok, partial} = FrameLimits.scan(limits, <<a>>)
    assert {:ok, partial} = FrameLimits.scan(partial, <<b, c>>)
    assert {:ok, partial} = FrameLimits.scan(partial, <<d, payload::binary>>)
    assert {:ok, partial} = FrameLimits.scan(partial, F.raw_frame(9, "between"))
    assert {:error, :invalid_frame} = FrameLimits.scan(partial, <<128, 2>>)
    assert {:ok, %{fragmented: nil}} = FrameLimits.scan(partial, F.raw_frame(0, "x"))

    for invalid <- [<<129, 127>>, <<130, 0>>, <<9, 0>>, <<193, 0>>, <<129, 128>>, <<136, 1>>] do
      assert {:error, :invalid_frame} = FrameLimits.scan(limits, invalid)
    end
  end

  test "WS upgrades with a coalesced control, assembles a split welcome, and distinguishes ping from freshness",
       context do
    peer = F.peer("ws", coalesced: true)
    {_, gate} = connect(context, peer)
    assert %{"type" => "hello", "device_id" => "test_device"} = hello_and_pong(peer)
    {:ok, message} = Vault.Protocol.encode(F.welcome(), :server_to_device)
    <<part::binary-size(49), rest::binary>> = message
    fragment = F.raw_frame(1, part, fin: false)
    <<byte, tail::binary>> = fragment
    :ok = F.send_bytes(peer, <<byte>>)
    :ok = F.send_bytes(peer, tail <> F.raw_frame(9, "during") <> F.raw_frame(0, rest))
    assert_receive {:simulator_client, 1, {:welcome, ^gate, %{"connection_id" => "conn_1"}}}
    assert {:ok, {1, 10, "during"}} = F.recv(peer)
    :ok = F.send_message(peer, F.challenge(1))

    assert {%{"type" => "heartbeat", "heartbeat_seq" => 1, "input" => nil}, _} =
             F.receive_message(peer)

    :ok = F.send_bytes(peer, F.raw_frame(9, "still-not-fresh"))
    assert {:ok, {1, 10, "still-not-fresh"}} = F.recv(peer)
    assert_receive {:simulator_runner, {:retired, 1, :server_silence, _}}, 1_750
  end

  test "command loss retries the exact bytes three times while challenges continue", context do
    peer = F.peer("ws")
    {_, gate} = connect(context, peer)
    {_, _} = F.receive_message(peer)
    :ok = F.send_message(peer, F.welcome())
    assert_receive {:simulator_client, 1, {:welcome, ^gate, _}}
    :ok = Client.command(gate, "claim_role", %{"role" => "a"})
    assert {%{"command_seq" => 1}, initial} = F.receive_message(peer)

    for seq <- 1..3 do
      :ok = F.send_message(peer, F.challenge(seq))
      assert {%{"type" => "heartbeat", "heartbeat_seq" => ^seq}, _} = F.receive_message(peer)
      assert {%{"command_seq" => 1}, ^initial} = F.receive_message(peer)
    end

    assert_receive {:simulator_runner, {:retired, 1, :result_timeout, _}}, 750
    assert {:error, :retired} = Client.command(gate, "request_snapshot", %{})
  end

  test "an oversized server frame declaration closes without waiting for its body", context do
    peer = F.peer("ws")
    {_, gate} = connect(context, peer)
    {_, _} = F.receive_message(peer)
    :ok = F.send_message(peer, F.welcome())
    assert_receive {:simulator_client, 1, {:welcome, ^gate, _}}
    :ok = F.send_bytes(peer, <<129, 126, 8_193::16>>)
    assert_receive {:simulator_runner, {:retired, 1, :invalid_frame, _}}
    assert_receive {:simulator_runner, {:owner_down, 1}}
  end

  for scheme <- ["ws", "wss"] do
    @tag :pressure
    test "#{scheme} real stopped reader saturates with bounded setup", context do
      scheme = unquote(scheme)
      tls = if scheme == "wss", do: F.tls(context.root)
      peer = F.peer(scheme, tls: tls, recbuf: 1_024)

      {_, gate} =
        connect(context, peer,
          socket_opts: [sndbuf: 2_048, high_watermark: 4_096, low_watermark: 2_048],
          cacerts: tls && [tls.ca],
          test_frames: true
        )

      assert_receive {:simulator_client, 1, {:socket_options, {:ok, options}}}, 1_200
      assert options[:send_timeout] == 100
      assert is_integer(options[:sndbuf])
      {_, _} = F.receive_message(peer)
      :ok = F.send_message(peer, F.welcome())
      assert_receive {:simulator_client, 1, {:welcome, ^gate, _}}
      # No reads from this point: even TLS stays passive at the application
      # boundary, and measuring the actual write return accounts for buffering.
      started = now()
      {total, write_ms, outcome} = saturate(gate, 0, started + 1_350)
      assert total <= 4_194_304
      assert write_ms >= 80 and write_ms <= 200
      assert outcome == {:error, :socket_timeout}
      assert_receive {:simulator_runner, {:retired, 1, :socket_timeout, retired}}
      assert_receive {:simulator_runner, {:close_window, 1, close_due}}
      assert (close_due - retired) in 100..102
      assert_receive {:simulator_runner, {:owner_down, 1}}, 300
      refute Process.alive?(gate.pid)
      assert now() - started <= 1_600

      IO.puts(
        "#{scheme} pressure: #{total} payload bytes attempted, blocked send #{write_ms} ms, effective sndbuf #{options[:sndbuf]}"
      )
    end
  end

  test "WSS rejects untrusted certificates and a trusted certificate with the wrong hostname",
       context do
    tls = F.tls(context.root)
    peer = F.peer("wss", tls: tls)
    {_, _} = connect(context, peer)
    assert_receive {:simulator_runner, {:retired, 1, :connect_failed, _}}, 1_400

    peer = F.peer("wss", tls: tls, hostname: "127.0.0.1")
    {_, _} = connect(context, peer, cacerts: [tls.ca])
    assert_receive {:simulator_runner, {:retired, 1, :connect_failed, _}}, 1_400
  end

  test "late successful return before the timeout message kills owner without a close window",
       context do
    {:ok, clock} = FakeClock.start_link(0)

    driver = [
      driver: SimulatorTestDriver,
      runner_clock: FakeClock.handle(clock),
      driver_test: self()
    ]

    {runner, gate} = fake_connect(context, driver)
    assert_receive {:driver_write, owner, :upgrade}
    assert owner == gate.pid
    assert_receive {:simulator_runner, {:write_start, 1, _, :upgrade, 200}}

    # Update the same monotonic clock but leave its scheduled timeout queued
    # in the fake scheduler; the completion must make the expiry decision.
    Agent.update(clock, &%{&1 | now_ms: 200})
    send(owner, {:driver_return, :ok})
    assert_receive {:simulator_runner, {:retired, 1, :write_deadline, 200}}
    assert_receive {:simulator_runner, {:owner_kill, 1, :write_deadline, 200}}
    assert_receive {:simulator_runner, {:owner_down, 1}}
    refute_receive {:driver_close, _}, 50
    refute_receive {:simulator_runner, {:close_window, _, _}}, 50
    assert Runner.gate(runner) == nil
  end

  test "a returned send error permits only the 100 ms close window and reconnects after owner exit",
       context do
    {:ok, clock} = FakeClock.start_link(0)

    driver = [
      driver: SimulatorTestDriver,
      runner_clock: FakeClock.handle(clock),
      driver_test: self(),
      reconnect: true
    ]

    {runner, gate} = fake_connect(context, driver)
    assert_receive {:driver_write, owner, :upgrade}
    assert owner == gate.pid
    send(owner, {:driver_return, {:error, :socket_timeout}})
    assert_receive {:simulator_runner, {:retired, 1, :socket_timeout, 0}}
    assert_receive {:simulator_runner, {:close_window, 1, 100}}
    assert_receive {:driver_close, ^owner}
    assert :ok = FakeClock.advance_to(clock, 99)
    assert Process.alive?(owner)
    assert :ok = FakeClock.advance_to(clock, 100)
    assert_receive {:simulator_runner, {:owner_kill, 1, :close_deadline, 100}}
    assert_receive {:simulator_runner, {:owner_down, 1}}
    assert {:error, :retired} = Client.command(gate, "request_snapshot", %{})
    assert_receive {:driver_write, next, :upgrade}, 500
    refute next == owner
    assert %{generation: 2} = Runner.gate(runner)
  end

  test "full producer mailbox reserves one active and nine waiters and retires on overflow",
       context do
    {_, gate} =
      fake_connect(context, driver: SimulatorTestDriver, driver_test: self(), test_frames: true)

    assert_receive {:driver_write, owner, :upgrade}
    send(owner, {:driver_return, :ok})
    send(owner, {:tcp, :stub, :upgraded})
    assert_receive {:driver_write, ^owner, :text}
    send(owner, {:driver_return, :ok})
    send(owner, {:tcp, :stub, {:message, F.welcome()}})
    assert_receive {:simulator_client, 1, {:welcome, ^gate, _}}

    frame = {:text, :binary.copy("x", 4_096)}
    :ok = Client.test_frame(gate, frame)
    assert_receive {:driver_write, ^owner, :text}

    for _ <- 1..9, do: assert(:ok == Client.test_frame(gate, frame))
    assert Admission.used(gate) == 10
    assert {:error, :overflow} = Client.test_frame(gate, frame)
    assert_receive {:simulator_runner, {:retired, 1, :queue_overflow, _}}
    assert_receive {:simulator_runner, {:owner_down, 1}}
    assert {:error, :retired} = Client.test_frame(gate, frame)
  end

  test "slow queued writes yield to socket messages between single write turns", context do
    {_, gate} =
      fake_connect(context, driver: SimulatorTestDriver, driver_test: self(), test_frames: true)

    assert_receive {:driver_write, owner, :upgrade}
    send(owner, {:driver_return, :ok})
    send(owner, {:tcp, :stub, :upgraded})
    assert_receive {:driver_write, ^owner, :text}
    send(owner, {:driver_return, :ok})
    send(owner, {:tcp, :stub, {:message, F.welcome()}})
    assert_receive {:simulator_client, 1, {:welcome, ^gate, _}}

    :ok = Client.test_frame(gate, {:text, "first"})
    assert_receive {:driver_write, ^owner, :text}
    :ok = Client.test_frame(gate, {:text, "second"})
    :ok = Client.test_frame(gate, {:text, "third"})
    send(owner, {:tcp, :stub, {:message, F.challenge(1)}})
    Process.sleep(35)
    send(owner, {:driver_return, :ok})
    assert_receive {:driver_stream, ^owner, {:message, %{"heartbeat_seq" => 1}}}

    for _ <- 1..3 do
      assert_receive {:driver_write, ^owner, :text}
      Process.sleep(35)
      send(owner, {:driver_return, :ok})
    end

    refute_receive {:simulator_runner, {:retired, 1, _, _}}, 70
  end

  defp hello_and_pong(peer) do
    {hello, _} = F.receive_message(peer)
    assert {:ok, {1, 10, "upgrade"}} = F.recv(peer)
    hello
  end

  defp saturate(_gate, bytes, _due) when bytes >= 4_194_304,
    do: flunk("peer did not cause real backpressure within the finite byte limit")

  defp saturate(gate, total, due) do
    assert now() < due, "peer did not cause real backpressure within the finite time limit"
    :ok = Client.test_frame(gate, {:text, :binary.copy("x", 4_096)})
    assert_receive {:simulator_client, 1, {:write_enter, :test_frame, start}}, 200
    assert_receive {:simulator_client, 1, {:write_return, :test_frame, outcome, done}}, 225
    total = total + 4_096

    if outcome == :ok do
      saturate(gate, total, due)
    else
      {total, done - start, outcome}
    end
  end

  defp fake_connect(context, opts) do
    connect(context, %{uri: URI.parse("ws://localhost:80/device/v1")}, opts)
  end

  defp connect(context, peer, opts \\ []) do
    defaults = [
      uri: peer.uri,
      credentials_file: context.credentials_file,
      device_id: "test_device",
      client_trace: self(),
      trace: self(),
      reconnect: false
    ]

    runner = start_supervised!({Runner, Keyword.merge(defaults, opts)}, id: make_ref())
    gate = Runner.gate(runner)
    assert %{__struct__: Admission} = gate
    {runner, gate}
  end

  defp now, do: System.monotonic_time(:millisecond)
end

defmodule Vault.Test.SimulatorTestDriver do
  def connect(opts), do: {:ok, opts[:driver_test]}
  def socket_options(_, _), do: {:ok, [send_timeout: 100, sndbuf: 2_048]}

  def write(test, operation) do
    send(test, {:driver_write, self(), elem(operation, 0)})

    receive do
      {:driver_return, :ok} -> {:ok, test}
      {:driver_return, {:error, reason}} -> {:error, test, reason}
    end
  end

  def stream(test, {:tcp, :stub, payload}) do
    send(test, {:driver_stream, self(), payload})

    events =
      case payload do
        :upgraded ->
          [:upgraded]

        {:message, msg} ->
          {:ok, bytes} = Vault.Protocol.encode(msg, :server_to_device)
          [{:text, bytes}]
      end

    {:ok, test, events}
  end

  def close(test) do
    send(test, {:driver_close, self()})

    receive do
      :driver_close -> :ok
    end
  end
end
