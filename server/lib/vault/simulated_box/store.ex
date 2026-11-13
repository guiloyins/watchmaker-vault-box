defmodule Vault.SimulatedBox.Store do
  @moduledoc "Independent SQLite storage for one simulated box."

  alias Exqlite.Sqlite3
  alias Vault.JSON
  alias Vault.JSON.Number
  alias Vault.SimulatedBox.Model.{Durable, Persist, ReadExpectation}

  @max_integer 9_007_199_254_740_991
  @limits %{max_bytes: 524_288, max_depth: 12}
  @schema """
  CREATE TABLE box_state (
    singleton INTEGER PRIMARY KEY NOT NULL CHECK(typeof(singleton)='integer' AND singleton=1),
    schema_version INTEGER NOT NULL CHECK(typeof(schema_version)='integer' AND schema_version=1),
    instance_id TEXT NOT NULL UNIQUE CHECK(typeof(instance_id)='text' AND length(CAST(instance_id AS BLOB)) BETWEEN 1 AND 64 AND instr(instance_id,char(0))=0 AND instance_id NOT GLOB '*[^A-Za-z0-9_-]*'),
    device_id TEXT NOT NULL CHECK(typeof(device_id)='text' AND length(CAST(device_id AS BLOB)) BETWEEN 1 AND 64 AND instr(device_id,char(0))=0 AND device_id NOT GLOB '*[^A-Za-z0-9_-]*'),
    revision INTEGER NOT NULL CHECK(typeof(revision)='integer' AND revision BETWEEN 0 AND 9007199254740991),
    last_operation_id TEXT NOT NULL CHECK(typeof(last_operation_id)='text' AND length(CAST(last_operation_id AS BLOB)) BETWEEN 1 AND 64 AND instr(last_operation_id,char(0))=0 AND last_operation_id NOT GLOB '*[^A-Za-z0-9_-]*'),
    payload_sha256 BLOB NOT NULL CHECK(typeof(payload_sha256)='blob' AND length(payload_sha256)=32),
    payload_json TEXT NOT NULL CHECK(typeof(payload_json)='text' AND length(CAST(payload_json AS BLOB))<=524288)
  )
  """
  @schema String.trim(@schema)
  @select """
  SELECT singleton, schema_version, instance_id, device_id, revision, last_operation_id, payload_sha256, payload_json
  FROM box_state
  WHERE typeof(instance_id)='text' AND typeof(device_id)='text' AND typeof(last_operation_id)='text'
    AND typeof(payload_sha256)='blob' AND typeof(payload_json)='text'
    AND length(CAST(payload_json AS BLOB))<=524288
  LIMIT 2
  """

  @enforce_keys [:db, :config]
  defstruct @enforce_keys

  def config(instance_id, device_id) do
    %{
      instance_id: instance_id,
      device_id: device_id,
      step_interval_ms: 10,
      release_steps: 100,
      motion_timeout_ms: 8_000
    }
  end

  @doc "Creates a new file exclusively and closes its setup connection."
  def init_new(path, instance_id, device_id) do
    with true <- valid_identity?(instance_id, device_id),
         :ok <- reserve_file(path),
         {:ok, db} <- Sqlite3.open(path, mode: :readwrite) do
      try do
        handle = %__MODULE__{db: db, config: config(instance_id, device_id)}
        document = initial_document(instance_id, device_id)

        with :ok <- configure(db),
             :ok <- initialize(handle, document),
             :ok <- verify_schema(db),
             {:ok, ^document} <- load(handle) do
          :ok
        else
          _ -> {:error, :invalid_store}
        end
      after
        Sqlite3.close(db)
      end
    else
      false -> {:error, :invalid_store}
      {:error, :eexist} -> {:error, :already_exists}
      _ -> {:error, :unavailable}
    end
  end

  @doc "Opens and validates the expected existing store. Never creates a database."
  def open_existing(path, instance_id, device_id) do
    with true <- valid_identity?(instance_id, device_id),
         {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
         {:ok, db} <- Sqlite3.open(path, mode: :readwrite) do
      handle = %__MODULE__{db: db, config: config(instance_id, device_id)}

      with :ok <- configure(db),
           :ok <- verify_schema(db),
           {:ok, _} <- load(handle) do
        {:ok, handle}
      else
        {:error, code} ->
          Sqlite3.close(db)
          {:error, code}
      end
    else
      false -> {:error, :invalid_store}
      {:ok, _} -> {:error, :invalid_store}
      _ -> {:error, :unavailable}
    end
  end

  def close(%__MODULE__{db: db}), do: Sqlite3.close(db)

  @doc "Reads and validates the complete committed durable document."
  def load(%__MODULE__{} = handle) do
    case read_row(handle) do
      {:ok, document, _hash} -> {:ok, document}
      {:error, _} = error -> error
    end
  end

  @doc "Applies one typed mutation under an immediate, identity/hash-checked transaction."
  def commit(%__MODULE__{db: db, config: config} = handle, %Persist{} = persist) do
    with true <- valid_expectation?(persist, config),
         :ok <- Sqlite3.execute(db, "BEGIN IMMEDIATE") do
      case update(handle, persist) do
        :ok ->
          case Sqlite3.execute(db, "COMMIT") do
            :ok -> {:ok, persist.next_revision, persist.payload_sha256}
            {:error, _} -> uncertain_commit(db)
          end

        {:error, _} ->
          rollback(db)
      end
    else
      _ -> {:error, :rolled_back}
    end
  end

  def readback(%__MODULE__{config: config} = handle, %ReadExpectation{} = expectation) do
    with true <- valid_expectation?(expectation, config),
         {:ok, document, hash} <- read_row(handle) do
      revision = document["store_revision"]
      operation = document["last_operation_id"]

      cond do
        revision == expectation.next_revision and hash == expectation.payload_sha256 and
            operation == expectation.operation_id ->
          {:committed, revision, hash, document}

        revision == expectation.base_revision and hash == expectation.expected_sha256 ->
          {:not_committed, revision, hash}

        true ->
          {:error, :conflict}
      end
    else
      false -> {:error, :conflict}
      {:error, code} -> {:error, code}
    end
  end

  defp valid_identity?(instance, device), do: Durable.id?(instance) and Durable.id?(device)

  defp valid_expectation?(expectation, config) do
    expectation.instance_id == config.instance_id and Durable.id?(expectation.operation_id) and
      Durable.nonnegative?(expectation.base_revision) and
      Durable.positive?(expectation.next_revision) and
      expectation.next_revision == expectation.base_revision + 1 and
      match?(<<_::256>>, expectation.expected_sha256) and
      match?(<<_::256>>, expectation.payload_sha256)
  end

  defp reserve_file(path) do
    with {:ok, file} <- File.open(path, [:write, :exclusive]) do
      try do
        File.chmod(path, 0o600)
      after
        File.close(file)
      end
    end
  end

  defp configure(db) do
    settings = [
      {"busy_timeout", "100", 100},
      {"journal_mode", "WAL", "wal"},
      {"synchronous", "FULL", 2},
      {"foreign_keys", "ON", 1}
    ]

    Enum.reduce_while(settings, :ok, fn {key, value, expected}, :ok ->
      with :ok <- Sqlite3.execute(db, "PRAGMA #{key}=#{value}"),
           {:ok, [[^expected]]} <- query(db, "PRAGMA #{key}") do
        {:cont, :ok}
      else
        _ -> {:halt, {:error, :invalid_store}}
      end
    end)
  end

  defp initialize(%__MODULE__{db: db}, document) do
    with {:ok, payload, hash} <- encode(document),
         :ok <- Sqlite3.execute(db, "BEGIN IMMEDIATE"),
         :ok <- Sqlite3.execute(db, @schema),
         :ok <- Sqlite3.execute(db, "PRAGMA user_version=1"),
         :ok <-
           execute(db, "INSERT INTO box_state VALUES (1,1,?,?,0,?,?,?)", [
             document["instance_id"],
             document["device_id"],
             document["last_operation_id"],
             {:blob, hash},
             payload
           ]),
         :ok <- Sqlite3.execute(db, "COMMIT") do
      :ok
    else
      _ ->
        Sqlite3.execute(db, "ROLLBACK")
        {:error, :invalid_store}
    end
  end

  defp verify_schema(db) do
    with {:ok, [[1]]} <- query(db, "PRAGMA user_version"),
         {:ok, [["ok"]]} <- query(db, "PRAGMA integrity_check"),
         {:ok, [["table", "box_state", @schema]]} <-
           query(db, "SELECT type,name,sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'") do
      :ok
    else
      _ -> {:error, :invalid_store}
    end
  end

  defp read_row(%__MODULE__{db: db, config: config}) do
    with {:ok, [[1, 1, instance, device, revision, operation, <<_::256>> = hash, payload]]} <-
           query(db, @select),
         true <- instance == config.instance_id and device == config.device_id,
         true <- is_binary(payload) and hash == :crypto.hash(:sha256, payload),
         {:ok, decoded} <- JSON.decode_object(payload, @limits),
         {:ok, document} <- normalize(decoded),
         {:ok, ^payload} <- JSON.canonical(document),
         true <-
           document["store_revision"] == revision and document["last_operation_id"] == operation,
         :ok <- Durable.validate(document, config) do
      {:ok, document, hash}
    else
      {:error, :unavailable} -> {:error, :unavailable}
      _ -> {:error, :invalid_store}
    end
  end

  defp update(%__MODULE__{db: db, config: config} = handle, persist) do
    with {:ok, base, hash} <- read_row(handle),
         true <-
           base["store_revision"] == persist.base_revision and hash == persist.expected_sha256,
         {:ok, operation, next} <- Durable.advance(base, persist.patch, config),
         true <-
           operation == persist.operation_id and next["store_revision"] == persist.next_revision,
         {:ok, payload, hash} <- encode(next),
         true <- hash == persist.payload_sha256,
         :ok <-
           execute(
             db,
             """
             UPDATE box_state SET revision=?, last_operation_id=?, payload_sha256=?, payload_json=?
             WHERE instance_id=? AND revision=? AND payload_sha256=?
             """,
             [
               persist.next_revision,
               operation,
               {:blob, hash},
               payload,
               persist.instance_id,
               persist.base_revision,
               {:blob, persist.expected_sha256}
             ]
           ),
         {:ok, 1} <- Sqlite3.changes(db) do
      :ok
    else
      _ -> {:error, :conflict}
    end
  end

  defp rollback(db) do
    case Sqlite3.execute(db, "ROLLBACK") do
      :ok -> {:error, :rolled_back}
      {:error, _} -> {:error, :unknown}
    end
  end

  defp uncertain_commit(db) do
    # A returned COMMIT error can mean SQLite already ended the transaction.
    # Only a successful rollback while it is still open proves no commit.
    case Sqlite3.transaction_status(db) do
      {:ok, :transaction} -> rollback(db)
      _ -> {:error, :unknown}
    end
  end

  defp encode(document) do
    with {:ok, payload} <- JSON.canonical(document) do
      {:ok, payload, :crypto.hash(:sha256, payload)}
    end
  end

  defp normalize({:json_number, _} = value), do: Number.integer(value, 0, @max_integer)

  defp normalize(value) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, element}, {:ok, acc} ->
      case normalize(element) do
        {:ok, normalized} -> {:cont, {:ok, Map.put(acc, key, normalized)}}
        error -> {:halt, error}
      end
    end)
  end

  defp normalize(value) when is_list(value) do
    value
    |> Enum.reduce_while({:ok, []}, fn element, {:ok, acc} ->
      case normalize(element) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp normalize(value), do: {:ok, value}

  defp execute(db, sql, args) do
    statement(db, sql, args, fn statement ->
      case Sqlite3.step(db, statement) do
        :done -> :ok
        _ -> {:error, :unavailable}
      end
    end)
  end

  defp query(db, sql) do
    statement(db, sql, [], fn statement -> rows(db, statement, []) end)
  end

  defp rows(db, statement, acc) do
    case Sqlite3.step(db, statement) do
      {:row, row} -> rows(db, statement, [row | acc])
      :done -> {:ok, Enum.reverse(acc)}
      _ -> {:error, :unavailable}
    end
  end

  defp statement(db, sql, args, callback) do
    with {:ok, statement} <- Sqlite3.prepare(db, sql) do
      try do
        with :ok <- Sqlite3.bind(statement, args) do
          callback.(statement)
        else
          _ -> {:error, :unavailable}
        end
      after
        Sqlite3.release(db, statement)
      end
    else
      _ -> {:error, :unavailable}
    end
  end

  defp initial_document(instance_id, device_id) do
    %{
      "schema_version" => 1,
      "instance_id" => instance_id,
      "device_id" => device_id,
      "store_revision" => 0,
      "last_operation_id" => "init",
      "journal" => [],
      "service" => %{
        "storage_version" => 1,
        "service_revision" => 0,
        "service_epoch" => 1,
        "service_inhibited" => true,
        "motion_frozen" => true,
        "entry_operation_id" => nil,
        "preparation_operation_id" => nil,
        "exit_operation_id" => nil,
        "stop_reason" => nil,
        "active_local_record_id" => nil,
        "clear_operation_id" => nil,
        "provisioning_operation_id" => nil,
        "provisioning_reboot_required" => false,
        "inflight_motion" => nil
      },
      "reconciliations" => [],
      "absent_reconciliation" => nil,
      "clear_authorization" => nil,
      "service_receipts" => [],
      "simulator_configuration" => %{
        "schema_version" => 1,
        "calibration_revision" => 0,
        "calibration" => nil
      }
    }
  end
end
