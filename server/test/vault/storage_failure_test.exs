defmodule Vault.StorageFailureTest do
  use ExUnit.Case, async: false

  alias Vault.StorageFixture

  @moduletag timeout: 30_000

  test "a real SQLite writer lock fails a host pause within the lease and preserves committed state" do
    root = prepare()

    source = """
    Vault.Test.FailingStore.lock_rejects_pause(root)
    """

    assert {result, 0} = StorageFixture.vm(root, source)
    assert Regex.match?(~r/server SQLite lock error in \d+ ms/, result)
    IO.write(result)
  end

  test "checkpoint write failure rolls back a proposed win, leaving no intent or motor output" do
    root = prepare()

    source = """
    Vault.Test.FailingStore.checkpoint_write_rejects_win(root)
    IO.puts("write fault passed")
    """

    assert {"write fault passed\n", 0} = StorageFixture.vm(root, source)
  end

  defp prepare do
    root = StorageFixture.temp_root()
    assert {"ok\n", 0} = StorageFixture.task(root, "prepare")
    root
  end
end
