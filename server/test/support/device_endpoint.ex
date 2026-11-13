defmodule Vault.Test.DeviceEndpoint do
  @moduledoc false

  import ExUnit.Assertions
  import Bitwise

  alias Mint.{HTTP, WebSocket}
  alias Vault.{Controllers, Credentials, Games, Repo}
  alias Vault.GameStore.Device

  def start do
    listener =
      ExUnit.Callbacks.start_supervised!(
        {Bandit,
         plug: VaultWeb.Endpoint,
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false,
         http_2_options: [enabled: false],
         thousand_island_options: [
           silent_terminate_on_error: true,
           transport_options: [send_timeout: 100, send_timeout_close: true, sndbuf: 1_024]
         ]}
      )

    assert {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(listener)

    device_id = Controllers.id("test_cyd")
    secret = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    now = Credentials.audit_ms()

    assert {:ok, _} =
             Repo.insert(%Device{
               device_id: device_id,
               device_class: "controller",
               transport: "raw",
               credential_sha256: Credentials.digest(secret),
               allowed_roles_mask: 1,
               enabled: true,
               capabilities_json: "{}",
               created_at_ms: now,
               updated_at_ms: now
             })

    ExUnit.Callbacks.on_exit(fn ->
      if record = Repo.get(Device, device_id), do: Repo.delete!(record)
    end)

    {:ok, game_id} = Games.active_id()
    %{port: port, device_id: device_id, secret: secret, game_id: game_id}
  end

  def hello(fixture, overrides \\ %{}) do
    Map.merge(
      %{
        "v" => 1,
        "type" => "hello",
        "device_id" => fixture.device_id,
        "device_class" => "controller",
        "boot_id" => Controllers.id("test_boot"),
        "firmware_version" => "test",
        "capabilities" => %{
          "touch" => true,
          "screen_width" => 240,
          "screen_height" => 320,
          "max_message_bytes" => 8192
        }
      },
      overrides
    )
  end

  def command(welcome, seq, action, payload \\ %{}) do
    welcome
    |> Map.take(~w(connection_id session_id))
    |> Map.merge(%{
      "v" => 1,
      "type" => "command",
      "command_seq" => seq,
      "action" => action,
      "payload" => payload
    })
  end

  def mint_open(fixture, headers \\ [], transport_opts \\ []) do
    {:ok, conn} =
      HTTP.connect(:http, "127.0.0.1", fixture.port,
        mode: :passive,
        protocols: [:http1],
        transport_opts: transport_opts
      )

    {:ok, conn, ref} = WebSocket.upgrade(:ws, conn, "/device/v1", headers)
    {conn, status, response_headers} = upgrade_response(conn, ref, nil, [])

    if status == 101 do
      {:ok, conn, websocket} = WebSocket.new(conn, ref, status, response_headers, mode: :passive)
      {:ok, %{conn: conn, websocket: websocket, ref: ref, pending: []}}
    else
      HTTP.close(conn)
      {:error, status, response_headers}
    end
  end

  def connect(fixture, hello \\ nil, transport_opts \\ []) do
    {:ok, client} = mint_open(fixture, bearer(fixture), transport_opts)
    client = send_json(client, hello || hello(fixture))
    {welcome, client} = receive_type(client, "welcome")
    {snapshot, client} = receive_type(client, "snapshot")
    {client, welcome, snapshot}
  end

  def bearer(fixture), do: [{"authorization", "Bearer " <> fixture.secret}]

  def send_json(client, map), do: send_frame(client, {:text, Jason.encode!(map)})

  def send_frame(client, frame) do
    {:ok, websocket, bytes} = WebSocket.encode(client.websocket, frame)
    {:ok, conn} = WebSocket.stream_request_body(client.conn, client.ref, bytes)
    %{client | conn: conn, websocket: websocket}
  end

  def close(client), do: HTTP.close(client.conn)

  def receive_type(client, type, timeout \\ 1_000) do
    receive_message(client, &match?(%{"type" => ^type}, &1), timeout)
  end

  def receive_message(client, predicate, timeout \\ 1_000) do
    case receive_until(client, predicate, now_ms() + timeout) do
      {:ok, message, client} -> {message, client}
      {:error, reason, _} -> flunk("device response missing (#{reason})")
    end
  end

  def receive_until(client, predicate, deadline) do
    case next(client, deadline) do
      {:ok, frame, client} ->
        message = decode_frame(frame)

        if predicate.(message),
          do: {:ok, message, client},
          else: receive_until(client, predicate, deadline)

      {:error, _, _} = error ->
        error
    end
  end

  def now_ms, do: System.monotonic_time(:millisecond)

  def raw_open(fixture) do
    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, fixture.port, [:binary, active: false, nodelay: true])

    key = Base.encode64(:crypto.strong_rand_bytes(16))

    :ok =
      :gen_tcp.send(socket, [
        "GET /device/v1 HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n",
        "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: ",
        key,
        "\r\nAuthorization: Bearer ",
        fixture.secret,
        "\r\n\r\n"
      ])

    assert String.starts_with?(raw_headers(socket, ""), "HTTP/1.1 101 ")
    socket
  end

  # This helper is reserved for exact wire boundaries Mint cannot construct.
  def raw_frame(opcode, final?, bytes) do
    length = byte_size(bytes)
    final = if final?, do: 1, else: 0
    <<mask::32>> = mask_bytes = :crypto.strong_rand_bytes(4)
    masked = mask_bytes(bytes, mask_bytes, mask)

    header =
      if length <= 125,
        do: <<final::1, 0::3, opcode::4, 1::1, length::7>>,
        else: <<final::1, 0::3, opcode::4, 1::1, 126::7, length::16>>

    [header, mask_bytes, masked]
  end

  def raw_receive(socket, opcode, timeout \\ 1_000),
    do: raw_receive_until(socket, opcode, now_ms() + timeout)

  def handler_pid(fixture, welcome) do
    {:ok, session} = Games.ensure(fixture.game_id)
    connection = welcome["connection_id"]

    :sys.get_state(session).actors
    |> Map.values()
    |> Enum.find_value(fn binding ->
      if binding.actor.connection_id == connection, do: binding.actor.owner_pid
    end)
  end

  defp upgrade_response(conn, ref, status, headers) do
    {:ok, conn, responses} = HTTP.recv(conn, 0, 1_000)

    {status, headers, done?} =
      Enum.reduce(responses, {status, headers, false}, fn
        {:status, ^ref, code}, {_, headers, done?} -> {code, headers, done?}
        {:headers, ^ref, fields}, {status, headers, done?} -> {status, headers ++ fields, done?}
        {:done, ^ref}, {status, headers, _} -> {status, headers, true}
        _, acc -> acc
      end)

    if done?, do: {conn, status, headers}, else: upgrade_response(conn, ref, status, headers)
  end

  defp next(%{pending: [frame | pending]} = client, _deadline),
    do: {:ok, frame, %{client | pending: pending}}

  defp next(client, deadline) do
    timeout = deadline - now_ms()

    if timeout > 0 do
      case WebSocket.recv(client.conn, 0, timeout) do
        {:ok, conn, [{:data, _, data}]} ->
          {:ok, websocket, pending} = WebSocket.decode(client.websocket, data)
          next(%{client | conn: conn, websocket: websocket, pending: pending}, deadline)

        {:error, conn, reason, _} ->
          {:error, reason, %{client | conn: conn}}
      end
    else
      {:error, :timeout, client}
    end
  end

  defp decode_frame({:text, bytes}) do
    assert byte_size(bytes) <= Vault.Protocol.byte_limit(:server_to_device)
    assert {:ok, %{message: message}} = Vault.Protocol.decode(bytes, :server_to_device)
    message
  end

  defp decode_frame(other), do: other

  defp raw_headers(socket, acc) do
    if String.ends_with?(acc, "\r\n\r\n") do
      acc
    else
      {:ok, byte} = :gen_tcp.recv(socket, 1, 1_000)
      raw_headers(socket, acc <> byte)
    end
  end

  defp raw_receive_until(socket, opcode, deadline) do
    timeout = max(1, deadline - now_ms())
    {:ok, <<1::1, 0::3, received::4, 0::1, length::7>>} = :gen_tcp.recv(socket, 2, timeout)

    length =
      if length == 126 do
        {:ok, <<extended::16>>} = :gen_tcp.recv(socket, 2, timeout)
        extended
      else
        length
      end

    payload = if length == 0, do: <<>>, else: elem(:gen_tcp.recv(socket, length, timeout), 1)
    if received == opcode, do: payload, else: raw_receive_until(socket, opcode, deadline)
  end

  defp mask_bytes(<<>>, _, _), do: []

  defp mask_bytes(<<word::32, rest::binary>>, mask_bytes, mask),
    do: [<<bxor(word, mask)::32>> | mask_bytes(rest, mask_bytes, mask)]

  defp mask_bytes(bytes, mask_bytes, _) do
    bytes
    |> :binary.bin_to_list()
    |> Enum.zip(:binary.bin_to_list(mask_bytes))
    |> Enum.map(fn {value, mask} -> bxor(value, mask) end)
  end
end
