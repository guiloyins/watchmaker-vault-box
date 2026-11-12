import Config

# Pure M0 loads configuration without opening resources or requiring a test root.
# M1 admission, not runtime.exs, checks the wrapper-owned preparation marker.
config :vault,
  data_dir: nil,
  database: nil,
  simulator_database: nil,
  test_root: nil

config :logger, level: :warning
