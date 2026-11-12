defmodule Vault.PuzzleTest do
  use ExUnit.Case, async: true

  alias Vault.{Clock, JSON, Puzzle}
  alias Vault.Test.FakeClock

  @moduletag :m0
  @fixture Path.expand("../../priv/puzzles/maze-v1.private.json", __DIR__)
  @fixture_profile %{max_bytes: 262_144, max_depth: 64}

  @route [
    {:a, :up, 8},
    {:b, :right, 9},
    {:a, :up, 5},
    {:b, :left, 4},
    {:a, :up, 0},
    {:b, :right, 1},
    {:b, :right, 2},
    {:a, :down, 6},
    {:a, :down, 10},
    {:b, :right, 11},
    {:a, :up, 7},
    {:a, :up, 3}
  ]

  @passages MapSet.new([
              {0, 1},
              {0, 4},
              {1, 2},
              {2, 6},
              {3, 7},
              {4, 5},
              {5, 9},
              {6, 10},
              {7, 11},
              {8, 9},
              {8, 12},
              {9, 13},
              {10, 11},
              {13, 14},
              {14, 15}
            ])

  setup do
    bytes =
      File.open!(@fixture, [:read, :binary], &IO.binread(&1, @fixture_profile.max_bytes + 1))

    assert {:ok, fixture} = JSON.decode(bytes, @fixture_profile)
    assert {:ok, puzzle} = Puzzle.from_fixture(fixture)
    %{puzzle: puzzle, fixture: fixture}
  end

  test "loads the private v1 rules and rejects inconsistent edges, walls, or clues", context do
    %{puzzle: puzzle, fixture: fixture} = context
    assert %{rows: 4, cols: 4, revision: 1, start: 12, goal: 3, overlap_ms: 2000} = puzzle

    assert {:error, :invalid_fixture} =
             fixture |> put_in(["open_edges", Access.at(0)], [3, 4]) |> Puzzle.from_fixture()

    assert {:error, :invalid_fixture} =
             fixture |> put_in(["roles", "a", "walls"], [2, 5, 6, 9]) |> Puzzle.from_fixture()

    assert {:error, :invalid_fixture} =
             fixture
             |> put_in(["seal", "clues_by_role", "a", "clue_rune"], "star")
             |> Puzzle.from_fixture()
  end

  test "all 16 cells have exactly the golden 15 bidirectional passages", %{puzzle: puzzle} do
    maze = enter_maze(puzzle)

    adjacency =
      Map.new(0..15, fn cell ->
        state = %{maze | position: cell}

        neighbors =
          for {role, direction, offset, inside?} <- [
                {:a, :up, -4, cell >= 4},
                {:a, :down, 4, cell < 12},
                {:b, :left, -1, rem(cell, 4) > 0},
                {:b, :right, 1, rem(cell, 4) < 3}
              ],
              reduce: [] do
            neighbors ->
              target = cell + offset
              result = Puzzle.transition(puzzle, state, {:move, role, direction, 0}, 0)

              cond do
                not inside? ->
                  assert {^state, {:rejected, :out_of_bounds, %{}}, []} = result
                  neighbors

                MapSet.member?(@passages, {min(cell, target), max(cell, target)}) ->
                  assert {%{position: ^target, board_version: 1},
                          {:applied, :moved, %{position: ^target, board_version: 1}}, []} = result

                  [target | neighbors]

                true ->
                  assert {^state, {:rejected, :wall, %{}}, []} = result
                  neighbors
              end
          end

        {cell, neighbors}
      end)

    assert Enum.sum(for {_cell, neighbors} <- adjacency, do: length(neighbors)) == 30
    assert reachable([12], adjacency, MapSet.new()) == MapSet.new(0..15)
  end

  test "only the last accepted golden move enters the seal and none propose release", %{
    puzzle: puzzle
  } do
    seal = enter_seal(puzzle)

    assert %{phase: :seal, position: 3, board_version: 12, selected_runes: %{a: nil, b: nil}} =
             seal

    assert seal.inputs.a.baseline_required and seal.inputs.b.baseline_required

    assert {^seal, {:rejected, :wrong_phase, %{phase: :seal}}, []} =
             Puzzle.transition(puzzle, seal, {:move, :a, :down, 12}, 0)
  end

  test "the B3 branch ends at D4 and can only be retraced", %{puzzle: puzzle} do
    state =
      Enum.reduce(
        [{:a, :up, 8}, {:b, :right, 9}, {:a, :down, 13}, {:b, :right, 14}, {:b, :right, 15}],
        enter_maze(puzzle),
        &take_step(puzzle, &2, &1)
      )

    assert {^state, {:rejected, :wall, %{}}, []} =
             Puzzle.transition(puzzle, state, {:move, :a, :up, 5}, 0)

    assert {^state, {:rejected, :out_of_bounds, %{}}, []} =
             Puzzle.transition(puzzle, state, {:move, :b, :right, 5}, 0)

    retraced =
      Enum.reduce(
        [{:b, :left, 14}, {:b, :left, 13}, {:a, :up, 9}],
        state,
        &take_step(puzzle, &2, &1)
      )

    assert %{position: 9, board_version: 8, phase: :maze} = retraced
  end

  test "role, axis, board, phase, pause and malformed action checks preserve the board", %{
    puzzle: puzzle
  } do
    lobby = Puzzle.initial_state(puzzle)

    assert {^lobby, {:rejected, :wrong_phase, %{phase: :lobby}}, []} =
             Puzzle.transition(puzzle, lobby, {:move, :a, :up, 0}, 0)

    maze = enter_maze(puzzle)

    for {action, expected} <- [
          {{:move, :c, :up, 0}, {:not_authorized, %{}}},
          {{:move, :a, :right, 0}, {:wrong_axis, %{}}},
          {{:move, :b, :down, 0}, {:wrong_axis, %{}}},
          {{:move, :a, :north, 0}, {:invalid_action, %{}}},
          {{:move, :a, :up, -1}, {:invalid_action, %{}}},
          {{:move, :a, :up, 0.0}, {:invalid_action, %{}}},
          {{:move, :a, :up}, {:invalid_action, %{}}},
          {{:select_rune, :a, :star}, {:wrong_phase, %{phase: :maze}}}
        ] do
      {code, data} = expected
      assert {^maze, {:rejected, ^code, ^data}, []} = Puzzle.transition(puzzle, maze, action, 0)
    end

    first_move = take_step(puzzle, maze, {:a, :up, 8})

    assert {^first_move, {:rejected, :stale_board, %{board_version: 1, position: 8}}, []} =
             Puzzle.transition(puzzle, first_move, {:move, :b, :right, 0}, 0)

    paused = apply_ok(puzzle, first_move, {:pause, [:operator]}, 0)

    assert {^paused, {:rejected, :paused, %{pause_reasons: [:operator]}}, []} =
             Puzzle.transition(puzzle, paused, {:move, :b, :right, 1}, 0)

    max = 9_007_199_254_740_991
    saturated = %{maze | board_version: max}

    assert {^saturated, {:rejected, :revision_exhausted, %{}}, []} =
             Puzzle.transition(puzzle, saturated, {:move, :a, :up, max}, 0)
  end

  test "qualification starts at the second valid press and proposes one atomic solve at 2,000 ms",
       %{puzzle: puzzle} do
    fake = start_supervised!({FakeClock, 0})
    clock = FakeClock.handle(fake)
    seal = ready_seal(puzzle)
    first_press = apply_ok(puzzle, seal, {:input, :a, {:pressed, 1}, 400}, Clock.now_ms(clock))
    refute first_press.attempt
    assert :ok = FakeClock.advance_to(fake, 350)

    assert {both, {:applied, :ok, %{}}, [{:schedule_qualification, 1, 2350}]} =
             Puzzle.transition(
               puzzle,
               first_press,
               {:input, :b, {:pressed, 1}, 750},
               Clock.now_ms(clock)
             )

    Clock.schedule_at(clock, self(), {:qualify, 1, :eligible}, 2350)
    both = refresh_both(puzzle, both, 375..2275//100)
    assert :ok = FakeClock.advance_to(fake, 2349)
    refute_received {:qualify, _, _}

    assert {^both, {:rejected, :not_due, %{}}, []} =
             Puzzle.transition(puzzle, both, {:qualify, 1, :eligible}, Clock.now_ms(clock))

    assert :ok = FakeClock.advance_to(fake, 2350)
    assert_received {:qualify, 1, :eligible} = timer

    assert {solved, {:applied, :qualified, %{}},
            [{:cancel_qualification, 1}, :commit_solve_and_release_intent]} =
             Puzzle.transition(puzzle, both, timer, Clock.now_ms(clock))

    assert %{phase: :solved, position: 3, board_version: 12, attempt: nil} = solved

    assert {^solved, {:rejected, :stale_attempt, %{}}, []} =
             Puzzle.transition(puzzle, solved, timer, Clock.now_ms(clock))
  end

  test "lease equality defeats qualification and stale true input cannot revive an expired press",
       %{puzzle: puzzle} do
    both = puzzle |> start_hold() |> then(&refresh_both(puzzle, &1, 100..1600//100))

    both =
      Enum.reduce(1700..1900//100, both, fn issued_ms, state ->
        apply_ok(puzzle, state, {:input, :a, {:pressed, 1}, issued_ms + 400}, issued_ms)
      end)

    assert {expired, {:rejected, :stale_attempt, %{}}, [{:cancel_qualification, 1}]} =
             Puzzle.transition(puzzle, both, {:qualify, 1, :eligible}, 2000)

    assert %{phase: :seal, attempt: nil, board_version: 12} = expired
    assert Puzzle.held?(expired, :a, 2000)
    refute Puzzle.held?(expired, :b, 2000)

    assert {^expired, {:rejected, :stale_challenge, %{}}, []} =
             Puzzle.transition(puzzle, expired, {:input, :b, :released, 2000}, 2000)

    assert {^expired, {:rejected, :must_release, %{}}, []} =
             Puzzle.transition(puzzle, expired, {:input, :b, {:pressed, 2}, 2400}, 2000)

    released = apply_ok(puzzle, expired, {:input, :b, :released, 2400}, 2000)

    assert {^released, {:rejected, :must_release, %{}}, []} =
             Puzzle.transition(puzzle, released, {:input, :b, {:pressed, 1}, 2400}, 2000)

    assert {_next, {:applied, :ok, %{}}, [{:schedule_qualification, 2, 4000}]} =
             Puzzle.transition(puzzle, released, {:input, :b, {:pressed, 2}, 2400}, 2000)
  end

  test "a sample arriving one millisecond before expiry retains its challenge deadline", %{
    puzzle: puzzle
  } do
    both = start_hold(puzzle)

    assert {^both, {:applied, :ok, %{}}, []} =
             Puzzle.transition(puzzle, both, {:input, :a, {:pressed, 1}, 400}, 399)

    assert {expired, {:applied, :ok, %{}}, [{:cancel_qualification, 1}]} =
             Puzzle.transition(puzzle, both, :expire_inputs, 400)

    assert Puzzle.fresh_press_required?(expired, :a, 400)
    refute Puzzle.held?(expired, :a, 400)
    refute expired.attempt
  end

  test "rune choices cancel overlap and a wrong choice still allows the physical hold", %{
    puzzle: puzzle
  } do
    both = start_hold(puzzle)

    assert {^both, {:rejected, :invalid_action, %{}}, []} =
             Puzzle.transition(puzzle, both, {:select_rune, :b, :square}, 100)

    assert {wrong, {:applied, :rune_selected, %{selected_rune: :sun}},
            [{:cancel_qualification, 1}]} =
             Puzzle.transition(puzzle, both, {:select_rune, :b, :sun}, 100)

    assert Puzzle.held?(wrong, :a, 100)

    assert {^wrong, {:rejected, :must_release, %{}}, []} =
             Puzzle.transition(puzzle, wrong, {:input, :b, {:pressed, 1}, 500}, 100)

    wrong = apply_ok(puzzle, wrong, {:input, :b, {:pressed, 2}, 500}, 100)
    assert Puzzle.held?(wrong, :b, 100)
    refute wrong.attempt

    corrected = apply_ok(puzzle, wrong, {:select_rune, :b, :moon}, 101)
    refute Puzzle.held?(corrected, :b, 101)

    assert {_, {:applied, :ok, %{}}, [{:schedule_qualification, 2, 2101}]} =
             Puzzle.transition(puzzle, corrected, {:input, :b, {:pressed, 3}, 500}, 101)
  end

  test "pause preserves choices, invalidates presses and accumulates reasons", %{puzzle: puzzle} do
    both = start_hold(puzzle)

    assert {paused, {:applied, :paused, %{}}, [{:cancel_qualification, 1}]} =
             Puzzle.transition(puzzle, both, {:pause, [:operator]}, 1)

    paused = apply_ok(puzzle, paused, {:pause, [:controller_offline, :recovery]}, 2)

    assert %{
             paused: true,
             phase: :seal,
             position: 3,
             board_version: 12,
             selected_runes: %{a: :star, b: :moon}
           } = paused

    assert paused.pause_reasons == [:operator, :controller_offline, :recovery]

    assert {^paused, {:rejected, :paused, %{pause_reasons: _}}, []} =
             Puzzle.transition(puzzle, paused, {:input, :a, {:pressed, 2}, 401}, 2)

    neutral = apply_ok(puzzle, paused, {:input, :a, :released, 401}, 2)
    refute Puzzle.fresh_press_required?(neutral, :a, 2)

    resumed = apply_ok(puzzle, neutral, :resume, 3)
    assert %{paused: false, pause_reasons: [], attempt: nil} = resumed
    assert Puzzle.fresh_press_required?(resumed, :a, 3)

    reset = apply_ok(puzzle, resumed, :reset, 4)

    assert %{phase: :lobby, position: 12, board_version: 0, selected_runes: %{a: nil, b: nil}} =
             reset

    assert {^reset, {:rejected, :stale_attempt, %{}}, []} =
             Puzzle.transition(puzzle, reset, {:qualify, 1, :eligible}, 2000)
  end

  test "a new owner needs a baseline and can number its first press independently", %{
    puzzle: puzzle
  } do
    both = start_hold(puzzle)

    assert {rebound, {:applied, :ok, %{}}, [{:cancel_qualification, 1}]} =
             Puzzle.transition(puzzle, both, {:invalidate_input, :a, :new_boot}, 10)

    assert {^rebound, {:rejected, :must_release, %{}}, []} =
             Puzzle.transition(puzzle, rebound, {:input, :a, {:pressed, 1}, 410}, 10)

    neutral = apply_ok(puzzle, rebound, {:input, :a, :released, 410}, 10)

    assert {_, {:applied, :ok, %{}}, [{:schedule_qualification, 2, 2010}]} =
             Puzzle.transition(puzzle, neutral, {:input, :a, {:pressed, 1}, 410}, 10)
  end

  test "a canceled timer that was already queued cannot qualify after release", %{puzzle: puzzle} do
    fake = start_supervised!({FakeClock, 0})
    clock = FakeClock.handle(fake)
    both = puzzle |> start_hold() |> then(&refresh_both(puzzle, &1, 100..1900//100))

    ref = Clock.schedule_at(clock, self(), {:qualify, 1, :eligible}, 2000)
    pending = Clock.schedule_at(clock, self(), :canceled_before_delivery, 2001)
    assert Clock.cancel(clock, pending)
    assert :ok = FakeClock.advance_to(fake, 2000)

    assert {released, {:applied, :ok, %{}}, [{:cancel_qualification, 1}]} =
             Puzzle.transition(puzzle, both, {:input, :b, :released, 2300}, Clock.now_ms(clock))

    refute Clock.cancel(clock, ref)
    assert_received {:qualify, 1, :eligible} = old_timer

    assert {^released, {:rejected, :stale_attempt, %{}}, []} =
             Puzzle.transition(puzzle, released, old_timer, Clock.now_ms(clock))

    assert :ok = FakeClock.advance_to(fake, 2001)
    refute_received :canceled_before_delivery
  end

  test "the caller's qualification-time context and readiness check can refuse a fresh attempt",
       %{puzzle: puzzle} do
    both = puzzle |> start_hold() |> then(&refresh_both(puzzle, &1, 100..1900//100))

    assert {seal, {:rejected, :not_eligible, %{}}, [{:cancel_qualification, 1}]} =
             Puzzle.transition(puzzle, both, {:qualify, 1, :ineligible}, 2000)

    assert %{phase: :seal, attempt: nil} = seal

    assert {^seal, {:rejected, :stale_attempt, %{}}, []} =
             Puzzle.transition(puzzle, seal, {:qualify, 1, :eligible}, 2000)
  end

  defp enter_maze(puzzle), do: apply_ok(puzzle, Puzzle.initial_state(puzzle), :start, 0)

  defp enter_seal(puzzle) do
    Enum.reduce(@route, enter_maze(puzzle), &take_step(puzzle, &2, &1))
  end

  defp take_step(puzzle, state, {role, direction, destination}) do
    version = state.board_version + 1

    assert {next, {:applied, :moved, %{position: ^destination, board_version: ^version}}, []} =
             Puzzle.transition(puzzle, state, {:move, role, direction, state.board_version}, 0)

    assert next.phase == if(destination == 3, do: :seal, else: :maze)
    next
  end

  defp ready_seal(puzzle) do
    Enum.reduce(
      [
        {:select_rune, :a, :star},
        {:select_rune, :b, :moon},
        {:input, :a, :released, 400},
        {:input, :b, :released, 400}
      ],
      enter_seal(puzzle),
      &apply_ok(puzzle, &2, &1, 0)
    )
  end

  defp start_hold(puzzle) do
    first = apply_ok(puzzle, ready_seal(puzzle), {:input, :a, {:pressed, 1}, 400}, 0)

    assert {both, {:applied, :ok, %{}}, [{:schedule_qualification, 1, 2000}]} =
             Puzzle.transition(puzzle, first, {:input, :b, {:pressed, 1}, 400}, 0)

    both
  end

  defp refresh_both(puzzle, state, times) do
    Enum.reduce(times, state, fn issued_ms, state ->
      renewed_a = apply_ok(puzzle, state, {:input, :a, {:pressed, 1}, issued_ms + 400}, issued_ms)
      apply_ok(puzzle, renewed_a, {:input, :b, {:pressed, 1}, issued_ms + 400}, issued_ms)
    end)
  end

  defp apply_ok(puzzle, state, action, now_ms) do
    assert {next, {:applied, _, _}, []} = Puzzle.transition(puzzle, state, action, now_ms)
    next
  end

  defp reachable([], _adjacency, visited), do: visited

  defp reachable([cell | rest], adjacency, visited) do
    if MapSet.member?(visited, cell) do
      reachable(rest, adjacency, visited)
    else
      reachable(Map.fetch!(adjacency, cell) ++ rest, adjacency, MapSet.put(visited, cell))
    end
  end
end
