defmodule VaultWeb.DeviceBoxStatusTest do
  use ExUnit.Case, async: true

  @moduletag :m2

  test "external box status receipts, replay conflicts, recovery query floor and simulation truthfulness" do
    root = Vault.StorageFixture.temp_root()

    assert {"raw box status checks passed\n", 0} =
             Vault.StorageFixture.vm(root, "Vault.Test.DeviceBoxStatus.exercise(root)")
  end

  test "physical host recovery stays actionable after a late terminal report" do
    root = Vault.StorageFixture.temp_root()

    assert {"physical recovery checks passed\n", 0} =
             Vault.StorageFixture.vm(root, "Vault.Test.DeviceBoxStatus.physical_recovery(root)")
  end

  test "a physical box reconnects when its confirmed release becomes uncertain" do
    root = Vault.StorageFixture.temp_root()

    assert {"physical reconnect checks passed\n", 0} =
             Vault.StorageFixture.vm(root, "Vault.Test.DeviceBoxStatus.physical_reconnect(root)")
  end
end
