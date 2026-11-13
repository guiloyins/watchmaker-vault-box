defmodule Vault.Simulator.MintTransport do
  @moduledoc false

  alias Mint.{HTTP, WebSocket}
  alias Vault.Simulator.FrameLimits

  defstruct [:conn, :ref, :websocket, :status, :headers, :upgrade_data, limits: %FrameLimits{}]

  def connect(opts) do
    uri = Keyword.fetch!(opts, :uri)
    scheme = if uri.scheme == "wss", do: :https, else: :http

    socket_opts =
      Keyword.merge(Keyword.get(opts, :socket_opts, []),
        timeout: 1_000,
        send_timeout: 100,
        send_timeout_close: false
      )

    socket_opts =
      if scheme == :https do
        socket_opts = Keyword.put(socket_opts, :verify, :verify_peer)

        case opts[:cacerts] do
          nil -> socket_opts
          certs -> Keyword.put(socket_opts, :cacerts, certs)
        end
      else
        socket_opts
      end

    case HTTP.connect(scheme, uri.host, uri.port,
           mode: :active,
           protocols: [:http1],
           transport_opts: socket_opts
         ) do
      {:ok, conn} -> {:ok, %__MODULE__{conn: conn}}
      {:error, _} -> {:error, :connect_failed}
    end
  end

  def write(%__MODULE__{conn: conn} = state, {:upgrade, uri, credential}) do
    scheme = if uri.scheme == "wss", do: :wss, else: :ws

    case WebSocket.upgrade(scheme, conn, uri.path, [{"authorization", "Bearer " <> credential}]) do
      {:ok, next, ref} -> {:ok, %{state | conn: next, ref: ref}}
      {:error, next, error} -> {:error, %{state | conn: next}, send_error(error)}
    end
  end

  def write(%__MODULE__{} = state, frame) do
    with {:ok, websocket, data} <- WebSocket.encode(state.websocket, frame),
         {:ok, conn} <- WebSocket.stream_request_body(state.conn, state.ref, data) do
      {:ok, %{state | websocket: websocket, conn: conn}}
    else
      {:error, %Mint.WebSocket{} = websocket, _} ->
        {:error, %{state | websocket: websocket}, :encode_failed}

      {:error, conn, error} ->
        {:error, %{state | conn: conn}, send_error(error)}
    end
  end

  defp send_error(%Mint.TransportError{reason: reason}) when reason in [:timeout, :etimedout],
    do: :socket_timeout

  defp send_error(_), do: :write_failed

  def stream(state, event) do
    case WebSocket.stream(state.conn, event) do
      {:ok, conn, responses} -> responses(%{state | conn: conn}, responses, [])
      {:error, conn, _error, _responses} -> {:error, %{state | conn: conn}, :transport_closed}
      :unknown -> {:ok, state, []}
    end
  end

  defp responses(state, [], acc), do: {:ok, state, Enum.reverse(acc)}

  defp responses(%{ref: ref} = state, [{:status, ref, status} | rest], acc),
    do: responses(%{state | status: status}, rest, acc)

  defp responses(%{ref: ref} = state, [{:headers, ref, headers} | rest], acc),
    do: responses(%{state | headers: headers}, rest, acc)

  defp responses(
         %{ref: ref, status: 101, websocket: nil, upgrade_data: nil} = state,
         [{:data, ref, data} | rest],
         acc
       )
       when byte_size(data) <= 65_536 do
    responses(%{state | upgrade_data: data}, rest, acc)
  end

  defp responses(%{ref: ref, status: 101, headers: headers} = state, [{:done, ref} | rest], acc) do
    with true <- valid_upgrade?(headers),
         {:ok, conn, ws} <- WebSocket.new(state.conn, ref, 101, headers, mode: :active) do
      next = %{state | conn: conn, websocket: ws, headers: nil, upgrade_data: nil}
      rest = if state.upgrade_data, do: [{:data, ref, state.upgrade_data} | rest], else: rest
      responses(next, rest, [:upgraded | acc])
    else
      _ -> {:error, state, :upgrade_rejected}
    end
  end

  defp responses(%{ref: ref} = state, [{:done, ref} | _], _),
    do: {:error, state, :upgrade_rejected}

  defp responses(%{ref: ref, websocket: ws} = state, [{:data, ref, data} | rest], acc)
       when not is_nil(ws) do
    with {:ok, limits} <- FrameLimits.scan(state.limits, data),
         {:ok, websocket, frames} <- WebSocket.decode(ws, data),
         true <- Enum.all?(frames, &valid_frame?/1) do
      responses(%{state | websocket: websocket, limits: limits}, rest, Enum.reverse(frames, acc))
    else
      _ -> {:error, state, :invalid_frame}
    end
  end

  defp responses(%{ref: ref} = state, [{:data, ref, _} | _], _),
    do: {:error, state, :upgrade_rejected}

  defp responses(state, _, _), do: {:error, state, :unexpected_response}

  defp valid_upgrade?(headers) do
    values = fn header ->
      for {^header, value} <- headers,
          part <- String.split(String.downcase(value), ","),
          do: String.trim(part)
    end

    values.("upgrade") == ["websocket"] and "upgrade" in values.("connection") and
      values.("sec-websocket-extensions") == [] and values.("sec-websocket-protocol") == []
  end

  defp valid_frame?({:text, _}), do: true
  defp valid_frame?({:ping, _}), do: true
  defp valid_frame?({:pong, _}), do: true
  defp valid_frame?({:close, _, _}), do: true
  defp valid_frame?(_), do: false

  def socket_options(%{conn: conn}, scheme) do
    socket = HTTP.get_socket(conn)

    if scheme == "wss",
      do: :ssl.getopts(socket, [:send_timeout, :sndbuf]),
      else: :inet.getopts(socket, [:send_timeout, :sndbuf])
  end

  def close(%__MODULE__{conn: conn}), do: HTTP.close(conn)
end
