defmodule VaultWeb.TerminalComponents do
  use VaultWeb, :html

  @directions %{a: [:up, :down], b: [:left, :right]}
  @arrows %{up: "↑", down: "↓", left: "←", right: "→"}
  @host_keys %{up: "W", down: "S", left: "A", right: "D"}
  @runes [
    {:star, "✧", "Star"},
    {:moon, "☾", "Moon"},
    {:sun, "☼", "Sun"},
    {:wave, "≋", "Wave"}
  ]

  attr :role, :atom, required: true
  attr :view, :map, required: true
  attr :actor, :any, required: true
  attr :mode, :atom, values: [:host, :player], required: true
  attr :mirror, :map, default: %{}
  slot :inner_block

  def terminal(assigns) do
    role = assigns.role
    peer = Enum.find(assigns.view.peers, &(&1.role != role))
    controlling = assigns.actor && assigns.actor.role == role
    enabled = controlling && !assigns.view.paused

    assigns =
      assign(assigns,
        role_label: role_label(role),
        peer: peer,
        controlling: !!controlling,
        enabled: !!enabled,
        directions: @directions[role],
        arrows: @arrows,
        runes: @runes
      )

    ~H"""
    <section
      class={["terminal panel", "terminal-#{@role}", @view.paused && "terminal-paused"]}
      id={"terminal-#{@role}"}
      aria-labelledby={"terminal-title-#{@role}"}
      phx-hook="VaultController"
      data-actor={@actor && @actor.actor_id}
      data-panel={@role}
      data-mode={@mode}
      data-session={@view.session_id}
      data-board={@view.board_version}
      data-phase={@view.phase}
      data-paused={@view.paused && "true"}
      data-selection={@view.seal && @view.seal.selected_rune}
      data-mirror-event={@mirror[:event_id]}
      data-mirror-direction={@mirror[:direction]}
      data-mirror-rune={@mirror[:rune]}
      data-mirror-code={@mirror[:code]}
    >
      <header class="terminal-header">
        <div class="terminal-ident">
          <span class="terminal-letter" aria-hidden="true">{@role_label}</span>
          <div>
            <div class="eyebrow">Player terminal</div>
            <h1 id={"terminal-title-#{@role}"}>Terminal {@role_label}</h1>
          </div>
        </div>
        <span class={["chip", @controlling && "chip-active"]} data-control-state>
          {if @controlling, do: "Controller", else: "Observer"}
        </span>
      </header>

      <div class="terminal-context">
        <span class="phase-tag">{phase_label(@view.phase)}</span>
        <span class={["connection", @peer && @peer.connected && "connected"]} data-peer-status>
          <span aria-hidden="true" class="indicator"></span>
          Partner {if @peer && @peer.connected, do: "connected", else: "offline"}
        </span>
      </div>

      <div :if={@view.paused} class="callout pause" role="status" data-paused-status>
        <strong>Ⅱ &nbsp; Paused</strong>
        <span>{pause_label(@view.pause_reasons)} Release controls and wait for the host.</span>
      </div>

      <div class="terminal-game">
        <div :if={@view.phase == :lobby} class="phase-card">
          <div class="dial" aria-hidden="true"><span>✧</span></div>
          <h2>Waiting for the host</h2>
          <p>{role_instruction(@role)}. Your partner sees the other walls.</p>
        </div>

        <div :if={@view.maze} class="maze-layout">
          <.maze maze={@view.maze} role={@role} />
          <div class="maze-controls">
            <div>
              <div class="eyebrow">The maze</div>
              <h2>Guide the key</h2>
              <p>{role_instruction(@role)}. Coordinate each step with your partner.</p>
            </div>
            <div class="move-buttons" aria-label="Move the key">
              <button
                :for={direction <- @directions}
                class="game-button move-button"
                type="button"
                data-command="move"
                data-value={direction}
                disabled={!@enabled}
                aria-label={direction_label(direction)}
              >
                <span class="arrow-icon" aria-hidden="true">{@arrows[direction]}</span>
                <span>{direction_label(direction)}</span>
                <kbd>{movement_key(@mode, direction)}</kbd>
              </button>
            </div>
          </div>
        </div>

        <div :if={@view.seal} class="seal-layout">
          <div class="clue">
            <div class="eyebrow">Your partner’s rune</div>
            <h2 data-clue>Tell {String.upcase(to_string(@view.seal.clue_for_role))}: hold {String.upcase(to_string(@view.seal.clue_rune))}</h2>
            <p>Ask your partner which rune you should hold.</p>
          </div>
          <div class="rune-buttons" aria-label="Select your rune">
            <button
              :for={{rune, icon, label} <- @runes}
              class="game-button rune-button"
              type="button"
              aria-label={label}
              aria-pressed={to_string(to_string(rune) == @view.seal.selected_rune)}
              data-command="select_rune"
              data-value={rune}
              disabled={!@enabled}
            >
              <span aria-hidden="true">{icon}</span>{label}
            </button>
          </div>
          <.progress hold={@view.hold} />
          <span class="hold-peer" data-peer-held={if @view.seal.partner_held, do: "true", else: "false"}>
            {if @view.seal.partner_held, do: "Partner is holding", else: "Waiting for partner’s hold"}
          </span>
          <button
            class="game-button hold-button"
            type="button"
            data-hold
            disabled={!@enabled || is_nil(@view.seal.selected_rune)}
          >
            <span aria-hidden="true">◈</span>
            Hold seal
            <kbd>{hold_key(@mode, @role)}</kbd>
          </button>
        </div>

        <div :if={@view.phase == :solved} class="phase-card solved">
          <div class="dial" aria-hidden="true"><span>✓</span></div>
          <h2>Puzzle solved</h2>
          <.box_status box={@view.box} phase={@view.phase} />
        </div>
      </div>

      <p
        class="action-status"
        id={"terminal-feedback-#{@role}"}
        role="status"
        data-action-status
        phx-update="ignore"
      ></p>
      <div class="terminal-ownership">
        <button
          :if={@actor && !@controlling}
          class="button quiet"
          type="button"
          data-command="claim_role"
          data-value={@role}
        >
          Request control
        </button>
        <button
          :if={@actor && @controlling}
          class="button quiet"
          type="button"
          data-command="release_role"
        >
          Release control
        </button>
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end

  attr :maze, :map, required: true
  attr :role, :atom, required: true

  def maze(assigns) do
    ~H"""
    <div class="maze-frame">
      <div
        class="maze-board"
        role="img"
        aria-label={"Partial maze for Terminal #{role_label(@role)}. Key at #{cell_name(@maze.position, @maze.cols)}. Exit at #{cell_name(@maze.goal, @maze.cols)}."}
        style={"--columns: #{@maze.cols}"}
        data-wall-kind={@maze.wall_kind}
        data-walls={Enum.join(@maze.walls, ",")}
        data-position={@maze.position}
        data-goal={@maze.goal}
      >
        <div
          :for={cell <- 0..(@maze.rows * @maze.cols - 1)}
          class={[
            "maze-cell",
            edge(@maze, cell, "right"),
            edge(@maze, cell, "bottom"),
            cell == @maze.position && "has-key",
            cell == @maze.goal && "has-goal"
          ]}
          aria-hidden="true"
        >
          <span class="cell-coordinate">{cell_name(cell, @maze.cols)}</span>
          <span :if={cell == @maze.goal} class="goal-icon">◎</span>
          <span :if={cell == @maze.position} class="key-icon">⚿</span>
        </div>
      </div>
      <div class="maze-legend" aria-hidden="true">
        <span><i class="legend-known"></i> Wall</span>
        <span><i class="legend-unknown"></i> Partner’s view</span>
        <span><b>◎</b> Exit</span>
      </div>
    </div>
    """
  end

  attr :hold, :map, required: true

  def progress(assigns) do
    ~H"""
    <div class="progress-status">
      <span>Shared hold</span><span>2 seconds</span>
    </div>
    <progress
      class="hold-progress"
      aria-label="Shared hold"
      max={@hold.duration_ms}
      value={@hold.elapsed_ms}
      data-progress
      data-active={if @hold.active, do: "true", else: "false"}
      data-qualified={if @hold.qualified, do: "true", else: "false"}
      data-fresh-required={if @hold.fresh_press_required, do: "true", else: "false"}
      data-elapsed={@hold.elapsed_ms}
    />
    """
  end

  attr :box, :map, required: true
  attr :phase, :atom, required: true

  def box_status(assigns) do
    ~H"""
    <div class="box-status" data-release-status={@box.release_status}>
      <span :if={@box.simulated} class="chip sim-chip">Simulated box</span>
      <span>{release_label(@box, @phase)}</span>
    </div>
    """
  end

  def phase_label(:lobby), do: "Lobby"
  def phase_label(:maze), do: "Maze"
  def phase_label(:seal), do: "Final seal"
  def phase_label(:solved), do: "Solved"
  def phase_label(other), do: humanize(other)

  def pause_label(reasons) do
    reasons
    |> Enum.map_join(", ", &humanize/1)
    |> case do
      "" -> ""
      labels -> labels <> "."
    end
  end

  def release_label(%{release_status: status, simulated: simulated}, phase) do
    case to_string(status) do
      "not_requested" when phase == :solved -> "Release pending"
      "not_requested" -> "Release not requested"
      status when status in ["pending", "requested"] -> "Release requested"
      "accepted" -> "Mechanism acknowledged"
      "motion_complete" when simulated -> "Simulated motion complete"
      "motion_complete" -> "Motion complete. Lift the lid."
      "position_confirmed" -> "Released position confirmed. Lift the lid."
      "interrupted" -> "Release interrupted. Inspect the mechanism."
      "failed" -> "Release failed. Inspect the mechanism."
      "uncertain" -> "Release uncertain. Operator review required."
      _ -> humanize(status)
    end
  end

  def humanize(value) when is_atom(value) or is_binary(value) do
    value |> to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  def humanize(_), do: "Unknown"

  def role_label(role), do: role |> to_string() |> String.upcase()
  defp role_instruction(:a), do: "You move the key up or down"
  defp role_instruction(:b), do: "You move the key left or right"
  defp direction_label(direction), do: direction |> to_string() |> String.capitalize()
  defp movement_key(:host, direction), do: @host_keys[direction]
  defp movement_key(:player, direction), do: @arrows[direction]
  defp hold_key(:player, _role), do: "Space"
  defp hold_key(:host, :a), do: "Q"
  defp hold_key(:host, :b), do: "P"

  defp cell_name(cell, columns), do: "#{<<65 + rem(cell, columns)>>}#{div(cell, columns) + 1}"

  defp edge(maze, cell, "right") when rem(cell + 1, maze.cols) == 0, do: nil
  defp edge(maze, cell, "bottom") when cell >= maze.cols * (maze.rows - 1), do: nil

  defp edge(maze, cell, direction) do
    cond do
      to_string(maze.wall_kind) != direction -> "unknown-#{direction}"
      cell in maze.walls -> "wall-#{direction}"
      true -> "open-#{direction}"
    end
  end
end
