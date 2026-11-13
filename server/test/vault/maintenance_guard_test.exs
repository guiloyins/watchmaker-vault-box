defmodule Vault.MaintenanceGuardTest do
  use ExUnit.Case, async: false

  alias Vault.{MaintenanceGuard, StorageFixture}

  @tag timeout: 30_000
  test "an independent VM blocks tasks until it closes the guard, including through a symlink" do
    root = StorageFixture.temp_root()
    alias_root = root <> "-alias"
    File.ln_s!(root, alias_root)
    on_exit(fn -> File.rm(alias_root) end)

    owner = """
    {:ok, guard} = Vault.MaintenanceGuard.acquire(root)
    IO.puts("held")
    "stop\n" = IO.gets("")
    :ok = Vault.MaintenanceGuard.release(guard)
    IO.puts("released")
    """

    {executable, arguments, env} = StorageFixture.command(root, owner)

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        args: arguments,
        env:
          Enum.map(env, fn {key, value} ->
            {String.to_charlist(key), String.to_charlist(value)}
          end)
      ])

    assert_receive {^port, {:data, "held\n"}}, 10_000
    assert {:error, :guard_owned} = MaintenanceGuard.acquire(alias_root)
    assert {"error=guard_owned\n", 1} = StorageFixture.task(root, "prepare")
    refute File.exists?(Path.join(root, "host.key"))
    Port.command(port, "stop\n")
    assert_receive {^port, {:data, "released\n"}}, 10_000
    assert_receive {^port, {:exit_status, 0}}, 10_000
    assert {:ok, acquired} = MaintenanceGuard.acquire(alias_root)
    assert {:ok, canonical} = MaintenanceGuard.owned_directory(root)
    assert acquired.path == Path.join(canonical, "vault.owner")
    assert :ok = MaintenanceGuard.release(acquired)
  end

  test "crashed and partial owners block until explicit offline removal" do
    root = StorageFixture.temp_root()

    source = """
    {:ok, _} = Vault.MaintenanceGuard.acquire(root)
    System.halt(3)
    """

    assert {"", 3} = StorageFixture.vm(root, source)
    marker = Path.join(root, "vault.owner")
    assert {:error, :guard_owned} = MaintenanceGuard.acquire(root)
    File.rm!(marker)
    File.write!(marker, "")
    File.chmod!(marker, 0o600)
    assert {:error, :guard_owned} = MaintenanceGuard.acquire(root)
    assert {"error=guard_owned\n", 1} = StorageFixture.task(root, "prepare")
    File.rm!(marker)
    assert {:ok, guard} = MaintenanceGuard.acquire(root)
    File.rm!(marker)
    File.write!(marker, "different owner\n")
    File.chmod!(marker, 0o600)
    assert {:error, :guard_cleanup_failed} = MaintenanceGuard.release(guard)
    assert File.read!(marker) == "different owner\n"
  end

  test "protected file creation rejects existing output, symlinks and unowned permissions" do
    root = StorageFixture.temp_root()
    path = Path.join(root, "protected.key")
    link = Path.join(root, "link.key")
    assert :ok = MaintenanceGuard.write_protected(path, "original")
    File.ln_s!(path, link)
    assert {:error, :output_exists} = MaintenanceGuard.write_protected(path, "replacement")
    assert {:error, :output_exists} = MaintenanceGuard.write_protected(link, "replacement")
    assert {:error, :protected_file_unreadable} = MaintenanceGuard.read_protected(link, 32)
    assert {:ok, "original"} = MaintenanceGuard.read_protected(path, 32)
    File.chmod!(path, 0o644)
    assert {:error, :protected_file_unreadable} = MaintenanceGuard.read_protected(path, 32)
    File.chmod!(root, 0o755)
    assert {:error, :guard_unavailable} = MaintenanceGuard.acquire(root)
  end
end
