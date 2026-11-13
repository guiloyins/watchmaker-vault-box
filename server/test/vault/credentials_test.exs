defmodule Vault.CredentialsTest do
  use ExUnit.Case, async: false

  alias Vault.{Auth, Credentials, MaintenanceGuard, StorageFixture}

  @tag timeout: 45_000
  test "offline rotation protects output first, preserves other scopes and supports safe readback" do
    root = StorageFixture.temp_root()
    assert {"ok\n", 0} = StorageFixture.task(root, "prepare")

    original = Path.join(root, "host.key")
    player_a = Path.join(root, "player-a.key")
    player_b = Path.join(root, "player-b.key")
    new = Path.join(root, "new-host.key")
    device = Path.join(root, "device.key")
    orphan = Path.join(root, "orphan.key")
    link = Path.join(root, "symlink.key")
    assert {"epoch=1 active=true\n", 0} = StorageFixture.task(root, "status", [original])
    assert {"ok\n", 0} = StorageFixture.task(root, "device", [device])
    snapshots = Map.new([original, player_a, player_b, device], &{&1, File.read!(&1)})

    assert :ok = MaintenanceGuard.write_protected(orphan, Credentials.key() <> "\n")
    assert {"epoch=1 active=false\n", 0} = StorageFixture.task(root, "status", [orphan])
    File.ln_s!(original, link)
    assert {"error=output_exists\n", 1} = StorageFixture.task(root, "rotate", [link])
    assert {"error=output_exists\n", 1} = StorageFixture.task(root, "rotate", [original])

    assert {"error=invalid_output_path\n", 1} =
             StorageFixture.task(root, "rotate", [Path.join([root, "missing", "key"])])

    assert {"epoch=1 active=true\n", 0} = StorageFixture.task(root, "status", [original])

    assert {:ok, guard} = MaintenanceGuard.acquire(root)
    assert {"error=guard_owned\n", 1} = StorageFixture.task(root, "rotate", [new])
    refute File.exists?(new)
    assert :ok = MaintenanceGuard.release(guard)

    assert {"ok\n", 0} = StorageFixture.task(root, "stop")
    assert {"ok\n", 0} = StorageFixture.task(root, "rotate", [new])
    assert {"epoch=2 active=false\n", 0} = StorageFixture.task(root, "status", [original])
    assert {"epoch=2 active=true\n", 0} = StorageFixture.task(root, "status", [new])
    assert {"epoch=2 active=false\n", 0} = StorageFixture.task(root, "status", [orphan])
    assert {"ok\n", 0} = StorageFixture.task(root, "init")
    Enum.each(snapshots, fn {path, contents} -> assert File.read!(path) == contents end)
    assert :ok = MaintenanceGuard.protected_file(new)

    checks = """
    {:ok, _} = Application.ensure_all_started(:ecto_sqlite3)
    {:ok, _} = Vault.Repo.start_link(Vault.Repo.options(Path.join(root, "vault.sqlite3")))
    {:ok, _} = Vault.Auth.start_link([])
    read = fn file -> {:ok, token} = Vault.Credentials.read_key(Path.join(root, file)); token end
    {:error, :not_authorized} = Vault.Auth.exchange(:host, read.("host.key"))
    {:ok, host} = Vault.Auth.exchange(:host, read.("new-host.key"))
    {:ok, a} = Vault.Auth.exchange(:player, read.("player-a.key"))
    {:ok, b} = Vault.Auth.exchange(:player, read.("player-b.key"))
    2 = host.auth_epoch
    [:a] = a.allowed_roles
    [:b] = b.allowed_roles
    {:ok, <<device_token::binary-size(64), "\n">>} =
      Vault.MaintenanceGuard.read_protected(Path.join(root, "device.key"), 65)
    {:ok, dev} = Vault.Auth.authenticate_device("fixture_cyd", device_token, a.game_id)
    [:b] = dev.allowed_roles
    IO.puts("ok")
    """

    assert {"ok\n", 0} = StorageFixture.vm(root, checks)
  end

  test "browser sessions enforce role, epoch, expiry, logout and bounded login attempts" do
    root = StorageFixture.temp_root()
    assert {"ok\n", 0} = StorageFixture.task(root, "prepare")

    checks = """
    {:ok, _} = Application.ensure_all_started(:ecto_sqlite3)
    {:ok, _} = Vault.Repo.start_link(Vault.Repo.options(Path.join(root, "vault.sqlite3")))
    {:ok, auth} = Vault.Auth.start_link([])
    {:ok, host_key} = Vault.Credentials.read_key(Path.join(root, "host.key"))
    {:ok, player_key} = Vault.Credentials.read_key(Path.join(root, "player-a.key"))
    {:ok, host} = Vault.Auth.exchange(:host, host_key, {127,0,0,2})
    {:ok, player} = Vault.Auth.exchange(:player, player_key, {127,0,0,3})
    true = Vault.Auth.valid?(host)
    true = Vault.Auth.valid?(player)
    false = Vault.Auth.valid?(%{player | allowed_roles: [:b]})
    false = Vault.Auth.valid?(%{host | expires_at_ms: 0})
    {:error, :not_authorized} = Vault.Auth.exchange(:host, player_key, {127,0,0,4})
    {:error, :not_authorized} = Vault.Auth.exchange(:player, host_key, {127,0,0,4})
    {:ok, ^host} = Vault.Auth.from_session(Vault.Auth.to_session(host))
    :ok = Vault.Auth.logout(host)
    {:error, :not_authorized} = Vault.Auth.from_session(Vault.Auth.to_session(host))
    true = Vault.Auth.valid?(player)
    for _ <- 1..8, do: {:error, :not_authorized} = Vault.Auth.exchange(:host, "invalid", {127,0,0,9})
    {:error, :not_authorized} = Vault.Auth.exchange(:host, host_key, {127,0,0,9})
    {:ok, next_host} = Vault.Auth.exchange(:host, host_key, {127,0,0,10})
    {:ok, _} = Ecto.Adapters.SQL.query(Vault.Repo, "UPDATE browser_credentials SET auth_epoch=2 WHERE kind='host'")
    false = Vault.Auth.valid?(next_host)
    true = Vault.Auth.valid?(player)
    :ok = GenServer.stop(auth)
    {:error, :not_authorized} = Vault.Auth.from_session(Vault.Auth.to_session(player))
    IO.puts("ok")
    """

    assert {"ok\n", 0} = StorageFixture.vm(root, checks)

    refute Auth.valid?(%{})
  end

  @tag timeout: 30_000
  test "writer contention leaves a durable inactive key and losing the task reply requires readback" do
    root = StorageFixture.temp_root()
    assert {"ok\n", 0} = StorageFixture.task(root, "prepare")
    previous = Path.join(root, "host.key")
    orphan = Path.join(root, "failed-activation.key")
    replacement = Path.join(root, "committed-without-reply.key")

    {:ok, _} = Application.ensure_all_started(:exqlite)
    {:ok, locker} = Exqlite.Sqlite3.open(Path.join(root, "vault.sqlite3"), mode: :readwrite)

    try do
      assert :ok = Exqlite.Sqlite3.execute(locker, "BEGIN IMMEDIATE")
      assert {"error=readback_required\n", 1} = StorageFixture.task(root, "rotate", [orphan])
      assert :ok = MaintenanceGuard.protected_file(orphan)
    after
      Exqlite.Sqlite3.execute(locker, "ROLLBACK")
      Exqlite.Sqlite3.close(locker)
    end

    assert {"epoch=1 active=false\n", 0} = StorageFixture.task(root, "status", [orphan])
    assert {"epoch=1 active=true\n", 0} = StorageFixture.task(root, "status", [previous])

    no_reply = """
    [output] = System.argv()
    :ok = Vault.Credentials.rotate_host(output)
    System.halt(75)
    """

    assert {"", 75} = StorageFixture.vm(root, no_reply, [replacement])
    assert {"epoch=2 active=true\n", 0} = StorageFixture.task(root, "status", [replacement])
    assert {"epoch=2 active=false\n", 0} = StorageFixture.task(root, "status", [previous])
    assert {"epoch=2 active=false\n", 0} = StorageFixture.task(root, "status", [orphan])
    assert {"error=output_exists\n", 1} = StorageFixture.task(root, "rotate", [replacement])
  end

  test "missing durable files never produce fresh setup credentials or history" do
    root = StorageFixture.temp_root()
    assert {"ok\n", 0} = StorageFixture.task(root, "prepare")
    database = Path.join(root, "vault.sqlite3")
    File.rm!(database)
    assert {"error=invalid_deployment\n", 1} = StorageFixture.task(root, "init")
    refute File.exists?(database)
    File.rm!(Path.join(root, "deployment.json"))
    assert {"error=partial_or_existing_setup\n", 1} = StorageFixture.task(root, "init")
    refute File.exists?(database)
  end
end
