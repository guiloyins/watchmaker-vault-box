defmodule VaultWeb.HostLive do
  use VaultWeb, :live_view

  import VaultWeb.Layouts, only: [brand: 1, sign_out: 1]
  import VaultWeb.TerminalComponents
  alias Vault.{Controllers, Games}
  alias VaultWeb.{Auth, BrowserController, GameLive}

  @host_actions ~w(start pause resume reset arm disarm)a
  @sim_faults %{
    "disconnect" => :disconnect,
    "reconnect" => :reconnect,
    "reboot" => :reboot,
    "lost_ack" => :lost_ack,
    "interrupt_motion" => :interrupt
  }
  @directions %{"up" => :up, "down" => :down, "left" => :left, "right" => :right}
  @runes %{"star" => :star, "moon" => :moon, "sun" => :sun, "wave" => :wave}

  @impl true
  def mount(%{"id" => game_id}, _session, socket) do
    socket =
      socket
      |> assign(:request_id, BrowserController.identifier())
      |> assign(:operator_feedback, nil)
      |> assign(:pending_operation, nil)

    GameLive.mount(socket, game_id, :host, [:a, :b])
  end

  @impl true
  def render(assigns) do
    projection = assigns.projection

    assigns =
      assign(assigns,
        box: projection.box,
        external_box: projection[:external_box] == true,
        ready: ready?(projection),
        box_armed: !!projection.box.readiness.arm_id,
        armable: box_armable?(projection) and controllers_ready?(projection),
        controllers_ready: controllers_ready?(projection),
        service_ready: projection[:simulated_service_ready] == true,
        unresolved: unresolved?(projection.release),
        reset_disabled: reset_disabled?(projection)
      )

    ~H"""
    <main class="host-shell">
      <header class="site-header">
        <.brand caption="Workshop control desk" />
        <.sign_out />
      </header>
      <div class="host-overview">
        <div>
          <h1>Host console</h1>
          <div class="host-status">
            <span class="phase-tag" data-host-phase={@projection.phase}>{phase_label(@projection.phase)}</span>
            <span class="chip">Active {elapsed(@projection.active_time_ms)}</span>
            <span class="chip" data-controllers-ready={to_string(@controllers_ready)}>
              {if @controllers_ready, do: "Controllers ready", else: "Waiting for released controls"}
            </span>
            <span :if={@projection.paused} class="chip" data-host-paused>Ⅱ Paused</span>
          </div>
          <p :if={@projection.paused}>{pause_label(@projection.pause_reasons)}</p>
        </div>
        <div class="status-actions">
          <.operator_button
            :if={@projection.phase == :lobby && !@projection.paused}
            label="Start game"
            action="start"
            request={@request_id}
            session={@projection.session_id}
            class="button primary"
            disabled={!@ready || !!@pending_operation}
          />
          <.operator_button
            :if={@projection.phase in [:maze, :seal] && !@projection.paused}
            label="Pause game"
            action="pause"
            request={@request_id}
            session={@projection.session_id}
            disabled={@unresolved || !!@pending_operation}
          />
          <.operator_button
            :if={@projection.paused && @projection.phase in [:lobby, :maze, :seal]}
            label="Resume game"
            action="resume"
            request={@request_id}
            session={@projection.session_id}
            class="button primary"
            disabled={!@ready || @unresolved || !!@pending_operation}
          />
          <.operator_button
            label="Reset puzzle"
            action="reset"
            request={@request_id}
            session={@projection.session_id}
            disabled={@reset_disabled || !!@pending_operation}
          />
        </div>
      </div>
      <div :if={@operator_feedback} class="callout" role="status" data-operator-feedback>
        {@operator_feedback}
        <button :if={@pending_operation} class="button" type="button" phx-click="read_operation">
          Check committed result
        </button>
      </div>

      <div class="host-trio">
        <.host_terminal
          role={:a}
          projection={@projection}
          actor={BrowserController.actor_for(@bindings, :a)}
          request={@request_id}
          pending={!!@pending_operation}
        />
        <section class="vault-panel panel" aria-labelledby="vault-status-title">
          <div class="eyebrow">Release mechanism</div>
          <h2 id="vault-status-title">The vault</h2>
          <.box_status box={@box} phase={@projection.phase} />
          <div class="box-emblem" data-state={box_visual_state(@box)} aria-hidden="true">
            <div class="box-center">◈</div>
            <span :for={n <- 0..7} class="box-led" style={"--led: #{n}"}></span>
          </div>
          <dl class="diagnostic-grid">
            <dt>Connection</dt><dd>{if @box.connected, do: "Online", else: "Offline"}</dd>
            <dt>Readiness</dt><dd data-box-readiness>{readiness_label(@box, @service_ready)}</dd>
            <dt>Latch position</dt><dd>{humanize(@box.latch_position)}</dd>
            <dt>Position basis</dt><dd>{humanize(@box.position_basis)}</dd>
            <dt>Motor</dt><dd>{if @box.motor_active, do: "Active", else: "Idle"}</dd>
            <dt :if={@box.failure_code}>Fault</dt><dd :if={@box.failure_code}>{humanize(@box.failure_code)}</dd>
          </dl>
          <div class="box-actions">
            <button
              :if={@box.simulated && !@external_box}
              class="button"
              type="button"
              phx-click="sim_prepare"
              disabled={!@box.connected || @box.motor_active || @unresolved}
            >
              Prepare simulated reference
            </button>
            <button
              :if={@box.simulated && !@external_box}
              class="button"
              type="button"
              phx-click="sim_exit"
              disabled={!ready_box?(@box) || @service_ready || @box_armed || @unresolved}
            >
              Exit simulated service
            </button>
            <.operator_button
              :if={!@box_armed}
              label="Arm box"
              action="arm"
              request={@request_id}
              session={@projection.session_id}
              disabled={!@armable || @unresolved || !!@pending_operation}
            />
            <.operator_button
              :if={@box_armed}
              label="Disarm box"
              action="disarm"
              request={@request_id}
              session={@projection.session_id}
              disabled={!!@pending_operation}
            />
          </div>
          <p class="host-help">Reset restarts the puzzle and leaves the mechanism unchanged.</p>
          <p :if={@external_box} class="host-help">Prepare the reference and exit service at the external simulator before arming here.</p>
          <details id="box-diagnostics" phx-mounted={Phoenix.LiveView.JS.ignore_attributes("open")}>
            <summary>Box diagnostics</summary>
            <dl class="diagnostic-grid">
              <dt>Device</dt><dd>{@projection[:box_device_id]}</dd>
              <dt>Boot</dt><dd data-box-boot>{get_in(@projection, [:box_binding, :boot_id]) || "Unavailable"}</dd>
              <dt>Command</dt><dd data-command-id>{@box.command_id || "None"}</dd>
              <dt>Arm</dt><dd>{@box.readiness.arm_id || "Disarmed"}</dd>
              <dt>Protocol</dt><dd>Version 1</dd>
            </dl>
          </details>
          <details :if={@box.simulated && !@external_box} id="box-faults" phx-mounted={Phoenix.LiveView.JS.ignore_attributes("open")}>
            <summary>Simulated faults</summary>
            <div class="box-actions">
              <button :for={{fault, label} <- fault_controls()} type="button" class="button quiet" phx-click="sim_fault" phx-value-fault={fault}>
                {label}
              </button>
            </div>
          </details>
          <.recovery
            release={@projection.release}
            session={@projection.session_id}
            request={@request_id}
            unresolved={@unresolved}
            pending={!!@pending_operation}
            simulated={@box.simulated && !@external_box}
            external={@external_box}
            binding={@projection[:box_binding] || %{}}
          />
        </section>
        <.host_terminal
          role={:b}
          projection={@projection}
          actor={BrowserController.actor_for(@bindings, :b)}
          request={@request_id}
          pending={!!@pending_operation}
        />
      </div>

      <section class="diagnostics panel" aria-labelledby="diagnostics-title">
        <h2 id="diagnostics-title">Recent actions</h2>
        <p :if={@projection.diagnostics == []}>No actions recorded.</p>
        <ol class="actions-log" data-diagnostics>
          <li :for={entry <- Enum.take(@projection.diagnostics, 200)}>{diagnostic_label(entry)}</li>
        </ol>
      </section>
    </main>
    """
  end

  attr :role, :atom, required: true
  attr :projection, :map, required: true
  attr :actor, :any, required: true
  attr :request, :string, required: true
  attr :pending, :boolean, required: true

  defp host_terminal(assigns) do
    peer = Enum.find(assigns.projection.peers, &(&1.role == assigns.role))
    current = assigns.projection.assignments[assigns.role]
    assignments = Enum.filter(assigns.projection.actors, &candidate?(&1, assigns.role, current))
    source = if current, do: Enum.find(assigns.projection.actors, &(&1.actor_id == current))
    panel = assigns.projection.panels[assigns.role]

    mirror =
      Enum.find(assigns.projection.diagnostics, %{}, fn event ->
        event[:role] == assigns.role && event[:event_id]
      end)

    assigns =
      assign(assigns,
        peer: peer,
        owner: source,
        candidates: assignments,
        current: current,
        panel: panel,
        mirror: mirror
      )

    ~H"""
    <.terminal role={@role} view={@panel} actor={@actor} mode={:host} mirror={@mirror}>
      <span class="mirror-state" data-mirror-role={@role} data-owner-source={@peer.source} data-held={to_string(@peer.held)}>
        {source_label(@owner)} · {if @peer.connected, do: "Fresh", else: "Awaiting controller"}{if @peer.held, do: " · Holding seal"}
      </span>
      <button
        :if={@current && @actor && @actor.role != @role}
        type="button"
        class="button quiet"
        phx-click="takeover"
        phx-value-role={@role}
        phx-value-actor={@actor.actor_id}
        phx-value-request={@request}
        phx-value-session={@projection.session_id}
        disabled={@pending}
      >
        Take control on this panel
      </button>
      <form :if={@candidates != []} phx-submit="takeover" class="operator-form">
        <input type="hidden" name="request" value={@request} />
        <input type="hidden" name="session" value={@projection.session_id} />
        <input type="hidden" name="role" value={@role} />
        <label for={"takeover-target-#{@role}"}>Assign Terminal {role_label(@role)}</label>
        <select id={"takeover-target-#{@role}"} name="actor" required>
          <option :for={candidate <- @candidates} value={candidate.actor_id}>
            {candidate_label(candidate, @actor)}
          </option>
        </select>
        <button type="submit" class="button quiet" disabled={@pending}>Replace controller</button>
      </form>
      <details :if={@projection.box.simulated} id={"simulated-cyd-#{@role}"} phx-mounted={Phoenix.LiveView.JS.ignore_attributes("open")}>
        <summary>Simulated CYD {role_label(@role)}</summary>
        <div class="box-actions">
          <button type="button" class="button quiet" phx-click="sim_controller" phx-value-role={@role} phx-value-action="connect">
            Connect simulated CYD
          </button>
          <button type="button" class="button quiet" phx-click="sim_controller" phx-value-role={@role} phx-value-action="disconnect">
            Disconnect simulated CYD
          </button>
        </div>
        <div :if={@peer.source == :cyd && @peer.connected && !@panel.paused} class="box-actions">
          <button
            :for={direction <- moves(@role)}
            :if={@panel.phase == :maze}
            type="button"
            class="button quiet"
            phx-click="sim_controller"
            phx-value-role={@role}
            phx-value-action="move"
            phx-value-value={direction}
            phx-value-board={@panel.board_version}
          >
            {humanize(direction)}
          </button>
          <button
            :for={rune <- ~w(star moon sun wave)}
            :if={@panel.phase == :seal}
            type="button"
            class="button quiet"
            phx-click="sim_controller"
            phx-value-role={@role}
            phx-value-action="select"
            phx-value-value={rune}
          >
            {humanize(rune)}
          </button>
          <button :if={@panel.phase == :seal} type="button" class="button quiet" phx-click="sim_controller" phx-value-role={@role} phx-value-action="hold" phx-value-value={if @peer.held, do: "false", else: "true"}>
            {if @peer.held, do: "Release simulated press", else: "Press simulated seal"}
          </button>
        </div>
      </details>
    </.terminal>
    """
  end

  attr :label, :string, required: true
  attr :action, :string, required: true
  attr :request, :string, required: true
  attr :session, :string, required: true
  attr :class, :string, default: "button"
  attr :disabled, :boolean, default: false

  defp operator_button(assigns) do
    ~H"""
    <button
      type="button"
      class={@class}
      phx-click="operate"
      phx-value-action={@action}
      phx-value-request={@request}
      phx-value-session={@session}
      disabled={@disabled}
    >
      {@label}
    </button>
    """
  end

  attr :release, :any, required: true
  attr :session, :string, required: true
  attr :request, :string, required: true
  attr :unresolved, :boolean, required: true
  attr :pending, :boolean, required: true

  attr :simulated, :boolean, required: true
  attr :external, :boolean, required: true
  attr :binding, :map, required: true

  defp recovery(assigns) do
    preparation = assigns.release && assigns.release[:preparation]
    disposition = assigns.release && assigns.release[:disposition]
    evidence = assigns.release && assigns.release[:close_evidence]

    assigns =
      assign(assigns, preparation: preparation, disposition: disposition, evidence: evidence)

    ~H"""
    <section :if={@unresolved || @disposition} class="recovery" aria-label="Release recovery">
      <h3>Release recovery</h3>
      <p :if={@disposition}>Closed without replay. Recorded release status remains {humanize(@release.status)}.</p>
      <form :if={@unresolved} class="operator-form" phx-submit="prepare_recovery">
        <input type="hidden" name="request" value={@request} />
        <input type="hidden" name="session" value={@session} />
        <input type="hidden" name="command" value={@release.command_id} />
        <input type="hidden" name="prior" value={@preparation && recovery_field(@preparation, :recovery_id)} />
        <button type="submit" class="button" disabled={@pending}>
          {if @preparation, do: "Replace recovery preparation", else: "Begin release recovery"}
        </button>
      </form>
      <p :if={@preparation} class="host-help">
        Preparation {recovery_field(@preparation, :recovery_id)} · generation {recovery_field(@preparation, :recovery_generation)}
      </p>
      <details :if={@external && @preparation} id="external-recovery-data" phx-mounted={Phoenix.LiveView.JS.ignore_attributes("open")}>
        <summary>Copy local recovery data</summary>
        <p class="host-help">Use these committed receipts and current context in the local service console. Recheck the binding after a reconnect or reboot.</p>
        <label :for={{label, value} <- service_documents(@release, @session, @binding)}>
          {label}<textarea readonly rows="8" spellcheck="false">{value}</textarea>
        </label>
      </details>
      <p :if={@unresolved && @preparation && !@evidence} class="host-help">
        Seal the local service record and obtain a current box observation before closing recovery.
      </p>
      <form :if={@external && @unresolved && @preparation && !@evidence} class="operator-form" phx-submit="attest_sealed_record">
        <input type="hidden" name="session" value={@session} />
        <input type="hidden" name="recovery" value={recovery_field(@preparation, :recovery_id)} />
        <input type="hidden" name="generation" value={recovery_field(@preparation, :recovery_generation)} />
        <input type="hidden" name="boot" value={@binding[:boot_id]} />
        <input type="hidden" name="connection" value={@binding[:connection_id]} />
        <label>Sealed local record ID<input name="local_record_id" required maxlength="64" /></label>
        <label>Local service epoch<input name="service_epoch" required inputmode="numeric" maxlength="16" /></label>
        <label>Seal operation ID<input name="seal_operation_id" required maxlength="64" /></label>
        <label class="confirm"><input type="checkbox" name="confirmed" value="yes" required /> I inspected the sealed record and checked its release identity, recovery generation and current box binding.</label>
        <button type="submit" class="button">Request fresh box observation</button>
      </form>
      <details :if={@simulated && @preparation} id="simulated-recovery" phx-mounted={Phoenix.LiveView.JS.ignore_attributes("open")}>
        <summary>Simulated recovery service</summary>
        <div class="box-actions">
          <button
            :for={{step, label} <- recovery_steps(@disposition)}
            class="button quiet"
            type="button"
            phx-click="sim_recovery"
            phx-value-step={step}
          >
            {label}
          </button>
        </div>
        <dl :if={@evidence} class="diagnostic-grid">
          <dt>Modeled local record</dt><dd>{@evidence.local_record_id}</dd>
          <dt>Service epoch</dt><dd>{@evidence.service_epoch}</dd>
          <dt>Seal operation</dt><dd>{@evidence.seal_operation_id}</dd>
        </dl>
      </details>
      <form :if={@unresolved && @preparation && @evidence} class="operator-form" phx-submit="close_recovery">
        <input type="hidden" name="request" value={@request} />
        <input type="hidden" name="command" value={@release.command_id} />
        <input type="hidden" name="recovery" value={recovery_field(@preparation, :recovery_id)} />
        <label>Sealed local record ID<input name="local_record_id" required maxlength="64" /></label>
        <label>Local service epoch<input name="service_epoch" required inputmode="numeric" maxlength="16" /></label>
        <label>Seal operation ID<input name="seal_operation_id" required maxlength="64" /></label>
        <label>Reason<textarea name="reason" required maxlength="512" rows="3"></textarea></label>
        <label class="confirm"><input type="checkbox" name="confirmed" value="yes" required /> I checked the matching sealed local service record.</label>
        <button type="submit" class="button" disabled={@pending}>Close release without replay</button>
      </form>
    </section>
    """
  end

  defp service_documents(release, session, binding) do
    preparation = release[:preparation]
    disposition = release[:disposition]

    current = %{
      session_id: session,
      recovery_id: recovery_field(preparation, :recovery_id),
      recovery_generation: recovery_field(preparation, :recovery_generation),
      disposition_id: disposition && recovery_field(disposition, :disposition_id)
    }

    bound = %{
      box_boot_id: binding[:boot_id],
      connection_id: binding[:connection_id],
      current_session_id: session
    }

    [
      {"Committed preparation", preparation},
      {"Current host context", current},
      {"Current box binding", bound},
      {"Committed closed disposition", disposition}
    ]
    |> Enum.reject(fn {_, value} -> is_nil(value) end)
    |> Enum.map(fn {label, value} -> {label, Jason.encode!(value, pretty: true)} end)
  end

  @impl true
  def handle_event(event, params, socket) when event in ["vault:input", "vault:command"] do
    GameLive.handle_event(event, params, socket)
  end

  def handle_event(event, params, socket) do
    GameLive.authenticated(socket, fn -> {:noreply, operate(event, params, socket)} end)
  end

  @impl true
  def handle_info(message, socket), do: GameLive.handle_info(message, socket)

  defp operate(
         "operate",
         %{"action" => action, "request" => request, "session" => session},
         socket
       ) do
    with {operation, _} <-
           Enum.find_value(@host_actions, &if(to_string(&1) == action, do: {&1, true})),
         true <- Controllers.id?(request) and Controllers.id?(session) do
      host_operation(socket, request, fn host, id ->
        Games.host(host, id, request, session, operation)
      end)
    else
      _ -> socket
    end
  end

  defp operate(
         "takeover",
         %{"role" => role, "actor" => actor, "request" => request, "session" => session},
         socket
       ) do
    with {:ok, role} <- Auth.role(role),
         true <- Enum.all?([actor, request, session], &Controllers.id?/1) do
      host_operation(socket, request, fn host, id ->
        Games.host(host, id, request, session, {:replace_controller, role, actor})
      end)
    else
      _ -> socket
    end
  end

  defp operate(
         "prepare_recovery",
         %{"request" => request, "session" => session, "command" => command} = params,
         socket
       ) do
    prior = params["prior"]

    if Enum.all?([request, session, command], &Controllers.id?/1) and
         (prior in [nil, ""] or Controllers.id?(prior)) do
      args = %{command_id: command, expected_session_id: session}

      host_operation(socket, request, fn host, id ->
        case prior do
          prior when prior in [nil, ""] ->
            Games.begin_recovery(host, id, request, args)

          prior ->
            Games.replace_recovery(host, id, request, Map.put(args, :expected_recovery_id, prior))
        end
      end)
    else
      socket
    end
  end

  defp operate(
         "close_recovery",
         %{
           "request" => request,
           "command" => command,
           "recovery" => recovery,
           "local_record_id" => local_record,
           "service_epoch" => service_epoch,
           "seal_operation_id" => seal_op,
           "reason" => reason,
           "confirmed" => "yes"
         },
         socket
       ) do
    selected = get_in(socket.assigns.projection, [:release, :close_evidence])

    with true <-
           Enum.all?([request, command, recovery, local_record, seal_op], &Controllers.id?/1),
         true <- is_binary(reason) and byte_size(reason) in 1..512,
         true <- is_binary(service_epoch) and byte_size(service_epoch) in 1..16,
         {epoch, ""} <- Integer.parse(service_epoch),
         true <- Controllers.number?(epoch, 1),
         true <- is_map(selected) do
      evidence =
        selected
        |> Map.merge(%{
          local_record_id: local_record,
          service_epoch: epoch,
          seal_operation_id: seal_op,
          operator_confirmed: true
        })

      host_operation(socket, request, fn host, id ->
        Games.close_recovery(host, id, request, %{
          command_id: command,
          expected_recovery_id: recovery,
          evidence: evidence,
          reason: reason
        })
      end)
    else
      _ -> assign(socket, :operator_feedback, "Enter the matching sealed local evidence.")
    end
  end

  defp operate("attest_sealed_record", %{"confirmed" => "yes"} = params, socket) do
    with true <-
           Enum.all?(
             ~w(session recovery boot connection local_record_id seal_operation_id),
             &Controllers.id?(params[&1])
           ),
         true <-
           is_binary(params["service_epoch"]) and byte_size(params["service_epoch"]) in 1..16,
         true <- is_binary(params["generation"]) and byte_size(params["generation"]) in 1..16,
         {epoch, ""} <- Integer.parse(params["service_epoch"] || ""),
         {generation, ""} <- Integer.parse(params["generation"] || ""),
         true <- Controllers.number?(epoch, 1) and Controllers.number?(generation, 1) do
      args = %{
        current_session_id: params["session"],
        recovery_id: params["recovery"],
        recovery_generation: generation,
        box_boot_id: params["boot"],
        connection_id: params["connection"],
        local_record_id: params["local_record_id"],
        service_epoch: epoch,
        seal_operation_id: params["seal_operation_id"],
        operator_confirmed: true
      }

      operation(socket, &Games.attest_sealed_record(&1, &2, args))
    else
      _ -> assign(socket, :operator_feedback, "Enter the matching sealed local evidence.")
    end
  end

  defp operate("read_operation", _, socket) do
    with %{request: request} <- socket.assigns.pending_operation do
      read_operation(socket, request)
    else
      _ -> socket
    end
  end

  defp operate("sim_exit", _, socket), do: operation(socket, &Games.exit_simulated/2)

  defp operate("sim_recovery", %{"step" => step}, socket) do
    case Enum.find(recovery_steps(nil) ++ recovery_steps(true), &(to_string(elem(&1, 0)) == step)) do
      {action, _label} -> operation(socket, &Games.recovery_step(&1, &2, action, %{}))
      nil -> socket
    end
  end

  defp operate("sim_prepare", _, socket) do
    operation(socket, &Games.prepare_simulated/2)
  end

  defp operate("sim_fault", %{"fault" => fault}, socket) do
    case Map.fetch(@sim_faults, fault) do
      {:ok, fault} -> operation(socket, &Games.fault_simulated(&1, &2, fault))
      :error -> socket
    end
  end

  defp operate("sim_controller", %{"role" => role, "action" => action} = params, socket) do
    with {:ok, role} <- Auth.role(role),
         {:ok, action} <- simulated_action(action, params) do
      operation(socket, &Games.simulated_controller(&1, &2, role, action))
    else
      _ -> socket
    end
  end

  defp operate(_, _, socket), do: socket

  defp simulated_action("connect", _), do: {:ok, :connect}
  defp simulated_action("disconnect", _), do: {:ok, :disconnect}

  defp simulated_action("move", %{"value" => value, "board" => board}) when is_binary(board) do
    with {:ok, direction} <- Map.fetch(@directions, value),
         true <- byte_size(board) in 1..16,
         {version, ""} <- Integer.parse(board),
         true <- Controllers.number?(version) do
      {:ok, {:move, direction, version}}
    end
  end

  defp simulated_action("select", %{"value" => value}) do
    with {:ok, rune} <- Map.fetch(@runes, value), do: {:ok, {:select_rune, rune}}
  end

  defp simulated_action("hold", %{"value" => value}) when value in ["true", "false"],
    do: {:ok, {:hold, value == "true"}}

  defp simulated_action(_, _), do: :error

  defp host_operation(socket, request, callback) do
    %{principal: principal, game_id: id, pending_operation: pending} = socket.assigns

    if pending do
      socket
    else
      case callback.(principal, id) do
        {:error, %{code: :readback_required}} -> read_operation(socket, request)
        result -> finish_operation(socket, result)
      end
    end
  end

  defp read_operation(socket, request) do
    case Games.read_operation(socket.assigns.principal, socket.assigns.game_id, request) do
      {:ok, _} = result ->
        finish_operation(socket, result)

      _ ->
        socket
        |> assign(:pending_operation, %{request: request})
        |> assign(
          :operator_feedback,
          "The committed result is not yet known. Check the operation before issuing another decision."
        )
    end
  end

  defp operation(socket, callback) do
    result = callback.(socket.assigns.principal, socket.assigns.game_id)
    assign(socket, :operator_feedback, feedback(result))
  end

  defp finish_operation(socket, result) do
    socket
    |> assign(:request_id, BrowserController.identifier())
    |> assign(:pending_operation, nil)
    |> assign(:operator_feedback, feedback(result))
  end

  defp feedback(:ok), do: "Operation accepted."

  defp feedback({:ok, %{simulated: true, receipt: %{"status" => "error", "code" => code}}}),
    do: "Modeled service declined. #{humanize(code)}."

  defp feedback(
         {:ok,
          %{
            simulated: true,
            receipt: %{
              "data" => %{"receipt" => %{"decision" => %{"status" => "rejected", "code" => code}}}
            }
          }}
       ),
       do: "Modeled service declined. #{humanize(code)}."

  defp feedback({:ok, _}), do: "Operation accepted."
  defp feedback({:error, %{code: code}}), do: "Operation declined. #{humanize(code)}."
  defp feedback(_), do: "Operation unavailable."

  defp recovery_field(receipt, field), do: receipt[field] || receipt[to_string(field)]

  defp ready?(projection) do
    controllers_ready?(projection) and box_armable?(projection) and
      projection.box.readiness.armed_session_id == projection.session_id and
      not is_nil(projection.box.readiness.arm_id)
  end

  defp controllers_ready?(projection),
    do: projection[:controllers_ready] == true

  defp box_armable?(projection) do
    ready_box?(projection.box) and
      (not projection.box.simulated or projection[:simulated_service_ready] == true)
  end

  defp ready_box?(box),
    do: box.connected and box.readiness.calibration_valid and box.readiness.start_verified

  defp readiness_label(%{readiness: %{arm_id: arm_id}}, _) when is_binary(arm_id), do: "Armed"

  defp readiness_label(box, service_ready) do
    cond do
      not ready_box?(box) -> "Setup required"
      box.simulated and not service_ready -> "Exit service required"
      true -> "Ready to arm"
    end
  end

  defp unresolved?(nil), do: false

  defp unresolved?(release),
    do:
      is_nil(release[:disposition]) and
        (release[:uncertain] == true or
           to_string(release.status) in ["pending", "requested", "accepted", "uncertain"])

  defp reset_disabled?(%{release: nil}), do: false

  defp reset_disabled?(%{release: release, box: box}) do
    unresolved?(release) or not box.connected or box.motor_active or
      (not is_nil(release[:preparation]) and not is_nil(box.readiness.arm_id))
  end

  defp box_visual_state(%{release_status: status})
       when status in [:motion_complete, :position_confirmed],
       do: "complete"

  defp box_visual_state(%{failure_code: code}) when not is_nil(code), do: "fault"
  defp box_visual_state(%{readiness: %{arm_id: arm}}) when is_binary(arm), do: "ready"
  defp box_visual_state(_), do: "idle"

  defp candidate?(actor, role, owner) do
    actor.actor_id != owner and actor.role in [nil, role] and
      (is_nil(actor[:panel]) or actor[:panel] == role)
  end

  defp source_label(nil), do: "Unassigned"
  defp source_label(%{source: :browser}), do: "Browser controller"
  defp source_label(%{source: :cyd, subject_id: "sim_cyd_" <> _}), do: "Simulated CYD controller"
  defp source_label(%{source: :cyd}), do: "CYD controller"
  defp source_label(_), do: "Unassigned"
  defp candidate_label(%{actor_id: id}, %{actor_id: id}), do: "This host panel"

  defp candidate_label(candidate, _),
    do: "#{source_label(candidate)} · #{String.slice(candidate.actor_id, -6, 6)}"

  defp elapsed(ms) when is_integer(ms) do
    seconds = div(max(ms, 0), 1_000)

    "#{div(seconds, 60)}:#{seconds |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  defp elapsed(_), do: "0:00"

  defp moves(:a), do: [:up, :down]
  defp moves(:b), do: [:left, :right]

  defp fault_controls do
    [
      {"disconnect", "Disconnect box"},
      {"reconnect", "Reconnect box"},
      {"reboot", "Reboot box"},
      {"lost_ack", "Drop next acknowledgement"},
      {"interrupt_motion", "Interrupt motion"}
    ]
  end

  defp recovery_steps(nil) do
    [
      {:stop, "Stop simulated mechanism"},
      {:enter, "Enter modeled recovery"},
      {:reboot, "Reboot into recovery"},
      {:seal, "Seal modeled record"},
      {:replace, "Attest replacement preparation"}
    ]
  end

  defp recovery_steps(_) do
    [
      {:acknowledge, "Attest closed disposition"},
      {:prepare_disposition, "Prepare simulated reference after closure"}
    ]
  end

  defp diagnostic_label(%{code: code, role: role}),
    do: "Terminal #{role_label(role)} · #{humanize(code)}"

  defp diagnostic_label(%{code: code}), do: humanize(code)
  defp diagnostic_label(%{event: event}), do: humanize(event)
  defp diagnostic_label(%{type: type}), do: humanize(type)
  defp diagnostic_label(_), do: "State updated"
end
