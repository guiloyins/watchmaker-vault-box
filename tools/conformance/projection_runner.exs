alias Vault.{GameStore.Checkpoint, Projections, Puzzle}
{:ok, fixture} = File.read!(Application.app_dir(:vault, "priv/puzzles/maze-v1.private.json"))
  |> Vault.JSON.decode(%{max_bytes: 262_144, max_depth: 64})
{:ok, puzzle} = Puzzle.from_fixture(fixture)
base = Puzzle.initial_state(puzzle)
cases = for phase <- [:lobby, :maze, :seal, :solved], paused <- [false, true], role <- [:a, :b] do
  paused = paused and phase != :solved
  rules = %{base | phase: phase, position: if(phase in [:seal, :solved], do: 3, else: 12),
    paused: paused, pause_reasons: if(paused, do: [:operator], else: []), selected_runes: %{a: :star, b: :moon}}
  checkpoint = Checkpoint.initial("oracle_game", "oracle_session")
    |> Map.merge(Map.take(Map.from_struct(rules), [:phase, :position, :paused, :pause_reasons, :selected_runes]))
  session = %{checkpoint: checkpoint, puzzle: puzzle, rules: rules, epochs: %{a: 1,b: 1}, owners: %{a: nil,b: nil},
    actors: %{}, diagnostics: [], record: %{game: %{box_mode: "simulated",box_device_id: "oracle_box"}},
    release: nil, close_evidence: nil, service_result: nil, box: %{report: nil,connected: false,boot_id: nil,connection_id: nil,binding_generation: 0}}
  controller = Projections.snapshot(session, {:player, role}, 1000)
  public = Projections.snapshot(session, :public, 1000)
  box = Projections.snapshot(session, :box, 1000)
  %{controller: controller, public: public, box: box}
end
IO.puts("VAULT_PROJECTIONS " <> Jason.encode!(cases))
