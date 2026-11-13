defmodule VaultWeb.Router do
  use VaultWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {VaultWeb.Layouts, :root}
    plug :protect_from_forgery

    plug :put_secure_browser_headers, %{
      "cache-control" => "no-store",
      "referrer-policy" => "no-referrer",
      "x-frame-options" => "DENY"
    }
  end

  pipeline :host do
    plug VaultWeb.Auth, :host
  end

  pipeline :player do
    plug VaultWeb.Auth, :player
  end

  scope "/", VaultWeb do
    get "/health", HealthController, :show, log: false
  end

  scope "/", VaultWeb do
    pipe_through :browser

    get "/", SessionController, :host
    get "/login", SessionController, :host
    post "/login", SessionController, :exchange_host, log: false
    get "/join", SessionController, :player
    post "/join", SessionController, :exchange_player, log: false
    post "/logout", SessionController, :logout, log: false
  end

  scope "/", VaultWeb do
    pipe_through [:browser, :host]

    live_session :vault_host, on_mount: [{VaultWeb.Auth, :host}] do
      live "/games/:id/host", HostLive, :show
    end
  end

  scope "/", VaultWeb do
    pipe_through [:browser, :player]

    live_session :vault_player, on_mount: [{VaultWeb.Auth, :player}] do
      live "/games/:id/play/:role", PlayerLive, :show
    end
  end
end
