import Config

# Environment parsing only. No files, network, guards or applications start here.
mode =
  case System.get_env("VAULT_BOX_MODE", "simulated") do
    "simulated" -> :simulated
    "physical" -> :physical
    _ -> :invalid
  end

bind =
  case :inet.parse_address(String.to_charlist(System.get_env("VAULT_BIND", "127.0.0.1"))) do
    {:ok, address} -> address
    {:error, _} -> :invalid
  end

port =
  case Integer.parse(System.get_env("VAULT_PORT", "4000")) do
    {value, ""} when value in 1..65_535 -> value
    _ -> :invalid
  end

default_root = if config_env() == :test, do: nil, else: Path.expand("../../data", __DIR__)
root = System.get_env("VAULT_DATA_DIR", default_root)

config :vault,
  box_mode: mode,
  bind: bind,
  port: port,
  origin: System.get_env("VAULT_ORIGIN", "http://localhost:4000"),
  data_dir: root,
  database: System.get_env("VAULT_DATABASE", root && Path.join(root, "vault.sqlite3")),
  simulator_database:
    System.get_env("VAULT_SIMULATOR_DATABASE", root && Path.join(root, "simulated-box.sqlite3")),
  host_key_file: System.get_env("VAULT_HOST_KEY_FILE"),
  secret_key_base_file: System.get_env("VAULT_SECRET_KEY_BASE_FILE"),
  test_root: System.get_env("VAULT_TEST_ROOT")
