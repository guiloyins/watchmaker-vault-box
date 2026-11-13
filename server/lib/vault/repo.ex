defmodule Vault.Repo do
  use Ecto.Repo, otp_app: :vault, adapter: Ecto.Adapters.SQLite3

  def options(database) do
    [
      database: database,
      mode: :readwrite,
      pool_size: 1,
      journal_mode: :wal,
      synchronous: :full,
      foreign_keys: :on,
      busy_timeout: 100,
      default_transaction_mode: :immediate,
      after_connect: {__MODULE__, :verify_connection, []},
      log: false,
      show_sensitive_data_on_connection_error: false
    ]
  end

  def verify_connection(conn) do
    # Exqlite's NIF timeout uses a private busy handler and reads as zero in
    # PRAGMA. Set SQLite's native timeout here so the effective value is
    # independently observable on each pooled connection.
    Exqlite.query!(conn, "PRAGMA busy_timeout = 100")

    Enum.each(
      [{"journal_mode", "wal"}, {"synchronous", 2}, {"foreign_keys", 1}, {"busy_timeout", 100}],
      fn {pragma, value} ->
        case Exqlite.query(conn, "PRAGMA " <> pragma) do
          {:ok, %{rows: [[^value]]}} -> :ok
          _ -> raise "Vault SQLite connection settings failed verification"
        end
      end
    )
  end
end
