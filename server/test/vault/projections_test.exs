defmodule Vault.ProjectionsTest do
  use ExUnit.Case, async: true

  alias Vault.{JSON, Projections, Puzzle}

  @moduletag :m0
  @fixture Path.expand("../../priv/puzzles/maze-v1.private.json", __DIR__)
  @fixture_profile %{max_bytes: 262_144, max_depth: 64}

  @waiting_hold %{
    active: false,
    qualified: false,
    elapsed_ms: 0,
    duration_ms: 2000,
    fresh_press_required: true
  }

  setup do
    bytes =
      File.open!(@fixture, [:read, :binary], &IO.binread(&1, @fixture_profile.max_bytes + 1))

    assert {:ok, fixture} = JSON.decode(bytes, @fixture_profile)
    assert {:ok, puzzle} = Puzzle.from_fixture(fixture)
    %{puzzle: puzzle}
  end

  test "maze gives A only the right walls and vertical controls, and B only the bottom walls and horizontal controls",
       %{puzzle: puzzle} do
    lobby = Puzzle.initial_state(puzzle)

    for role <- [:a, :b] do
      assert Projections.controller(puzzle, lobby, role, 0) == %{
               board_version: 0,
               maze: nil,
               seal: nil,
               hold: @waiting_hold
             }
    end

    maze = apply_ok(puzzle, lobby, :start, 0)
    moved = apply_ok(puzzle, maze, {:move, :a, :up, 0}, 0)

    assert Projections.controller(puzzle, moved, :a, 0) == %{
             board_version: 1,
             maze: %{
               rows: 4,
               cols: 4,
               position: 8,
               goal: 3,
               wall_kind: "right",
               walls: [2, 5, 6, 9, 12],
               allowed_moves: ["up", "down"]
             },
             seal: nil,
             hold: @waiting_hold
           }

    assert Projections.controller(puzzle, moved, :b, 0) == %{
             board_version: 1,
             maze: %{
               rows: 4,
               cols: 4,
               position: 8,
               goal: 3,
               wall_kind: "bottom",
               walls: [1, 4, 10, 11],
               allowed_moves: ["left", "right"]
             },
             seal: nil,
             hold: @waiting_hold
           }
  end

  test "seal includes only the partner's clue and the viewer's selection", %{puzzle: puzzle} do
    seal = enter_seal(puzzle)

    assert Projections.controller(puzzle, seal, :a, 0) == %{
             board_version: 12,
             maze: nil,
             seal: %{
               clue_for_role: "b",
               clue_rune: "moon",
               selected_rune: nil,
               partner_held: false
             },
             hold: @waiting_hold
           }

    assert Projections.controller(puzzle, seal, :b, 0) == %{
             board_version: 12,
             maze: nil,
             seal: %{
               clue_for_role: "a",
               clue_rune: "star",
               selected_rune: nil,
               partner_held: false
             },
             hold: @waiting_hold
           }

    selected = apply_ok(puzzle, seal, {:select_rune, :a, :wave}, 1)
    selected = apply_ok(puzzle, selected, {:select_rune, :b, :sun}, 1)

    assert Projections.controller(puzzle, selected, :a, 1).seal == %{
             clue_for_role: "b",
             clue_rune: "moon",
             selected_rune: "wave",
             partner_held: false
           }

    assert Projections.controller(puzzle, selected, :b, 1).seal == %{
             clue_for_role: "a",
             clue_rune: "star",
             selected_rune: "sun",
             partner_held: false
           }

    wrong = apply_ok(puzzle, selected, {:input, :b, :released, 401}, 1)
    wrong = apply_ok(puzzle, wrong, {:input, :b, {:pressed, 1}, 401}, 1)
    assert Projections.controller(puzzle, wrong, :a, 400).seal.partner_held
    refute Projections.controller(puzzle, wrong, :a, 400).hold.active
    refute Projections.controller(puzzle, wrong, :a, 401).seal.partner_held
  end

  test "the progress projection starts at zero, stays below completion until solved, and clears on pause",
       %{puzzle: puzzle} do
    seal = enter_seal(puzzle)

    ready =
      Enum.reduce(
        [
          {:select_rune, :a, :star},
          {:select_rune, :b, :moon},
          {:input, :a, :released, 400},
          {:input, :b, :released, 400},
          {:input, :a, {:pressed, 1}, 400}
        ],
        seal,
        &apply_ok(puzzle, &2, &1, 0)
      )

    assert {holding, {:applied, :ok, %{}}, [{:schedule_qualification, 1, 2000}]} =
             Puzzle.transition(puzzle, ready, {:input, :b, {:pressed, 1}, 400}, 0)

    assert Projections.controller(puzzle, holding, :a, 0).hold == %{
             active: true,
             qualified: false,
             elapsed_ms: 0,
             duration_ms: 2000,
             fresh_press_required: false
           }

    current =
      Enum.reduce(100..1900//100, holding, fn now_ms, state ->
        next = apply_ok(puzzle, state, {:input, :a, {:pressed, 1}, now_ms + 400}, now_ms)
        apply_ok(puzzle, next, {:input, :b, {:pressed, 1}, now_ms + 400}, now_ms)
      end)

    assert Projections.controller(puzzle, current, :a, 2000).hold == %{
             active: true,
             qualified: false,
             elapsed_ms: 1999,
             duration_ms: 2000,
             fresh_press_required: false
           }

    assert {paused, {:applied, :paused, %{}}, [{:cancel_qualification, 1}]} =
             Puzzle.transition(puzzle, current, {:pause, [:operator]}, 2000)

    assert Projections.controller(puzzle, paused, :a, 2000).hold == @waiting_hold
    assert Projections.controller(puzzle, paused, :a, 2000).seal.selected_rune == "star"
    refute Projections.controller(puzzle, paused, :a, 2000).seal.partner_held

    assert {solved, {:applied, :qualified, %{}}, _effects} =
             Puzzle.transition(puzzle, current, {:qualify, 1, :eligible}, 2000)

    assert Projections.controller(puzzle, solved, :a, 2000) == %{
             board_version: 12,
             maze: nil,
             seal: nil,
             hold: %{
               active: false,
               qualified: true,
               elapsed_ms: 2000,
               duration_ms: 2000,
               fresh_press_required: false
             }
           }
  end

  defp enter_seal(puzzle) do
    state = %{Puzzle.initial_state(puzzle) | phase: :maze, position: 7, board_version: 11}
    apply_ok(puzzle, state, {:move, :a, :up, 11}, 0)
  end

  defp apply_ok(puzzle, state, action, now_ms) do
    assert {next, {:applied, _, _}, []} = Puzzle.transition(puzzle, state, action, now_ms)
    next
  end
end
