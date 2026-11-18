defmodule Vault.GameSession do
  @moduledoc "Single game authority: validate, commit, adopt, then publish or dispatch."
  use GenServer

  alias Vault.{
    BoxFeedback,
    BoxLink,
    Clock,
    Controllers,
    DeviceTimingDiagnostics,
    Games,
    GameStore,
    Projections,
    Puzzle,
    Updates
  }

  alias Vault.Controllers.{Actor, Context, Input, Principal}
  alias Vault.Games.{CommandResult, InputResult, Receipt}
  alias Vault.SimulatedBox.Adapter

  @controller_freshness_ms 1500

  def start_link(opts) do
    record = Keyword.fetch!(opts, :record)

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {Vault.Registry, record.game.game_id}}
    )
  end

  def child_spec(opts),
    do: %{
      id: {__MODULE__, opts[:record].game.game_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent
    }

  @impl true
  def init(opts) do
    record = Keyword.fetch!(opts, :record)
    clock = Keyword.get(opts, :clock, Clock.system())

    with {:ok, record} <- GameStore.load(record.game.game_id),
         {:ok, bytes} <-
           File.read(Application.app_dir(:vault, "priv/puzzles/maze-v1.private.json")),
         {:ok, parsed} <- Vault.JSON.decode(bytes, %{max_bytes: 262_144, max_depth: 64}),
         {:ok, puzzle} <- Puzzle.from_fixture(parsed),
         {:ok, record} <- Vault.Recovery.restart(record) do
      s = %{
        record: record,
        checkpoint: record.checkpoint,
        checkpoint_revision: record.game.checkpoint_revision,
        puzzle: puzzle,
        rules: rules_from(record.checkpoint),
        clock: clock,
        actors: %{},
        controllers_ready: false,
        press_history: %{},
        owners: %{a: nil, b: nil},
        epochs: %{a: 0, b: 0},
        generation: 0,
        box: empty_box(),
        runtime: Keyword.get(opts, :runtime, Vault.SimulatedBox),
        release: Vault.Recovery.release(record),
        diagnostics: [],
        qualification_timer: nil,
        timing_diagnostics: clock == Clock.system() and DeviceTimingDiagnostics.enabled?(),
        heartbeat_tick_due_ms: nil,
        publish_timer: nil,
        last_publish_ms: nil,
        service_pending: %{},
        service_result: nil,
        last_active_ms: Clock.now_ms(clock),
        query: nil,
        seal_attestation: nil,
        service_context: %{},
        close_evidence: nil,
        seal_check: nil
      }

      send(self(), {:connect_box, record.checkpoint.session_id})
      {:ok, schedule_heartbeat_tick(s)}
    else
      _ -> {:stop, :invalid_game_store}
    end
  end

  defp rules_from(cp),
    do: %Puzzle.State{
      phase: cp.phase,
      position: cp.position,
      board_version: cp.board_version,
      selected_runes: cp.selected_runes,
      paused: cp.paused,
      pause_reasons: cp.pause_reasons
    }

  @impl true
  def handle_call({:scope, p, audience}, _from, s) do
    {:reply,
     if(Controllers.scope?(p, s.checkpoint.game_id, audience),
       do: {:ok, s.checkpoint.session_id},
       else: Games.error(:not_authorized)
     ), s}
  end

  def handle_call({:fetch, p, audience}, _from, s) do
    s = expire(s) |> sync_controller_readiness()

    result =
      if Controllers.scope?(p, s.checkpoint.game_id, audience),
        do: {:ok, Projections.snapshot(s, audience, now(s))},
        else: Games.error(:not_authorized)

    {:reply, result, s}
  end

  def handle_call({:device_scope, actor}, {caller, _}, s) do
    {:reply, device_scope(s, actor, caller), s}
  end

  def handle_call({:device_snapshot, actor}, {caller, _}, s) do
    s = expire(s) |> sync_controller_readiness()

    result =
      with {:ok, {_session, audience, _epoch}} <- device_scope(s, actor, caller) do
        {:ok, Projections.snapshot(s, audience, now(s))}
      end

    {:reply, result, s}
  end

  def handle_call({:bind, principal, opts}, {caller, _}, s) do
    panel = Map.get(opts, :panel)
    source = Map.get(opts, :source)
    boot_key = {principal.subject_id, opts[:boot_id], panel}

    allowed =
      Controllers.valid?(principal) and is_pid(opts[:owner_pid]) and opts[:owner_pid] == caller and
        Controllers.id?(opts[:boot_id]) and map_size(s.actors) < 32 and
        ((source == :browser and principal.kind in [:host, :player]) or
           (source == :cyd and Vault.Auth.device_class(principal) == :controller) or
           (source == :box and (not simulated?(s) or external_box_configured?()) and
              Vault.Auth.device_class(principal) == :box and
              principal.subject_id == s.record.game.box_device_id)) and
        (principal.kind == :host or principal.game_id == s.checkpoint.game_id) and
        (panel == nil or panel in principal.allowed_roles) and
        (Map.has_key?(s.press_history, boot_key) or map_size(s.press_history) < 512)

    if allowed do
      s =
        Enum.reduce(s.actors, s, fn {id, b}, acc ->
          if b.actor.principal.subject_id == principal.subject_id and
               ((principal.kind == :device and b.actor.source in [:cyd, :box]) or
                  (b.actor.boot_id == opts.boot_id and b.panel == panel)),
             do: remove_actor(acc, id, :replaced),
             else: acc
        end)

      generation = System.unique_integer([:positive, :monotonic])

      actor = %Actor{
        actor_id: Controllers.id("actor"),
        principal: principal,
        source: source,
        owner_pid: caller,
        boot_id: opts.boot_id,
        connection_id: Controllers.id("conn"),
        binding_generation: generation,
        session_id: s.checkpoint.session_id,
        role: nil,
        control_epoch: nil
      }

      b = %{
        actor: actor,
        panel: panel,
        delivery: Map.get(opts, :device_delivery),
        monitor: Process.monitor(caller),
        next_seq: 1,
        results: %{},
        challenges: %{},
        heartbeat_seq: 0,
        input_seq: 0,
        last_challenge: 0,
        last_seen_ms: nil,
        bound_at_ms: now(s),
        neutral: false,
        press_high: Map.get(s.press_history, boot_key, 0),
        boot_key: boot_key,
        lease_until_ms: nil
      }

      s =
        %{
          s
          | actors: Map.put(s.actors, actor.actor_id, b),
            generation: generation,
            press_history: Map.put_new(s.press_history, boot_key, 0)
        }
        |> visible()

      s =
        if source == :box do
          box = %{
            empty_box()
            | transport: :external,
              actor_id: actor.actor_id,
              boot_id: actor.boot_id,
              connection_id: actor.connection_id,
              binding_generation: generation,
              runtime_pid: caller,
              connected: true,
              bound_at_ms: now(s),
              feedback: if(not simulated?(s), do: BoxFeedback.new(opts[:box_feedback]))
          }

          send(self(), {:query_bound_box, generation})

          %{s | box: box, query: nil, close_evidence: nil, seal_check: nil, seal_attestation: nil}
          |> visible()
        else
          s
        end

      {:reply, {:ok, {actor, Controllers.context(actor, s.checkpoint)}}, s}
    else
      {:reply, Games.error(:invalid_binding), s}
    end
  end

  def handle_call({:command, actor, seq, context, action}, {caller, _}, s) do
    s = expire(s)

    case actor_binding(s, actor, caller) do
      {:ok, b} ->
        if Controllers.number?(seq, 1) do
          key = {context, action}

          cond do
            Map.has_key?(b.results, seq) ->
              case b.results[seq] do
                {^key, result} ->
                  {:reply, {:ok, result}, s}

                _ ->
                  {:reply, Games.error(:invalid_binding),
                   remove_actor(s, actor.actor_id, :replaced)}
              end

            seq < b.next_seq ->
              {:reply, {:ok, command_result(s, seq, :rejected, :result_expired, %{})}, publish(s)}

            seq > b.next_seq ->
              {:reply,
               {:ok,
                command_result(s, seq, :rejected, :seq_gap, %{expected_command_seq: b.next_seq})},
               s}

            true ->
              {s, status, code, data} = controller_command(s, b, context, action)

              s =
                if code == :wall,
                  do: update_in(s.box.feedback, &BoxFeedback.wall(&1, now(s))),
                  else: s

              s =
                if status == :applied and code in [:moved, :rune_selected] do
                  details =
                    case action do
                      {:move, direction, _} -> %{direction: direction}
                      {:select_rune, rune} -> %{rune: rune}
                    end

                  diagnostic(
                    s,
                    code,
                    Map.merge(details, %{
                      event_id: Controllers.id("event"),
                      role: b.actor.role,
                      actor_id: b.actor.actor_id,
                      command_seq: seq
                    })
                  )
                else
                  s
                end

              result = command_result(s, seq, status, code, data)

              s =
                if Map.has_key?(s.actors, actor.actor_id) do
                  update_in(s.actors[actor.actor_id], fn current ->
                    cache = Map.put(current.results, seq, {key, result}) |> Map.delete(seq - 128)
                    %{current | results: cache, next_seq: seq + 1}
                  end)
                else
                  s
                end

              {:reply, {:ok, result}, s}
          end
        else
          {:reply, Games.error(:invalid_binding), s}
        end

      _ ->
        {:reply, Games.error(:not_authorized), s}
    end
  end

  def handle_call({:sample, actor, %Input{} = input}, {caller, _}, s) do
    s = expire(s)

    case actor_binding(s, actor, caller) do
      {:ok, binding} ->
        {s, accepted, code} = sample(s, binding, input)
        s = sync_controller_readiness(s)

        {:reply,
         {:ok,
          %InputResult{
            heartbeat_seq: input.heartbeat_seq,
            input_seq: input.input_seq,
            input_accepted: accepted,
            code: code
          }}, s}

      _ ->
        {:reply, Games.error(:not_authorized), s}
    end
  end

  def handle_call({:host, host, request_id, session_id, action}, _from, s) do
    s = expire(s)

    if host?(host) and Controllers.id?(request_id) do
      case host_operation(s, host, request_id, session_id, action) do
        {reply, next} -> {:reply, reply, next}
      end
    else
      {:reply, Games.error(:not_authorized), s}
    end
  end

  def handle_call({:read_operation, host, id}, _from, s) do
    result =
      with true <- host?(host),
           true <- Controllers.id?(id) || {:error, :not_found},
           {:ok, operation} <-
             GameStore.read_operation(s.checkpoint.game_id, id, host.subject_id),
           true <- host?(host) do
        {:ok, operation}
      else
        false -> Games.error(:not_authorized)
        {:error, code} -> Games.error(fixed_error(code))
      end

    {:reply, result, s}
  end

  def handle_call({:recovery, operation, host, id, args}, _from, s) do
    s = expire(s)

    if host?(host) do
      {result, s} = Vault.Recovery.perform(s, operation, host, id, args)
      {:reply, result, s}
    else
      {:reply, Games.error(:not_authorized), s}
    end
  end

  def handle_call({:disconnect, actor, reason}, {caller, _}, s) do
    case actor_binding(s, actor, caller, false) do
      {:ok, _} -> {:reply, :ok, remove_actor(s, actor.actor_id, reason)}
      _ -> {:reply, :ok, s}
    end
  end

  def handle_call({:prepare_simulated, host}, from, s), do: start_service(s, host, :prepare, from)

  def handle_call({:attest_sealed_record, host, args}, _from, s) do
    s = expire_query(s)

    if host?(host) do
      {result, next} = Vault.Recovery.attest_sealed_record(s, host, args)
      {:reply, result, next}
    else
      {:reply, Games.error(:not_authorized), s}
    end
  end

  def handle_call({:service, host, request}, from, s),
    do: start_service(s, host, {:request, request}, from)

  def handle_call({:service_operation, host, command, args}, from, s),
    do: start_service(s, host, {:operation, command, args}, from)

  def handle_call({:exit_simulated, host}, from, s),
    do:
      start_service(
        s,
        host,
        {:operation, "service.exit", %{"binding" => Vault.Recovery.binding(s)}},
        from
      )

  def handle_call({:recovery_step, host, step, args}, from, s) do
    case Vault.Recovery.service_step(s, host, step, args) do
      {:ok, command, service_args} ->
        start_service(s, host, {:operation, command, service_args}, from)

      {:error, code} ->
        {:reply, Games.error(code), s}
    end
  end

  def handle_call({:fault_simulated, host, :reconnect}, _from, s) do
    if host?(host) and simulated?(s) and not external_box_configured?() do
      send(self(), {:connect_box, s.checkpoint.session_id})
      {:reply, :ok, s}
    else
      {:reply, Games.error(:not_authorized), s}
    end
  end

  def handle_call({:fault_simulated, host, fault}, _from, s) do
    if host?(host) and simulated?(s) and not external_box_configured?() and
         fault in [:disconnect, :reboot, :lost_ack, :interrupt] do
      {:reply, Adapter.fault(s.runtime, fault), s}
    else
      {:reply, Games.error(:not_authorized), s}
    end
  end

  def handle_call(
        {:box_observation, actor, %{status: report, comparison: comparison} = validated, query},
        {caller, _},
        s
      ) do
    s = expire_query(s)

    with {:ok, %{actor: %{source: :box}}} <- actor_binding(s, actor, caller),
         true <- actor.actor_id == s.box.actor_id and s.box.connected,
         true <-
           report.connection_id == actor.connection_id and report.box_boot_id == actor.boot_id and
             report.session_id == s.checkpoint.session_id,
         true <- truthful_simulation?(s, report) do
      cached = s.box.status_cache[report.status_seq]
      stale = report.status_seq <= s.box.status_seq and cached == nil
      next = accept_box_status(s, actor.binding_generation, validated, query)

      cond do
        cached != nil and cached != comparison ->
          {:reply, Games.error(:invalid_binding), remove_actor(next, actor.actor_id, :closed)}

        stale ->
          {:reply, {:ok, %{status_seq: report.status_seq, accepted: false, code: :stale_status}},
           next}

        Map.get(next.box.status_cache, report.status_seq) == comparison ->
          {:reply, {:ok, %{status_seq: report.status_seq, accepted: true, code: :ok}}, next}

        true ->
          {:reply, Games.error(:storage_error), next}
      end
    else
      _ -> {:reply, Games.error(:not_authorized), s}
    end
  end

  def handle_call({:box_observation, _, _, _}, _from, s),
    do: {:reply, Games.error(:not_authorized), s}

  def handle_call(_, _from, s), do: {:reply, Games.error(:not_authorized), s}

  @impl true
  def handle_info(:tick, s) do
    started = DeviceTimingDiagnostics.start(s.timing_diagnostics)
    DeviceTimingDiagnostics.finish(:room_tick, s.heartbeat_tick_due_ms)

    s = expire(s)

    s =
      Enum.reduce(Map.keys(s.actors), s, fn id, acc ->
        b = acc.actors[id]

        if Controllers.valid?(b.actor.principal) do
          seq = b.heartbeat_seq + 1
          issued = now(acc)

          challenges =
            b.challenges
            |> Enum.filter(fn {_, t} -> issued < t + 400 end)
            |> Map.new()
            |> Map.put(seq, issued)

          challenge =
            {:vault_challenge, id, b.actor.connection_id, b.actor.binding_generation, seq}

          challenge =
            if b.delivery,
              do:
                Tuple.insert_at(
                  challenge,
                  tuple_size(challenge),
                  System.monotonic_time(:millisecond) + 400
                ),
              else: challenge

          notify_actor(b, challenge)
          acc = put_in(acc.actors[id], %{b | heartbeat_seq: seq, challenges: challenges})

          if b.actor.source == :box,
            do: %{acc | box: %{acc.box | heartbeat_seq: seq, challenges: challenges}},
            else: acc
        else
          remove_actor(acc, id, :expired)
        end
      end)

    s =
      if s.box.connected and not BoxLink.external?(s) do
        issued = now(s)
        seq = s.box.heartbeat_seq + 1
        Adapter.challenge(s.runtime, s.box.binding_generation, seq, issued)

        challenges =
          s.box.challenges
          |> Enum.filter(fn {_, t} -> issued < t + 400 end)
          |> Map.new()
          |> Map.put(seq, issued)

        %{s | box: %{s.box | heartbeat_seq: seq, challenges: challenges}}
      else
        s
      end

    s = s |> schedule_heartbeat_tick() |> sync_controller_readiness() |> box_feedback()
    DeviceTimingDiagnostics.finish(:room_tick_work, started)
    {:noreply, s}
  end

  def handle_info({:qualify, session_id, generation}, s) do
    s = expire(s)

    if session_id == s.checkpoint.session_id do
      eligibility = if controllers_ready?(s) and box_ready?(s), do: :eligible, else: :ineligible

      {rules, result, effects} =
        Puzzle.transition(s.puzzle, s.rules, {:qualify, generation, eligibility}, now(s))

      s =
        if :commit_solve_and_release_intent in effects and elem(result, 0) == :applied,
          do: win(s, rules, generation),
          else: run_effects(%{s | rules: rules}, effects)

      {:noreply, s}
    else
      {:noreply, s}
    end
  end

  def handle_info(:publish, s), do: {:noreply, publish(%{s | publish_timer: nil})}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, s) do
    if s.box.monitor == ref do
      s = %{
        s
        | box: %{empty_box() | binding_generation: s.box.binding_generation},
          query: nil,
          seal_attestation: nil,
          close_evidence: nil,
          seal_check: nil
      }

      retry_box(s)
      {:noreply, offline_pause(s, :box_offline) |> visible()}
    else
      id = Enum.find_value(s.actors, fn {id, b} -> if b.monitor == ref, do: id end)
      {:noreply, if(id, do: remove_actor(s, id, :closed), else: s)}
    end
  end

  def handle_info({:connect_box, session_id}, s) do
    if simulated?(s) and not external_box_configured?() and session_id == s.checkpoint.session_id and
         not s.box.connected do
      case Adapter.boot_id(s.runtime) do
        {:ok, boot_id} ->
          generation = System.unique_integer([:positive, :monotonic])

          box = %{
            empty_box()
            | boot_id: boot_id,
              connection_id: Controllers.id("conn"),
              binding_generation: generation,
              connected: true,
              bound_at_ms: now(s)
          }

          binding = %{
            connection_id: box.connection_id,
            session_id: session_id,
            binding_generation: generation
          }

          case Adapter.bind(s.runtime, boot_id, binding) do
            :ok ->
              if s.box.monitor, do: Process.demonitor(s.box.monitor, [:flush])
              runtime_pid = if is_pid(s.runtime), do: s.runtime, else: Process.whereis(s.runtime)
              box = %{box | monitor: Process.monitor(runtime_pid), runtime_pid: runtime_pid}

              s = %{
                s
                | box: box,
                  generation: generation,
                  query: nil,
                  seal_attestation: nil,
                  close_evidence: nil,
                  seal_check: nil
              }

              BoxLink.query(s, s.checkpoint.release_command_id, nil)
              {:noreply, visible(s)}

            _ ->
              retry_box(s)
              {:noreply, s}
          end

        _ ->
          retry_box(s)
          {:noreply, s}
      end
    else
      {:noreply, s}
    end
  end

  def handle_info({:query_bound_box, generation}, s) do
    s =
      if s.box.connected and generation == s.box.binding_generation do
        if s.checkpoint.release_command_id do
          {_, next} = Vault.Recovery.request_query(s)
          next
        else
          BoxLink.query(s, nil, nil)
          s
        end
      else
        s
      end

    {:noreply, s}
  end

  def handle_info({:box_query_timeout, session, id}, s) do
    next =
      if session == s.checkpoint.session_id and s.query != nil and s.query.query_id == id,
        do: expire_query(s),
        else: s

    {:noreply, next}
  end

  def handle_info({:simulated_box, :heartbeat, generation, boot_id, seq, input_seq}, s) do
    issue = s.box.challenges[seq]

    if s.box.connected and generation == s.box.binding_generation and boot_id == s.box.boot_id and
         is_integer(issue) and
         now(s) < issue + 400 and input_seq > s.box.input_seq and seq >= s.box.last_challenge do
      s = %{
        s
        | box: %{
            s.box
            | last_seen_ms: now(s),
              lease_until_ms: issue + 400,
              input_seq: input_seq,
              last_challenge: seq
          }
      }

      {:noreply, clear_offline(s)}
    else
      {:noreply, s}
    end
  end

  def handle_info({:simulated_box, :status, generation, report, query}, s) do
    {:noreply, accept_box_status(s, generation, report, query)}
  end

  def handle_info({:simulated_box, :unbound, generation, reason}, s) do
    s =
      if generation == s.box.binding_generation do
        s = %{
          s
          | box: %{
              s.box
              | connected: false,
                report: nil,
                lease_until_ms: nil,
                service_ready: false
            },
            query: nil,
            seal_attestation: nil,
            close_evidence: nil,
            seal_check: nil
        }

        s = offline_pause(s, :box_offline)
        # Service and reboots deliberately replace the transport; new binding grants no arm.
        if reason != :disconnect,
          do:
            Clock.schedule_at(
              s.clock,
              self(),
              {:connect_box, s.checkpoint.session_id},
              now(s) + 100
            )

        visible(s)
      else
        s
      end

    {:noreply, s}
  end

  def handle_info({:simulated_box, :boot, device, _boot}, s) do
    if device == s.record.game.box_device_id,
      do: send(self(), {:connect_box, s.checkpoint.session_id})

    {:noreply, s}
  end

  def handle_info({:seal_readback_timeout, tag}, s) do
    next = Vault.Recovery.seal_readback_timeout(s, tag)
    {:noreply, if(next == s, do: s, else: visible(next))}
  end

  def handle_info({:service_timeout, tag}, s) do
    case Map.pop(s.service_pending, tag) do
      {nil, _} ->
        {:noreply, s}

      {%{from: from}, pending} ->
        GenServer.reply(from, Games.error(:readback_required))

        {:noreply,
         %{
           s
           | service_pending: pending,
             service_result: %{"status" => "error", "code" => "commit_uncertain"}
         }
         |> visible()}
    end
  end

  def handle_info({:simulated_box, :service, {:seal_readback, _} = tag, result}, s) do
    next = Vault.Recovery.seal_readback(s, tag, result)
    {:noreply, if(next == s, do: s, else: visible(next))}
  end

  def handle_info({:simulated_box, :service, tag, result}, s) do
    case Map.pop(s.service_pending, tag) do
      {nil, _} ->
        {:noreply, s}

      {%{from: from, host: host, kind: kind, timer: timer, deadline: deadline}, pending} ->
        Clock.cancel(s.clock, timer)

        result =
          if now(s) < deadline,
            do: result,
            else: %{"status" => "error", "code" => "commit_uncertain"}

        s = %{s | service_pending: pending, service_result: result}

        s =
          case {kind, result} do
            {{:operation, "service.exit", %{"binding" => binding}}, %{"status" => "ok"}} ->
              put_in(
                s.box.service_ready,
                s.box.connected and binding == Vault.Recovery.binding(s)
              )

            _ ->
              s
          end

        s = Vault.Recovery.service_completed(s, kind, result)

        reply =
          cond do
            not host?(host) -> Games.error(:not_authorized)
            now(s) >= deadline -> Games.error(:readback_required)
            true -> {:ok, %{simulated: true, receipt: result}}
          end

        GenServer.reply(from, reply)
        {:noreply, visible(s)}
    end
  end

  def handle_info(_, s), do: {:noreply, s}

  defp schedule_heartbeat_tick(s) do
    due = now(s) + 100
    Clock.schedule_at(s.clock, self(), :tick, due)
    %{s | heartbeat_tick_due_ms: if(s.timing_diagnostics, do: due)}
  end

  defp controller_command(s, b, %Context{} = context, action) do
    cond do
      context.connection_id != b.actor.connection_id or
          context.session_id != s.checkpoint.session_id ->
        {s, :rejected, :stale_session, %{}}

      match?({:claim_role, _}, action) ->
        claim(s, b, elem(action, 1))

      action == :request_snapshot ->
        {publish(s), :applied, :snapshot_sent, %{}}

      b.actor.role == nil or s.owners[b.actor.role] != b.actor.actor_id or
        context.role != b.actor.role or context.control_epoch != b.actor.control_epoch ->
        {s, :rejected, :stale_controller, %{}}

      action == :release_role ->
        {revoke(s, b.actor.role, :role_changed), :applied, :role_released, %{}}

      context.round_id != s.checkpoint.round_id ->
        {s, :rejected, :stale_round, %{round_id: s.checkpoint.round_id}}

      context.puzzle_revision != s.checkpoint.puzzle_revision ->
        {s, :rejected, :stale_puzzle, %{puzzle_revision: s.checkpoint.puzzle_revision}}

      true ->
        rule_action =
          case action do
            {:move, direction, board} -> {:move, b.actor.role, direction, board}
            {:select_rune, rune} -> {:select_rune, b.actor.role, rune}
            _ -> :invalid
          end

        {rules, {status, code, data}, effects} =
          Puzzle.transition(s.puzzle, s.rules, rule_action, now(s))

        if status == :applied do
          qualify = fn ->
            Controllers.valid?(b.actor.principal) and Process.alive?(b.actor.owner_pid)
          end

          case commit(
                 s,
                 rules,
                 :checkpoint,
                 nil,
                 Controllers.id("request"),
                 %{"actor" => b.actor.actor_id, "action" => json_value(action)},
                 qualify: qualify
               ) do
            {:ok, next, _receipt} ->
              next = run_effects(next, effects) |> visible(false)

              next =
                if rules.phase != s.rules.phase, do: invalidate(next, :role_changed), else: next

              {next, status, code, data}

            {:error, next, _} ->
              {next, :rejected, :not_authorized, %{}}
          end
        else
          {s, status, code, data}
        end
    end
  end

  defp controller_command(s, _, _, _), do: {s, :rejected, :stale_session, %{}}

  defp claim(s, b, role) do
    cond do
      role not in [:a, :b] or role not in b.actor.principal.allowed_roles or
          (b.panel != nil and b.panel != role) ->
        {s, :rejected, :not_authorized, %{}}

      s.owners[role] != nil and s.owners[role] != b.actor.actor_id ->
        {s, :rejected, :role_busy, %{}}

      b.actor.role != nil and b.actor.role != role ->
        {s, :rejected, :role_busy, %{}}

      s.owners[role] == b.actor.actor_id ->
        {s, :applied, :role_claimed, %{role: role, control_epoch: b.actor.control_epoch}}

      true ->
        epoch = s.epochs[role] + 1
        actor = %{b.actor | role: role, control_epoch: epoch}

        {rules, _, effects} =
          Puzzle.transition(s.puzzle, s.rules, {:invalidate_input, role, :new_boot}, now(s))

        s =
          s
          |> put_in([:actors, actor.actor_id], %{b | actor: actor, neutral: false})
          |> put_in([:owners, role], actor.actor_id)
          |> put_in([:epochs, role], epoch)

        s = run_effects(%{s | rules: rules}, effects) |> visible()
        context_message(s, actor, :role_changed)
        {s, :applied, :role_claimed, %{role: role, control_epoch: epoch}}
    end
  end

  defp sample(s, b, input) do
    issued = b.challenges[input.heartbeat_seq]

    cond do
      not Controllers.number?(input.input_seq, 1) or input.input_seq <= b.input_seq ->
        {s, false, :stale_sample}

      not Controllers.number?(input.heartbeat_seq, 1) or input.heartbeat_seq < b.last_challenge or
        not is_integer(issued) or now(s) >= issued + 400 ->
        {s, false, :stale_challenge}

      b.actor.role == nil and (input.context != nil or input.pressed or input.press_id != nil) ->
        {s, false, :stale_context}

      b.actor.role != nil and
          not Controllers.same_context?(input.context, Controllers.context(b.actor, s.checkpoint)) ->
        {s, false, :stale_context}

      not is_boolean(input.pressed) or
        (input.pressed and not Controllers.number?(input.press_id, 1)) or
          (not input.pressed and input.press_id != nil) ->
        {s, false, :stale_sample}

      input.pressed and input.press_id <= b.press_high and
          not (b.actor.role != nil and s.rules.inputs[b.actor.role].press_id == input.press_id) ->
        {s, false, :must_release}

      true ->
        before_sample = s
        sample_at = now(s)
        was_fresh = controller_sample_fresh?(b, sample_at)

        b = %{
          b
          | press_high:
              if(input.pressed, do: max(b.press_high, input.press_id), else: b.press_high),
            input_seq: input.input_seq,
            last_challenge: input.heartbeat_seq,
            last_seen_ms: sample_at,
            neutral: not input.pressed,
            lease_until_ms: issued + 400
        }

        s = put_in(s.actors[b.actor.actor_id], b)
        s = put_in(s.press_history[b.boot_key], b.press_high)

        s =
          if b.actor.source == :box do
            %{
              s
              | box: %{
                  s.box
                  | last_seen_ms: now(s),
                    lease_until_ms: issued + 400,
                    input_seq: input.input_seq,
                    last_challenge: input.heartbeat_seq
                }
            }
          else
            s
          end

        if b.actor.role == nil do
          {clear_offline(s), true, if(s.rules.paused, do: :paused, else: :ok)}
        else
          action =
            {:input, b.actor.role,
             if(input.pressed, do: {:pressed, input.press_id}, else: :released), issued + 400}

          {rules, {_status, code, _}, effects} =
            Puzzle.transition(s.puzzle, s.rules, action, now(s))

          # A syntactically fresh but rejected input (for example, a press
          # before its neutral baseline) cannot renew transport liveness.
          accepted = code in [:ok, :paused]
          s = if accepted, do: s, else: before_sample
          # One peer can become fresh while aggregate readiness stays false.
          changed =
            (accepted and not was_fresh) or
              visible_input(s.rules, now(s)) != visible_input(rules, now(s))

          s = run_effects(%{s | rules: rules}, effects)
          s = if changed, do: visible(s), else: s
          s = clear_offline(s)

          {s, accepted, if(code in [:ok, :paused, :must_release], do: code, else: :stale_context)}
        end
    end
  end

  defp host_operation(s, host, id, expected_session, action) do
    request = %{"expected_session_id" => expected_session, "action" => json_value(action)}
    # Retry lookup compares the complete normalized operation inside commit; readiness
    # predicates run only for a new decision, not after an already committed receipt.
    case GameStore.read_operation(s.checkpoint.game_id, id, host.subject_id) do
      {:ok, _} ->
        case commit(s, s.rules, action_tag(action), host, id, request,
               expected_session: expected_session
             ) do
          {:ok, next, receipt} -> {{:ok, receipt}, next}
          {:error, next, code} -> {Games.error(code), next}
        end

      _ ->
        host_new(s, host, id, expected_session, action, request)
    end
  end

  defp host_new(s, host, id, expected, action, request) do
    cond do
      expected != s.checkpoint.session_id ->
        {Games.error(:stale_session), s}

      action in [:start, :resume, :arm] and not controllers_ready?(s) ->
        {Games.error(:not_ready), s}

      action in [:start, :resume] and not box_ready?(s) ->
        {Games.error(:not_ready), s}

      action in [:pause, :reset] and not reset_or_pause_allowed?(s, action) ->
        {Games.error(:unresolved_release), s}

      action in [:arm, :disarm] ->
        if not s.box.connected or (action == :arm and not armable?(s)) do
          {Games.error(:not_ready), s}
        else
          arm =
            if action == :arm,
              do: Controllers.id("arm"),
              else: get_in(s.box.report || %{}, [:readiness, :arm_id])

          result_data = %{arm_id: arm}

          qualify = fn ->
            host?(host) and s.box.connected and
              (action == :disarm or (controllers_ready?(s) and armable?(s)))
          end

          case commit(s, s.rules, action, host, id, request,
                 result_data: result_data,
                 qualify: qualify
               ) do
            {:ok, next, receipt} ->
              if action == :arm,
                do: BoxLink.arm(s, arm),
                else: maybe_disarm(s, arm)

              {{:ok, receipt}, visible(next, false)}

            {:error, next, code} ->
              {Games.error(code), next}
          end
        end

      match?({:replace_controller, _, _}, action) ->
        replace_controller(s, host, id, action, request)

      action in [:start, :pause, :resume, :reset] ->
        rule_action = if action == :pause, do: {:pause, [:operator]}, else: action

        {rules, {status, _code, _data}, effects} =
          Puzzle.transition(s.puzzle, s.rules, rule_action, now(s))

        if status == :applied do
          qualify = fn ->
            host?(host) and
              case action do
                action when action in [:start, :resume] -> controllers_ready?(s) and box_ready?(s)
                :reset -> reset_or_pause_allowed?(s, :reset)
                :pause -> reset_or_pause_allowed?(s, :pause)
              end
          end

          options = [qualify: qualify]

          options =
            if action == :reset,
              do: Keyword.put(options, :new_session, Controllers.id("session")),
              else: options

          case commit(s, rules, action, host, id, request, options) do
            {:ok, next, receipt} ->
              next = run_effects(next, effects)

              next =
                cond do
                  action == :reset ->
                    rotate_session(next, s.checkpoint.session_id)

                  action in [:pause, :resume] ->
                    invalidate(next, if(action == :pause, do: :paused, else: :resumed))

                  true ->
                    next
                end

              if action == :pause, do: maybe_disarm(s)
              {{:ok, receipt}, visible(next, false)}

            {:error, next, code} ->
              {Games.error(code), next}
          end
        else
          {Games.error(:wrong_phase), s}
        end

      true ->
        {Games.error(:not_authorized), s}
    end
  end

  defp replace_controller(s, host, id, {:replace_controller, role, target}, request) do
    target_binding = s.actors[target]

    qualify = fn ->
      host?(host) and role in [:a, :b] and target_binding != nil and
        role in target_binding.actor.principal.allowed_roles and
        target_binding.actor.role in [nil, role] and target_binding.panel in [nil, role] and
        Process.alive?(target_binding.actor.owner_pid) and
        Controllers.valid?(target_binding.actor.principal)
    end

    if qualify.() do
      {rules, _, effects} =
        Puzzle.transition(s.puzzle, s.rules, {:pause, [:operator, :recovery]}, now(s))

      epoch = s.epochs[role] + 3

      assignment = %{
        game_id: s.checkpoint.game_id,
        role: Atom.to_string(role),
        device_id:
          if(target_binding.actor.principal.kind == :device,
            do: target_binding.actor.principal.subject_id
          ),
        browser_credential_id:
          if(target_binding.actor.principal.kind != :device,
            do: target_binding.actor.principal.subject_id
          ),
        updated_at_ms: System.system_time(:millisecond)
      }

      case commit(s, rules, :replace_controller, host, id, request,
             assignment: assignment,
             qualify: qualify,
             result_data: %{role: role, actor_id: target, control_epoch: epoch}
           ) do
        {:ok, next, receipt} ->
          next = revoke(next, role, :role_changed, false)
          {next, _, _, _} = claim(next, next.actors[target], role)
          next = run_effects(next, effects) |> invalidate(:paused)
          maybe_disarm(s)
          {{:ok, receipt}, next}

        {:error, next, code} ->
          {Games.error(code), next}
      end
    else
      {Games.error(:not_ready), s}
    end
  end

  @doc false
  def commit(s, rules, operation, host, id, request, opts \\ []) do
    new_session = Keyword.get(opts, :new_session)
    checkpoint = checkpoint(s, rules, new_session)

    checkpoint =
      if Keyword.has_key?(opts, :command),
        do: %{checkpoint | release_command_id: opts[:command].command_id},
        else: checkpoint

    receipt = %Receipt{
      request_id: id,
      operation: operation,
      game_id: checkpoint.game_id,
      session_id: checkpoint.session_id,
      state_revision: checkpoint.state_revision,
      data: Keyword.get(opts, :result_data, %{})
    }

    result = Keyword.get(opts, :result, json_value(receipt))

    args = %{
      game_id: checkpoint.game_id,
      expected_revision: s.checkpoint_revision,
      expected_session_id: Keyword.get(opts, :expected_session, s.checkpoint.session_id),
      request_id: id,
      operation: operation,
      operator_credential_id: if(host, do: host.subject_id),
      request: request,
      checkpoint: if(Keyword.get(opts, :no_checkpoint, false), do: nil, else: checkpoint),
      result: result
    }

    qualify = Keyword.get(opts, :qualify, fn -> is_nil(host) or host?(host) end)

    store_options =
      opts
      |> Keyword.drop([:new_session, :result_data, :result, :no_checkpoint, :expected_session])
      |> Keyword.put(:qualify, qualify)
      |> Keyword.put(:authorize, fn -> is_nil(host) or host?(host) end)

    started = DeviceTimingDiagnostics.start(s.timing_diagnostics and !opts[:no_checkpoint])

    try do
      case GameStore.commit(args, store_options) do
        {:ok, %{status: :replayed} = saved} ->
          {:ok, s, receipt_from(saved.result, operation)}

        {:ok, saved} ->
          {:ok, record} = GameStore.load(checkpoint.game_id)

          next = %{
            s
            | rules: rules,
              checkpoint: if(opts[:no_checkpoint], do: s.checkpoint, else: checkpoint),
              checkpoint_revision: saved.checkpoint_revision,
              record: record,
              release: Vault.Recovery.release(record),
              last_active_ms: now(s)
          }

          {:ok, next, if(Keyword.has_key?(opts, :result), do: saved.result, else: receipt)}

        {:error, :readback_required} ->
          {:error, uncertain_commit(s, args, host), :readback_required}

        {:error, :storage_error} ->
          {:error, storage_fault(s), :storage_error}

        {:error, code} ->
          {:error, s, fixed_error(code)}
      end
    after
      DeviceTimingDiagnostics.finish(:room_checkpoint, started)
    end
  end

  defp checkpoint(s, rules, new_session) do
    cp =
      Map.merge(
        s.checkpoint,
        Map.take(Map.from_struct(rules), [
          :phase,
          :position,
          :board_version,
          :selected_runes,
          :paused,
          :pause_reasons
        ])
      )

    elapsed =
      if s.rules.phase in [:maze, :seal] and not s.rules.paused,
        do: max(0, now(s) - s.last_active_ms),
        else: 0

    cp = %{
      cp
      | state_revision: cp.state_revision + 1,
        active_time_ms: cp.active_time_ms + elapsed
    }

    if new_session do
      %{
        cp
        | session_id: new_session,
          state_revision: 0,
          round_id: 1,
          active_time_ms: if(rules.phase == :lobby, do: 0, else: cp.active_time_ms),
          release_command_id: if(rules.phase == :lobby, do: nil, else: cp.release_command_id)
      }
    else
      cp
    end
  end

  defp win(s, rules, generation) do
    binding = %{
      box_boot_id: s.box.boot_id,
      connection_id: s.box.connection_id,
      session_id: s.checkpoint.session_id,
      arm_id: get_in(s.box.report, [:readiness, :arm_id]),
      heartbeat_seq: s.box.last_challenge,
      binding_generation: s.box.binding_generation
    }

    command = %{
      command_id: Controllers.id("command"),
      game_id: s.checkpoint.game_id,
      original_session_id: s.checkpoint.session_id,
      original_round_id: s.checkpoint.round_id,
      puzzle_revision: s.checkpoint.puzzle_revision,
      intended_box_id: s.record.game.box_device_id,
      action: "set_latch",
      target: "released",
      dispatch_binding_json: canonical!(binding),
      dispatch_claimed: false,
      dispatch_retired: false,
      retired_at_ms: nil,
      history_revision: 0,
      created_at_ms: System.system_time(:millisecond)
    }

    qualify = fn ->
      controllers_ready?(s) and box_ready?(s) and
        elem(Puzzle.transition(s.puzzle, s.rules, {:qualify, generation, :eligible}, now(s)), 0).phase ==
          :solved
    end

    case commit(
           s,
           rules,
           :win,
           nil,
           Controllers.id("request"),
           %{"command_id" => command.command_id},
           command: command,
           qualify: qualify,
           result_data: %{command_id: command.command_id}
         ) do
      {:ok, next, _} ->
        # Only this post-commit branch holds a live dispatch ticket. Neither load nor
        # receipt readback reconstructs it. The immutable binding is checked again.
        if qualify.() and next.checkpoint.session_id == binding.session_id do
          case GameStore.claim_dispatch(
                 next.checkpoint.game_id,
                 command.command_id,
                 json_value(binding)
               ) do
            {:ok, _} ->
              if qualify.() and
                   GameStore.dispatch_current?(
                     next.checkpoint.game_id,
                     command.command_id,
                     json_value(binding)
                   ) do
                BoxLink.release(s, binding, command.command_id)
              end

            _ ->
              :ok
          end
        end

        visible(next, false)

      {:error, next, _} ->
        next
    end
  end

  defp accept_box_status(
         s,
         generation,
         %{status: report, original_json: original, comparison: comparison},
         query
       ) do
    current =
      s.box.connected and generation == s.box.binding_generation and
        report.connection_id == s.box.connection_id and
        report.box_boot_id == s.box.boot_id and report.session_id == s.checkpoint.session_id

    seq = report.status_seq
    cached = s.box.status_cache[seq]

    if current and cached == comparison do
      BoxLink.ack(s, seq)
      s
    else
      classification =
        cond do
          not current -> "stale"
          cached != nil or seq == s.box.status_seq -> "content_conflict"
          seq < s.box.status_seq -> "stale"
          true -> "admitted"
        end

      attrs = %{
        observation_id: Controllers.id("observation"),
        command_id: report.command_id,
        source_device_id: s.record.game.box_device_id,
        box_boot_id: report.box_boot_id,
        connection_id: report.connection_id,
        current_session_id: report.session_id,
        status_seq: seq,
        report_sha256: :crypto.hash(:sha256, comparison),
        report_json: original,
        comparison: comparison,
        classification: classification,
        query_id: if(is_map(query), do: query.query_id),
        observed_at_ms: System.system_time(:millisecond)
      }

      persisted = if report.command_id != nil, do: GameStore.observe(attrs), else: {:ok, nil}

      case persisted do
        {:ok, saved} ->
          stored = if is_map(saved), do: Map.get(saved, :observation, attrs), else: attrs
          old_view = Projections.box(s)

          s =
            if report.command_id != nil do
              case GameStore.load(s.checkpoint.game_id) do
                {:ok, record} -> %{s | record: record, release: Vault.Recovery.release(record)}
                _ -> storage_fault(s)
              end
            else
              s
            end

          if current and stored.classification == "admitted" and classification == "admitted" do
            cache =
              Map.put(s.box.status_cache, seq, comparison)
              |> Enum.sort_by(&elem(&1, 0), :desc)
              |> Enum.take(16)
              |> Map.new()

            s = %{s | box: %{s.box | report: report, status_seq: seq, status_cache: cache}}

            s =
              if report.motor_active or report.readiness.arm_id != nil,
                do: %{s | close_evidence: nil, seal_attestation: nil},
                else: s

            s = Vault.Recovery.query_observation(s, stored, report, query)
            BoxLink.ack(s, seq)
            if Projections.box(s) != old_view or query != nil, do: visible(s), else: s
          else
            # Retain evidence, but a conflict never grants readiness or closure.
            s =
              if stored.classification in ["identity_conflict", "content_conflict"],
                do: %{s | close_evidence: nil, seal_attestation: nil},
                else: s

            if Projections.box(s) != old_view, do: visible(s), else: s
          end

        {:error, code} when code in [:storage_error, :readback_required] ->
          storage_fault(s)

        _ ->
          diagnostic(s, :invalid_box_observation)
      end
    end
  end

  defp accept_box_status(s, _, _, _), do: s

  defp start_service(s, host, kind, from) do
    if host?(host) and simulated?(s) and not external_box_configured?() and
         map_size(s.service_pending) < 2 do
      tag = make_ref()

      s =
        case kind do
          {:operation, command, _} when command in ["inspect", "operation.get", "service.exit"] ->
            s

          {:request, %{"command" => command}} when command in ["inspect", "operation.get"] ->
            s

          _ ->
            put_in(s.box.service_ready, false)
        end

      result =
        case kind do
          :prepare ->
            Adapter.prepare_async(s.runtime, tag)

          {:request, request} ->
            Adapter.request_service(s.runtime, request, tag)

          {:operation, command, args} ->
            Adapter.service_operation_async(s.runtime, command, args, tag)
        end

      if result == :ok do
        deadline = now(s) + 3_000
        timer = Clock.schedule_at(s.clock, self(), {:service_timeout, tag}, deadline)

        pending =
          Map.put(s.service_pending, tag, %{
            from: from,
            host: host,
            kind: kind,
            timer: timer,
            deadline: deadline
          })

        {:noreply, %{s | service_pending: pending}}
      else
        {:reply, Games.error(:not_ready), s}
      end
    else
      {:reply, Games.error(:not_authorized), s}
    end
  end

  defp actor_binding(s, actor, caller, validate \\ true)

  defp actor_binding(s, %Actor{} = actor, caller, validate) do
    case s.actors[actor.actor_id] do
      %{actor: saved} = binding
      when saved.owner_pid == caller and saved.connection_id == actor.connection_id and
             saved.binding_generation == actor.binding_generation and
             saved.principal == actor.principal and saved.session_id == actor.session_id ->
        if not validate or Controllers.valid?(saved.principal), do: {:ok, binding}, else: :error

      _ ->
        :error
    end
  end

  defp actor_binding(_, _, _, _), do: :error

  defp expire(s) do
    s = expire_query(s)
    before = visible_input(s.rules, now(s) - 1)
    {rules, _, effects} = Puzzle.transition(s.puzzle, s.rules, :expire_inputs, now(s))
    s = run_effects(%{s | rules: rules}, effects)
    s = if before != visible_input(rules, now(s)), do: visible(s), else: s

    s =
      Enum.reduce(s.owners, s, fn {_role, id}, acc ->
        if id != nil do
          b = acc.actors[id]

          if b != nil and
               now(acc) >= (b.last_seen_ms || b.bound_at_ms) + @controller_freshness_ms,
             do: offline_pause(acc, :controller_offline),
             else: acc
        else
          acc
        end
      end)

    if s.box.connected and now(s) >= (s.box.last_seen_ms || s.box.bound_at_ms) + 1500 do
      BoxLink.unbind(s, :expired)

      offline_pause(
        %{
          s
          | box: %{
              s.box
              | connected: false,
                report: nil,
                lease_until_ms: nil,
                service_ready: false
            }
        },
        :box_offline
      )
    else
      s
    end
  end

  defp expire_query(s) do
    if s.query != nil and now(s) >= s.query.deadline_ms do
      s = %{s | query: nil, seal_attestation: nil, close_evidence: nil}
      # V1 has no echoed query ID. Retire the binding before another request so
      # a late reply cannot be mistaken for the next recovery observation.
      if BoxLink.external?(s) do
        remove_actor(s, s.box.actor_id, :closed)
      else
        BoxLink.unbind(s, :query_timeout)
        offline_pause(s, :box_offline)
      end
    else
      s
    end
  end

  defp offline_pause(s, reason) do
    if s.rules.phase != :solved and reason not in s.rules.pause_reasons do
      {rules, _, effects} =
        Puzzle.transition(s.puzzle, s.rules, {:pause, [reason, :recovery]}, now(s))

      next =
        case commit(s, rules, :checkpoint, nil, Controllers.id("request"), %{
               "reason" => Atom.to_string(reason)
             }) do
          {:ok, next, _} -> next
          {:error, next, _} -> next
        end

      if not s.rules.paused, do: maybe_disarm(s)
      run_effects(next, effects) |> invalidate(:disconnected) |> visible(false)
    else
      s
    end
  end

  defp clear_offline(s) do
    reasons = s.rules.pause_reasons

    reasons =
      if controllers_fresh?(s), do: List.delete(reasons, :controller_offline), else: reasons

    reasons = if box_fresh?(s), do: List.delete(reasons, :box_offline), else: reasons

    if reasons != s.rules.pause_reasons do
      rules = %{s.rules | pause_reasons: reasons}

      case commit(s, rules, :checkpoint, nil, Controllers.id("request"), %{
             "freshness_restored" => true
           }) do
        {:ok, next, _} -> visible(next, false)
        {:error, next, _} -> next
      end
    else
      s
    end
  end

  defp remove_actor(s, id, reason) do
    case s.actors[id] do
      nil ->
        s

      b ->
        send(b.actor.owner_pid, {:vault_disconnect, id, reason})
        Process.demonitor(b.monitor, [:flush])
        s = if b.actor.role != nil, do: revoke(s, b.actor.role, reason), else: s

        s =
          if b.actor.source == :box and s.box.actor_id == id do
            %{
              s
              | box: %{empty_box() | transport: :external},
                query: nil,
                close_evidence: nil,
                seal_check: nil,
                seal_attestation: nil
            }
            |> offline_pause(:box_offline)
          else
            s
          end

        %{s | actors: Map.delete(s.actors, id)} |> visible()
    end
  end

  defp revoke(s, role, reason, pause? \\ true) do
    id = s.owners[role]

    s =
      if id && s.actors[id] do
        b = s.actors[id]
        actor = %{b.actor | role: nil, control_epoch: nil}
        s = put_in(s.actors[id], %{b | actor: actor, neutral: false})
        context_message(s, actor, reason)
        s
      else
        s
      end

    {rules, _, effects} =
      Puzzle.transition(s.puzzle, s.rules, {:invalidate_input, role, :same_boot}, now(s))

    s = s |> put_in([:owners, role], nil) |> put_in([:epochs, role], s.epochs[role] + 1)
    s = run_effects(%{s | rules: rules}, effects)
    s = if pause?, do: offline_pause(s, :controller_offline), else: s
    visible(s)
  end

  @doc false
  def invalidate(s, reason) do
    {rules, _, effects} = Puzzle.transition(s.puzzle, s.rules, :invalidate_inputs, now(s))
    s = %{s | rules: rules}

    s =
      Enum.reduce([:a, :b], s, fn role, acc ->
        epoch = acc.epochs[role] + 1
        acc = put_in(acc.epochs[role], epoch)
        id = acc.owners[role]

        if id && acc.actors[id] do
          b = acc.actors[id]
          actor = %{b.actor | control_epoch: epoch}
          acc = put_in(acc.actors[id], %{b | actor: actor, neutral: false})
          context_message(acc, actor, reason)
          acc
        else
          acc
        end
      end)

    run_effects(s, effects)
  end

  @doc false
  def rotate_session(s, old_session) do
    for {_id, b} <- s.actors,
        do: send(b.actor.owner_pid, {:vault_disconnect, b.actor.actor_id, :session_changed})

    for {_id, b} <- s.actors, do: Process.demonitor(b.monitor, [:flush])
    if not BoxLink.external?(s), do: BoxLink.unbind(s, :session_changed)
    if s.box.monitor, do: Process.demonitor(s.box.monitor, [:flush])
    Updates.session_changed(s.checkpoint.game_id, old_session, s.checkpoint.session_id)
    send(self(), {:connect_box, s.checkpoint.session_id})

    %{
      s
      | actors: %{},
        owners: %{a: nil, b: nil},
        epochs: %{a: 0, b: 0},
        box: empty_box(),
        query: nil,
        seal_attestation: nil,
        close_evidence: nil,
        seal_check: nil
    }
  end

  defp context_message(s, actor, reason),
    do:
      notify_actor(
        s.actors[actor.actor_id],
        {:vault_context, actor, Controllers.context(actor, s.checkpoint), reason}
      )

  defp notify_actor(%{delivery: delivery}, message) when not is_nil(delivery),
    do: VaultWeb.DeviceSocket.deliver(delivery, message)

  defp notify_actor(%{actor: actor}, message), do: send(actor.owner_pid, message)

  defp device_scope(s, %Actor{session_id: session}, _caller)
       when session != s.checkpoint.session_id,
       do: Games.error(:stale_session)

  defp device_scope(s, actor, caller) do
    with {:ok, %{actor: saved}} <- actor_binding(s, actor, caller),
         true <- saved.source in [:cyd, :box] do
      audience =
        cond do
          saved.source == :box and saved.actor_id == s.box.actor_id -> :box
          saved.role != nil and s.owners[saved.role] == saved.actor_id -> {:player, saved.role}
          true -> :public
        end

      {:ok, {s.checkpoint.session_id, audience, saved.control_epoch}}
    else
      _ -> Games.error(:not_authorized)
    end
  end

  defp run_effects(s, effects) do
    Enum.reduce(effects, s, fn
      {:schedule_qualification, generation, due}, acc ->
        ref =
          Clock.schedule_at(
            acc.clock,
            self(),
            {:qualify, acc.checkpoint.session_id, generation},
            due
          )

        %{acc | qualification_timer: ref}

      {:cancel_qualification, _}, acc ->
        if acc.qualification_timer, do: Clock.cancel(acc.clock, acc.qualification_timer)
        %{acc | qualification_timer: nil}

      _, acc ->
        acc
    end)
  end

  @doc false
  def visible(s, increment \\ true) do
    s = %{s | controllers_ready: controllers_ready?(s)}

    s =
      if increment,
        do: put_in(s.checkpoint.state_revision, s.checkpoint.state_revision + 1),
        else: s

    if s.publish_timer == nil do
      due = if s.last_publish_ms, do: max(now(s), s.last_publish_ms + 100), else: now(s)
      %{s | publish_timer: Clock.schedule_at(s.clock, self(), :publish, due)}
    else
      s
    end
  end

  defp sync_controller_readiness(s) do
    if s.controllers_ready == controllers_ready?(s), do: s, else: visible(s)
  end

  defp box_feedback(%{box: %{feedback: nil}} = s), do: s

  defp box_feedback(s) do
    {next, packet} =
      BoxFeedback.tick(
        s.box.feedback,
        s.rules,
        s.puzzle.overlap_ms,
        s.controllers_ready,
        s.release,
        now(s)
      )

    if packet, do: BoxLink.feedback(s, packet)
    put_in(s.box.feedback, next)
  end

  defp publish(s) do
    for audience <- [:host, :public, :box, {:player, :a}, {:player, :b}] do
      Updates.publish(
        s.checkpoint.game_id,
        s.checkpoint.session_id,
        audience,
        Projections.snapshot(s, audience, now(s))
      )
    end

    %{s | last_publish_ms: now(s)}
  end

  defp storage_fault(s) do
    {rules, _, effects} = Puzzle.transition(s.puzzle, s.rules, {:pause, [:recovery]}, now(s))

    s = %{
      s
      | rules: rules,
        checkpoint: %{s.checkpoint | paused: true, pause_reasons: rules.pause_reasons}
    }

    if s.checkpoint.phase != :solved, do: maybe_disarm(s)
    run_effects(s, effects) |> diagnostic(:storage_error) |> invalidate(:paused) |> visible()
  end

  defp uncertain_commit(s, args, host) do
    stopped = storage_fault(s)
    # Resolve the exact operation under current authorization. A committed win is
    # adopted as history in a new paused session; no dispatch ticket is recreated.
    with {:ok, _receipt} <-
           GameStore.retry_operation(args, fn -> is_nil(host) or host?(host) end),
         {:ok, committed} <- GameStore.load(s.checkpoint.game_id),
         {:ok, recovered} <- Vault.Recovery.restart(committed) do
      %{
        stopped
        | record: recovered,
          checkpoint: recovered.checkpoint,
          checkpoint_revision: recovered.game.checkpoint_revision,
          rules: rules_from(recovered.checkpoint),
          release: Vault.Recovery.release(recovered)
      }
      |> rotate_session(s.checkpoint.session_id)
      |> visible(false)
    else
      _ -> stopped
    end
  end

  defp diagnostic(s, code, details \\ %{}),
    do: %{
      s
      | diagnostics:
          Enum.take(
            [
              Map.merge(%{code: code, at_ms: System.system_time(:millisecond)}, details)
              | s.diagnostics
            ],
            200
          )
    }

  defp controllers_fresh?(s),
    do:
      Enum.all?([:a, :b], fn role ->
        b = s.actors[s.owners[role]]

        controller_sample_fresh?(b, now(s)) and
          Controllers.valid?(b.actor.principal) and Process.alive?(b.actor.owner_pid)
      end)

  defp controller_sample_fresh?(%{last_seen_ms: last_seen}, at) when is_integer(last_seen),
    do: at < last_seen + @controller_freshness_ms

  defp controller_sample_fresh?(_, _), do: false

  defp controllers_ready?(s),
    do:
      controllers_fresh?(s) and
        Enum.all?([:a, :b], fn role ->
          b = s.actors[s.owners[role]]

          (s.rules.phase == :seal and not s.rules.paused) or
            (b.neutral and b.lease_until_ms != nil and now(s) < b.lease_until_ms)
        end)

  defp box_fresh?(s),
    do:
      s.box.connected and is_pid(s.box.runtime_pid) and Process.alive?(s.box.runtime_pid) and
        s.box.lease_until_ms != nil and now(s) < s.box.lease_until_ms

  defp armable?(s) do
    r = get_in(s.box.report || %{}, [:readiness]) || %{}

    box_fresh?(s) and (BoxLink.external?(s) or s.box.service_ready) and
      r[:calibration_valid] == true and
      r[:start_verified] == true and
      s.box.report[:motor_active] == false
  end

  defp box_ready?(s),
    do:
      armable?(s) and get_in(s.box.report, [:readiness, :arm_id]) != nil and
        get_in(s.box.report, [:readiness, :armed_session_id]) == s.checkpoint.session_id

  defp host?(%Principal{kind: :host} = p), do: Controllers.valid?(p)
  defp host?(_), do: false
  defp simulated?(s), do: s.record.game.box_mode == "simulated"

  defp truthful_simulation?(s, report) do
    not simulated?(s) or
      (report.latch_position == :unknown and report.position_basis == :unverified and
         report.command_confirmation == nil and report.release_status != :position_confirmed)
  end

  defp external_box_configured?,
    do: Application.get_env(:vault, :simulator_transport, :internal) == :external

  defp reset_or_pause_allowed?(%{release: nil}, _), do: true
  defp reset_or_pause_allowed?(s, :reset), do: Vault.Recovery.reset_allowed?(s)
  defp reset_or_pause_allowed?(_, _), do: false

  defp maybe_disarm(s, arm \\ nil) do
    arm = arm || get_in(s.box.report || %{}, [:readiness, :arm_id])
    if arm && s.box.connected, do: BoxLink.disarm(s, arm)
    :ok
  end

  defp command_result(s, seq, status, code, data),
    do: %CommandResult{
      command_seq: seq,
      status: status,
      code: code,
      session_id: s.checkpoint.session_id,
      state_revision: s.checkpoint.state_revision,
      data: data
    }

  defp action_tag({tag, _, _}), do: tag
  defp action_tag(tag) when tag in [:start, :pause, :resume, :reset, :arm, :disarm], do: tag
  defp action_tag(_), do: :checkpoint

  defp visible_input(rules, _time),
    do:
      {rules.attempt && rules.attempt.generation, rules.inputs.a.press_id != nil,
       rules.inputs.b.press_id != nil}

  defp empty_box,
    do: %{
      boot_id: nil,
      transport: :internal,
      actor_id: nil,
      monitor: nil,
      runtime_pid: nil,
      service_ready: false,
      connection_id: nil,
      binding_generation: 0,
      connected: false,
      report: nil,
      heartbeat_seq: 0,
      last_challenge: 0,
      input_seq: 0,
      last_seen_ms: nil,
      lease_until_ms: nil,
      bound_at_ms: nil,
      challenges: %{},
      status_seq: 0,
      status_cache: %{},
      feedback: nil
    }

  defp retry_box(s),
    do: Clock.schedule_at(s.clock, self(), {:connect_box, s.checkpoint.session_id}, now(s) + 100)

  def now(s), do: Clock.now_ms(s.clock)
  def json_value(%_{} = struct), do: struct |> Map.from_struct() |> json_value()

  def json_value(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), json_value(v)} end)

  def json_value(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> json_value()
  def json_value(list) when is_list(list), do: Enum.map(list, &json_value/1)
  def json_value(value) when value in [true, false, nil], do: value
  def json_value(atom) when is_atom(atom), do: Atom.to_string(atom)
  def json_value(other), do: other

  def canonical!(value) do
    {:ok, bytes} = Vault.JSON.canonical(json_value(value))
    bytes
  end

  defp receipt_from(saved, operation) do
    if Map.has_key?(saved, "data") do
      %Receipt{
        request_id: saved["request_id"],
        operation: operation,
        game_id: saved["game_id"],
        session_id: saved["session_id"],
        state_revision: saved["state_revision"],
        data: saved["data"]
      }
    else
      saved
    end
  end

  defp fixed_error(code)
       when code in [
              :not_authorized,
              :not_found,
              :stale_session,
              :wrong_phase,
              :not_ready,
              :unresolved_release,
              :recovery_exists,
              :recovery_replaced,
              :already_closed,
              :evidence_stale,
              :evidence_mismatch,
              :request_conflict,
              :storage_error,
              :readback_required
            ],
       do: code

  defp fixed_error(_), do: :storage_error
end
