import Config

config :phoenix, :json_library, Jason

config :vault,
  ecto_repos: [Vault.Repo],
  environment: config_env(),
  box_mode: :simulated,
  bind: {127, 0, 0, 1},
  port: 4000

config :vault, VaultWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [html: VaultWeb.ErrorHTML, json: VaultWeb.ErrorJSON], layout: false],
  pubsub_server: Vault.PubSub,
  live_view: [signing_salt: "vault-liveview-v1"],
  server: false

config :phoenix, :filter_parameters, [
  "key",
  "token",
  "password",
  "secret",
  "credential",
  "authorization"
]

config :esbuild,
  version: "0.25.12",
  vault: [
    args:
      ~w(js/app.js css/app.css --bundle --target=es2022 --entry-names=[name] --outdir=../priv/static/assets --external:/fonts/* --external:/images/* --metafile=../_build/assets-meta.json),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

import_config "#{config_env()}.exs"
