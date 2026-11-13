defmodule Vault.SimulatedBox do
  @moduledoc "Runs one simulated box with independently scheduled motion and serialized storage."

  use GenServer

  alias Vault.Clock
  alias Vault.SimulatedBox.{Adapter, Model, Store}
  alias Vault.SimulatedBox.Model.{Durable, Service}

  @store_deadline 200
  @service_limit 34
  @status_limit 16
  @retry_ms 500
  @status_retries 3
  @maximum 9_007_199_254_740_991
  @refusals ~w(not_armed unknown_position stale_binding busy history_full)a

  defstruct [
    :model,
    :clock,
    :store_worker,
    :trace,
    :maintenance_owner,
    :owner,
    :owner_id,
    :owner_monitor,
    :store_operation,
    :unresolved_readback,
    :reboot_boot,
    :preparation,
    :highest_binding,
    timers: %{},
    replies: %{},
    statuses: %{},
    status_seq: 0,
    input_seq: 0,
    outputs_active: false,
    lost_ack: false
  ]

  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    instance = Keyword.fetch!(opts, :instance_id)
    device = Keyword.fetch!(opts, :device_id)
    clock = Keyword.get(opts, :clock, Clock.system())
    store = Keyword.get(opts, :store, Store)
    parent = self()

    with {:ok, handle, document} <- open_store(store, path, instance, device),
         {:ok, model, effects} <-
           Model.new(
             Store.config(instance, device),
             document,
             Adapter.id("boot"),
             Clock.now_ms(clock)
           ) do
      worker =
        spawn_link(fn ->
          monitor = Process.monitor(parent)
          store_loop(parent, monitor, store, {path, instance, device}, handle)
        end)

      state = %__MODULE__{
        model: model,
        clock: clock,
        store_worker: worker,
        trace: opts[:trace],
        maintenance_owner: opts[:maintenance_owner]
      }

      {:ok, run_effects(state, effects)}
    else
      {:error, code} -> {:stop, {:simulated_box_store, code}}
    end
  end

  @impl true
  def handle_call(:boot_id, _from, %{reboot_boot: nil} = state),
    do: {:reply, {:ok, state.model.boot_id}, state}

  def handle_call(:boot_id, _from, state), do: {:reply, {:error, :unavailable}, state}

  def handle_call({:bind, boot, binding}, {caller, _}, state) do
    with nil <- state.reboot_boot,
         true <- boot == state.model.boot_id,
         true <- can_bind?(state, caller, binding) do
      if same_binding?(state, caller, binding) do
        {:reply, :ok, state}
      else
        state =
          state
          |> detach(:replaced)
          |> watch_owner(caller)
          |> Map.put(:highest_binding, binding.binding_generation)

        model_binding = Map.put(binding, :owner_id, state.owner_id)
        {:reply, :ok, transition(state, {:bind, model_binding})}
      end
    else
      _ -> {:reply, {:error, :invalid_binding}, state}
    end
  end

  def handle_call(:adapter_owner, {caller, _}, %{owner: caller} = state),
    do: {:reply, {:ok, state.owner_id}, state}

  def handle_call(:adapter_owner, _from, state), do: {:reply, {:error, :invalid_binding}, state}

  def handle_call(:adapter_barrier, {caller, _}, %{owner: caller} = state),
    do: {:reply, :ok, state}

  def handle_call(:adapter_store_worker, {caller, _}, %{maintenance_owner: caller} = state),
    do: {:reply, {:ok, state.store_worker}, state}

  def handle_call(:adapter_store_worker, _from, state),
    do: {:reply, {:error, :invalid_binding}, state}

  def handle_call(:adapter_barrier, _from, state),
    do: {:reply, {:error, :invalid_binding}, state}

  def handle_call(request, {caller, _} = from, state) do
    if local_owner?(state, caller) and is_nil(state.reboot_boot) do
      {:noreply, local_request(state, request, {:call, from})}
    else
      {:reply, Service.error(:binding_mismatch), state}
    end
  end

  @impl true
  def handle_cast({:owner, caller, owner_id, event}, %{owner: caller, owner_id: owner_id} = state)
      when is_reference(owner_id) do
    {:noreply, owner_event(state, caller, event)}
  end

  def handle_cast({:owner, _caller, _owner_id, _event}, state), do: {:noreply, state}

  @impl true
  def handle_info(
        {:DOWN, monitor, :process, owner, _},
        %{owner_monitor: monitor, owner: owner} = state
      ) do
    state =
      state
      |> unbind(:owner_down)
      |> Map.merge(%{owner: nil, owner_id: nil, owner_monitor: nil})

    {:noreply, state}
  end

  def handle_info({:model_timer, token, effect, motion, kind, due}, state) do
    case state.timers do
      %{^kind => {^token, _ref}} ->
        state = %{state | timers: Map.delete(state.timers, kind)}
        {:noreply, transition(state, {:timer, effect, motion, kind, due})}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:storage_deadline, token}, state) do
    state =
      case state.store_operation do
        %{token: ^token, kind: {:commit, persist}, timed_out: false} ->
          timeout_store(state, persist)

        %{token: ^token, kind: {:readback, _}, timed_out: false} ->
          emit_trace(state, {:diagnostic, :readback_timeout})
          state = put_in(state.store_operation.timed_out, true)
          reply_to_pending_write(state, Service.error(:commit_uncertain))

        _ ->
          state
      end

    {:noreply, state}
  end

  def handle_info({:box_store, worker, token, result}, %{store_worker: worker} = state) do
    case state.store_operation do
      %{token: ^token} = operation ->
        {:noreply, finish_store(state, operation, result)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:status_retry, generation, status_seq, token}, state) do
    {:noreply, retry_status(state, generation, status_seq, token)}
  end

  def handle_info(:continue_preparation, %{preparation: %{remaining: [_ | _]}} = state),
    do: {:noreply, continue_preparation(state)}

  def handle_info(_event, state), do: {:noreply, state}

  defp local_request(state, {:service, request}, reply),
    do: submit_service(state, request, reply)

  defp local_request(state, {:service_operation, command, args}, reply) when is_binary(command),
    do: submit_service(state, Adapter.service_request(state.model, command, args), reply)

  defp local_request(state, {:inspect, section}, reply),
    do: local_request(state, {:service_operation, "inspect", %{"section" => section}}, reply)

  defp local_request(%{preparation: nil, model: %{binding: binding}} = state, :prepare, reply)
       when not is_nil(binding) do
    state = %{
      state
      | preparation: %{
          reply: reply,
          binding: binding,
          boot_id: state.model.boot_id,
          remaining: Adapter.ordinary_preparation(state.model)
        }
    }

    continue_preparation(state)
  end

  defp local_request(state, :prepare, reply), do: respond(state, reply, Service.error(:busy))

  defp local_request(state, _request, reply),
    do: respond(state, reply, Service.error(:invalid_args))

  defp owner_event(%{owner: caller, reboot_boot: nil} = state, caller, {:service, request, tag}),
    do: local_request(state, {:service, request}, {:message, caller, tag})

  defp owner_event(
         %{owner: caller, reboot_boot: nil} = state,
         caller,
         {:service_operation, command, args, tag}
       ),
       do: local_request(state, {:service_operation, command, args}, {:message, caller, tag})

  defp owner_event(%{owner: caller, reboot_boot: nil} = state, caller, {:prepare, tag}),
    do: local_request(state, :prepare, {:message, caller, tag})

  defp owner_event(%{owner: caller} = state, caller, {:service, _request, tag}),
    do: respond(state, {:message, caller, tag}, Service.error(:busy))

  defp owner_event(%{owner: caller} = state, caller, {:service_operation, _command, _args, tag}),
    do: respond(state, {:message, caller, tag}, Service.error(:busy))

  defp owner_event(%{owner: caller} = state, caller, {:prepare, tag}),
    do: respond(state, {:message, caller, tag}, Service.error(:busy))

  defp owner_event(%{owner: caller, reboot_boot: nil} = state, caller, {:fault, fault}),
    do: inject_fault(state, fault)

  defp owner_event(
         %{owner: caller, reboot_boot: nil} = state,
         caller,
         {:local_control_lost, effect_generation, motion_generation} = event
       ) do
    if Durable.positive?(effect_generation) and Durable.positive?(motion_generation),
      do: transition(state, event),
      else: state
  end

  defp owner_event(
         %{owner: caller, reboot_boot: nil, model: %{binding: binding}} = state,
         caller,
         event
       )
       when not is_nil(binding) do
    bound_event(state, binding, event)
  end

  defp owner_event(state, caller, {:service, _request, tag}),
    do: respond(state, {:message, caller, tag}, Service.error(:binding_mismatch))

  defp owner_event(state, caller, {:service_operation, _command, _args, tag}),
    do: respond(state, {:message, caller, tag}, Service.error(:binding_mismatch))

  defp owner_event(state, caller, {:prepare, tag}),
    do: respond(state, {:message, caller, tag}, Service.error(:binding_mismatch))

  defp owner_event(state, _caller, _event), do: state

  defp bound_event(
         state,
         %{binding_generation: generation},
         {:challenge, generation, seq, observed}
       ) do
    if Durable.positive?(seq) and is_integer(observed) do
      previous = state.model.challenges
      state = transition(state, {:challenge, generation, seq, observed})

      if state.model.challenges != previous and
           match?([{^seq, ^observed} | _], state.model.challenges) do
        send_heartbeat(state, generation, seq)
      else
        state
      end
    else
      state
    end
  end

  defp bound_event(state, %{binding_generation: generation} = binding, {action, generation, arm})
       when action in [:arm, :disarm] do
    if Durable.id?(arm), do: transition(state, {action, binding, arm}), else: state
  end

  defp bound_event(
         state,
         %{binding_generation: generation} = binding,
         {:release, generation, boot, arm, seq, command, fingerprint}
       ) do
    if Durable.id?(boot) and Durable.id?(arm) and Durable.positive?(seq) and Durable.id?(command) do
      transition(state, {:command, binding, boot, arm, seq, command, fingerprint})
    else
      state
    end
  end

  defp bound_event(
         state,
         %{binding_generation: generation} = binding,
         {:query, generation, command, context}
       ) do
    if is_nil(command) or Durable.id?(command) do
      transition(state, {:query, binding, command}, {:query, command, context})
    else
      state
    end
  end

  defp bound_event(state, %{binding_generation: generation}, {:ack_status, generation, seq}) do
    state |> transition(:sweep) |> discard_status(seq)
  end

  defp bound_event(state, %{binding_generation: generation}, {:unbind, generation, reason}),
    do: unbind(state, reason)

  defp bound_event(state, _binding, _event), do: state

  defp send_heartbeat(%{input_seq: @maximum} = state, _generation, _seq),
    do: unbind(state, :counter_exhausted)

  defp send_heartbeat(state, generation, seq) do
    input_seq = state.input_seq + 1

    send(
      state.owner,
      {:simulated_box, :heartbeat, generation, state.model.boot_id, seq, input_seq}
    )

    %{state | input_seq: input_seq}
  end

  defp can_bind?(state, caller, binding) do
    Durable.fields?(binding, [:connection_id, :session_id, :binding_generation]) and
      Durable.id?(binding.connection_id) and Durable.id?(binding.session_id) and
      Durable.positive?(binding.binding_generation) and
      (same_binding?(state, caller, binding) or
         (owner_available?(state, caller) and
            (is_nil(state.highest_binding) or binding.binding_generation > state.highest_binding)))
  end

  defp owner_available?(%{owner: nil}, _caller), do: true
  defp owner_available?(%{owner: caller}, caller), do: true
  defp owner_available?(%{owner: owner}, _caller), do: not Process.alive?(owner)

  defp same_binding?(%{owner: caller, model: %{binding: binding}}, caller, proposed)
       when not is_nil(binding),
       do: Map.delete(binding, :owner_id) == proposed

  defp same_binding?(_state, _caller, _proposed), do: false

  defp local_owner?(state, caller), do: state.owner == caller or state.maintenance_owner == caller

  defp watch_owner(%{owner: caller} = state, caller), do: state

  defp watch_owner(state, caller) do
    if state.owner_monitor, do: Process.demonitor(state.owner_monitor, [:flush])
    %{state | owner: caller, owner_id: make_ref(), owner_monitor: Process.monitor(caller)}
  end

  defp detach(%{model: %{binding: nil}} = state, _reason), do: state

  defp detach(state, reason) do
    send_unbound(state, state.model.binding.binding_generation, reason)
    reset_statuses(state)
  end

  defp send_unbound(%{owner: owner}, generation, reason) when is_pid(owner),
    do: send(owner, {:simulated_box, :unbound, generation, reason})

  defp reset_statuses(state) do
    Enum.each(state.statuses, fn {_seq, entry} -> Clock.cancel(state.clock, entry.ref) end)
    %{state | statuses: %{}, status_seq: 0, input_seq: 0, lost_ack: false}
  end

  defp unbind(%{model: %{binding: nil}} = state, _reason), do: state

  defp unbind(state, reason) do
    generation = state.model.binding.binding_generation
    state = detach(state, reason)
    transition(state, {:unbind, generation, reason})
  end

  defp inject_fault(state, :disconnect), do: unbind(state, :disconnect)
  defp inject_fault(state, :reboot), do: begin_reboot(state)
  defp inject_fault(state, :lost_ack), do: %{state | lost_ack: true}

  defp inject_fault(state, :interrupt) do
    local_request(
      state,
      {:service_operation, "motion.stop",
       %{"operator" => %{"operator_id" => "simulation", "observation" => "Injected interruption"}}},
      :discard
    )
  end

  defp inject_fault(state, _fault), do: state

  defp submit_service(state, request, reply) do
    cond do
      not Adapter.valid_service?(request) ->
        respond(state, reply, Service.error(:invalid_args))

      request["command"] == "operation.get" and
        request["device_id"] == state.model.config.device_id and
        request["box_boot_id"] in [nil, state.model.boot_id] and
        is_nil(request["operation_id"]) and is_nil(request["expected_revision"]) and
        Durable.sequence(request["args"]["operation_id"]) != nil and
          state.model.fault in [:commit_uncertain, :verifying_clear] ->
        state
        |> retry_unavailable_readback()
        |> respond(reply, Service.error(:commit_uncertain))

      map_size(state.replies) >= @service_limit ->
        respond(state, reply, Service.error(:busy))

      Map.has_key?(state.replies, request["operation_id"]) ->
        respond(state, reply, Service.error(:busy))

      true ->
        state = %{state | replies: Map.put(state.replies, request["operation_id"], reply)}
        transition(state, {:service, request})
    end
  end

  defp continue_preparation(%{preparation: %{remaining: [{command, args} | rest]} = prep} = state) do
    if prep.binding == state.model.binding and prep.boot_id == state.model.boot_id and
         is_nil(state.reboot_boot) do
      state = %{state | preparation: %{prep | remaining: rest}}
      submit_service(state, Adapter.service_request(state.model, command, args), :preparation)
    else
      respond(%{state | preparation: nil}, prep.reply, Service.error(:binding_mismatch))
    end
  end

  defp respond(%{preparation: %{remaining: [_ | _]}} = state, :preparation, %{"status" => "ok"}) do
    # Finish the current effect batch before interpreting the next operation.
    send(self(), :continue_preparation)
    state
  end

  defp respond(%{preparation: %{reply: reply}} = state, :preparation, result) do
    respond(%{state | preparation: nil}, reply, result)
  end

  defp respond(state, {:call, from}, result) do
    GenServer.reply(from, result)
    state
  end

  defp respond(state, {:message, pid, tag}, result) do
    send(pid, {:simulated_box, :service, tag, result})
    state
  end

  defp respond(state, :discard, _result), do: state

  defp transition(state, event, context \\ nil)

  defp transition(%{reboot_boot: reboot} = state, _event, _context) when not is_nil(reboot),
    do: state

  defp transition(state, event, context) do
    before = state.model
    {model, effects} = Model.transition(before, event, Clock.now_ms(state.clock))
    state = %{state | model: model}

    state =
      if before.binding && is_nil(model.binding) && not match?({:unbind, _, _}, event) do
        send_unbound(state, before.binding.binding_generation, :service)
        reset_statuses(state)
      else
        state
      end

    state = run_effects(state, effects, context)

    if not is_nil(model.binding) and model.binding == before.binding and
         current_facts_changed?(before, model) and
         not Enum.any?(effects, &match?({:status, _}, &1)) do
      publish_status(state, nil, nil, nil)
    else
      state
    end
  end

  defp current_facts_changed?(before, model) do
    Adapter.readiness(model) != Adapter.readiness(before) or
      Model.motor_active?(model) != Model.motor_active?(before)
  end

  defp run_effects(state, effects, context \\ nil)
  defp run_effects(state, [], _context), do: state

  defp run_effects(state, [{:diagnostic, code}, {:status, command} | rest], context)
       when code in @refusals and not is_nil(command) do
    emit_trace(state, {:diagnostic, code})
    state |> publish_status(command, code, context) |> run_effects(rest, context)
  end

  defp run_effects(state, [{:status, command} | rest], context),
    do: state |> publish_status(command, nil, context) |> run_effects(rest, context)

  defp run_effects(state, [effect | rest], context),
    do: state |> run_effect(effect) |> run_effects(rest, context)

  defp run_effect(state, {:persist, persist}) do
    false = state.outputs_active
    start_store(state, {:commit, persist})
  end

  defp run_effect(state, {:read_store, expectation}) do
    false = state.outputs_active
    start_store(state, {:readback, expectation})
  end

  defp run_effect(state, {:schedule, timer}) do
    state = cancel_timer(state, timer.kind)
    token = make_ref()

    emit_trace(
      state,
      {:scheduled, timer.kind, timer.effect_generation, timer.motion_generation, timer.due_at_ms}
    )

    message =
      {:model_timer, token, timer.effect_generation, timer.motion_generation, timer.kind,
       timer.due_at_ms}

    ref = Clock.schedule_at(state.clock, self(), message, timer.due_at_ms)
    %{state | timers: Map.put(state.timers, timer.kind, {token, ref})}
  end

  defp run_effect(state, {:cancel_timers, _generation}),
    do: Enum.reduce(Map.keys(state.timers), state, &cancel_timer(&2, &1))

  defp run_effect(state, {:step, step}) do
    emit_trace(state, {:step, step.motion_generation, step.ordinal})
    %{state | outputs_active: true}
  end

  defp run_effect(state, {:deactivate, reason}) do
    emit_trace(state, {:deactivate, reason})
    %{state | outputs_active: false}
  end

  defp run_effect(state, {:service_reply, operation, result}) do
    respond_to_operation(state, operation, result)
  end

  defp run_effect(state, {:reboot_requested, _operation}), do: begin_reboot(state)

  defp run_effect(state, {:diagnostic, code}) do
    emit_trace(state, {:diagnostic, code})
    state
  end

  defp respond_to_operation(state, operation, result) do
    case Map.pop(state.replies, operation) do
      {nil, _} -> state
      {reply, remaining} -> respond(%{state | replies: remaining}, reply, result)
    end
  end

  defp reply_to_pending_write(%{model: %{pending_write: %{patch: patch}}} = state, result) do
    operation = patch["operation_id"] || patch["receipt"]["operation_id"]
    if operation, do: respond_to_operation(state, operation, result), else: state
  end

  defp retry_unavailable_readback(
         %{store_operation: nil, unresolved_readback: expectation} = state
       )
       when not is_nil(expectation) do
    start_store(%{state | unresolved_readback: nil}, {:readback, expectation})
  end

  defp retry_unavailable_readback(state), do: state

  defp cancel_timer(state, kind) do
    case Map.pop(state.timers, kind) do
      {nil, _} ->
        state

      {{_token, ref}, remaining} ->
        Clock.cancel(state.clock, ref)
        %{state | timers: remaining}
    end
  end

  defp publish_status(%{model: %{binding: nil}} = state, _command, _refusal, _context), do: state

  defp publish_status(%{status_seq: @maximum} = state, _command, _refusal, _context),
    do: unbind(state, :counter_exhausted)

  defp publish_status(state, command, refusal, context) do
    generation = state.model.binding.binding_generation
    seq = state.status_seq + 1
    query? = match?({:query, ^command, _}, context)
    context = if query?, do: elem(context, 2)
    report = Adapter.report(state.model, seq, command, refusal)
    status = %{report: report, context: context, attempts: 0}
    state = %{state | status_seq: seq}

    if not is_nil(command) and state.lost_ack and not query? do
      emit_trace(state, {:status_dropped, seq, command})
      state
    else
      state = if query? and not is_nil(command), do: %{state | lost_ack: false}, else: state
      send_status(state, generation, status)
      retain_status(state, generation, seq, status)
    end
  end

  defp send_status(state, generation, status) do
    send(state.owner, {:simulated_box, :status, generation, status.report, status.context})
  end

  defp retain_status(state, generation, seq, status) do
    state =
      if map_size(state.statuses) >= @status_limit do
        discard_status(state, Enum.min(Map.keys(state.statuses)))
      else
        state
      end

    token = make_ref()
    due = Clock.now_ms(state.clock) + @retry_ms
    ref = Clock.schedule_at(state.clock, self(), {:status_retry, generation, seq, token}, due)

    %{
      state
      | statuses: Map.put(state.statuses, seq, Map.merge(status, %{ref: ref, token: token}))
    }
  end

  defp discard_status(state, seq) do
    case Map.pop(state.statuses, seq) do
      {nil, _} ->
        state

      {entry, statuses} ->
        Clock.cancel(state.clock, entry.ref)
        %{state | statuses: statuses}
    end
  end

  defp retry_status(
         %{model: %{binding: %{binding_generation: generation}}} = state,
         generation,
         seq,
         token
       ) do
    state = transition(state, :sweep)

    case state.statuses do
      %{^seq => %{token: ^token, attempts: attempts} = status} when attempts < @status_retries ->
        state = discard_status(state, seq)
        send_status(state, generation, status)

        if attempts + 1 < @status_retries do
          retain_status(state, generation, seq, %{status | attempts: attempts + 1})
        else
          state
        end

      _ ->
        state
    end
  end

  defp retry_status(state, _generation, _seq, _token), do: state

  defp start_store(
         %{store_operation: %{timed_out: true} = operation} = state,
         {:readback, expectation}
       ) do
    %{state | store_operation: Map.put(operation, :readback, expectation)}
  end

  defp start_store(%{store_operation: nil} = state, kind) do
    token = make_ref()
    due = Clock.now_ms(state.clock) + @store_deadline

    timer =
      case kind do
        :reopen -> nil
        _ -> Clock.schedule_at(state.clock, self(), {:storage_deadline, token}, due)
      end

    emit_trace(state, {:storage_started, storage_trace(kind)})
    send(state.store_worker, {:work, token, kind})

    %{
      state
      | store_operation: %{token: token, kind: kind, due: due, timer: timer, timed_out: false}
    }
  end

  defp storage_trace({:commit, persist}), do: {:commit, persist.operation_id, persist.purpose}
  defp storage_trace({:readback, expectation}), do: {:readback, expectation.operation_id}
  defp storage_trace(:reopen), do: :reopen

  defp timeout_store(%{reboot_boot: nil} = state, persist) do
    state = put_in(state.store_operation.timed_out, true)
    transition(state, failure_event(persist, :unknown))
  end

  defp timeout_store(state, _persist), do: state

  defp finish_store(state, %{kind: :reopen}, result) do
    state = %{state | store_operation: nil}

    case result do
      {:ok, document} ->
        {:ok, model, effects} =
          Model.new(state.model.config, document, state.reboot_boot, Clock.now_ms(state.clock))

        state = %{state | model: model, reboot_boot: nil}
        state = run_effects(state, effects)

        if state.owner,
          do: send(state.owner, {:simulated_box, :boot, model.config.device_id, model.boot_id})

        state

      {:error, code} ->
        emit_trace(state, {:diagnostic, code})
        state
    end
  end

  defp finish_store(%{reboot_boot: boot} = state, operation, _result) when not is_nil(boot) do
    cancel_store_timer(state, operation)
    start_store(%{state | store_operation: nil}, :reopen)
  end

  defp finish_store(state, %{kind: {:commit, persist}} = operation, result) do
    cancel_store_timer(state, operation)

    state =
      if not operation.timed_out and Clock.now_ms(state.clock) >= operation.due do
        timeout_store(state, persist)
      else
        state
      end

    operation = state.store_operation
    state = %{state | store_operation: nil}
    emit_trace(state, {:storage_finished, persist.operation_id, result})

    case operation do
      %{timed_out: true, readback: expectation} ->
        start_store(state, {:readback, expectation})

      %{timed_out: true} ->
        state

      _ ->
        transition(state, commit_event(persist, result))
    end
  end

  defp finish_store(state, %{kind: {:readback, expectation}} = operation, result) do
    cancel_store_timer(state, operation)
    state = %{state | store_operation: nil}

    state =
      if operation.timed_out or Clock.now_ms(state.clock) >= operation.due,
        do: reply_to_pending_write(state, Service.error(:commit_uncertain)),
        else: state

    emit_trace(state, {:storage_readback, expectation.operation_id, elem(result, 0)})

    case result do
      {:committed, revision, hash, document} ->
        transition(state, {:readback, expectation.operation_id, document, revision, hash})

      {:not_committed, revision, hash} ->
        transition(
          state,
          {:readback, expectation.operation_id, Model.durable(state.model), revision, hash}
        )

      {:error, code} ->
        emit_trace(state, {:diagnostic, code})
        state = reply_to_pending_write(state, Service.error(:commit_uncertain))
        if code == :unavailable, do: %{state | unresolved_readback: expectation}, else: state
    end
  end

  defp cancel_store_timer(state, %{timer: timer}) when not is_nil(timer),
    do: Clock.cancel(state.clock, timer)

  defp cancel_store_timer(_state, _operation), do: :ok

  defp commit_event(persist, {:ok, revision, hash}),
    do:
      {:persisted, persist.instance_id, persist.operation_id, persist.base_revision, revision,
       hash, persist.effect_generation}

  defp commit_event(persist, {:error, certainty}), do: failure_event(persist, certainty)

  defp failure_event(persist, certainty),
    do:
      {:persist_failed, persist.instance_id, persist.operation_id, persist.base_revision,
       persist.effect_generation, certainty}

  defp begin_reboot(%{reboot_boot: boot} = state) when not is_nil(boot), do: state

  defp begin_reboot(state) do
    boot = Adapter.id("boot")
    state = detach(state, :reboot)
    {model, effects} = Model.transition(state.model, {:reboot, boot}, Clock.now_ms(state.clock))

    stop_effects =
      Enum.filter(effects, &(match?({:deactivate, _}, &1) or match?({:cancel_timers, _}, &1)))

    state =
      run_effects(
        %{state | model: model, reboot_boot: boot, unresolved_readback: nil},
        stop_effects
      )

    replies = Map.values(state.replies)

    state =
      Enum.reduce(
        replies,
        %{state | replies: %{}},
        &respond(&2, &1, Service.error(:commit_uncertain))
      )

    if state.store_operation, do: state, else: start_store(state, :reopen)
  end

  defp open_store(store, path, instance, device) do
    case store.open_existing(path, instance, device) do
      {:ok, handle} ->
        case store.load(handle) do
          {:ok, document} ->
            {:ok, handle, document}

          {:error, _} = error ->
            store.close(handle)
            error
        end

      {:error, _} = error ->
        error
    end
  end

  defp store_loop(parent, monitor, store, {path, instance, device} = location, handle) do
    receive do
      {:work, token, {:commit, persist}} ->
        send(parent, {:box_store, self(), token, store.commit(handle, persist)})
        store_loop(parent, monitor, store, location, handle)

      {:work, token, {:readback, expectation}} ->
        send(parent, {:box_store, self(), token, store.readback(handle, expectation)})
        store_loop(parent, monitor, store, location, handle)

      {:work, token, :reopen} ->
        store.close(handle)

        case open_store(store, path, instance, device) do
          {:ok, next_handle, document} ->
            send(parent, {:box_store, self(), token, {:ok, document}})
            store_loop(parent, monitor, store, location, next_handle)

          {:error, _} = error ->
            send(parent, {:box_store, self(), token, error})
        end

      {:DOWN, ^monitor, :process, ^parent, _reason} ->
        store.close(handle)
    end
  end

  defp emit_trace(%{trace: pid}, event) when is_pid(pid), do: send(pid, {:box_trace, event})
  defp emit_trace(_state, _event), do: :ok
end
