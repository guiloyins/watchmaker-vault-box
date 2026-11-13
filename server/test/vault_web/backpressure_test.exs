defmodule VaultWeb.BackpressureTest do
  use ExUnit.Case, async: false

  alias Vault.{Auth, Credentials, Games, Updates}
  alias Vault.Test.DeviceEndpoint, as: Client
  alias VaultWeb.DeviceSocket

  @moduletag :m2

  test "slow consumption coalesces snapshots and preserves each required result before overflow" do
    fixture = Client.start()
    {client, welcome, _} = Client.connect(fixture)
    pid = Client.handler_pid(fixture, welcome)
    assert is_pid(pid)
    {delivery, slot} = delivery(pid)
    session = welcome["session_id"]
    game = fixture.game_id

    root = Application.fetch_env!(:vault, :data_dir)
    {:ok, key} = Credentials.read_key(Path.join(root, "host.key"))
    {:ok, host} = Auth.exchange(:host, key, {127, 0, 0, :erlang.phash2(make_ref(), 254) + 1})
    on_exit(fn -> Auth.logout(host) end)
    {:ok, projection} = Games.fetch(host, game, :public)
    revision = projection.state_revision + 1_000

    :sys.suspend(pid)

    client =
      try do
        client =
          Enum.reduce(1..5, client, fn seq, client ->
            Client.send_json(client, Client.command(welcome, seq, "claim_role", %{"role" => "b"}))
          end)

        for revision <- (revision - 200)..revision do
          Updates.publish(game, session, :public, %{projection | state_revision: revision})
        end

        assert :ets.info(slot, :size) == 1
        assert {:message_queue_len, count} = Process.info(pid, :message_queue_len)
        assert count < 20
        client
      after
        :sys.resume(pid)
      end

    client =
      Enum.reduce(1..5, client, fn seq, client ->
        assert {%{"command_seq" => ^seq, "code" => "not_authorized"}, client} =
                 Client.receive_type(client, "command_result")

        client
      end)

    assert :atomics.get(delivery.counter, 2) == 0

    assert {:ok, _, client} =
             Client.receive_until(
               client,
               &match?(%{"type" => "heartbeat_request"}, &1),
               Client.now_ms() + 500
             )

    Client.close(client)
  end

  test "one bounded producer overflow retires the connection and stops admission" do
    fixture = Client.start()
    {client, welcome, _} = Client.connect(fixture)
    pid = Client.handler_pid(fixture, welcome)
    {delivery, _slot} = delivery(pid)

    :sys.suspend(pid)

    try do
      for _ <- 1..1_000, do: DeviceSocket.deliver(delivery, :probe)
      assert :atomics.get(delivery.counter, 1) == 32
      assert :atomics.get(delivery.counter, 2) == 1

      {:messages, messages} = Process.info(pid, :messages)
      assert Enum.count(messages, &match?({:vault_device_overflow, _}, &1)) == 1
      assert Enum.count(messages, &match?({:vault_device_delivery, _, _}, &1)) == 32
    after
      :sys.resume(pid)
    end

    assert {{:close, 1013, "slow_consumer"}, client} =
             Client.receive_message(client, &match?({:close, _, _}, &1))

    assert {:error, :backpressure} = DeviceSocket.deliver(delivery, :probe)
    Client.close(client)
    {reconnected, fresh, _} = Client.connect(fixture)
    assert fresh["connection_id"] != welcome["connection_id"]
    Client.close(reconnected)
  end

  test "Bandit times out a real WS write when its peer stops reading" do
    fixture = Client.start()

    {client, welcome, _} =
      Client.connect(fixture, nil, recbuf: 1_024, send_timeout: 100, send_timeout_close: true)

    pid = Client.handler_pid(fixture, welcome)
    id = {__MODULE__, make_ref()}
    events = [:thousand_island, :connection]
    test = self()
    counters = :atomics.new(2, signed: false)

    :ok =
      :telemetry.attach_many(
        id,
        [events ++ [:send], events ++ [:send_error], events ++ [:async_recv]],
        &__MODULE__.measure_write/4,
        {pid, test, counters}
      )

    try do
      monitor = Process.monitor(pid)
      started = Client.now_ms()
      payload = String.duplicate("p", 125)
      frame = Client.raw_frame(9, true, payload)
      socket = Mint.HTTP.get_socket(client.conn)

      # A controlled peer stops receiving, but can still send a bounded batch
      # of legal control frames to make the server send automatic pongs.
      frames = 16_000

      assert :gen_tcp.send(socket, List.duplicate(frame, frames)) in [
               :ok,
               {:error, :timeout},
               {:error, :closed}
             ]

      assert_receive {:peer_write_timeout, elapsed_us, bytes, writes},
                     1_000,
                     "WS pressure not observed after #{:atomics.get(counters, 1)} writes and #{:atomics.get(counters, 2)} bytes"

      assert elapsed_us in 50_000..500_000
      assert bytes in 1..2_100_000
      assert writes in 1..16_020
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 500
      cleanup_ms = Client.now_ms() - started
      assert cleanup_ms < 2_500

      if System.get_env("VAULT_TEST_TRANSPORT_EVIDENCE") == "true" do
        IO.puts(
          "Bandit WS send interval #{elapsed_us} us, #{writes} writes, #{bytes} bytes, handler stopped within #{cleanup_ms} ms"
        )
      end
    after
      :telemetry.detach(id)
      Client.close(client)
    end
  end

  def measure_write(event, %{data: data} = measurements, _, {pid, test, counters}) do
    if self() == pid do
      case {List.last(event), Map.get(measurements, :error)} do
        {:send, _} ->
          :atomics.add(counters, 1, 1)
          :atomics.add(counters, 2, IO.iodata_length(data))

        {:send_error, :timeout} ->
          if Process.get({__MODULE__, :last_activity}) do
            elapsed =
              System.monotonic_time(:microsecond) - Process.get({__MODULE__, :last_activity})

            send(
              test,
              {:peer_write_timeout, elapsed, :atomics.get(counters, 2), :atomics.get(counters, 1)}
            )
          end

        _ ->
          :ok
      end

      Process.put({__MODULE__, :last_activity}, System.monotonic_time(:microsecond))
    end
  end

  defp delivery(pid) do
    {_socket, %{connection: %{websock_state: %{delivery: delivery, slot: slot}}}} =
      :sys.get_state(pid)

    {delivery, slot}
  end
end
