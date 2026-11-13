defmodule Vault.Simulator.FaultTransport do
  @moduledoc "Bounded raw WS frames for isolated protocol tests."

  import Bitwise

  @timeout 1_000
  @header_cap 8_192

  def connect(%URI{scheme: "ws"} = uri, secret) do
    case :gen_tcp.connect(
           String.to_charlist(uri.host),
           uri.port,
           [:binary, active: false, send_timeout: 100],
           @timeout
         ) do
      {:ok, socket} ->
        case upgrade(socket, uri, secret) do
          :ok ->
            {:ok, socket}

          error ->
            :gen_tcp.close(socket)
            error
        end

      _ ->
        {:error, :connect_failed}
    end
  end

  def connect(_, _), do: {:error, :fault_transport_requires_loopback_ws}

  defp upgrade(socket, uri, secret) do
    nonce = Base.encode64(:crypto.strong_rand_bytes(16))
    accept = Base.encode64(:crypto.hash(:sha, nonce <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))

    request = [
      "GET ",
      uri.path,
      " HTTP/1.1\r\nHost: ",
      uri.host,
      ":",
      Integer.to_string(uri.port),
      "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13",
      "\r\nSec-WebSocket-Key: ",
      nonce,
      "\r\nAuthorization: Bearer ",
      secret,
      "\r\n\r\n"
    ]

    with :ok <- :gen_tcp.send(socket, request),
         {:ok, headers} <- read_header(socket, :gen_tcp),
         true <- String.starts_with?(headers, "HTTP/1.1 101 "),
         true <- Regex.match?(~r/\r\nsec-websocket-accept: [^\r]+/i, headers),
         [^accept] <-
           Regex.run(~r/\r\nsec-websocket-accept: ([^\r]+)/i, headers, capture: :all_but_first) do
      :ok
    else
      _ -> {:error, :upgrade_failed}
    end
  end

  def read_header(socket, transport),
    do: read_header(socket, transport, <<>>, now() + @timeout)

  defp read_header(socket, transport, acc, due) when byte_size(acc) < @header_cap do
    with remaining when remaining > 0 <- due - now(),
         {:ok, byte} <- transport.recv(socket, 1, remaining) do
      bytes = acc <> byte

      if String.ends_with?(bytes, "\r\n\r\n"),
        do: {:ok, bytes},
        else: read_header(socket, transport, bytes, due)
    else
      _ -> {:error, :header_incomplete}
    end
  end

  defp read_header(_, _, _, _), do: {:error, :header_limit}

  def frame(opcode, payload, opts \\ [])
      when opcode in 0..15 and is_binary(payload) and byte_size(payload) <= 8_193 do
    fin = if Keyword.get(opts, :fin, true), do: 1, else: 0
    masked = if Keyword.get(opts, :masked, true), do: 1, else: 0
    length = byte_size(payload)

    extension =
      if length <= 125, do: <<length::7>>, else: <<126::7, length::16>>

    if masked == 1 do
      mask = :crypto.strong_rand_bytes(4)

      <<fin::1, 0::3, opcode::4, masked::1, extension::bitstring, mask::binary,
        mask(payload, mask)::binary>>
    else
      <<fin::1, 0::3, opcode::4, masked::1, extension::bitstring, payload::binary>>
    end
  end

  def split_send(socket, bytes, stride)
      when is_binary(bytes) and byte_size(bytes) <= 8_256 and stride in 1..8_256,
      do: split_send(socket, bytes, stride, now() + @timeout)

  defp split_send(_socket, <<>>, _, _), do: :ok

  defp split_send(socket, bytes, stride, due) do
    count = min(byte_size(bytes), stride)
    <<part::binary-size(count), rest::binary>> = bytes

    with true <- now() < due,
         :ok <- :gen_tcp.send(socket, part) do
      split_send(socket, rest, stride, due)
    else
      _ -> {:error, :send_incomplete}
    end
  end

  def recv_frame(socket, transport, timeout \\ @timeout) when timeout in 1..2_000 do
    due = now() + timeout

    with {:ok, <<fin::1, 0::3, opcode::4, masked::1, length::7>>} <-
           recv_exact(socket, transport, 2, due),
         {:ok, length} <- length(socket, transport, length, due),
         {:ok, mask} <- recv_exact(socket, transport, masked * 4, due),
         {:ok, payload} <- recv_exact(socket, transport, length, due) do
      {:ok, {fin, opcode, mask(payload, mask)}}
    end
  end

  defp length(_, _, length, _) when length <= 125, do: {:ok, length}

  defp length(socket, transport, 126, due) do
    with {:ok, <<length::16>>} when length <= 8_192 <- recv_exact(socket, transport, 2, due),
         do: {:ok, length},
         else: (_ -> {:error, :frame_size})
  end

  defp length(_, _, _, _), do: {:error, :frame_size}

  defp recv_exact(_, _, 0, _), do: {:ok, <<>>}

  defp recv_exact(socket, transport, size, due) do
    remaining = due - now()
    if remaining > 0, do: transport.recv(socket, size, remaining), else: {:error, :timeout}
  end

  defp mask(payload, <<>>), do: payload

  defp mask(payload, key) do
    for {byte, index} <- Enum.with_index(:binary.bin_to_list(payload)), into: <<>> do
      <<bxor(byte, :binary.at(key, rem(index, 4)))>>
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
