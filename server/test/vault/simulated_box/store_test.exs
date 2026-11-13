defmodule Vault.SimulatedBox.StoreTest do
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias Vault.JSON
  alias Vault.SimulatedBox.Model.{Durable, Persist, ReadExpectation}
  alias Vault.SimulatedBox.Store

  @moduletag :m1
  @instance "store_instance"
  @device "store_box"

  setup do
    directory = Path.join(System.tmp_dir!(), "box_store_#{System.unique_integer([:positive])}")
    File.mkdir!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{path: Path.join(directory, "box.sqlite3")}
  end

  test "explicit setup is exclusive and opening missing, corrupt or unsupported stores fails closed",
       %{path: path} do
    assert {:error, :unavailable} = Store.open_existing(path, @instance, @device)
    refute File.exists?(path)
    assert :ok = Store.init_new(path, @instance, @device)
    assert {:error, :already_exists} = Store.init_new(path, @instance, @device)
    assert {:error, :invalid_store} = Store.open_existing(path, "wrong_instance", @device)
    assert {:error, :invalid_store} = Store.open_existing(path, @instance, "wrong_device")

    inspect_db(path, fn db ->
      assert :ok = Sqlite3.execute(db, "PRAGMA user_version=2")
    end)

    assert {:error, :invalid_store} = Store.open_existing(path, @instance, @device)

    inspect_db(path, fn db ->
      assert :ok = Sqlite3.execute(db, "PRAGMA user_version=1")
      assert :ok = Sqlite3.execute(db, "UPDATE box_state SET payload_sha256=zeroblob(32)")
    end)

    assert {:error, :invalid_store} = Store.open_existing(path, @instance, @device)
    assert {:error, :already_exists} = Store.init_new(path, @instance, @device)
  end

  test "schema has verified runtime PRAGMAs and SQLite rejects invalid types and sizes", %{
    path: path
  } do
    assert :ok = Store.init_new(path, @instance, @device)
    {:ok, handle} = Store.open_existing(path, @instance, @device)
    on_exit(fn -> Store.close(handle) end)
    assert [["wal"]] = rows(handle.db, "PRAGMA journal_mode")
    assert [[2]] = rows(handle.db, "PRAGMA synchronous")
    assert [[1]] = rows(handle.db, "PRAGMA foreign_keys")
    assert [[100]] = rows(handle.db, "PRAGMA busy_timeout")
    assert [[1]] = rows(handle.db, "PRAGMA user_version")

    assert [[1, 1, @instance, @device, 0, "init", 32, "blob", "text"]] =
             rows(handle.db, """
             SELECT singleton,schema_version,instance_id,device_id,revision,last_operation_id,
                    length(payload_sha256),typeof(payload_sha256),typeof(payload_json)
             FROM box_state
             """)

    for statement <- [
          "UPDATE box_state SET instance_id='bad!'",
          "UPDATE box_state SET device_id=''",
          "UPDATE box_state SET revision=9007199254740992",
          "UPDATE box_state SET revision=1.5",
          "UPDATE box_state SET schema_version=2",
          "UPDATE box_state SET last_operation_id='x'||char(0)",
          "UPDATE box_state SET payload_sha256='abcdefghijklmnopqrstuvwxyz012345'",
          "UPDATE box_state SET payload_json=zeroblob(1)",
          "UPDATE box_state SET payload_json=printf('%0524289d',0)"
        ] do
      assert {:error, _} = Sqlite3.execute(handle.db, statement)
    end

    assert {:ok, %{"store_revision" => 0, "journal" => []}} = Store.load(handle)
  end

  test "readback distinguishes lost reply, unchanged base, stale CAS and incompatible history", %{
    path: path
  } do
    :ok = Store.init_new(path, @instance, @device)
    {:ok, first} = Store.open_existing(path, @instance, @device)
    {:ok, competing} = Store.open_existing(path, @instance, @device)

    try do
      {:ok, base} = Store.load(first)
      {persist, expectation} = mutation(base, accept_patch("one"))
      {other, other_expectation} = mutation(base, accept_patch("other"))

      assert {:not_committed, 0, base_hash} = Store.readback(competing, expectation)
      assert base_hash == expectation.expected_sha256
      assert {:error, :rolled_back} = Store.commit(first, %{persist | payload_sha256: <<0::256>>})
      assert {:not_committed, 0, ^base_hash} = Store.readback(competing, expectation)

      assert {:ok, 1, committed_hash} = Store.commit(first, persist)
      assert {:error, :rolled_back} = Store.commit(competing, other)
      assert {:error, :conflict} = Store.readback(competing, other_expectation)
      assert {:committed, 1, ^committed_hash, committed} = Store.readback(competing, expectation)
      assert [%{"command_id" => "one"}] = committed["journal"]

      assert :ok = Store.close(first)
      {:ok, reloaded} = Store.open_existing(path, @instance, @device)
      assert {:committed, 1, ^committed_hash, ^committed} = Store.readback(reloaded, expectation)

      {next, _} = mutation(committed, accept_patch("next"))
      assert {:ok, 2, _} = Store.commit(reloaded, next)
      assert {:error, :conflict} = Store.readback(competing, expectation)
      assert :ok = Store.close(reloaded)
    after
      Store.close(first)
      Store.close(competing)
    end
  end

  test "box open rejects a correctly hashed noncanonical, incomplete or over-deep durable payload",
       %{path: path} do
    :ok = Store.init_new(path, @instance, @device)
    {:ok, handle} = Store.open_existing(path, @instance, @device)
    {:ok, document} = Store.load(handle)
    :ok = Store.close(handle)
    {:ok, payload} = JSON.canonical(document)
    {:ok, missing} = JSON.canonical(Map.delete(document, "clear_authorization"))
    nested = Enum.reduce(1..14, nil, fn _, acc -> [acc] end)
    {:ok, deep} = JSON.canonical(Map.put(document, "clear_authorization", nested))

    for corrupt <- [payload <> " ", missing, deep] do
      inspect_db(path, fn db ->
        {:ok, update} =
          Sqlite3.prepare(db, "UPDATE box_state SET payload_json=?,payload_sha256=?")

        :ok = Sqlite3.bind(update, [corrupt, {:blob, :crypto.hash(:sha256, corrupt)}])
        :done = Sqlite3.step(db, update)
        :ok = Sqlite3.release(db, update)
      end)

      assert {:error, :invalid_store} = Store.open_existing(path, @instance, @device)
    end
  end

  defp accept_patch(command) do
    %{
      "kind" => "accept",
      "entry" => %{
        "schema_version" => 1,
        "command_id" => command,
        "fingerprint" => %{
          "session_id" => "session",
          "action" => "set_latch",
          "target" => "released"
        },
        "reserved_arm_id" => "arm",
        "accepted_boot_id" => "boot",
        "accept_operation_id" => "outcome_#{command}",
        "outcomes" => [
          %{
            "kind" => "accepted",
            "failure_code" => nil,
            "boot_id" => "boot",
            "operation_id" => "outcome_#{command}"
          }
        ],
        "conflicted" => false
      }
    }
  end

  defp mutation(base, patch) do
    {:ok, operation, next} = Durable.advance(base, patch, Store.config(@instance, @device))
    {:ok, base_hash} = Durable.hash(base)
    {:ok, next_hash} = Durable.hash(next)

    expectation = %ReadExpectation{
      instance_id: @instance,
      operation_id: operation,
      base_revision: base["store_revision"],
      next_revision: next["store_revision"],
      expected_sha256: base_hash,
      payload_sha256: next_hash
    }

    persist =
      struct!(
        Persist,
        Map.merge(Map.from_struct(expectation), %{
          effect_generation: 1,
          motion_generation: 1,
          purpose: :accept,
          patch: patch
        })
      )

    {persist, expectation}
  end

  defp inspect_db(path, fun) do
    {:ok, db} = Sqlite3.open(path, mode: :readwrite)

    try do
      fun.(db)
    after
      Sqlite3.close(db)
    end
  end

  defp rows(db, sql) do
    {:ok, statement} = Sqlite3.prepare(db, sql)

    try do
      {:ok, rows} = Sqlite3.fetch_all(db, statement)
      rows
    after
      Sqlite3.release(db, statement)
    end
  end
end
