defmodule Vault.ReconciliationTest do
  use ExUnit.Case, async: false

  alias Vault.StorageFixture

  @moduletag timeout: 30_000

  test "replace a sealed recovery, restart authority, and reseal in the committed current session" do
    root = StorageFixture.temp_root()
    assert {"ok\n", 0} = StorageFixture.task(root, "prepare")

    source = """
    Vault.Test.ReconciliationCases.replacement_and_reseal(root)
    IO.puts("reconciliation passed")
    """

    assert {"reconciliation passed\n", 0} = StorageFixture.vm(root, source)
  end

  test "failed Begin, expired Close evidence, and lost Close reply preserve local motion freeze" do
    root = StorageFixture.temp_root()
    assert {"ok\n", 0} = StorageFixture.task(root, "prepare")

    source = """
    Vault.Test.ReconciliationCases.administrative_write_boundaries(root)
    IO.puts("administrative faults passed")
    """

    assert {"administrative faults passed\n", 0} = StorageFixture.vm(root, source)
  end
end
