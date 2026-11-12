# Dependency/toolchain probe in its own VM; this is not an application store test.
alias Exqlite.Sqlite3
{:ok, _} = Application.ensure_all_started(:exqlite)
root = Path.join(System.tmp_dir!(), "vault-sqlite-probe-#{System.unique_integer([:positive])}")
File.mkdir_p!(root)

try do
  {:ok, db} = Sqlite3.open(Path.join(root, "probe.sqlite3"))

  try do
    :ok = Sqlite3.execute(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=100;")
    query = fn sql ->
      {:ok, statement} = Sqlite3.prepare(db, sql)
      {:ok, rows} = Sqlite3.fetch_all(db, statement)
      :ok = Sqlite3.release(db, statement)
      rows
    end

    values = %{
      sqlite_version: query.("SELECT sqlite_version()"),
      journal_mode: query.("PRAGMA journal_mode"),
      synchronous: query.("PRAGMA synchronous"),
      foreign_keys: query.("PRAGMA foreign_keys"),
      busy_timeout: query.("PRAGMA busy_timeout")
    }

    %{journal_mode: [["wal"]], synchronous: [[2]], foreign_keys: [[1]], busy_timeout: [[100]]} = values
    :ok = Sqlite3.execute(db, "CREATE TABLE probe(id INTEGER PRIMARY KEY, value TEXT NOT NULL); BEGIN IMMEDIATE; INSERT INTO probe VALUES(1, 'committed'); COMMIT;")
    [["committed"]] = query.("SELECT value FROM probe WHERE id=1")
    IO.puts(Jason.encode!(%{result: "passed", evidence: "dependency probe only", values: values}))
  after
    :ok = Sqlite3.close(db)
  end
after
  File.rm_rf!(root)
end
