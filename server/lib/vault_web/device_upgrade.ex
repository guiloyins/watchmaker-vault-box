defmodule VaultWeb.DeviceUpgrade do
  @moduledoc false
  @behaviour Plug

  import Plug.Conn
  alias Vault.{Auth, Protocol}
  alias VaultWeb.DeviceSocket

  @impl true
  def init(:upgrade), do: :upgrade

  @impl true
  def call(conn, :upgrade) do
    with [<<"Bearer ", token::binary-size(64)>>] <- get_req_header(conn, "authorization"),
         {:ok, registration} <- Auth.authenticate_device(token) do
      conn = delete_req_header(conn, "authorization")

      if secure_transport?(conn),
        do: upgrade(conn, registration),
        else: conn |> send_resp(403, "Secure device transport required") |> halt()
    else
      _ ->
        conn
        |> delete_req_header("authorization")
        |> put_resp_header("www-authenticate", "Bearer")
        |> send_resp(401, "Unauthorized")
        |> halt()
    end
  end

  defp upgrade(conn, registration) do
    limit = Protocol.byte_limit(:device_to_server)

    conn
    |> WebSockAdapter.upgrade(DeviceSocket, registration,
      compress: false,
      # Bandit's frame cap includes the two header bytes, length and masking key.
      max_frame_size: limit + 8,
      max_fragmented_message_size: limit,
      log_protocol_errors: false,
      timeout: 5_500
    )
    |> halt()
  rescue
    WebSockAdapter.UpgradeError -> conn |> send_resp(400, "Invalid WebSocket upgrade") |> halt()
  end

  defp secure_transport?(%{scheme: :https}), do: true

  defp secure_transport?(%{remote_ip: remote_ip}) do
    Application.get_env(:vault, :environment) in [:dev, :test] and
      (loopback?(remote_ip) or Application.get_env(:vault, :trusted_lan_ws, false))
  end

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_), do: false
end
