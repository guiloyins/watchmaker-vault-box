defmodule Vault.Test.SimulatorFixture do
  @moduledoc false
  @compile {:no_warn_undefined, Vault.Simulator.FaultTransport}

  import ExUnit.Assertions
  alias Vault.{Credentials, MaintenanceGuard, Protocol}

  @tool_root Path.expand("../../../tools/simulator", __DIR__)
  @guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  def load_tools do
    :global.trans({{__MODULE__, :load_tools}, self()}, fn ->
      unless Code.ensure_loaded?(Vault.Simulator.Client),
        do: Code.require_file("load.exs", @tool_root)
    end)
  end

  def root do
    path = Path.join(System.tmp_dir!(), "vault-simulator-" <> Credentials.id())
    File.mkdir!(path)
    File.chmod!(path, 0o700)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  def credentials(root) do
    path = Path.join(root, "sim.key")
    secret = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    :ok = MaintenanceGuard.write_protected(path, secret <> "\n")
    path
  end

  def tls(root) do
    ca_key = Path.join(root, "test-ca.key")
    ca_pem = Path.join(root, "test-ca.pem")
    server_key = Path.join(root, "test-server.key")
    csr = Path.join(root, "test-server.csr")
    cert = Path.join(root, "test-server.pem")
    ext = Path.join(root, "extensions.conf")
    File.write!(ext, "subjectAltName=DNS:localhost\nextendedKeyUsage=serverAuth\n")

    openssl!([
      "req",
      "-new",
      "-x509",
      "-newkey",
      "rsa:2048",
      "-nodes",
      "-days",
      "1",
      "-subj",
      "/CN=Local Vault simulator test CA",
      "-keyout",
      ca_key,
      "-out",
      ca_pem
    ])

    openssl!([
      "req",
      "-new",
      "-newkey",
      "rsa:2048",
      "-nodes",
      "-subj",
      "/CN=localhost",
      "-keyout",
      server_key,
      "-out",
      csr
    ])

    openssl!([
      "x509",
      "-req",
      "-in",
      csr,
      "-CA",
      ca_pem,
      "-CAkey",
      ca_key,
      "-CAcreateserial",
      "-days",
      "1",
      "-out",
      cert,
      "-extfile",
      ext
    ])

    [{:Certificate, ca, :not_encrypted}] = :public_key.pem_decode(File.read!(ca_pem))
    %{cert: cert, key: server_key, ca: ca}
  end

  defp openssl!(args) do
    case System.cmd("openssl", args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      _ -> flunk("could not build ephemeral TLS fixture")
    end
  end

  def peer(scheme, opts \\ []) do
    parent = self()

    pid =
      spawn(fn ->
        run_peer(parent, scheme, opts)
      end)

    ExUnit.Callbacks.on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    assert_receive {:peer_ready, ^pid, port}, 2_000
    host = Keyword.get(opts, :hostname, if(scheme == "wss", do: "localhost", else: "127.0.0.1"))
    %{pid: pid, uri: URI.parse("#{scheme}://#{host}:#{port}/device/v1")}
  end

  defp run_peer(parent, scheme, opts) do
    {transport, listener, port} = listen(scheme, opts)
    send(parent, {:peer_ready, self(), port})

    case accept(transport, listener) do
      {:ok, socket} ->
        peer_request(parent, transport, socket, opts)
        transport.close(socket)

      {:error, reason} ->
        send(parent, {:peer_accept_error, self(), reason})
    end

    transport.close(listener)
  end

  defp listen("ws", opts) do
    {:ok, listener} = :gen_tcp.listen(0, socket_opts(opts))
    {:ok, port} = :inet.port(listener)
    {:gen_tcp, listener, port}
  end

  defp listen("wss", opts) do
    tls = Keyword.fetch!(opts, :tls)

    socket =
      socket_opts(opts) ++
        [certfile: String.to_charlist(tls.cert), keyfile: String.to_charlist(tls.key)]

    {:ok, listener} = :ssl.listen(0, socket)
    {:ok, {_, port}} = :ssl.sockname(listener)
    {:ssl, listener, port}
  end

  defp socket_opts(opts) do
    [
      :binary,
      ip: {127, 0, 0, 1},
      active: false,
      packet: :raw,
      reuseaddr: true,
      send_timeout: 100,
      recbuf: Keyword.get(opts, :recbuf, 4_096)
    ]
  end

  defp accept(:gen_tcp, listener), do: :gen_tcp.accept(listener, 4_000)

  defp accept(:ssl, listener) do
    with {:ok, socket} <- :ssl.transport_accept(listener, 4_000),
         do: :ssl.handshake(socket, 1_000)
  end

  defp peer_request(parent, transport, socket, opts) do
    with {:ok, request} <- fault().read_header(socket, transport),
         [nonce] <-
           Regex.run(~r/\r\nsec-websocket-key: ([^\r]+)/i, request, capture: :all_but_first) do
      accept = Base.encode64(:crypto.hash(:sha, nonce <> @guid))
      greeting = if opts[:coalesced], do: raw_frame(9, "upgrade"), else: <<>>

      response =
        if opts[:reject] do
          "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n"
        else
          [
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade",
            "\r\nSec-WebSocket-Accept: ",
            accept,
            "\r\n\r\n",
            greeting
          ]
        end

      :ok = transport.send(socket, response)
      unless opts[:reject], do: peer_loop(parent, transport, socket)
    end
  end

  defp peer_loop(parent, transport, socket) do
    receive do
      {:peer_send, ref, bytes} ->
        send(parent, {:peer_sent, ref, transport.send(socket, bytes)})
        peer_loop(parent, transport, socket)

      {:peer_recv, ref, timeout} ->
        send(parent, {:peer_received, ref, fault().recv_frame(socket, transport, timeout)})
        peer_loop(parent, transport, socket)

      {:peer_stop, ref} ->
        send(parent, {:peer_stopped, ref})
    after
      6_000 -> :ok
    end
  end

  def recv(peer, timeout \\ 800) do
    ref = make_ref()
    send(peer.pid, {:peer_recv, ref, timeout})
    assert_receive {:peer_received, ^ref, result}, timeout + 300
    result
  end

  def send_bytes(peer, bytes) do
    ref = make_ref()
    send(peer.pid, {:peer_send, ref, bytes})
    assert_receive {:peer_sent, ^ref, :ok}, 1_000
    :ok
  end

  def send_message(peer, message) do
    {:ok, bytes} = Protocol.encode(message, :server_to_device)
    send_bytes(peer, raw_frame(1, bytes))
  end

  def raw_frame(op, bytes, opts \\ []),
    do: fault().frame(op, bytes, Keyword.put(opts, :masked, false))

  def stop(peer) do
    ref = make_ref()
    send(peer.pid, {:peer_stop, ref})
    assert_receive {:peer_stopped, ^ref}, 1_000
  end

  def welcome(overrides \\ %{}) do
    Map.merge(
      %{
        "v" => 1,
        "type" => "welcome",
        "connection_id" => "conn_1",
        "session_id" => "original",
        "round_id" => 1,
        "puzzle_revision" => 1,
        "required_roles" => ["a", "b"],
        "assigned_role" => nil,
        "heartbeat_interval_ms" => 100,
        "input_lease_ms" => 400,
        "peer_dead_ms" => 1_500,
        "allowed_roles" => ["a"]
      },
      overrides
    )
  end

  def challenge(seq, conn \\ "conn_1"),
    do: %{
      "v" => 1,
      "type" => "heartbeat_request",
      "connection_id" => conn,
      "heartbeat_seq" => seq
    }

  def receive_message(peer) do
    assert {:ok, {1, 1, bytes}} = recv(peer)
    assert {:ok, %{message: message}} = Protocol.decode(bytes, :device_to_server)
    {message, bytes}
  end

  defp fault, do: Vault.Simulator.FaultTransport
end
