defmodule VaultWeb.DeviceSocketTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Vault.{Auth, Controllers, Credentials, GameStore, Games, Repo}
  alias Vault.GameStore.Device
  alias Vault.Test.DeviceEndpoint, as: Client

  @moduletag :m2
  setup do: Client.start()

  describe "socket close diagnostics" do
    setup do
      flag = "VAULT_DEVICE_SOCKET_DIAGNOSTICS"
      previous = System.get_env(flag)

      on_exit(fn ->
        if previous, do: System.put_env(flag, previous), else: System.delete_env(flag)
      end)

      System.put_env(flag, "true")
      %{diagnostics_flag: flag}
    end

    test "logs a server policy code with the registered role and leaves the close frame unchanged",
         fixture do
      fixture.device_id
      |> then(&Repo.get!(Device, &1))
      |> Ecto.Changeset.change(allowed_roles_mask: 2)
      |> Repo.update!()

      hello = Client.hello(fixture)
      {client, welcome, _} = Client.connect(fixture, hello)
      marker = "private invalid message"

      log =
        capture_log(fn ->
          client = Client.send_frame(client, {:text, marker})
          assert {{:close, 1002, "invalid_message"}, client} = close_frame(client)
          Client.close(client)
        end)

      assert [_, admission_age, tokens, socket_age] =
               Regex.run(
                 ~r/Device socket server close code=1002 cause=invalid_message binding_generation=\d+ role_mask=2 admission_age_ms=(\d+) tokens_after_admit=(\d+) socket_age_ms=(\d+)/,
                 log
               )

      assert String.to_integer(admission_age) <= String.to_integer(socket_age)
      assert String.to_integer(tokens) in 8_000..9_000

      refute log =~ "Device socket terminated"
      refute log =~ marker
      refute log =~ fixture.secret
      refute log =~ fixture.device_id
      refute log =~ hello["boot_id"]
      refute log =~ welcome["connection_id"]
      refute log =~ welcome["session_id"]
    end

    test "classifies a peer close without logging the peer close payload", fixture do
      {client, _, _} = Client.connect(fixture)
      marker = "private peer close payload"

      log =
        capture_log(fn ->
          client = Client.send_frame(client, {:close, 1000, marker})
          assert {{:close, 1000, _}, client} = close_frame(client)
          Client.close(client)
        end)

      assert log =~
               ~r/Device socket terminated cause=peer_close_frame binding_generation=\d+ role_mask=1 admission_age_ms=\d+ tokens_after_admit=9000 socket_age_ms=\d+/

      refute log =~ "Device socket server close"
      refute log =~ marker
      refute log =~ fixture.secret
      refute log =~ fixture.device_id
    end

    test "is quiet without opt-in", fixture do
      System.delete_env(fixture.diagnostics_flag)
      {:ok, client} = Client.mint_open(fixture, Client.bearer(fixture))

      log =
        capture_log(fn ->
          client = Client.send_frame(client, {:binary, "invalid binary"})
          assert {{:close, 1003, "text_required"}, client} = close_frame(client)
          Client.close(client)
        end)

      refute log =~ "Device socket"
    end
  end

  test "validates bearer credentials before upgrade and binds the registered role scope",
       fixture do
    assert {:error, 401, _} = Client.mint_open(fixture)

    assert {:error, 401, _} =
             Client.mint_open(fixture, [{"authorization", "Bearer " <> String.duplicate("0", 64)}])

    assert {:error, 401, _} =
             Client.mint_open(fixture, Client.bearer(fixture) ++ Client.bearer(fixture))

    {client, welcome, initial} = Client.connect(fixture)
    assert welcome["assigned_role"] == nil
    assert welcome["allowed_roles"] == ["a"]
    assert welcome["required_roles"] == ["a", "b"]
    assert initial["projection"] == "public"
    assert initial["connection_id"] == welcome["connection_id"]
    assert Map.take(initial, ~w(game_id board_version maze seal hold)) == %{}

    client = Client.send_json(client, Client.command(welcome, 1, "claim_role", %{"role" => "b"}))
    {result, client} = Client.receive_type(client, "command_result")
    assert %{"status" => "rejected", "code" => "not_authorized", "data" => %{}} = result

    client = Client.send_json(client, Client.command(welcome, 2, "claim_role", %{"role" => "a"}))
    {result, client} = Client.receive_type(client, "command_result")

    assert %{
             "status" => "applied",
             "code" => "role_claimed",
             "data" => %{"role" => "a", "control_epoch" => epoch}
           } = result

    {projection, client} = Client.receive_type(client, "snapshot")
    assert %{"projection" => "controller", "role" => "a", "control_epoch" => ^epoch} = projection
    assert Map.take(projection, ~w(game_id panels actors diagnostics)) == %{}
    {challenge, client} = Client.receive_type(client, "heartbeat_request")

    heartbeat = %{
      "v" => 1,
      "type" => "heartbeat",
      "connection_id" => welcome["connection_id"],
      "heartbeat_seq" => challenge["heartbeat_seq"],
      "input_seq" => 1,
      "input" => %{
        "session_id" => projection["session_id"],
        "round_id" => projection["round_id"],
        "puzzle_revision" => projection["puzzle_revision"],
        "role" => "a",
        "control_epoch" => epoch,
        "pressed" => false,
        "press_id" => nil
      }
    }

    client = Client.send_json(client, heartbeat)
    {ack, client} = Client.receive_type(client, "heartbeat_ack")
    assert %{"input_accepted" => true, "input_seq" => 1} = ack
    client = Client.send_json(client, heartbeat)
    {ack, client} = Client.receive_type(client, "heartbeat_ack")
    assert %{"input_accepted" => false, "code" => "stale_sample", "input_seq" => 1} = ack
    Client.close(client)
  end

  test "rejects mismatched hello identity, class, binary frames and absent hello", fixture do
    for hello <- [
          Client.hello(fixture, %{"device_id" => "spoof"}),
          Client.hello(fixture, %{
            "device_class" => "box",
            "capabilities" => %{
              "latch" => "stepper",
              "home_sensor" => false,
              "released_sensor" => false,
              "led_count" => 8,
              "buzzer" => false,
              "max_message_bytes" => 8192
            }
          })
        ] do
      {:ok, client} = Client.mint_open(fixture, Client.bearer(fixture))
      client = Client.send_json(client, hello)
      assert {{:close, 1008, "identity_mismatch"}, client} = close_frame(client)
      Client.close(client)
    end

    {:ok, client} = Client.mint_open(fixture, Client.bearer(fixture))
    client = Client.send_frame(client, {:binary, Jason.encode!(Client.hello(fixture))})
    assert {{:close, 1003, "text_required"}, client} = close_frame(client)
    Client.close(client)

    {:ok, client} = Client.mint_open(fixture, Client.bearer(fixture))
    started = Client.now_ms()
    assert {{:close, 1008, "hello_timeout"}, client} = close_frame(client, 5_500)
    assert (Client.now_ms() - started) in 4_800..5_500
    Client.close(client)
  end

  test "counts assembled bytes across continuations and allows an interleaved ping", fixture do
    hello = Jason.encode!(Client.hello(fixture))
    exact = hello <> String.duplicate(" ", 4096 - byte_size(hello))
    <<first::binary-size(2048), second::binary>> = exact
    socket = Client.raw_open(fixture)

    assert :ok =
             :gen_tcp.send(socket, [
               Client.raw_frame(1, false, first),
               Client.raw_frame(9, true, "probe"),
               Client.raw_frame(0, true, second)
             ])

    assert "probe" = Client.raw_receive(socket, 10)
    assert %{"type" => "welcome"} = socket |> Client.raw_receive(1) |> Jason.decode!()
    :gen_tcp.close(socket)

    socket = Client.raw_open(fixture)
    assert :ok = :gen_tcp.send(socket, Client.raw_frame(1, true, exact))
    assert %{"type" => "welcome"} = socket |> Client.raw_receive(1) |> Jason.decode!()
    :gen_tcp.close(socket)

    for frames <- [
          [Client.raw_frame(1, false, first), Client.raw_frame(0, true, second <> " ")],
          [Client.raw_frame(1, true, exact <> " ")]
        ] do
      socket = Client.raw_open(fixture)
      assert :ok = :gen_tcp.send(socket, frames)
      assert <<1009::16, _::binary>> = Client.raw_receive(socket, 8)
      :gen_tcp.close(socket)
    end

    socket = Client.raw_open(fixture)
    assert :ok = :gen_tcp.send(socket, Client.raw_frame(9, false, "bad"))
    assert <<1002::16, _::binary>> = Client.raw_receive(socket, 8)
    :gen_tcp.close(socket)
  end

  test "accepts depth eight and closes on malformed JSON, extensions or enums outside the contract",
       fixture do
    hello = Client.hello(fixture)
    nest = fn depth -> Enum.reduce(1..depth, "leaf", fn _, acc -> %{"child" => acc} end) end
    hello_at_limit = Map.put(hello, "extension", nest.(7))
    {client, _, _} = Client.connect(fixture, hello_at_limit)
    Client.close(client)

    for {bytes, code} <- [
          {Jason.encode!(Map.put(hello, "extension", nest.(8))), 1002},
          {Jason.encode!(Map.put(hello, "v", 2)), 1002},
          {Jason.encode!(Map.put(hello, "firmware_version", String.duplicate("a", 129))), 1002},
          {Jason.encode!(hello) <> "{}", 1002},
          {"{\"v\":1,\"\\u0076\":1}", 1002},
          {"{\"type\":\"" <> <<255>> <> "\"}", 1007}
        ] do
      socket = Client.raw_open(fixture)
      assert :ok = :gen_tcp.send(socket, Client.raw_frame(1, true, bytes))
      assert <<^code::16, _::binary>> = Client.raw_receive(socket, 8)
      :gen_tcp.close(socket)
    end
  end

  test "uses complete decoded retry identity and rejects sequence gaps without consuming the next command",
       fixture do
    {client, welcome, _} = Client.connect(fixture)
    gap = Client.command(welcome, 2, "request_snapshot")
    client = Client.send_json(client, gap)

    assert {%{"code" => "seq_gap", "data" => %{"expected_command_seq" => 1}}, client} =
             Client.receive_type(client, "command_result")

    command =
      Client.command(welcome, 1, "request_snapshot")
      |> Map.put("extension", %{"value" => 2, "word" => "a"})

    client = Client.send_json(client, command)
    {first, client} = Client.receive_type(client, "command_result")
    assert %{"code" => "snapshot_sent", "status" => "applied"} = first

    equivalent =
      Jason.encode!(command)
      |> String.replace("\"value\":2", "\"value\":2.0e0")
      |> String.replace("\"word\":\"a\"", "\"word\":\"\\u0061\"")

    client = Client.send_frame(client, {:text, equivalent})
    assert {^first, client} = Client.receive_type(client, "command_result")
    changed = put_in(command["extension"]["value"], 3)
    client = Client.send_json(client, changed)
    assert {{:close, 1002, "sequence_conflict"}, client} = close_frame(client)
    Client.close(client)
  end

  test "expires exactly the oldest retained command and emits a snapshot", fixture do
    {client, welcome, _} = Client.connect(fixture)

    client =
      Enum.reduce(1..129, client, fn seq, client ->
        started = Client.now_ms()
        command = Client.command(welcome, seq, "claim_role", %{"role" => "d"})
        client = Client.send_json(client, command)

        assert {%{"code" => "not_authorized", "command_seq" => ^seq}, client} =
                 Client.receive_type(client, "command_result")

        Process.sleep(max(0, 35 - (Client.now_ms() - started)))
        client
      end)

    client = Client.send_json(client, Client.command(welcome, 2, "claim_role", %{"role" => "d"}))
    assert {%{"code" => "not_authorized"}, client} = Client.receive_type(client, "command_result")
    client = Client.send_json(client, Client.command(welcome, 1, "claim_role", %{"role" => "d"}))
    assert {%{"code" => "result_expired"}, client} = Client.receive_type(client, "command_result")
    assert {%{"projection" => "public"}, client} = Client.receive_type(client, "snapshot")
    Client.close(client)
  end

  test "rejects a burst above ten assembled application messages", fixture do
    socket = Client.raw_open(fixture)

    assert :ok =
             :gen_tcp.send(
               socket,
               Client.raw_frame(1, true, Jason.encode!(Client.hello(fixture)))
             )

    welcome = socket |> Client.raw_receive(1) |> Jason.decode!()
    command = Client.command(welcome, 1, "claim_role", %{"role" => "d"})
    frame = Client.raw_frame(1, true, Jason.encode!(command))

    assert :ok = :gen_tcp.send(socket, List.duplicate(frame, 24))
    assert <<1008::16, "rate_limit">> = Client.raw_receive(socket, 8)
    :gen_tcp.close(socket)
  end

  @tag timeout: 10_000
  test "paced unclaimed heartbeat replies stay usable but compressed delivery hits the burst limit",
       fixture do
    {paced, welcome, _} = Client.connect(fixture)
    assert welcome["assigned_role"] == nil
    assert welcome["heartbeat_interval_ms"] == 100
    inputs = 1..14

    paced =
      Enum.reduce(inputs, paced, fn input_seq, client ->
        {challenge, client} = Client.receive_type(client, "heartbeat_request")
        client = Client.send_json(client, unclaimed_heartbeat(challenge, input_seq))

        assert {%{"input_accepted" => true, "input_seq" => ^input_seq}, client} =
                 Client.receive_type(client, "heartbeat_ack")

        client
      end)

    paced = Client.send_json(paced, Client.command(welcome, 1, "request_snapshot"))
    assert {%{"code" => "snapshot_sent"}, paced} = Client.receive_type(paced, "command_result")
    Client.close(paced)

    {buffered, welcome, _} = Client.connect(fixture)
    assert welcome["assigned_role"] == nil

    {frames, {buffered, _sequence}} =
      Enum.map_reduce(inputs, {buffered, 0}, fn input_seq, {client, previous} ->
        {%{"heartbeat_seq" => sequence} = challenge, client} =
          Client.receive_type(client, "heartbeat_request")

        assert sequence > previous
        payload = Jason.encode!(unclaimed_heartbeat(challenge, input_seq))
        {Client.raw_frame(1, true, payload), {client, sequence}}
      end)

    # Each reply was built on receipt of a real challenge. Flush them in one
    # write to reproduce delivery compression with margin for token refill
    # while the server processes the first ten frames.
    assert {:ok, conn} = Mint.WebSocket.stream_request_body(buffered.conn, buffered.ref, frames)
    buffered = %{buffered | conn: conn}

    {closed, buffered} =
      Enum.reduce_while(inputs, {false, buffered}, fn input_seq, {false, client} ->
        {reply, client} =
          Client.receive_message(
            client,
            &(match?(%{"type" => "heartbeat_ack"}, &1) or match?({:close, _, _}, &1))
          )

        case reply do
          {:close, 1008, "rate_limit"} ->
            assert input_seq > 5
            {:halt, {true, client}}

          %{"type" => "heartbeat_ack", "input_seq" => ^input_seq} ->
            if input_seq <= 5 do
              assert %{"code" => "stale_challenge", "input_accepted" => false} = reply
            end

            {:cont, {false, client}}

          _ ->
            flunk("Unexpected reply while draining compressed heartbeat delivery")
        end
      end)

    assert closed
    Client.close(buffered)
  end

  defp unclaimed_heartbeat(challenge, input_seq) do
    %{
      "v" => 1,
      "type" => "heartbeat",
      "connection_id" => challenge["connection_id"],
      "heartbeat_seq" => challenge["heartbeat_seq"],
      "input_seq" => input_seq,
      "input" => nil
    }
  end

  test "replacement across boots fences the old connection and a GameSession crash rotates authority",
       fixture do
    {old, welcome, _} = Client.connect(fixture)
    old = Client.send_json(old, Client.command(welcome, 1, "claim_role", %{"role" => "a"}))
    assert {%{"code" => "role_claimed"}, old} = Client.receive_type(old, "command_result")
    {current, replacement, _} = Client.connect(fixture)
    assert replacement["connection_id"] != welcome["connection_id"]
    assert replacement["session_id"] == welcome["session_id"]
    assert {{:close, 1008, "binding_ended"}, old} = close_frame(old)
    Client.close(old)

    {:ok, authority} = Games.ensure(fixture.game_id)
    Process.exit(authority, :kill)
    assert {{:close, 4003, "session_reset"}, current} = close_frame(current)
    Client.close(current)

    {reconnected, fresh, snapshot} = Client.connect(fixture)
    assert fresh["session_id"] != replacement["session_id"]
    assert fresh["connection_id"] != replacement["connection_id"]
    assert %{"paused" => true, "pause_reasons" => reasons} = snapshot
    assert "recovery" in reasons
    Client.close(reconnected)
  end

  test "a host reset closes the old device session before a reconnect", fixture do
    root = Application.fetch_env!(:vault, :data_dir)
    {:ok, key} = Credentials.read_key(Path.join(root, "host.key"))
    {:ok, host} = Auth.exchange(:host, key, {127, 0, 0, :erlang.phash2(make_ref(), 254) + 1})
    on_exit(fn -> Auth.logout(host) end)
    {client, welcome, _} = Client.connect(fixture)

    assert {:ok, _} =
             Games.host(
               host,
               fixture.game_id,
               Controllers.id("reset"),
               welcome["session_id"],
               :reset
             )

    assert {{:close, 4003, "session_reset"}, client} = close_frame(client)
    Client.close(client)
    assert {:ok, %{checkpoint: checkpoint}} = GameStore.load(fixture.game_id)
    assert checkpoint.session_id != welcome["session_id"]
  end

  test "a reset queued between socket preflight and heartbeat dispatch closes with session_reset",
       fixture do
    root = Application.fetch_env!(:vault, :data_dir)
    {:ok, key} = Credentials.read_key(Path.join(root, "host.key"))
    {:ok, host} = Auth.exchange(:host, key, {127, 0, 0, :erlang.phash2(make_ref(), 254) + 1})
    on_exit(fn -> Auth.logout(host) end)

    {client, welcome, _} = Client.connect(fixture)
    {%{"heartbeat_seq" => seq}, client} = Client.receive_type(client, "heartbeat_request")
    handler = Client.handler_pid(fixture, welcome)
    {:ok, authority} = Games.ensure(fixture.game_id)
    marker = self()
    request = Controllers.id("reset")
    session = welcome["session_id"]

    # Suspend authority while putting the socket's scope check immediately
    # before reset in its mailbox. The follow-up :sample arrives after reset,
    # while the socket is still processing the frame (not its disconnect event).
    :ok = :sys.suspend(authority)

    client =
      try do
        client =
          Client.send_json(client, %{
            "v" => 1,
            "type" => "heartbeat",
            "connection_id" => welcome["connection_id"],
            "heartbeat_seq" => seq,
            "input_seq" => 1,
            "input" => nil
          })

        assert await_scope_preflight(authority, handler, Client.now_ms() + 1_000)

        send(
          authority,
          {:"$gen_call", {marker, request}, {:host, host, request, session, :reset}}
        )

        client
      after
        :ok = :sys.resume(authority)
      end

    assert_receive {^request, {:ok, _}}, 1_000
    assert {{:close, 4003, "session_reset"}, client} = close_frame(client)
    Client.close(client)
  end

  defp await_scope_preflight(authority, handler, deadline) do
    {:messages, queued} = Process.info(authority, :messages)

    cond do
      Enum.any?(queued, &match?({:"$gen_call", {^handler, _}, {:device_scope, _}}, &1)) ->
        true

      Client.now_ms() >= deadline ->
        false

      true ->
        Process.sleep(1)
        await_scope_preflight(authority, handler, deadline)
    end
  end

  defp close_frame(client, timeout \\ 1_000),
    do: Client.receive_message(client, &match?({:close, _, _}, &1), timeout)
end
