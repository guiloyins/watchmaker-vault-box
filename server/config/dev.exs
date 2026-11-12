import Config

config :vault,
  data_dir: Path.expand("../../data", __DIR__),
  database: Path.expand("../../data/vault.sqlite3", __DIR__),
  simulator_database: Path.expand("../../data/simulated-box.sqlite3", __DIR__),
  asset_watcher_args: ["--sourcemap", "--watch"]
