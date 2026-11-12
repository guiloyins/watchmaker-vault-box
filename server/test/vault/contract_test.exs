defmodule Vault.ContractTest do
  use ExUnit.Case, async: false
  @moduletag :m0
  @root Path.expand("../../..", __DIR__)
  @types ~w(hello welcome command command_result snapshot heartbeat_request heartbeat heartbeat_ack box_arm box_disarm box_command box_query box_status box_status_ack box_feedback)

  # Registered while test files load, before any selected test executes.
  initial_apps = Application.started_applications() |> Enum.map(&elem(&1, 0)) |> MapSet.new()

  ExUnit.after_suite(fn _ ->
    final_apps = Application.started_applications() |> Enum.map(&elem(&1, 0)) |> MapSet.new()
    if final_apps != initial_apps, do: raise("M0 changed the started application set")

    resources =
      Process.registered()
      |> Enum.filter(fn name -> String.starts_with?(Atom.to_string(name), "Elixir.Vault") end)

    if resources != [], do: raise("M0 left a named Vault runtime resource running")
    IO.puts("M0 runtime guard passed: started applications unchanged; no named Vault resources.")
  end)

  test "authoritative schema and fixtures are copied exactly" do
    for {source, copy} <- [
          {"docs/specs/contracts/protocol-v1.schema.json", "contracts/protocol-v1.schema.json"},
          {"docs/specs/fixtures/protocol-examples.json",
           "contracts/fixtures/protocol-examples.json"},
          {"docs/specs/fixtures/timing-cases.json", "contracts/fixtures/timing-cases.json"},
          {"docs/specs/fixtures/maze-v1.private.json", "server/priv/puzzles/maze-v1.private.json"}
        ] do
      assert File.read!(Path.join(@root, source)) == File.read!(Path.join(@root, copy))
    end
  end

  test "source example metadata covers every v1 type with unique identifiers" do
    schema = source("contracts/protocol-v1.schema.json")
    examples = source("contracts/fixtures/protocol-examples.json")
    assert schema["$schema"] == "https://json-schema.org/draft/2020-12/schema"
    assert schema["$id"] == "urn:watchmakers-vault:protocol:v1"
    assert {:ok, 1} = Vault.JSON.Number.integer(examples["protocol_version"], 1, 1)
    assert length(examples["valid_examples"]) == 51
    assert length(examples["invalid_examples"]) == 15
    cases = examples["valid_examples"] ++ examples["invalid_examples"]
    names = Enum.map(cases, & &1["name"])
    assert length(names) == MapSet.size(MapSet.new(names))
    assert Enum.all?(names, &(is_binary(&1) and byte_size(&1) > 0))
    actual = MapSet.new(examples["valid_examples"], & &1["message"]["type"])
    assert actual == MapSet.new(@types)
  end

  test "timing fixtures remain named source vectors without invoking future providers" do
    timing = source("contracts/fixtures/timing-cases.json")
    assert timing["time_unit"] == "milliseconds"
    assert length(timing["cases"]) == 10
    ids = Enum.map(timing["cases"], & &1["id"])
    assert Enum.all?(ids, &(is_binary(&1) and byte_size(&1) > 0))
    assert length(ids) == MapSet.size(MapSet.new(ids))
  end

  test "no application, persistent store or endpoint is started by the pure checkpoint" do
    apps = Application.started_applications() |> Enum.map(&elem(&1, 0))
    for app <- [:vault, :phoenix, :ecto_sql, :exqlite, :mint], do: refute(app in apps)
    assert Application.get_env(:vault, :database) == nil
    assert Application.get_env(:vault, :simulator_database) == nil
    refute File.exists?(Path.join(@root, "data"))
    refute File.exists?(Path.join(@root, "server/priv/static/maze-v1.private.json"))
  end

  defp source(path) do
    {:ok, value} =
      Vault.JSON.decode(File.read!(Path.join(@root, path)), %{max_bytes: 262_144, max_depth: 64})

    value
  end
end
