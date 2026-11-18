defmodule VaultWeb.DeviceSocket do
  @moduledoc false
  @behaviour WebSock

  require Logger

  alias Vault.{DeviceTimingDiagnostics, Games, Protocol, Updates}
  alias Vault.Controllers.{Actor, Context, Input}
  alias Vault.Protocol.CommandWindow

  @hello_ms 5_000
  @snapshot_ms 100
  @burst 10_000
  @rate 30
  @delivery_limit 32
  @snapshot_fields ~w(session_id round_id puzzle_revision state_revision phase paused pause_reasons
                       required_roles peers box projection role control_epoch maze seal hold board_version)a
  @roles %{"a" => :a, "b" => :b, "c" => :c, "d" => :d}
  @role_bits [a: 1, b: 2, c: 4, d: 8]
  @moves %{"up" => :up, "down" => :down, "left" => :left, "right" => :right}
  @runes %{"star" => :star, "moon" => :moon, "sun" => :sun, "wave" => :wave}
  @report_fields ~w(connection_id box_boot_id session_id status_seq command_id command_session_id
                     motor_active release_status latch_position position_basis failure_code)a
  @report_enums Map.new(
                  ~w(not_requested accepted motion_complete position_confirmed uncertain failed
                     locked released unknown endstop manual_verified unverified unknown_command
                     not_armed unknown_position stale_binding busy history_full connection_lost
                     reboot_interrupted freshness_lost travel_timeout limit_fault driver_fault)a,
                  &{Atom.to_string(&1), &1}
                )

  defmodule Delivery do
    @moduledoc false
    @enforce_keys [:pid, :counter]
    defstruct @enforce_keys ++ [:feedback]
  end

  defstruct [
    :registration,
    :delivery,
    :hello_deadline,
    :hello_timer,
    :game_pid,
    :game_monitor,
    :actor,
    :scope,
    :slot,
    :commands,
    :query,
    :pending_snapshot,
    :snapshot_timer,
    :snapshot_at,
    :token_at,
    timing_diagnostics: false,
    last_revision: -1,
    tokens: @burst
  ]

  # Reserve a mailbox slot before the producer sends. Overflow fences the entire
  # connection once, even if more than one producer observes it concurrently.
  def deliver(%Delivery{pid: pid, counter: counter}, event) do
    if :atomics.get(counter, 2) == 0 do
      if :atomics.add_get(counter, 1, 1) <= @delivery_limit do
        send(pid, {:vault_device_delivery, counter, event})
        :ok
      else
        :atomics.sub(counter, 1, 1)

        if :atomics.compare_exchange(counter, 2, 0, 1) == :ok,
          do: send(pid, {:vault_device_overflow, counter})

        {:error, :backpressure}
      end
    else
      {:error, :backpressure}
    end
  end

  # The GameSession is the sole producer. Replacing the slot cannot fill the
  # queue reserved for a challenge, arm, release, or query.
  def offer_feedback(%Delivery{pid: pid, feedback: slot} = delivery, payload)
      when is_reference(slot) do
    cond do
      :ets.insert_new(slot, {:latest, payload}) ->
        Kernel.send(pid, {:vault_device_feedback, slot})

      :ets.update_element(slot, :latest, {2, payload}) ->
        :ok

      true ->
        offer_feedback(delivery, payload)
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  def offer_feedback(_, _), do: :ok

  @impl true
  def init(registration) do
    now = now_ms()
    timer = Process.send_after(self(), :device_hello_deadline, @hello_ms)

    {:ok,
     %__MODULE__{
       registration: registration,
       delivery: %Delivery{pid: self(), counter: :atomics.new(2, signed: false)},
       hello_deadline: now + @hello_ms,
       hello_timer: timer,
       commands: CommandWindow.new(),
       token_at: now,
       timing_diagnostics: DeviceTimingDiagnostics.enabled?()
     }}
  end

  @impl true
  def handle_in({_, opcode: :binary}, state), do: close(state, 1003, "text_required")

  def handle_in({bytes, opcode: :text}, state) do
    with {:ok, state} <- admit(state),
         {:ok, message} <- Protocol.decode(bytes) do
      handle_message(message, state)
    else
      :backpressure -> close(state, 1013, "slow_consumer")
      :rate_limit -> close(state, 1008, "rate_limit")
      {:error, :size} -> close(state, 1009, "message_size")
      {:error, _} -> close(state, 1002, "invalid_message")
    end
  end

  @impl true
  def handle_info(:device_hello_deadline, %{actor: nil} = state),
    do: close(state, 1008, "hello_timeout")

  def handle_info({:DOWN, ref, :process, _, _}, %{game_monitor: ref} = state),
    do: session_reset(state)

  def handle_info({:vault_session, game_id, session_id, _}, state) do
    if (state.registration.game_id == game_id and state.actor) &&
         state.actor.session_id == session_id,
       do: session_reset(state),
       else: {:ok, state}
  end

  def handle_info({:vault_disconnect, id, :session_changed}, %{actor: %{actor_id: id}} = state),
    do: session_reset(state)

  def handle_info({:vault_disconnect, id, _reason}, %{actor: %{actor_id: id}} = state),
    do: close(state, 1008, "binding_ended")

  def handle_info({:vault_device_overflow, counter}, %{delivery: %{counter: counter}} = state),
    do: close(state, 1013, "slow_consumer")

  def handle_info(
        {:vault_device_delivery, counter, event},
        %{delivery: %{counter: counter}} = state
      ) do
    :atomics.sub(counter, 1, 1)

    if :atomics.get(counter, 2) == 1,
      do: close(state, 1013, "slow_consumer"),
      else: handle_delivery(event, state)
  end

  def handle_info({:vault_device_snapshot, slot}, %{slot: slot} = state)
      when is_reference(slot) do
    case Updates.take_device_snapshot(slot) do
      {:ok, {:vault_snapshot, game_id, session, audience, projection}} ->
        with true <- state.registration.game_id == game_id,
             {^session, ^audience, epoch} <- state.scope,
             true <- projection.control_epoch == epoch and projection.session_id == session do
          {:ok, offer_snapshot(state, projection, false)}
        else
          _ -> {:ok, state}
        end

      :empty ->
        {:ok, state}
    end
  end

  def handle_info({:device_snapshot_flush, token}, %{snapshot_timer: {_, token}} = state),
    do: flush_snapshot(%{state | snapshot_timer: nil})

  def handle_info({:vault_device_feedback, slot}, %{delivery: %{feedback: slot}} = state)
      when is_reference(slot) do
    case :ets.take(slot, :latest) do
      [{:latest, {:vault_box, _, _, _, _, deadline} = event}] ->
        if now_ms() < deadline, do: handle_delivery(event, state), else: {:ok, state}

      [] ->
        {:ok, state}
    end
  end

  def handle_info(_, state), do: {:ok, state}

  @impl true
  def terminate(reason, state) do
    :atomics.put(state.delivery.counter, 2, 2)
    if reason != :normal, do: log_close(state, "terminated cause=#{termination_cause(reason)}")

    if state.actor && Process.alive?(state.game_pid),
      do: Games.disconnect(state.actor, state.registration.game_id, :disconnected)

    :ok
  end

  defp termination_cause(:remote), do: :peer_close_frame
  defp termination_cause({:error, :closed}), do: :transport_closed
  defp termination_cause(:timeout), do: :transport_timeout
  defp termination_cause(:shutdown), do: :server_shutdown
  defp termination_cause({:error, _}), do: :adapter_error
  defp termination_cause(_), do: :unknown

  defp handle_message(%{message: %{"type" => "hello"} = hello}, %{actor: nil} = state),
    do: hello(hello, state)

  defp handle_message(_, %{actor: nil} = state), do: close(state, 1002, "hello_required")

  defp handle_message(%{message: %{"connection_id" => id}} = decoded, %{actor: actor} = state)
       when actor.connection_id == id do
    started = DeviceTimingDiagnostics.start(state.timing_diagnostics)
    result = Games.device_scope(actor, state.registration.game_id)
    DeviceTimingDiagnostics.finish(:device_scope, started)

    case result do
      {:ok, scope} -> route(decoded, scope, state)
      error -> authority_error(state, error)
    end
  end

  defp handle_message(_, state), do: close(state, 1002, "invalid_binding")

  defp hello(hello, state) do
    %{principal: principal, game_id: game, device_class: class} = state.registration

    cond do
      now_ms() >= state.hello_deadline ->
        close(state, 1008, "hello_timeout")

      hello["device_id"] != principal.subject_id or hello["device_class"] != Atom.to_string(class) ->
        close(state, 1008, "identity_mismatch")

      true ->
        bind(state, game, principal, class, hello)
    end
  end

  defp bind(state, game, principal, class, hello) do
    caps = hello["capabilities"]

    state =
      if class == :box and (caps["led_count"] > 0 or caps["buzzer"]),
        do: put_in(state.delivery.feedback, :ets.new(:box_feedback, [:set, :public])),
        else: state

    opts = %{
      source: if(class == :controller, do: :cyd, else: :box),
      boot_id: hello["boot_id"],
      owner_pid: self(),
      panel: nil,
      device_delivery: state.delivery,
      box_feedback: if(state.delivery.feedback, do: caps)
    }

    with {:ok, {actor, context, pid}} <- Games.bind_device(principal, game, opts) do
      state = %{state | actor: actor, game_pid: pid, game_monitor: Process.monitor(pid)}
      Process.cancel_timer(state.hello_timer)
      bootstrap(state, context, principal.allowed_roles, class)
    else
      error -> authority_error(state, error)
    end
  end

  defp bootstrap(state, context, roles, class) do
    with {:ok, {session, _, _} = scope} <-
           Games.device_scope(state.actor, state.registration.game_id),
         true <- session == context.session_id,
         {:ok, state, projection} <- subscribe(state, scope) do
      welcome = %{
        session_id: session,
        round_id: projection.round_id,
        puzzle_revision: projection.puzzle_revision,
        required_roles: if(class == :controller, do: projection.required_roles, else: []),
        allowed_roles: roles,
        assigned_role: nil,
        heartbeat_interval_ms: 100,
        input_lease_ms: 400,
        peer_dead_ms: 1_500
      }

      with {:ok, greeting} <- Protocol.encode(wire(state, "welcome", welcome)),
           {:ok, snapshot} <- Protocol.encode(snapshot_wire(state, projection)) do
        {:push, [text: greeting, text: snapshot], snapshot_sent(state, projection)}
      else
        _ -> close(state, 1011, "invalid_output")
      end
    else
      false -> session_reset(state)
      error -> authority_error(state, error)
    end
  end

  defp route(%{message: %{"type" => "heartbeat"} = message}, _scope, state) do
    input = message["input"]

    sample = %Input{
      heartbeat_seq: message["heartbeat_seq"],
      input_seq: message["input_seq"],
      context: if(input, do: context(message["connection_id"], input)),
      pressed: if(input, do: input["pressed"], else: false),
      press_id: if(input, do: input["press_id"])
    }

    started = DeviceTimingDiagnostics.start(state.timing_diagnostics)
    result = Games.sample(state.actor, state.registration.game_id, sample)
    DeviceTimingDiagnostics.finish(:device_sample, started)

    case result do
      {:ok, result} -> push(state, wire(state, "heartbeat_ack", Map.from_struct(result)))
      error -> authority_error(state, error)
    end
  end

  defp route(%{message: %{"session_id" => session}}, {current, _, _}, state)
       when session != current,
       do: session_reset(state)

  defp route(
         %{message: %{"type" => "command"} = message, comparison: comparison},
         scope,
         %{registration: %{device_class: :controller}} = state
       ),
       do: command(state, scope, message, comparison)

  defp route(
         %{message: %{"type" => "box_status", "box_boot_id" => boot} = message} = decoded,
         _scope,
         %{registration: %{device_class: :box}, actor: %{boot_id: boot}} = state
       ) do
    status = box_status(message)

    report = %{
      status: status,
      comparison: decoded.comparison,
      original_json: decoded.original_json
    }

    query =
      case state.query do
        {id, %{minimum_status_seq: floor} = context}
        when id == status.command_id and status.status_seq > floor ->
          context

        _ ->
          nil
      end

    case Games.box_observation(state.actor, state.registration.game_id, report, query) do
      {:ok, ack} ->
        state = if query && ack.accepted, do: %{state | query: nil}, else: state
        push(state, wire(state, "box_status_ack", ack))

      {:error, %{code: code}} when code in [:content_conflict, :invalid_binding] ->
        close(state, 1002, "sequence_conflict")

      {:error, %{code: :storage_error}} ->
        close(state, 1011, "storage_error")

      error ->
        authority_error(state, error)
    end
  end

  defp route(_, _, state), do: close(state, 1008, "message_scope")

  defp command(state, scope, message, comparison) do
    seq = message["command_seq"]

    case CommandWindow.check(state.commands, seq, comparison) do
      :next ->
        execute_command(state, scope, message, seq, comparison)

      {:replay, result} ->
        push(state, result)

      {:gap, expected} ->
        sequence_result(state, scope, seq, :seq_gap, %{expected_command_seq: expected})

      :expired ->
        sequence_result(state, scope, seq, :result_expired, %{})

      :conflict ->
        close(state, 1002, "sequence_conflict")
    end
  end

  defp execute_command(state, scope, message, seq, comparison) do
    context = context(state.actor.connection_id, message)
    action = action(message["action"], message["payload"])

    case Games.command(state.actor, state.registration.game_id, seq, context, action) do
      {:ok, %{code: :stale_session}} ->
        session_reset(state)

      {:ok, result} ->
        result = wire(state, "command_result", Map.from_struct(result))
        state = %{state | commands: CommandWindow.put(state.commands, seq, comparison, result)}

        if action == :request_snapshot,
          do: sequence_snapshot(state, scope, result),
          else: push(state, result)

      error ->
        authority_error(state, error)
    end
  end

  defp sequence_result(state, scope, seq, code, data) do
    with {:ok, state, projection} <- current_projection(state, scope) do
      result =
        wire(state, "command_result", %{
          command_seq: seq,
          status: :rejected,
          code: code,
          session_id: projection.session_id,
          state_revision: projection.state_revision,
          data: data
        })

      state = if code == :result_expired, do: offer_snapshot(state, projection, true), else: state
      push(state, result)
    else
      error -> authority_error(state, error)
    end
  end

  defp sequence_snapshot(state, scope, result) do
    case current_projection(state, scope) do
      {:ok, state, projection} -> push(offer_snapshot(state, projection, true), result)
      error -> authority_error(state, error)
    end
  end

  defp handle_delivery(
         {:vault_challenge, id, connection, generation, seq, deadline},
         %{actor: %{actor_id: id, connection_id: connection, binding_generation: generation}} =
           state
       ) do
    if now_ms() < deadline,
      do: scoped_push(state, wire(state, "heartbeat_request", %{heartbeat_seq: seq}), deadline),
      else: {:ok, state}
  end

  defp handle_delivery(
         {:vault_box, id, generation, %{"connection_id" => connection} = message, query,
          deadline},
         %{
           registration: %{device_class: :box},
           actor: %{actor_id: id, connection_id: connection, binding_generation: generation}
         } = state
       ) do
    state =
      if message["type"] == "box_query",
        do: %{state | query: if(query, do: {message["command_id"], query})},
        else: state

    scoped_push(state, message, deadline)
  end

  defp handle_delivery(
         {:vault_context, %Actor{actor_id: id, binding_generation: generation} = actor, _, _},
         %{actor: %{actor_id: id, binding_generation: generation}} = state
       ) do
    state = %{state | actor: actor}

    with {:ok, scope} <- Games.device_scope(actor, state.registration.game_id),
         {:ok, state} <- sync_scope(state, scope) do
      {:ok, state}
    else
      error -> authority_error(state, error)
    end
  end

  defp handle_delivery(_, state), do: {:ok, state}

  defp scoped_push(state, message, deadline) do
    with {:ok, scope} <- Games.device_scope(state.actor, state.registration.game_id),
         {:ok, state} <- sync_scope(state, scope) do
      push(state, message, deadline)
    else
      error -> authority_error(state, error)
    end
  end

  defp current_projection(state, scope, remaining \\ 3)

  defp current_projection(_state, _scope, 0), do: Games.error(:scope_changed)

  defp current_projection(state, scope, remaining) do
    with {:ok, state} <- sync_scope(state, scope),
         {:ok, projection} <- Games.device_snapshot(state.actor, state.registration.game_id) do
      case projection_scope(projection) do
        scope when scope == state.scope -> {:ok, state, projection}
        scope -> current_projection(state, scope, remaining - 1)
      end
    end
  end

  defp sync_scope(%{scope: scope} = state, scope), do: {:ok, state}

  defp sync_scope(state, scope) do
    with {:ok, state, projection} <- subscribe(state, scope),
         do: {:ok, offer_snapshot(state, projection, true)}
  end

  defp subscribe(state, scope) do
    game = state.registration.game_id
    if state.slot, do: Updates.unsubscribe_device(game, state.scope, state.slot)
    if state.snapshot_timer, do: Process.cancel_timer(elem(state.snapshot_timer, 0))
    subscribe(state, scope, 3)
  end

  defp subscribe(_state, _scope, 0), do: Games.error(:scope_changed)

  defp subscribe(state, scope, remaining) do
    game = state.registration.game_id

    case Updates.subscribe_device(state.actor, game, scope) do
      {:ok, slot, projection} ->
        {:ok,
         %{
           state
           | slot: slot,
             scope: scope,
             pending_snapshot: nil,
             snapshot_timer: nil,
             last_revision: -1
         }, projection}

      {:error, %{code: :scope_changed}} ->
        with {:ok, current} <- Games.device_scope(state.actor, game),
             do: subscribe(state, current, remaining - 1)

      error ->
        error
    end
  end

  defp offer_snapshot(state, projection, explicit) do
    revision = projection.state_revision

    if revision > state.last_revision or (explicit and revision == state.last_revision) do
      projection =
        case state.pending_snapshot do
          %{state_revision: newer} = pending when newer >= revision -> pending
          _ -> projection
        end

      schedule_snapshot(%{state | pending_snapshot: projection})
    else
      state
    end
  end

  defp schedule_snapshot(%{snapshot_timer: {_, _}} = state), do: state

  defp schedule_snapshot(state) do
    now = now_ms()
    due = if state.snapshot_at, do: max(now, state.snapshot_at + @snapshot_ms), else: now
    token = make_ref()
    ref = Process.send_after(self(), {:device_snapshot_flush, token}, due - now)
    %{state | snapshot_timer: {ref, token}}
  end

  defp flush_snapshot(state) do
    case Games.device_scope(state.actor, state.registration.game_id) do
      {:ok, scope} when scope == state.scope ->
        projection = state.pending_snapshot
        push(snapshot_sent(state, projection), snapshot_wire(state, projection))

      {:ok, scope} ->
        case sync_scope(state, scope) do
          {:ok, state} -> {:ok, state}
          error -> authority_error(state, error)
        end

      error ->
        authority_error(state, error)
    end
  end

  defp snapshot_sent(state, projection) do
    %{
      state
      | snapshot_at: now_ms(),
        last_revision: projection.state_revision,
        pending_snapshot: nil
    }
  end

  defp projection_scope(%{projection: :controller} = projection),
    do: {projection.session_id, {:player, projection.role}, projection.control_epoch}

  defp projection_scope(projection), do: {projection.session_id, projection.projection, nil}

  defp snapshot_wire(state, projection),
    do: wire(state, "snapshot", Map.take(projection, @snapshot_fields))

  defp wire(state, type, fields) do
    fields
    |> json_value()
    |> Map.merge(%{"v" => 1, "type" => type, "connection_id" => state.actor.connection_id})
  end

  defp push(state, message, deadline \\ nil) do
    with {:ok, bytes} <- Protocol.encode(message) do
      cond do
        :atomics.get(state.delivery.counter, 2) == 1 -> close(state, 1013, "slow_consumer")
        deadline == nil or now_ms() < deadline -> {:push, {:text, bytes}, state}
        message["type"] in ["heartbeat_request", "box_feedback"] -> {:ok, state}
        true -> close(state, 1013, "delivery_expired")
      end
    else
      _ -> close(state, 1011, "invalid_output")
    end
  end

  defp json_value(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), json_value(item)} end)

  defp json_value(values) when is_list(values), do: Enum.map(values, &json_value/1)
  defp json_value(value) when value in [nil, true, false], do: value
  defp json_value(value) when is_atom(value), do: Atom.to_string(value)
  defp json_value(value), do: value

  defp context(connection_id, message) do
    %Context{
      connection_id: connection_id,
      session_id: message["session_id"],
      round_id: message["round_id"],
      puzzle_revision: message["puzzle_revision"],
      role: @roles[message["role"]],
      control_epoch: message["control_epoch"]
    }
  end

  defp action("claim_role", %{"role" => role}), do: {:claim_role, @roles[role]}
  defp action("release_role", _), do: :release_role
  defp action("request_snapshot", _), do: :request_snapshot

  defp action("move", %{"direction" => direction, "expected_board_version" => board}),
    do: {:move, @moves[direction], board}

  defp action("select_rune", %{"rune" => rune}), do: {:select_rune, @runes[rune]}

  defp box_status(message) do
    status = string_fields(message, @report_fields)

    readiness =
      string_fields(
        message["readiness"],
        ~w(arm_id armed_session_id calibration_valid start_verified)a
      )

    confirmation =
      case message["command_confirmation"] do
        nil ->
          nil

        %{"basis" => basis, "box_boot_id" => boot} ->
          %{basis: @report_enums[basis], box_boot_id: boot}
      end

    status
    |> Map.update!(:release_status, &Map.fetch!(@report_enums, &1))
    |> Map.update!(:latch_position, &Map.fetch!(@report_enums, &1))
    |> Map.update!(:position_basis, &Map.fetch!(@report_enums, &1))
    |> Map.update!(:failure_code, &Map.get(@report_enums, &1))
    |> Map.merge(%{command_confirmation: confirmation, readiness: readiness})
  end

  defp string_fields(map, keys), do: Map.new(keys, fn key -> {key, map[Atom.to_string(key)]} end)

  defp admit(state) do
    now = now_ms()
    tokens = min(@burst, state.tokens + @rate * (now - state.token_at))

    cond do
      :atomics.get(state.delivery.counter, 2) == 1 -> :backpressure
      tokens < 1_000 -> :rate_limit
      true -> {:ok, %{state | tokens: tokens - 1_000, token_at: now}}
    end
  end

  defp authority_error(state, {:error, %{code: :stale_session}}), do: session_reset(state)

  defp authority_error(%{game_pid: pid} = state, _) when is_pid(pid) do
    # A reset can commit after the preflight scope check and before the
    # dispatched operation finds the old actor. Classify the close using the
    # same authority, without executing the operation again or granting scope.
    if Process.alive?(pid) and
         not match?(
           {:error, %{code: :stale_session}},
           Games.device_scope(state.actor, state.registration.game_id)
         ) and Process.alive?(pid),
       do: close(state, 1008, "binding_ended"),
       else: session_reset(state)
  end

  defp authority_error(state, _), do: close(state, 1008, "binding_ended")
  defp session_reset(state), do: close(state, 4003, "session_reset")

  defp close(state, code, reason) do
    log_close(state, "server close code=#{code} cause=#{reason}")
    {:stop, :normal, {code, reason}, state}
  end

  defp log_close(state, event) do
    if System.get_env("VAULT_DEVICE_SOCKET_DIAGNOSTICS") == "true" do
      generation = if state.actor, do: state.actor.binding_generation, else: "unbound"
      roles = state.registration.principal.allowed_roles

      role_mask =
        Enum.reduce(@role_bits, 0, fn {role, bit}, mask ->
          if role in roles, do: mask + bit, else: mask
        end)

      now = now_ms()
      # token_at starts at socket initialization and advances only on admission.
      admission_age = max(now - state.token_at, 0)
      socket_age = max(now - (state.hello_deadline - @hello_ms), 0)

      Logger.warning(
        "Device socket #{event} binding_generation=#{generation} role_mask=#{role_mask} " <>
          "admission_age_ms=#{admission_age} tokens_after_admit=#{state.tokens} socket_age_ms=#{socket_age}"
      )
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
