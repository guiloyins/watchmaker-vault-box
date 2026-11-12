defmodule Vault.Projections do
  @moduledoc "Allowlisted puzzle fragments for an already-authorized controller role."

  alias Vault.Puzzle
  alias Vault.Puzzle.State

  @doc "Builds the controller's maze, seal, and hold fragments for its current phase."
  def controller(%Puzzle{} = puzzle, %State{} = state, role, now_ms)
      when role in [:a, :b] and is_integer(now_ms) do
    %{
      board_version: state.board_version,
      maze: maze(puzzle, state, role),
      seal: seal(puzzle, state, role, now_ms),
      hold: hold(puzzle, state, role, now_ms)
    }
  end

  defp maze(puzzle, %State{phase: :maze} = state, role) do
    %{wall_kind: wall_kind, walls: walls, allowed_moves: moves} =
      Map.fetch!(puzzle.role_views, role)

    %{
      rows: puzzle.rows,
      cols: puzzle.cols,
      position: state.position,
      goal: puzzle.goal,
      wall_kind: wall_kind,
      walls: walls,
      allowed_moves: moves
    }
  end

  defp maze(_puzzle, _state, _role), do: nil

  defp seal(puzzle, %State{phase: :seal} = state, role, now_ms) do
    partner = partner(role)

    %{
      clue_for_role: Atom.to_string(partner),
      clue_rune: puzzle.expected_runes |> Map.fetch!(partner) |> Atom.to_string(),
      selected_rune: state.selected_runes |> Map.fetch!(role) |> rune_label(),
      partner_held: Puzzle.held?(state, partner, now_ms)
    }
  end

  defp seal(_puzzle, _state, _role, _now_ms), do: nil

  defp hold(puzzle, %State{phase: :solved}, _role, _now_ms) do
    %{
      active: false,
      qualified: true,
      elapsed_ms: puzzle.overlap_ms,
      duration_ms: puzzle.overlap_ms,
      fresh_press_required: false
    }
  end

  defp hold(puzzle, state, role, now_ms) do
    active = Puzzle.attempt_active?(state, now_ms)

    elapsed =
      if active do
        (now_ms - state.attempt.started_at_ms) |> max(0) |> min(puzzle.overlap_ms - 1)
      else
        0
      end

    %{
      active: active,
      qualified: false,
      elapsed_ms: elapsed,
      duration_ms: puzzle.overlap_ms,
      fresh_press_required: Puzzle.fresh_press_required?(state, role, now_ms)
    }
  end

  defp partner(:a), do: :b
  defp partner(:b), do: :a

  defp rune_label(nil), do: nil
  defp rune_label(rune), do: Atom.to_string(rune)
end
