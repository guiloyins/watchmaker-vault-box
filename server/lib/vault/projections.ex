defmodule Vault.Projections do
  @moduledoc "Allowlisted puzzle fragments for an already-authorized controller role."

  alias Vault.Puzzle
  alias Vault.Puzzle.State

  @doc "Complete audience DTOs built only from accepted GameSession state."
  def snapshot(session, audience, now_ms) do
    checkpoint = session.checkpoint

    base =
      Map.take(checkpoint, [
        :game_id,
        :session_id,
        :round_id,
        :puzzle_revision,
        :state_revision,
        :phase,
        :paused,
        :pause_reasons,
        :required_roles,
        :active_time_ms
      ])

    base =
      Map.merge(base, %{
        ui_revision: checkpoint.state_revision,
        peers: peers(session, now_ms),
        box: box(session),
        role: nil,
        control_epoch: nil
      })

    case audience do
      {:player, role} when role in [:a, :b] ->
        Map.merge(base, controller(session.puzzle, session.rules, role, now_ms))
        |> Map.merge(%{projection: :controller, role: role, control_epoch: session.epochs[role]})

      :host ->
        Map.merge(base, %{
          projection: :host,
          panels: Map.new([:a, :b], &{&1, snapshot(session, {:player, &1}, now_ms)}),
          actors: actor_list(session, now_ms),
          simulated_service_ready: Map.get(session.box, :service_ready, false),
          controllers_ready: Map.get(session, :controllers_ready, false),
          assignments: session.owners,
          diagnostics: session.diagnostics,
          release:
            if(session.release,
              do: Map.put(session.release, :close_evidence, session.close_evidence)
            ),
          box_device_id: session.record.game.box_device_id,
          box_binding: Map.take(session.box, [:boot_id, :connection_id, :binding_generation]),
          service_result: session.service_result
        })

      :public ->
        Map.put(base, :projection, :public)

      :box ->
        Map.put(base, :projection, :box)
    end
  end

  def box(session) do
    report = session.box.report || %{}
    release = session.release

    %{
      connected: session.box.connected,
      simulated: session.record.game.box_mode == "simulated",
      command_id: if(release, do: release.command_id, else: nil),
      release_status: if(release, do: release.status, else: :not_requested),
      motor_active: Map.get(report, :motor_active, false),
      latch_position: Map.get(report, :latch_position, :unknown),
      position_basis: Map.get(report, :position_basis, :unverified),
      command_confirmation: if(release, do: Map.get(release, :command_confirmation), else: nil),
      readiness:
        Map.get(report, :readiness, %{
          arm_id: nil,
          armed_session_id: nil,
          calibration_valid: false,
          start_verified: false
        }),
      failure_code:
        if(release, do: Map.get(release, :failure_code), else: Map.get(report, :failure_code))
    }
  end

  defp peers(session, now_ms) do
    for role <- [:a, :b] do
      binding = Map.get(session.actors, session.owners[role])

      %{
        role: role,
        connected: fresh?(binding, now_ms),
        source: if(binding, do: binding.actor.source, else: :none),
        held: Puzzle.held?(session.rules, role, now_ms)
      }
    end
  end

  defp actor_list(session, now_ms) do
    session.actors
    |> Map.values()
    |> Enum.map(fn binding ->
      actor = binding.actor

      %{
        actor_id: actor.actor_id,
        panel: binding.panel,
        role: actor.role,
        source: actor.source,
        owner: actor.role != nil and session.owners[actor.role] == actor.actor_id,
        fresh: fresh?(binding, now_ms),
        subject_id: actor.principal.subject_id
      }
    end)
    |> Enum.sort_by(& &1.actor_id)
  end

  defp fresh?(nil, _), do: false
  defp fresh?(%{last_seen_ms: nil}, _), do: false
  defp fresh?(binding, now), do: now < binding.last_seen_ms + 1500

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
