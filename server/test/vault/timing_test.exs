defmodule Vault.TimingTest do
  use ExUnit.Case, async: false

  alias Vault.StorageFixture
  alias Vault.Test.TimingCases

  @moduletag timeout: 30_000
  @fixtures Path.expand("../../../contracts/fixtures/timing-cases.json", __DIR__)

  test "the unchanged timing fixture names all exercised domain scenarios" do
    cases = @fixtures |> File.read!() |> Jason.decode!() |> Map.fetch!("cases")
    assert Enum.map(cases, &Map.fetch!(&1, "id")) == TimingCases.fixture_cases()
  end

  for name <- TimingCases.fixture_cases() ++ ["heartbeat_presentation"] do
    test "authoritative timing: #{name}" do
      root = StorageFixture.temp_root()
      assert {"ok\n", 0} = StorageFixture.task(root, "prepare")
      name = unquote(name)

      source = """
      Vault.Test.TimingCases.run(root, :#{name})
      IO.puts("timing passed")
      """

      assert {"timing passed\n", 0} = StorageFixture.vm(root, source)
    end
  end
end
