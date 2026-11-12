defmodule Vault.SimulatedBox.Model do
  @moduledoc """
  Pure simulated-box state machine. Adapters provide validated events and execute
  effects in order. Times are local signed monotonic milliseconds.
  """

  alias __MODULE__.{Durable, Service}

  @maximum 9_007_199_254_740_991
  @challenge_window 400
  @watchdog_window 1_500
  @journal_limit 32

  defmodule State do
    @moduledoc false
    @enforce_keys [:config, :durable, :store_revision, :boot_id]
    defstruct @enforce_keys ++
                [
                  binding: nil,
                  effect_generation: 1,
                  motion_generation: 1,
                  arm: nil,
                  retired_arm_ids: [],
                  challenges: [],
                  last_challenge_ms: nil,
                  last_local_control_ms: nil,
                  local_control_deadline_ms: nil,
                  readiness: %{calibration_valid: false, start_verified: false},
                  local_reference: nil,
                  reservation: nil,
                  motion: nil,
                  pending_write: nil,
                  pending_durable: [],
                  fault: nil
                ]

    @type t :: %__MODULE__{}
  end

  defmodule Persist do
    @moduledoc false
    @enforce_keys [
      :instance_id,
      :operation_id,
      :base_revision,
      :next_revision,
      :expected_sha256,
      :patch,
      :payload_sha256,
      :effect_generation,
      :motion_generation,
      :purpose
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{}
  end

  defmodule ReadExpectation do
    @moduledoc false
    @enforce_keys [
      :instance_id,
      :operation_id,
      :base_revision,
      :next_revision,
      :expected_sha256,
      :payload_sha256
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{}
  end

  @type id :: String.t()
  @type mono_ms :: integer()
  @type generation :: pos_integer()
  @type digest :: <<_::256>>
  @type binding :: %{
          connection_id: id(),
          session_id: id(),
          binding_generation: generation(),
          owner_id: term()
        }
  @type fingerprint :: %{session_id: id(), action: String.t(), target: String.t()}
  @type timer_kind :: :step | :watchdog | :local_watchdog
  @type event ::
          {:bind, binding()}
          | {:unbind, generation(), atom()}
          | {:challenge, generation(), pos_integer(), mono_ms()}
          | {:arm, binding(), id()}
          | {:disarm, binding(), id()}
          | {:command, binding(), id(), id(), pos_integer(), id(), fingerprint()}
          | {:query, binding(), id() | nil}
          | {:timer, generation(), generation(), timer_kind(), mono_ms()}
          | {:persisted, id(), id(), non_neg_integer(), pos_integer(), digest(), generation()}
          | {:persist_failed, id(), id(), non_neg_integer(), generation(),
             :rolled_back | :unknown}
          | {:readback, id(), map(), non_neg_integer(), digest()}
          | {:service, Service.request()}
          | {:local_control_lost, generation(), generation()}
          | {:reboot, id()}
  @type effect ::
          {:persist, Persist.t()}
          | {:schedule,
             %{
               effect_generation: generation(),
               motion_generation: generation(),
               kind: timer_kind(),
               due_at_ms: mono_ms()
             }}
          | {:cancel_timers, generation()}
          | {:step, %{motion_generation: generation(), ordinal: pos_integer()}}
          | {:deactivate, atom()}
          | {:status, id() | nil}
          | {:service_reply, id() | nil, map()}
          | {:read_store, ReadExpectation.t()}
          | {:reboot_requested, id()}
          | {:diagnostic, atom()}

  @spec new(map(), map(), id(), mono_ms()) :: {:ok, State.t(), [effect()]} | {:error, atom()}
  def new(config, durable, boot_id, now_ms) when is_integer(now_ms) do
    with true <- valid_config?(config) and Durable.id?(boot_id),
         :ok <- Durable.validate(durable, config) do
      state = %State{
        config: config,
        durable: durable,
        store_revision: durable["store_revision"],
        boot_id: boot_id
      }

      {state, effects} = reconcile_boot(state)
      {:ok, state, [{:deactivate, :boot} | effects]}
    else
      false -> {:error, :invalid_configuration}
      {:error, code} -> {:error, code}
    end
  end

  @spec durable(State.t()) :: map()
  def durable(%State{durable: durable}), do: durable

  @doc "Whether the modeled stroke is active. A service timeline awaiting its write is only reserved."
  @spec motor_active?(State.t()) :: boolean()
  def motor_active?(%State{motion: motion, pending_write: write}),
    do: not is_nil(motion) and is_nil(write)

  @spec transition(State.t(), event(), mono_ms()) :: {State.t(), [effect()]}
  def transition(%State{} = state, event, now_ms) when is_integer(now_ms) do
    {state, deadline_effects} = sweep_deadlines(state, now_ms)
    {state, effects} = handle_event(state, event, now_ms)
    {state, pending_effects} = drain(state, now_ms)
    {state, deadline_effects ++ effects ++ pending_effects}
  end

  defp handle_event(state, {:bind, binding}, _now) do
    cond do
      state.binding == binding ->
        {state, []}

      not valid_binding?(binding) or
          (state.binding && binding.binding_generation <= state.binding.binding_generation) ->
        {state, []}

      true ->
        {state, effects} = invalidate(state, :connection_lost)
        {reset_binding(state, binding), effects ++ [{:status, nil}]}
    end
  end

  defp handle_event(
         %State{binding: %{binding_generation: generation}} = state,
         {:unbind, generation, _},
         _now
       ) do
    {state, effects} = invalidate(state, :connection_lost)
    {reset_binding(state, nil), effects}
  end

  defp handle_event(
         %State{binding: %{binding_generation: generation}} = state,
         {:challenge, generation, seq, observed},
         now
       )
       when is_integer(observed) and observed <= now and observed > now - @challenge_window do
    case state.challenges do
      [{latest, _} | _] when seq <= latest ->
        {state, []}

      _ ->
        if is_nil(state.last_challenge_ms) or observed >= state.last_challenge_ms do
          challenges = Enum.take([{seq, observed} | state.challenges], 32)
          {%{state | challenges: challenges, last_challenge_ms: observed}, []}
        else
          {state, []}
        end
    end
  end

  defp handle_event(%State{binding: binding} = state, {:arm, binding, arm_id}, _now)
       when not is_nil(binding) do
    cond do
      state.arm == %{arm_id: arm_id, binding: binding} and is_nil(state.reservation) ->
        {state, [{:status, nil}]}

      arm_id in state.retired_arm_ids or length(state.retired_arm_ids) >= 32 ->
        {state, [{:diagnostic, :history_full}, {:status, nil}]}

      not gameplay_ready?(state) or not is_nil(state.arm) ->
        {state, [{:status, nil}]}

      true ->
        {%{state | arm: %{arm_id: arm_id, binding: binding}}, [{:status, nil}]}
    end
  end

  defp handle_event(%State{binding: binding} = state, {:disarm, binding, arm_id}, _now)
       when not is_nil(binding) do
    case state.arm do
      %{arm_id: ^arm_id} ->
        if state.reservation do
          {state, effects} = invalidate(state, :freshness_lost)
          {state, effects ++ [{:status, nil}]}
        else
          {retire_arm(state), [{:status, nil}]}
        end

      _ ->
        {state, [{:status, nil}]}
    end
  end

  defp handle_event(state, {:command, binding, boot, arm, seq, command, fingerprint}, now) do
    fingerprint = normalize_fingerprint(fingerprint)

    cond do
      state.binding != binding or is_nil(binding) or boot != state.boot_id ->
        {state, [{:diagnostic, :stale_binding}]}

      not Durable.fingerprint?(fingerprint) ->
        {state, [{:diagnostic, :identity_mismatch}]}

      entry = Durable.journal_entry(state.durable, command) ->
        if entry["fingerprint"] == fingerprint do
          {state, [{:status, command}]}
        else
          {state, [{:diagnostic, :identity_mismatch}]}
        end

      fingerprint["session_id"] != binding.session_id ->
        reject_command(state, command, :stale_binding)

      length(state.durable["journal"]) >= @journal_limit ->
        reject_command(state, command, :history_full)

      state.pending_write || state.motion || state.reservation || state.pending_durable != [] ->
        reject_command(state, command, :busy)

      not state.readiness.calibration_valid or not state.readiness.start_verified ->
        reject_command(state, command, :unknown_position)

      not gameplay_ready?(state) or state.arm != %{arm_id: arm, binding: binding} ->
        reject_command(state, command, :not_armed)

      not fresh_challenge?(state, seq, now) ->
        reject_command(state, command, :stale_binding)

      state.motion_generation >= @maximum ->
        invariant_fault(state, :counter_exhausted)

      true ->
        reserve_gameplay(state, command, fingerprint, arm, seq)
    end
  end

  defp handle_event(%State{binding: binding} = state, {:query, binding, command}, _now)
       when not is_nil(binding),
       do: {state, [{:status, command}]}

  defp handle_event(
         %State{effect_generation: effect, motion_generation: motion} = state,
         {:timer, effect, motion, kind, due},
         now
       )
       when due <= now do
    timer(state, kind, due, now)
  end

  defp handle_event(
         state,
         {:persisted, instance, operation, base, revision, hash, generation},
         now
       ) do
    case state.pending_write do
      %Persist{
        instance_id: ^instance,
        operation_id: ^operation,
        base_revision: ^base,
        next_revision: ^revision,
        payload_sha256: ^hash,
        effect_generation: ^generation
      } = persist
      when state.fault not in [:commit_uncertain, :invalid_store, :verifying_clear] ->
        adopt_commit(state, persist, now)

      _ ->
        {state, []}
    end
  end

  defp handle_event(
         state,
         {:persist_failed, instance, operation, base, generation, certainty},
         _now
       ) do
    case state.pending_write do
      %Persist{
        instance_id: ^instance,
        operation_id: ^operation,
        base_revision: ^base,
        effect_generation: ^generation
      } = persist
      when state.fault not in [:commit_uncertain, :invalid_store, :verifying_clear] ->
        persistence_failure(state, persist, certainty)

      _ ->
        {state, []}
    end
  end

  defp handle_event(
         %State{pending_write: %Persist{operation_id: operation} = persist} = state,
         {:readback, operation, durable, revision, hash},
         now
       ) do
    resolve_readback(state, persist, durable, revision, hash, now)
  end

  defp handle_event(state, {:service, request}, now), do: service_request(state, request, now)

  defp handle_event(
         %State{effect_generation: effect, motion_generation: motion} = state,
         {:local_control_lost, effect, motion},
         _now
       ) do
    if state.local_control_deadline_ms, do: interrupt(state, :freshness_lost), else: {state, []}
  end

  defp handle_event(state, {:reboot, boot}, _now) when boot != state.boot_id do
    {state, effects} = invalidate(state, :reboot_interrupted)
    # A requested reboot causes the runtime to reopen its store. Preserve the
    # exact in-flight expectation here for a late completion while it is alive.
    state = reset_binding(%{state | boot_id: boot}, nil)
    {state, reconciliation_effects} = reconcile_boot(state)
    {state, effects ++ reconciliation_effects}
  end

  defp handle_event(state, _event, _now), do: {state, []}

  defp valid_config?(
         %{
           device_id: device,
           instance_id: instance,
           step_interval_ms: 10,
           release_steps: 100,
           motion_timeout_ms: 8_000
         } = config
       )
       when map_size(config) == 5,
       do: Durable.id?(device) and Durable.id?(instance)

  defp valid_config?(_), do: false

  defp valid_binding?(
         %{
           connection_id: connection,
           session_id: session,
           binding_generation: generation,
           owner_id: owner
         } = binding
       )
       when map_size(binding) == 4 do
    Durable.id?(connection) and Durable.id?(session) and Durable.positive?(generation) and
      not is_nil(owner)
  end

  defp valid_binding?(_), do: false

  defp normalize_fingerprint(%{session_id: session, action: action, target: target} = fingerprint)
       when map_size(fingerprint) == 3,
       do: %{"session_id" => session, "action" => action, "target" => target}

  defp normalize_fingerprint(fingerprint), do: fingerprint

  defp reject_command(state, command, code),
    do: {state, [{:diagnostic, code}, {:status, command}]}

  defp gameplay_ready?(state) do
    state.readiness.calibration_valid and state.readiness.start_verified and
      is_nil(state.fault) and is_nil(state.pending_write) and state.pending_durable == [] and
      is_nil(state.motion) and is_nil(state.reservation) and
      not state.durable["service"]["service_inhibited"] and
      not state.durable["service"]["motion_frozen"]
  end

  defp fresh_challenge?(state, seq, now) do
    case List.keyfind(state.challenges, seq, 0) do
      {^seq, observed} -> now < observed + @challenge_window
      nil -> false
    end
  end

  defp reserve_gameplay(state, command, fingerprint, arm, seq) do
    generation = state.motion_generation + 1

    reservation = %{
      command_id: command,
      fingerprint: fingerprint,
      arm_id: arm,
      binding: state.binding,
      heartbeat_seq: seq,
      motion_generation: generation
    }

    accepted = outcome(state, command, "accepted", nil)

    entry = %{
      "schema_version" => 1,
      "command_id" => command,
      "fingerprint" => fingerprint,
      "reserved_arm_id" => arm,
      "accepted_boot_id" => state.boot_id,
      "accept_operation_id" => accepted["operation_id"],
      "outcomes" => [accepted],
      "conflicted" => false
    }

    state = %{state | reservation: reservation, motion_generation: generation}

    case write(state, %{"kind" => "accept", "entry" => entry}, :accept) do
      {%State{pending_write: %Persist{}} = state, effects} ->
        {state,
         effects ++ [schedule(state, :watchdog, state.last_challenge_ms + @watchdog_window)]}

      result ->
        result
    end
  end

  defp sweep_deadlines(state, now) do
    cond do
      state.local_control_deadline_ms && now >= state.local_control_deadline_ms ->
        interrupt(state, :freshness_lost)

      (not is_nil(state.reservation) or match?(%{kind: :gameplay}, state.motion)) &&
          now >= state.last_challenge_ms + @watchdog_window ->
        interrupt(state, :connection_lost)

      state.motion && now >= state.motion.deadline_ms ->
        interrupt(state, :travel_timeout)

      true ->
        {state, []}
    end
  end

  defp timer(%State{pending_write: %Persist{}} = state, :step, _due, _now),
    do: {state, []}

  defp timer(
         %State{motion: %{next_step_at_ms: due}, reservation: %{heartbeat_seq: seq}} = state,
         :step,
         due,
         now
       ) do
    if fresh_challenge?(state, seq, now) do
      timer(%{state | reservation: nil}, :step, due, now)
    else
      interrupt(state, :freshness_lost)
    end
  end

  defp timer(%State{motion: %{next_step_at_ms: due}} = state, :step, due, now) do
    motion = state.motion
    ordinal = motion.steps_done + 1
    step = {:step, %{motion_generation: motion.motion_generation, ordinal: ordinal}}

    if ordinal == motion.step_limit do
      {state, effects} = finish_motion(state, ordinal)
      {state, [step | effects]}
    else
      due = now + motion.step_interval_ms
      motion = %{motion | steps_done: ordinal, next_step_at_ms: due}
      {%{state | motion: motion}, [step, schedule(state, :step, due)]}
    end
  end

  defp timer(%State{local_control_deadline_ms: deadline} = state, :local_watchdog, due, _now)
       when is_integer(deadline) and due < deadline,
       do: {state, [schedule(state, :local_watchdog, deadline)]}

  defp timer(state, :watchdog, due, _now) do
    if (not is_nil(state.reservation) or match?(%{kind: :gameplay}, state.motion)) and
         due < state.last_challenge_ms + @watchdog_window do
      {state, [schedule(state, :watchdog, state.last_challenge_ms + @watchdog_window)]}
    else
      {state, []}
    end
  end

  defp timer(state, _kind, _due, _now), do: {state, []}

  defp schedule(state, kind, due) do
    {:schedule,
     %{
       effect_generation: state.effect_generation,
       motion_generation: state.motion_generation,
       kind: kind,
       due_at_ms: due
     }}
  end

  defp reset_binding(state, binding) do
    %{state | binding: binding, retired_arm_ids: [], challenges: [], last_challenge_ms: nil}
  end

  defp retire_arm(%State{arm: nil} = state), do: state

  defp retire_arm(state) do
    %{state | arm: nil, retired_arm_ids: [state.arm.arm_id | state.retired_arm_ids]}
  end

  defp clear_verification(state) do
    %{state | readiness: %{calibration_valid: false, start_verified: false}, local_reference: nil}
  end

  defp clear_motion(state) do
    %{
      state
      | reservation: nil,
        motion: nil,
        last_local_control_ms: nil,
        local_control_deadline_ms: nil
    }
  end

  defp invalidate(state, reason) do
    state =
      state
      |> record_interruption(reason)
      |> retire_arm()
      |> clear_verification()
      |> clear_motion()

    effect_generation = min(state.effect_generation + 1, @maximum)
    motion_generation = min(state.motion_generation + 1, @maximum)

    fault =
      if effect_generation == @maximum or motion_generation == @maximum,
        do: state.fault || :counter_exhausted,
        else: state.fault

    state = %{
      state
      | effect_generation: effect_generation,
        motion_generation: motion_generation,
        fault: fault
    }

    {state, [{:deactivate, reason}, {:cancel_timers, effect_generation}]}
  end

  defp interrupt(state, reason), do: invalidate(state, reason)

  defp record_interruption(
         %State{motion: %{kind: :gameplay, command_id: command}} = state,
         reason
       ) do
    {kind, code} = interruption(reason)
    enqueue(state, {:outcome, command, outcome(state, command, kind, code), :outcome})
  end

  defp record_interruption(%State{reservation: %{command_id: command}} = state, reason) do
    {kind, code} = interruption(reason)
    enqueue(state, {:outcome, command, outcome(state, command, kind, code), :outcome})
  end

  defp record_interruption(%State{motion: %{kind: :service} = motion} = state, reason) do
    {kind, code} = local_interruption(reason)

    enqueue(
      state,
      {:service_complete, motion.service_operation_id, completion(kind, code, motion.steps_done),
       :service}
    )
  end

  defp record_interruption(
         %State{pending_write: %Persist{patch: %{"receipt" => %{"operation_id" => id}}}} = state,
         reason
       )
       when not is_nil(state.local_control_deadline_ms) do
    {kind, code} = local_interruption(reason)
    enqueue(state, {:service_complete, id, completion(kind, code, 0), :service})
  end

  defp record_interruption(state, _reason), do: state

  defp interruption(:travel_timeout), do: {"failed", "travel_timeout"}
  defp interruption(:reboot_interrupted), do: {"uncertain", "reboot_interrupted"}
  defp interruption(:connection_lost), do: {"uncertain", "connection_lost"}
  defp interruption(_), do: {"uncertain", "freshness_lost"}

  defp local_interruption(:travel_timeout), do: {"failed", "travel_timeout"}
  defp local_interruption(:reboot_interrupted), do: {"uncertain", "reboot_interrupted"}
  defp local_interruption(:stopped), do: {"uncertain", "stopped"}
  defp local_interruption(_), do: {"uncertain", "freshness_lost"}

  # This historical ID is separate from the store mutation ID. The latter
  # hashes the entire patch and cannot also appear inside its contents.
  defp outcome(state, command, kind, failure) do
    identity = %{
      "instance_id" => state.config.instance_id,
      "boot_id" => state.boot_id,
      "command_id" => command,
      "kind" => kind,
      "failure_code" => failure
    }

    %{
      "kind" => kind,
      "failure_code" => failure,
      "boot_id" => state.boot_id,
      "operation_id" => "outcome_" <> Durable.digest_prefix(identity)
    }
  end

  defp completion(kind, code, steps),
    do: %{"state" => kind, "code" => code, "steps_executed" => steps}

  defp finish_motion(state, ordinal) do
    state =
      case state.motion do
        %{kind: :gameplay, command_id: command} ->
          enqueue(
            state,
            {:outcome, command, outcome(state, command, "motion_complete", nil), :outcome}
          )

        %{kind: :service, service_operation_id: id} ->
          enqueue(state, {:service_complete, id, completion("complete", "ok", ordinal), :service})
      end

    state =
      if state.motion.kind == :service and state.local_reference do
        %{state | local_reference: %{state.local_reference | modeled_position: :unknown}}
      else
        state
      end

    state = clear_motion(state)
    {state, [{:deactivate, :motion_complete}, {:cancel_timers, state.effect_generation}]}
  end

  defp start_motion(state, kind, command, service_id, budget, now) do
    motion = motion_timeline(state, kind, command, service_id, budget, now)
    {%{state | motion: motion}, [schedule(state, :step, motion.next_step_at_ms)]}
  end

  defp motion_timeline(state, kind, command, service_id, budget, now) do
    %{
      kind: kind,
      command_id: command,
      service_operation_id: service_id,
      motion_generation: state.motion_generation,
      binding: state.binding,
      started_at_ms: now,
      deadline_ms: budget.deadline,
      next_step_at_ms: now + budget.interval,
      steps_done: 0,
      step_limit: budget.steps,
      step_interval_ms: budget.interval
    }
  end

  defp reconcile_boot(state) do
    state =
      Enum.reduce(state.durable["journal"], state, fn entry, acc ->
        if Durable.unfinished?(entry) do
          command = entry["command_id"]

          item =
            {:outcome, command, outcome(acc, command, "uncertain", "reboot_interrupted"),
             :boot_reconcile}

          enqueue(acc, item)
        else
          acc
        end
      end)

    state =
      case state.durable["service"]["inflight_motion"] do
        %{"operation_id" => id} ->
          enqueue(
            state,
            {:service_complete, id, completion("uncertain", "reboot_interrupted", nil),
             :boot_reconcile}
          )

        nil ->
          state
      end

    drain(state, nil)
  end

  defp enqueue(state, item) do
    if Enum.any?(state.pending_durable, &same_evidence?(&1, item)) do
      state
    else
      case length(state.pending_durable) do
        size when size < 32 -> %{state | pending_durable: state.pending_durable ++ [item]}
        32 -> %{state | fault: state.fault || :pending_capacity}
      end
    end
  end

  defp same_evidence?({:outcome, id, %{"kind" => kind}, _}, {:outcome, id, %{"kind" => kind}, _}),
    do: true

  defp same_evidence?({:service_complete, id, _, _}, {:service_complete, id, _, _}), do: true
  defp same_evidence?(left, right), do: left == right

  defp drain(
         %State{pending_write: nil, motion: nil, fault: nil, pending_durable: [item | rest]} =
           state,
         now
       ) do
    state = %{state | pending_durable: rest}

    case item do
      {:service, request} ->
        {state, effects} = service_request(state, request, now, :queued)
        {state, more_effects} = drain(state, now)
        {state, effects ++ more_effects}

      _ ->
        case Durable.rebase(state.durable, item) do
          {:ok, patch, purpose} -> write(state, patch, purpose)
          :skip -> drain(state, now)
          {:error, code} -> invariant_fault(state, code)
        end
    end
  end

  defp drain(%State{pending_write: nil, motion: nil, fault: nil} = state, _now) do
    case Durable.clear_work(state.durable) do
      {:ok, patch, purpose} -> write(state, patch, purpose)
      :skip -> {state, []}
      {:error, code} -> invariant_fault(state, code)
    end
  end

  defp drain(state, _now), do: {state, []}

  defp write(%State{motion: nil, pending_write: nil} = state, patch, purpose) do
    with {:ok, operation, next} <- Durable.advance(state.durable, patch, state.config),
         {:ok, old_hash} <- Durable.hash(state.durable),
         {:ok, new_hash} <- Durable.hash(next) do
      persist = %Persist{
        instance_id: state.config.instance_id,
        operation_id: operation,
        base_revision: state.store_revision,
        next_revision: next["store_revision"],
        expected_sha256: old_hash,
        payload_sha256: new_hash,
        patch: patch,
        effect_generation: state.effect_generation,
        motion_generation: state.motion_generation,
        purpose: purpose
      }

      {%{state | pending_write: persist}, [{:persist, persist}]}
    else
      {:error, code} -> invariant_fault(state, code)
    end
  end

  defp invariant_fault(state, code) do
    {state, effects} = invalidate(state, :storage_error)
    {%{state | fault: code}, effects ++ [{:diagnostic, code}]}
  end

  defp expectation(persist) do
    %ReadExpectation{
      instance_id: persist.instance_id,
      operation_id: persist.operation_id,
      base_revision: persist.base_revision,
      next_revision: persist.next_revision,
      expected_sha256: persist.expected_sha256,
      payload_sha256: persist.payload_sha256
    }
  end

  defp adopt_commit(state, persist, now) do
    with {:ok, _, durable} <- Durable.advance(state.durable, persist.patch, state.config) do
      state = %{
        state
        | durable: durable,
          store_revision: persist.next_revision,
          pending_write: nil
      }

      if clear_admission?(persist) do
        {%{state | pending_write: persist, fault: :verifying_clear},
         [{:read_store, expectation(persist)}]}
      else
        after_commit(state, persist, now, :live)
      end
    else
      {:error, code} -> invariant_fault(state, code)
    end
  end

  defp clear_admission?(%Persist{
         patch: %{"kind" => "service_admit", "receipt" => %{"command" => "history.clear"}}
       }),
       do: true

  defp clear_admission?(_), do: false

  defp after_commit(
         state,
         %Persist{purpose: :accept, patch: %{"entry" => entry}} = persist,
         now,
         mode
       ) do
    command = entry["command_id"]
    reservation = state.reservation
    state = retire_arm(state)

    if mode == :live and not is_nil(reservation) and reservation.command_id == command and
         reservation.motion_generation == state.motion_generation and
         persist.effect_generation == state.effect_generation and
         reservation.binding == state.binding and is_nil(state.fault) and
         state.readiness.calibration_valid and state.readiness.start_verified and
         not state.durable["service"]["service_inhibited"] and
         not state.durable["service"]["motion_frozen"] and
         fresh_challenge?(state, reservation.heartbeat_seq, now) do
      readiness = %{state.readiness | start_verified: false}
      reference = %{state.local_reference | modeled_position: :unknown}

      budget = %{
        steps: state.config.release_steps,
        interval: state.config.step_interval_ms,
        deadline: now + state.config.motion_timeout_ms
      }

      {state, effects} =
        start_motion(
          %{state | readiness: readiness, local_reference: reference},
          :gameplay,
          command,
          nil,
          budget,
          now
        )

      {state, [{:status, command} | effects]}
    else
      state = state |> clear_verification() |> clear_motion()

      state =
        enqueue(
          state,
          {:outcome, command, outcome(state, command, "uncertain", "freshness_lost"), :outcome}
        )

      {state, [{:status, command}]}
    end
  end

  defp after_commit(
         state,
         %Persist{patch: %{"kind" => "outcome", "command_id" => command}},
         _now,
         _mode
       ),
       do: {state, [{:status, command}]}

  defp after_commit(
         state,
         %Persist{patch: %{"kind" => "service_admit", "receipt" => receipt}} = persist,
         now,
         mode
       ) do
    {state, effects} = service_commit(state, persist, receipt, now, mode)
    {state, [Service.reply(receipt["operation_id"], Service.receipt_result(receipt)) | effects]}
  end

  defp after_commit(
         state,
         %Persist{patch: %{"kind" => "service_complete", "operation_id" => operation}},
         _now,
         _mode
       ) do
    receipt = Durable.receipt(state.durable, operation)
    {state, [Service.reply(operation, Service.receipt_result(receipt))]}
  end

  defp after_commit(state, _persist, _now, _mode), do: {state, []}

  defp persistence_failure(state, persist, certainty) do
    {state, effects} = invalidate(state, :storage_error)
    service_receipt = persist.patch["receipt"]

    operation =
      persist.patch["operation_id"] || (service_receipt && service_receipt["operation_id"])

    case certainty do
      :rolled_back ->
        state = retain_rolled_back_evidence(state, persist)
        state = %{state | pending_write: nil, fault: :storage_error}

        {state,
         effects ++ [{:diagnostic, :storage_error}] ++ service_failure(operation, :storage_error)}

      :unknown ->
        state = %{state | fault: :commit_uncertain}

        {state,
         effects ++
           [{:diagnostic, :commit_uncertain}, {:read_store, expectation(persist)}] ++
           service_failure(operation, :commit_uncertain)}
    end
  end

  defp retain_rolled_back_evidence(state, %Persist{
         patch: %{"kind" => "outcome", "command_id" => command, "outcome" => terminal}
       }) do
    uncertain = outcome(state, command, "uncertain", "freshness_lost")

    state
    |> enqueue({:outcome, command, uncertain, :outcome})
    |> enqueue({:outcome, command, terminal, :outcome})
  end

  defp retain_rolled_back_evidence(state, %Persist{
         patch: %{"kind" => "service_complete", "operation_id" => id, "completion" => completion}
       }) do
    if state.durable["service"]["inflight_motion"]["operation_id"] == id do
      enqueue(
        state,
        {:service_complete, id,
         %{
           "state" => "uncertain",
           "code" => "storage_error",
           "steps_executed" => completion["steps_executed"]
         }, :service}
      )
    else
      state
    end
  end

  defp retain_rolled_back_evidence(state, _persist), do: state

  defp service_failure(nil, _reason), do: []
  defp service_failure(operation, reason), do: [Service.reply(operation, Service.error(reason))]

  defp resolve_readback(%State{fault: fault} = state, persist, durable, revision, hash, now)
       when fault in [:commit_uncertain, :verifying_clear] do
    with :ok <- Durable.validate(durable, state.config),
         {:ok, ^hash} <- Durable.hash(durable),
         true <- durable["store_revision"] == revision do
      cond do
        revision == persist.next_revision and hash == persist.payload_sha256 and
            durable["last_operation_id"] == persist.operation_id ->
          state = %{
            state
            | pending_write: nil,
              durable: durable,
              store_revision: revision,
              fault: nil
          }

          after_commit(state, persist, now, :historical)

        fault == :commit_uncertain and revision == persist.base_revision and
            hash == persist.expected_sha256 ->
          state = %{
            state
            | pending_write: nil,
              durable: durable,
              store_revision: revision,
              fault: nil
          }

          retry_evidence(state, persist)

        true ->
          invariant_fault(state, :invalid_store)
      end
    else
      _ -> invariant_fault(state, :invalid_store)
    end
  end

  defp resolve_readback(state, _persist, _durable, _revision, _hash, _now), do: {state, []}

  defp retry_evidence(state, %Persist{patch: %{"kind" => kind}} = persist)
       when kind in ["outcome", "service_complete"],
       do: write(state, persist.patch, persist.purpose)

  defp retry_evidence(state, _persist), do: {state, []}

  defp service_request(state, request, now, admission \\ :new) do
    case Service.plan(state, request) do
      {:read, result, renew?} ->
        state =
          if renew? and state.local_control_deadline_ms do
            %{
              state
              | last_local_control_ms: now,
                local_control_deadline_ms: now + @watchdog_window
            }
          else
            state
          end

        {state, [Service.reply(request["operation_id"], result)]}

      {:reply, result} ->
        {state, [Service.reply(request["operation_id"], result)]}

      {:admit, patch, action} ->
        admit_service(state, request, patch, action, now, admission)
    end
  end

  defp admit_service(state, request, patch, action, now, admission) do
    urgent? = action in [:stop, :recovery_entry, :seal, :clear]

    cond do
      urgent? and (state.motion || state.reservation || state.pending_write) ->
        {state, effects} = invalidate(state, :stopped)

        if length(state.pending_durable) < 32 do
          {enqueue(state, {:service, request}), effects}
        else
          {state, effects ++ [Service.reply(request["operation_id"], Service.error(:busy))]}
        end

      state.pending_write || state.motion || (admission == :new and state.pending_durable != []) ->
        {state, [Service.reply(request["operation_id"], Service.error(:busy))]}

      true ->
        {state, effects} = if urgent?, do: invalidate(state, :stopped), else: {state, []}

        state =
          if action == :local_motion do
            %{
              state
              | motion_generation: state.motion_generation + 1,
                last_local_control_ms: now,
                local_control_deadline_ms: now + @watchdog_window
            }
          else
            state
          end

        {state, write_effects} =
          write(state, patch, if(action == :clear, do: :clear, else: :service))

        {state, watchdog} =
          if action == :local_motion and match?(%Persist{}, state.pending_write) do
            admitted = patch["service_after"]["inflight_motion"]
            interval = div(1_000 + admitted["rate_steps_s"] - 1, admitted["rate_steps_s"])

            budget = %{
              steps: admitted["max_steps"],
              interval: interval,
              deadline: now + admitted["timeout_ms"]
            }

            # The timeline is reserved while the admission write is pending.
            # Only the independent watchdog is scheduled until commit.
            motion = motion_timeline(state, :service, nil, admitted["operation_id"], budget, now)
            reserved = %{state | motion: motion}
            {reserved, [schedule(reserved, :local_watchdog, reserved.local_control_deadline_ms)]}
          else
            {state, []}
          end

        {state, effects ++ write_effects ++ watchdog}
    end
  end

  defp service_commit(state, persist, receipt, now, mode) do
    id = receipt["operation_id"]
    command = receipt["command"]

    live? =
      mode == :live and persist.effect_generation == state.effect_generation and
        persist.motion_generation == state.motion_generation and is_nil(state.fault)

    cond do
      command == "reboot" and live? ->
        {state, [{:reboot_requested, id}]}

      command == "recovery.enter" ->
        {reset_binding(clear_verification(state), nil), []}

      command in [
        "stop",
        "motion.stop",
        "recovery.seal",
        "recovery.attest_replacement",
        "service.prepare",
        "calibration.set",
        "history.clear"
      ] ->
        {clear_verification(state), []}

      command == "reference.set" and live? ->
        revision = receipt["decision"]["data"]["reference_revision"]

        reference = %{
          reference_revision: revision,
          calibration_revision: Durable.calibration_revision(state.durable),
          binding: state.binding,
          modeled_position: :unknown
        }

        {%{
           state
           | local_reference: reference,
             readiness: %{calibration_valid: true, start_verified: false}
         }, []}

      command == "position.confirm" and live? ->
        mode = receipt["decision"]["data"]["modeled_position"]
        position = if mode == "locked", do: :locked, else: :released
        reference = %{state.local_reference | modeled_position: position}
        readiness = %{state.readiness | start_verified: position == :locked}
        {%{state | local_reference: reference, readiness: readiness}, []}

      command == "service.exit" ->
        {state, [{:status, nil}]}

      command in ["motion.jog", "motion.relock", "motion.release_test"] ->
        start_service_motion(state, id, live?, now)

      true ->
        {state, []}
    end
  end

  defp start_service_motion(state, id, live?, now) do
    admitted = state.durable["service"]["inflight_motion"]

    if live? and match?(%{kind: :service, service_operation_id: ^id}, state.motion) and
         not is_nil(state.local_control_deadline_ms) and not is_nil(admitted) and
         admitted["admission_box_boot_id"] == state.boot_id and
         state.durable["service"]["service_inhibited"] and
         not state.durable["service"]["motion_frozen"] do
      due = now + state.motion.step_interval_ms
      motion = %{state.motion | next_step_at_ms: due}
      readiness = %{state.readiness | start_verified: false}
      state = %{state | motion: motion, readiness: readiness}
      {state, [schedule(state, :step, due)]}
    else
      state = clear_motion(state)

      {enqueue(
         state,
         {:service_complete, id, completion("uncertain", "freshness_lost", 0), :service}
       ), []}
    end
  end
end
