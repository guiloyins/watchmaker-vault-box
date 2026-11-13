defmodule VaultWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :vault

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [
      connect_info: [session: {__MODULE__, :session_options, []}],
      max_frame_size: 16_384,
      log: false
    ],
    longpoll: false

  @static_options Plug.Static.init(at: "/", from: :vault, gzip: false)
  @asset_pattern ~r/\Aapp(?:-[a-f0-9]{32})?\.(?:css|js)(?:\.map)?\z/

  plug :serve_assets
  plug Plug.RequestId

  plug Plug.Parsers,
    parsers: [:urlencoded],
    length: 2_048,
    read_length: 2_048,
    read_timeout: 2_000

  plug :browser_session
  plug VaultWeb.Router

  defp serve_assets(%Plug.Conn{path_info: ["assets", name]} = conn, _opts) do
    if Regex.match?(@asset_pattern, name), do: Plug.Static.call(conn, @static_options), else: conn
  end

  defp serve_assets(conn, _opts), do: conn

  def session_options do
    secure? =
      :vault
      |> Application.get_env(:origin, "http://localhost:4000")
      |> URI.parse()
      |> Map.get(:scheme) == "https"

    [
      store: :cookie,
      key: "_watchmakers_vault",
      signing_salt: "vault-browser-signing-v1",
      encryption_salt: "vault-browser-encryption-v1",
      same_site: "Lax",
      http_only: true,
      secure: secure?
    ]
  end

  defp browser_session(conn, _opts),
    do: Plug.Session.call(conn, Plug.Session.init(session_options()))
end
