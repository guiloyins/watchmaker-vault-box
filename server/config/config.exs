import Config

config :phoenix, :json_library, Jason

config :vault,
  box_mode: :simulated,
  bind: {127, 0, 0, 1},
  port: 4000

# Entries are implemented in M1. No setup/build alias invokes missing sources.
config :esbuild,
  version: "0.25.12",
  vault: [
    args:
      ~w(js/app.js css/app.css --bundle --target=es2022 --outdir=../priv/static/assets --external:/fonts/* --external:/images/* --metafile=../priv/static/assets/meta.json),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

import_config "#{config_env()}.exs"
