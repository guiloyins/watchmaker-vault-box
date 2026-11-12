defmodule Vault.Puzzle do
  @moduledoc """
  Pure maze and seal rules. The session supplies authenticated actions and monotonic time.

  The session owns bindings, sequence numbers, heartbeat challenge validation, and
  readiness. It checks host authorization before start, pause, resume, and reset,
  including unresolved pause and release restrictions. It also rechecks ownership,
  context, and box readiness when dispatching a qualification timer. The reducer
  checks the attempt, presses, selections, phase, and leases independently.

  The returned state is a proposal. On qualification the session must commit solved
  state and one release intent atomically before adopting the state or dispatching.
  Timer generations belong to this state and must also be fenced by session context.
  """

  alias Vault.JSON.Number

  defmodule Input do
    @moduledoc false
    defstruct baseline_required: true, last_press_id: 0, press_id: nil, lease_until_ms: nil
  end

  defmodule State do
    @moduledoc "Puzzle state, including volatile input and qualification data."
    @enforce_keys [:position]
    defstruct [
      :position,
      phase: :lobby,
      board_version: 0,
      selected_runes: %{a: nil, b: nil},
      paused: false,
      pause_reasons: [],
      inputs: %{a: %Input{}, b: %Input{}},
      attempt: nil,
      attempt_generation: 0
    ]
  end

  @roles [:a, :b]
  @directions [:up, :down, :left, :right]
  @runes [:star, :moon, :sun, :wave]
  @pause_reasons [:operator, :controller_offline, :box_offline, :recovery]
  @max_revision 9_007_199_254_740_991

  @enforce_keys [
    :revision,
    :rows,
    :cols,
    :start,
    :goal,
    :open_edges,
    :role_views,
    :expected_runes,
    :overlap_ms
  ]
  defstruct @enforce_keys

  @doc "Normalizes the already-decoded server-private v1 fixture into rule data."
  def from_fixture(%{
        "fixture_version" => version,
        "puzzle_revision" => revision,
        "puzzle_id" => "watchmakers_vault_golden_v1",
        "audience" => "server_and_tests_only",
        "rows" => rows,
        "cols" => cols,
        "start" => start,
        "goal" => goal,
        "open_edges" => edges,
        "roles" => %{"a" => view_a, "b" => view_b},
        "seal" => %{
          "options" => ["star", "moon", "sun", "wave"],
          "expected_by_role" => %{"a" => expected_a, "b" => expected_b},
          "clues_by_role" => %{
            "a" => %{"clue_for_role" => "b", "clue_rune" => expected_b},
            "b" => %{"clue_for_role" => "a", "clue_rune" => expected_a}
          },
          "overlap_ms" => overlap
        }
      }) do
    with {:ok, 1} <- fixture_integer(version, 1, 1),
         {:ok, 1} <- fixture_integer(revision, 1, 1),
         {:ok, 4} <- fixture_integer(rows, 4, 4),
         {:ok, 4} <- fixture_integer(cols, 4, 4),
         {:ok, 12} <- fixture_integer(start, 12, 12),
         {:ok, 3} <- fixture_integer(goal, 3, 3),
         {:ok, 2000} <- fixture_integer(overlap, 2000, 2000),
         :star <- fixture_rune(expected_a),
         :moon <- fixture_rune(expected_b),
         {:ok, open_edges} <- normalize_edges(edges),
         {:ok, view_a} <- normalize_view(view_a, "right", ["up", "down"], open_edges),
         {:ok, view_b} <- normalize_view(view_b, "bottom", ["left", "right"], open_edges) do
      {:ok,
       %__MODULE__{
         revision: 1,
         rows: 4,
         cols: 4,
         start: 12,
         goal: 3,
         open_edges: open_edges,
         role_views: %{a: view_a, b: view_b},
         expected_runes: %{a: :star, b: :moon},
         overlap_ms: 2000
       }}
    else
      _ -> {:error, :invalid_fixture}
    end
  end

  def from_fixture(_), do: {:error, :invalid_fixture}

  def initial_state(%__MODULE__{start: start}), do: %State{position: start}

  @doc """
  Returns `{proposed_state, {status, code, data}, effects}` after sweeping expired holds.

  Maze moves use `{:move, role, direction, expected_board_version}`. Rune selection
  uses `{:select_rune, role, rune}`. Host-admitted phase actions are `:start`,
  `{:pause, reasons}`, `:resume`, and `:reset`.

  `{:input, role, sample, lease_until_ms}` carries a validated `:released` or
  `{:pressed, press_id}` sample. The adapter supplies the deadline derived from
  its recorded challenge issue time. `:expire_inputs` runs the sweep alone.
  `:invalidate_inputs` clears both baselines. `{:invalidate_input, role, boot}`
  clears one, retaining the press high-water mark for `:same_boot` and clearing
  it for `:new_boot`.

  Schedule a generation-tagged timer from the returned
  `{:schedule_qualification, generation, due_at_ms}` effect. When handling the
  timer, send `{:qualify, generation, eligibility}` with the session's fresh
  `:eligible` or `:ineligible` verdict.
  `{:cancel_qualification, generation}` cancels a pending timer. Only
  `:commit_solve_and_release_intent` proposes a release intent.
  """
  def transition(%__MODULE__{} = puzzle, %State{} = state, action, now_ms)
      when is_integer(now_ms) do
    {state, expiry_effects} = expire_inputs(state, now_ms)
    {state, result, effects} = apply_action(puzzle, state, action, now_ms)
    {state, result, expiry_effects ++ effects}
  end

  @doc false
  def fresh_press_required?(%State{} = state, role, now_ms) do
    input = Map.fetch!(state.inputs, role)
    input.baseline_required or expired?(input, now_ms)
  end

  @doc "Reports whether the role has a currently accepted physical press."
  def held?(%State{phase: :seal, paused: false} = state, role, now_ms) do
    case Map.fetch!(state.inputs, role) do
      %Input{press_id: nil} -> false
      %Input{lease_until_ms: deadline} -> now_ms < deadline
    end
  end

  def held?(%State{}, _role, _now_ms), do: false

  @doc false
  def attempt_active?(%State{attempt: %{}} = state, now_ms) do
    Enum.all?(@roles, &held?(state, &1, now_ms))
  end

  def attempt_active?(%State{}, _now_ms), do: false

  defp apply_action(_puzzle, state, :start, _now_ms) do
    with :ok <- phase_guard(state, :lobby) do
      applied(%{state | phase: :maze}, :started)
    else
      {:error, code, data} -> rejected(state, code, data)
    end
  end

  defp apply_action(_puzzle, state, {:pause, [_ | _] = reasons}, _now_ms) do
    if Enum.all?(reasons, &(&1 in @pause_reasons)) do
      {state, effects} = clear_inputs(state)
      reasons = Enum.uniq(state.pause_reasons ++ reasons)
      applied(%{state | paused: true, pause_reasons: reasons}, :paused, %{}, effects)
    else
      rejected(state, :invalid_action)
    end
  end

  defp apply_action(_puzzle, %State{paused: true} = state, :resume, _now_ms) do
    {state, effects} = clear_inputs(state)
    applied(%{state | paused: false, pause_reasons: []}, :resumed, %{}, effects)
  end

  defp apply_action(_puzzle, %State{} = state, :resume, _now_ms) do
    rejected(state, :wrong_phase, %{phase: state.phase})
  end

  defp apply_action(puzzle, state, :reset, _now_ms) do
    {state, effects} = clear_inputs(state)

    next = %{
      initial_state(puzzle)
      | attempt_generation: state.attempt_generation,
        inputs: state.inputs
    }

    applied(next, :reset, %{}, effects)
  end

  defp apply_action(puzzle, state, {:move, role, direction, observed_version}, _now_ms) do
    with :ok <- known_role(role),
         :ok <- phase_guard(state, :maze),
         :ok <- board_guard(state, observed_version),
         :ok <- allowed_direction(role, direction),
         {:ok, target} <- neighbor(puzzle, state.position, direction),
         :ok <- edge_guard(puzzle, state.position, target),
         :ok <- revision_guard(state.board_version) do
      next = %{state | position: target, board_version: state.board_version + 1}

      {next, effects} =
        if target == puzzle.goal do
          clear_inputs(%{next | phase: :seal})
        else
          {next, []}
        end

      applied(next, :moved, %{position: target, board_version: next.board_version}, effects)
    else
      {:error, code, data} -> rejected(state, code, data)
    end
  end

  defp apply_action(_puzzle, state, {:select_rune, role, rune}, _now_ms) do
    with :ok <- known_role(role),
         :ok <- phase_guard(state, :seal),
         :ok <- known_rune(rune) do
      input = Map.fetch!(state.inputs, role)
      {state, effects} = state |> put_input(role, clear_press(input)) |> cancel_attempt()
      state = %{state | selected_runes: Map.replace!(state.selected_runes, role, rune)}
      applied(state, :rune_selected, %{selected_rune: rune}, effects)
    else
      {:error, code, data} -> rejected(state, code, data)
    end
  end

  defp apply_action(_puzzle, state, :invalidate_inputs, _now_ms) do
    {state, effects} = clear_inputs(state)
    applied(state, :ok, %{}, effects)
  end

  defp apply_action(_puzzle, state, {:invalidate_input, role, boot}, _now_ms)
       when role in @roles and boot in [:same_boot, :new_boot] do
    input = Map.fetch!(state.inputs, role)
    last_press_id = if boot == :same_boot, do: input.last_press_id, else: 0

    {state, effects} =
      state |> put_input(role, %Input{last_press_id: last_press_id}) |> cancel_attempt()

    applied(state, :ok, %{}, effects)
  end

  defp apply_action(_puzzle, state, :expire_inputs, _now_ms), do: applied(state, :ok)

  defp apply_action(puzzle, state, {:input, role, sample, lease_until_ms}, now_ms)
       when role in @roles and is_integer(lease_until_ms) do
    if now_ms < lease_until_ms do
      apply_sample(puzzle, state, role, sample, lease_until_ms, now_ms)
    else
      rejected(state, :stale_challenge)
    end
  end

  defp apply_action(puzzle, state, {:qualify, generation, eligibility}, now_ms)
       when eligibility in [:eligible, :ineligible] do
    qualify(puzzle, state, generation, eligibility, now_ms)
  end

  defp apply_action(_puzzle, state, _action, _now_ms), do: rejected(state, :invalid_action)

  defp apply_sample(_puzzle, state, role, :released, _lease_until_ms, _now_ms) do
    input = Map.fetch!(state.inputs, role)
    next = %{clear_press(input) | baseline_required: false}
    {state, effects} = state |> put_input(role, next) |> cancel_attempt()
    applied(state, :ok, %{}, effects)
  end

  defp apply_sample(puzzle, state, role, {:pressed, press_id}, lease_until_ms, now_ms)
       when is_integer(press_id) and press_id > 0 and press_id <= @max_revision do
    with :ok <- phase_guard(state, :seal),
         input = Map.fetch!(state.inputs, role),
         :ok <- press_guard(input, press_id) do
      next = %{
        input
        | press_id: press_id,
          last_press_id: press_id,
          lease_until_ms: lease_until_ms
      }

      state = put_input(state, role, next)

      if input.press_id == press_id do
        applied(state, :ok)
      else
        {state, cancel_effects} = cancel_attempt(state)
        {state, start_effects} = begin_attempt(puzzle, state, now_ms)
        applied(state, :ok, %{}, cancel_effects ++ start_effects)
      end
    else
      {:error, code, data} -> rejected(state, code, data)
    end
  end

  defp apply_sample(_puzzle, state, _role, _sample, _lease_until_ms, _now_ms),
    do: rejected(state, :invalid_action)

  defp qualify(
         puzzle,
         %State{phase: :seal, paused: false, attempt: %{generation: generation} = attempt} =
           state,
         generation,
         eligibility,
         now_ms
       ) do
    cond do
      now_ms < attempt.due_at_ms ->
        rejected(state, :not_due)

      eligibility == :eligible and
          attempt.press_ids == qualifying_press_ids(puzzle, state, now_ms) ->
        {state, effects} = clear_inputs(%{state | phase: :solved})
        applied(state, :qualified, %{}, effects ++ [:commit_solve_and_release_intent])

      true ->
        {state, effects} = cancel_attempt(state)
        rejected(state, :not_eligible, %{}, effects)
    end
  end

  defp qualify(_puzzle, state, _generation, _eligibility, _now_ms),
    do: rejected(state, :stale_attempt)

  defp begin_attempt(puzzle, state, now_ms) do
    case qualifying_press_ids(puzzle, state, now_ms) do
      nil ->
        {state, []}

      press_ids ->
        generation = state.attempt_generation + 1
        due_at_ms = now_ms + puzzle.overlap_ms

        attempt = %{
          generation: generation,
          started_at_ms: now_ms,
          due_at_ms: due_at_ms,
          press_ids: press_ids
        }

        {%{state | attempt: attempt, attempt_generation: generation},
         [{:schedule_qualification, generation, due_at_ms}]}
    end
  end

  defp qualifying_press_ids(puzzle, state, now_ms) do
    if state.selected_runes == puzzle.expected_runes and
         Enum.all?(@roles, &held?(state, &1, now_ms)) do
      %{a: state.inputs.a.press_id, b: state.inputs.b.press_id}
    end
  end

  defp expire_inputs(state, now_ms) do
    Enum.reduce(@roles, {state, []}, fn role, {state, effects} ->
      input = Map.fetch!(state.inputs, role)

      if expired?(input, now_ms) do
        next = %Input{last_press_id: input.last_press_id}
        {state, cancel_effects} = state |> put_input(role, next) |> cancel_attempt()
        {state, effects ++ cancel_effects}
      else
        {state, effects}
      end
    end)
  end

  defp expired?(%Input{press_id: nil}, _now_ms), do: false
  defp expired?(%Input{lease_until_ms: deadline}, now_ms), do: deadline <= now_ms

  defp clear_inputs(state) do
    inputs =
      Map.new(state.inputs, fn {role, input} ->
        {role, %Input{last_press_id: input.last_press_id}}
      end)

    cancel_attempt(%{state | inputs: inputs})
  end

  defp clear_press(input), do: %{input | press_id: nil, lease_until_ms: nil}

  defp put_input(state, role, input),
    do: %{state | inputs: Map.replace!(state.inputs, role, input)}

  defp cancel_attempt(%State{attempt: nil} = state), do: {state, []}

  defp cancel_attempt(%State{attempt: %{generation: generation}} = state) do
    {%{state | attempt: nil}, [{:cancel_qualification, generation}]}
  end

  defp phase_guard(%State{paused: true, pause_reasons: reasons}, _phase),
    do: {:error, :paused, %{pause_reasons: reasons}}

  defp phase_guard(%State{phase: phase}, phase), do: :ok
  defp phase_guard(%State{phase: phase}, _phase), do: {:error, :wrong_phase, %{phase: phase}}

  defp board_guard(%State{board_version: version, position: position}, observed)
       when is_integer(observed) and observed >= 0 and observed <= @max_revision do
    if observed == version do
      :ok
    else
      {:error, :stale_board, %{board_version: version, position: position}}
    end
  end

  defp board_guard(_state, _observed), do: {:error, :invalid_action, %{}}

  defp revision_guard(version) when version < @max_revision, do: :ok
  defp revision_guard(_version), do: {:error, :revision_exhausted, %{}}

  defp known_role(role) when role in @roles, do: :ok
  defp known_role(_role), do: {:error, :not_authorized, %{}}

  defp known_rune(rune) when rune in @runes, do: :ok
  defp known_rune(_rune), do: {:error, :invalid_action, %{}}

  defp allowed_direction(:a, direction) when direction in [:up, :down], do: :ok
  defp allowed_direction(:b, direction) when direction in [:left, :right], do: :ok

  defp allowed_direction(_role, direction) when direction in @directions,
    do: {:error, :wrong_axis, %{}}

  defp allowed_direction(_role, _direction), do: {:error, :invalid_action, %{}}

  defp press_guard(%Input{baseline_required: true}, _id), do: {:error, :must_release, %{}}
  defp press_guard(%Input{press_id: id}, id), do: :ok
  defp press_guard(%Input{last_press_id: last_id}, id) when id > last_id, do: :ok
  defp press_guard(%Input{}, _id), do: {:error, :must_release, %{}}

  defp neighbor(%__MODULE__{rows: rows, cols: cols}, position, direction) do
    row = div(position, cols)
    col = rem(position, cols)

    case direction do
      :up when row > 0 -> {:ok, position - cols}
      :down when row < rows - 1 -> {:ok, position + cols}
      :left when col > 0 -> {:ok, position - 1}
      :right when col < cols - 1 -> {:ok, position + 1}
      _ -> {:error, :out_of_bounds, %{}}
    end
  end

  defp edge_guard(%__MODULE__{open_edges: open_edges}, from, to) do
    if MapSet.member?(open_edges, edge(from, to)), do: :ok, else: {:error, :wall, %{}}
  end

  defp edge(from, to), do: {min(from, to), max(from, to)}

  defp applied(state, code, data \\ %{}, effects \\ []),
    do: {state, {:applied, code, data}, effects}

  defp rejected(state, code, data \\ %{}, effects \\ []),
    do: {state, {:rejected, code, data}, effects}

  defp normalize_edges(edges) when is_list(edges) and length(edges) == 15 do
    with {:ok, edges} <- normalize_list(edges, &normalize_edge/1),
         set = MapSet.new(edges),
         true <- MapSet.size(set) == 15 do
      {:ok, set}
    else
      _ -> :error
    end
  end

  defp normalize_edges(_edges), do: :error

  defp normalize_edge([first, second]) do
    with {:ok, first} <- fixture_integer(first, 0, 15),
         {:ok, second} <- fixture_integer(second, 0, 15),
         {from, to} = edge(first, second),
         true <- to - from == 4 or (to - from == 1 and div(from, 4) == div(to, 4)) do
      {:ok, {from, to}}
    else
      _ -> :error
    end
  end

  defp normalize_edge(_edge), do: :error

  defp normalize_view(view, kind, moves, open_edges) do
    with %{"wall_kind" => ^kind, "allowed_moves" => ^moves, "walls" => walls} <- view,
         true <- is_list(walls),
         {:ok, walls} <- normalize_list(walls, &fixture_integer(&1, 0, 15)),
         true <- walls == closed_walls(kind, open_edges) do
      {:ok, %{wall_kind: kind, walls: walls, allowed_moves: moves}}
    else
      _ -> :error
    end
  end

  defp closed_walls("right", open_edges) do
    for cell <- 0..15,
        rem(cell, 4) != 3,
        not MapSet.member?(open_edges, {cell, cell + 1}),
        do: cell
  end

  defp closed_walls("bottom", open_edges) do
    for cell <- 0..11, not MapSet.member?(open_edges, {cell, cell + 4}), do: cell
  end

  defp normalize_list(values, normalize) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, normalized} ->
      case normalize.(value) do
        {:ok, converted} -> {:cont, {:ok, [converted | normalized]}}
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      :error -> :error
    end
  end

  defp fixture_integer(value, min, max) when is_integer(value) and value >= min and value <= max,
    do: {:ok, value}

  defp fixture_integer({:json_number, _} = token, min, max), do: Number.integer(token, min, max)
  defp fixture_integer(_value, _min, _max), do: :error

  defp fixture_rune("star"), do: :star
  defp fixture_rune("moon"), do: :moon
  defp fixture_rune(_other), do: :invalid
end
