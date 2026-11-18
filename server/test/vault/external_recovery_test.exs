defmodule Vault.ExternalRecoveryTest do
  use ExUnit.Case, async: false

  alias Vault.StorageFixture

  @fixture Path.expand("../support/external_recovery_scenario.exs", __DIR__)
  @tools Path.expand("../../../tools/simulator/load.exs", __DIR__)
  @moduletag timeout: 30_000

  for outcome <- [:interrupted, :absent] do
    test "external box closes a literal #{outcome} release and starts a fresh round" do
      root = StorageFixture.temp_root()

      source = """
      {:ok, _} = Application.ensure_all_started(:crypto)
      {:ok, _} = Vault.Credentials.prepare_test(external_simulator: true)
      IO.puts("prepared")
      """

      assert {"prepared\n", 0} = StorageFixture.vm(root, source)
      outcome = unquote(outcome)

      scenario = """
      Code.require_file(#{inspect(@tools)})
      Code.require_file(#{inspect(@fixture)})
      Vault.Test.ExternalRecoveryScenario.run(root, #{inspect(outcome)})
      IO.puts("external recovery passed")
      """

      assert {"external recovery passed\n", 0} = StorageFixture.vm(root, scenario)
    end
  end

  # Four separate Mix/BEAM launches share this test budget. Individual
  # connection and write deadlines remain enforced by the simulator.
  @tag timeout: 60_000
  test "executable simulator connects from a separate no-start VM using provisioned files" do
    root = StorageFixture.temp_root()

    source = """
    {:ok, _} = Application.ensure_all_started(:crypto)
    {:ok, _} = Vault.Credentials.prepare_test(external_simulator: true)
    IO.puts("prepared")
    """

    assert {"prepared\n", 0} = StorageFixture.vm(root, source)

    scenario = """
    Code.require_file(#{inspect(@tools)})
    Code.require_file(#{inspect(@fixture)})
    Vault.Test.ExternalRecoveryScenario.cli(root)
    IO.puts("external executable passed")
    """

    assert {"external executable passed\n", 0} = StorageFixture.vm(root, scenario)
  end

  test "external executable refuses the internal deployment before opening its box store" do
    root = StorageFixture.temp_root()
    assert {"ok\n", 0} = StorageFixture.task(root, "prepare")

    scenario = """
    Code.require_file(#{inspect(@tools)})
    Code.require_file(#{inspect(@fixture)})
    Vault.Test.ExternalRecoveryScenario.refuse_internal_cli(root)
    IO.puts("internal box preserved")
    """

    assert {"internal box preserved\n", 0} = StorageFixture.vm(root, scenario)
  end
end
