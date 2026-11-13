defmodule VaultWeb.DeviceBoxStatusTest do
  use ExUnit.Case, async: true

  @moduletag :m2

  test "external box status receipts, replay conflicts, recovery query floor and simulation truthfulness" do
    root = Vault.StorageFixture.temp_root()

    assert {"raw box status checks passed\n", 0} =
             Vault.StorageFixture.vm(root, "Vault.Test.DeviceBoxStatus.exercise(root)")
  end
end
