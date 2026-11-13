defmodule Vault.Simulator.Client do
  @moduledoc false
  use GenServer

  alias Vault.Protocol
  alias Vault.SimulatedBox.Adapter
  alias Vault.Simulator.{Admission, BoxRuntime, MintTransport, Runner}

  @retry_ms 500
  @max_int 9_007_199_254_740_991
  @welcome_ms 2_000
  @silence_ms 1_500
  @context_fields ~w(session_id round_id puzzle_revision role control_epoch)

  def start_link(runner, generation, opts),
    do: GenServer.start_link(__MODULE__, {runner, generation, opts})

  def command(gate, action, payload)
      when action in ~w(claim_role release_role request_snapshot move select_rune) and
             is_map(payload) do
    if :erlang.external_size(payload) <= 1_024,
      do: Admission.offer(gate, {:command, action, payload}),
      else: {:error, :invalid_payload}
  end

  def hold(gate, pressed) when is_boolean(pressed), do: Admission.offer(gate, {:hold, pressed})

  @doc false
  def box_status(gate, encoded) when byte_size(encoded) <= 4_096,
    do: Admission.offer(gate, {:box_status, encoded})

  @doc false
  def box_heartbeat(gate, seq, input_seq, observed)
      when is_integer(seq) and is_integer(input_seq) and is_integer(observed),
      do: Admission.offer(gate, {:box_heartbeat, seq, input_seq, observed})

  @doc false
  def test_frame(gate, {:text, bytes} = frame) when byte_size(bytes) <= 4_096,
    do: Admission.offer(gate, {:test_frame, frame})

  @doc false
  def test_frame(gate, {kind, bytes} = frame)
      when kind in [:ping, :pong] and byte_size(bytes) <= 125,
      do: Admission.offer(gate, {:test_frame, frame})

  @impl true
  def init({runner, generation, opts}) do
    {:ok,
     %{
       runner: runner,
       generation: generation,
       opts: opts,
       driver: Keyword.get(opts, :driver, MintTransport),
       transport: nil,
       gate: nil,
       box_gate: nil,
       boot: opts[:boot_id] || Adapter.id("boot"),
       phase: :connect,
       phase_due: nil,
       phase_token: nil,
       welcome: nil,
       snapshot: nil,
       challenge: nil,
       pending: nil,
       feedback_seq: 0,
       feedback_until: nil,
       command_seq: 0,
       input_seq: 0,
       press_counter: opts[:press_counter],
       explicit_snapshot: nil,
       pressed: nil,
       neutral: false,
       neutral_seq: nil,
       queue: :queue.new(),
       heartbeat: nil,
       turn: nil,
       budget: {10_000, now()}
     }}
  end

  @impl true
  def handle_info({:connect, gate}, state) do
    state = %{state | gate: gate}

    with {:ok, boot} <- boot(state),
         {:ok, credential} <- credential(state.opts),
         {:ok, conn} <- state.driver.connect(state.opts),
         :ok <- Runner.connected(state.runner, state.generation),
         :ok <- Admission.reserve(gate) do
      trace(state, {:socket_options, state.driver.socket_options(conn, state.opts[:uri].scheme)})

      state = set_phase(%{state | transport: conn, boot: boot}, :upgrade, @welcome_ms)
      write(state, {:upgrade, state.opts[:uri], credential}, :upgrade)
    else
      _ -> retire(state, :connect_failed)
    end
  end

  def handle_info({:admitted, g, item}, %{generation: g} = state) do
    with :ok <- check_deadlines(state) do
      incoming(state, item)
    else
      {:error, reason} -> retire(state, reason)
    end
  end

  def handle_info({:turn, token}, %{turn: token} = state) do
    state = %{state | turn: nil}

    with :ok <- check_deadlines(state) do
      send_one(state)
    else
      {:error, reason} -> retire(state, reason)
    end
  end

  def handle_info({:phase_deadline, token}, %{phase_token: token} = state) do
    case check_deadlines(state) do
      :ok -> {:noreply, schedule_phase_timer(state)}
      {:error, reason} -> retire(state, reason)
    end
  end

  def handle_info({:retry, token}, %{pending: %{token: token} = pending} = state) do
    with :ok <- check_deadlines(state) do
      cond do
        pending.attempts >= 3 ->
          retire(state, :result_timeout)

        pending.queued ->
          {:noreply, state}

        true ->
          state = put_in(state.pending.queued, true)
          enqueue(state, {:command_write, pending.sequence, pending.bytes}, false)
      end
    else
      {:error, reason} -> retire(state, reason)
    end
  end

  def handle_info({:box_unbound, g}, %{generation: g} = state), do: retire(state, :box_unbound)

  def handle_info({kind, _, _} = event, state) when kind in [:tcp, :tcp_error, :ssl, :ssl_error],
    do: socket_event(state, event)

  def handle_info({kind, _} = event, state) when kind in [:tcp_closed, :ssl_closed],
    do: socket_event(state, event)

  def handle_info({:feedback_expired, sequence}, %{feedback_seq: sequence} = state) do
    case state.feedback_until do
      nil ->
        {:noreply, state}

      due ->
        if now() >= due do
          trace(state, {:feedback, :quiet})
          {:noreply, %{state | feedback_until: nil}}
        else
          Process.send_after(self(), {:feedback_expired, sequence}, due, abs: true)
          {:noreply, state}
        end
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def format_status(status), do: Map.drop(status, [:state, :message, :log, :reason])

  defp boot(%{opts: opts, boot: boot}) do
    if opts[:box], do: BoxRuntime.boot_id(opts[:box]), else: {:ok, boot}
  end

  defp credential(opts) do
    with {:ok, <<token::binary-size(64), "\n">>} <-
           Vault.MaintenanceGuard.read_protected(opts[:credentials_file], 65),
         true <- Vault.Credentials.device_key?(token) do
      {:ok, token}
    else
      _ -> {:error, :invalid_credentials_file}
    end
  end

  defp socket_event(%{transport: nil} = state, _), do: {:noreply, state}

  defp socket_event(state, event) do
    observed = %{transport_ms: now(), box_ms: box_now(state)}

    with :ok <- check_deadlines(state),
         {:ok, transport, events} <- state.driver.stream(state.transport, event) do
      Enum.reduce_while(events, {:noreply, %{state | transport: transport}}, fn event,
                                                                                {:noreply, acc} ->
        result = frame(acc, event, observed)
        if elem(result, 0) == :noreply, do: {:cont, result}, else: {:halt, result}
      end)
    else
      {:error, transport, reason} -> retire(%{state | transport: transport}, reason)
      {:error, reason} -> retire(state, reason)
    end
  end

  defp frame(%{phase: :upgrade} = state, :upgraded, _observed) do
    box? = state.opts[:box] != nil

    hello = %{
      "v" => 1,
      "type" => "hello",
      "device_id" => state.opts[:device_id],
      "boot_id" => state.boot,
      "device_class" => if(box?, do: "box", else: "controller"),
      "firmware_version" => "0.1.0",
      "capabilities" => capabilities(box?)
    }

    state = set_phase(state, :welcome, @welcome_ms)
    enqueue_message(state, hello)
  end

  defp frame(%{phase: :closing} = state, _, _), do: {:noreply, state}

  defp frame(state, {:ping, bytes}, _), do: enqueue(state, {:pong, bytes}, false)
  defp frame(state, {:pong, _}, _), do: {:noreply, state}

  defp frame(state, {:close, code, reason}, _) do
    # The acknowledgement is a separately budgeted write; discard any work
    # waiting for this closing connection and stop the independent runtime now.
    if state.opts[:box], do: BoxRuntime.retire(state.opts[:box], self(), state.generation)
    state = drop_queue(state)

    state = %{
      state
      | phase: :closing,
        phase_due: nil,
        phase_token: nil,
        pending: nil,
        heartbeat: nil
    }

    enqueue(state, {:close, code || 1_000, reason || ""}, false)
  end

  defp frame(state, {:text, bytes}, observed) do
    case Protocol.decode(bytes, :server_to_device) do
      {:ok, %{message: message}} -> server_message(state, message, observed)
      _ -> retire(state, :invalid_server_message)
    end
  end

  defp frame(state, _, _), do: retire(state, :unexpected_frame)

  defp capabilities(false),
    do: %{
      "touch" => true,
      "screen_width" => 240,
      "screen_height" => 320,
      "max_message_bytes" => 8192
    }

  defp capabilities(true),
    do: %{
      "latch" => "stepper",
      "home_sensor" => false,
      "released_sensor" => false,
      "led_count" => 0,
      "buzzer" => false,
      "max_message_bytes" => 8192
    }

  defp server_message(%{phase: :welcome} = state, %{"type" => "welcome"} = welcome, _observed) do
    box = state.opts[:box]

    with {:ok, box_gate} <-
           if(box,
             do: BoxRuntime.bind(box, state.gate, state.boot, welcome),
             else: {:ok, nil}
           ) do
      state = set_phase(%{state | welcome: welcome, box_gate: box_gate}, :open, @silence_ms)
      trace(state, {:welcome, state.gate, welcome})
      {:noreply, state}
    else
      _ -> retire(state, :box_binding_rejected)
    end
  end

  defp server_message(%{phase: :open} = state, %{"connection_id" => id} = msg, observed) do
    if id == state.welcome["connection_id"] and
         Map.get(msg, "session_id", state.welcome["session_id"]) == state.welcome["session_id"] do
      bound_message(state, msg, observed)
    else
      retire(state, :stale_binding)
    end
  end

  defp server_message(state, _, _), do: retire(state, :unexpected_message)

  defp bound_message(
         state,
         %{"type" => "heartbeat_request", "heartbeat_seq" => seq} = msg,
         %{transport_ms: at, box_ms: observed}
       ) do
    if (is_nil(state.challenge) or seq > elem(state.challenge, 0)) and
         observed + 400 > box_now(state) do
      state = renew_silence(%{state | challenge: {seq, observed}}, at)

      if state.box_gate,
        do: box_event(state, msg, observed),
        else: enqueue_heartbeat(state, :controller, false)
    else
      {:noreply, state}
    end
  end

  defp bound_message(state, %{"type" => "snapshot"} = snapshot, _) do
    previous = state.snapshot

    newer? = is_nil(previous) or snapshot["state_revision"] > previous["state_revision"]

    requested? =
      state.explicit_snapshot && now() < state.explicit_snapshot &&
        snapshot["state_revision"] == previous["state_revision"]

    if newer? or requested? == true do
      changed =
        is_nil(previous) or
          Map.take(previous, @context_fields) != Map.take(snapshot, @context_fields) or
          previous["paused"] != snapshot["paused"] or previous["phase"] != snapshot["phase"] or
          (get_in(snapshot, ["hold", "fresh_press_required"]) == true &&
             get_in(previous, ["hold", "fresh_press_required"]) != true)

      state = %{state | snapshot: snapshot, explicit_snapshot: nil}
      state = if changed, do: clear_press(state), else: state
      trace(state, {:snapshot, snapshot})
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  defp bound_message(state, %{"type" => "command_result", "command_seq" => seq} = result, _) do
    if state.pending && state.pending.sequence == seq do
      trace(state, {:command_result, result})
      {:noreply, %{state | pending: nil}}
    else
      {:noreply, state}
    end
  end

  defp bound_message(state, %{"type" => "heartbeat_ack"} = ack, _) do
    trace(state, {:heartbeat_ack, ack})

    cond do
      state.neutral_seq != nil and ack["input_seq"] >= state.neutral_seq and ack["input_accepted"] ->
        {:noreply, %{state | neutral: true, neutral_seq: nil}}

      ack["code"] in ~w(must_release stale_context) ->
        {:noreply, clear_press(state)}

      true ->
        {:noreply, state}
    end
  end

  defp bound_message(%{box_gate: box} = state, %{"type" => "box_feedback"} = msg, observed)
       when not is_nil(box) do
    due = observed.transport_ms + msg["ttl_ms"]

    if msg["box_boot_id"] == state.boot and msg["feedback_seq"] > state.feedback_seq and
         now() < due do
      trace(state, {:feedback, Map.take(msg, ~w(feedback_seq light_mode progress_percent sound))})
      Process.send_after(self(), {:feedback_expired, msg["feedback_seq"]}, due, abs: true)
      {:noreply, %{state | feedback_seq: msg["feedback_seq"], feedback_until: due}}
    else
      {:noreply, state}
    end
  end

  defp bound_message(%{box_gate: box} = state, %{"type" => type} = msg, observed)
       when not is_nil(box) and
              type in ~w(box_arm box_disarm box_command box_query box_status_ack) do
    box_event(state, msg, observed.box_ms)
  end

  defp bound_message(state, _, _), do: retire(state, :unexpected_message)

  defp box_event(state, msg, observed) do
    case BoxRuntime.deliver(state.box_gate, msg, observed) do
      :ok -> {:noreply, state}
      {:error, reason} -> retire(state, reason)
    end
  end

  defp incoming(%{phase: :open, pending: nil, box_gate: nil} = state, {:command, action, payload}) do
    if state.command_seq == @max_int do
      retire(state, :counter_exhausted)
    else
      seq = state.command_seq + 1

      command =
        %{
          "v" => 1,
          "type" => "command",
          "connection_id" => state.welcome["connection_id"],
          "session_id" => state.welcome["session_id"],
          "command_seq" => seq,
          "action" => action,
          "payload" => payload
        }
        |> Map.merge(command_context(state.snapshot, action))

      case Protocol.encode(command, :device_to_server) do
        {:ok, bytes} ->
          pending = %{sequence: seq, token: nil, bytes: bytes, attempts: -1, queued: true}
          state = %{state | pending: pending, command_seq: seq}

          state =
            if action == "request_snapshot",
              do: %{state | explicit_snapshot: now() + 2_000},
              else: state

          enqueue(state, {:command_write, seq, bytes}, true)

        _ ->
          discard(state, :invalid_command)
      end
    end
  end

  defp incoming(%{phase: :open, box_gate: nil} = state, {:hold, pressed}) do
    eligible =
      state.snapshot && state.snapshot["projection"] == "controller" &&
        state.snapshot["phase"] == "seal" && !state.snapshot["paused"]

    cond do
      !pressed ->
        Admission.release(state.gate)
        enqueue_heartbeat(%{state | pressed: nil}, :controller, false)

      eligible && state.neutral && is_nil(state.pressed) &&
          :atomics.get(state.press_counter, 1) < @max_int ->
        press = :atomics.add_get(state.press_counter, 1, 1)
        Admission.release(state.gate)
        enqueue_heartbeat(%{state | pressed: press}, :controller, false)

      true ->
        discard(state, :fresh_press_required)
    end
  end

  defp incoming(%{phase: :open, box_gate: box} = state, {:box_status, bytes})
       when not is_nil(box),
       do: enqueue(state, {:text, bytes}, true)

  defp incoming(%{phase: :open, box_gate: box} = state, {:box_heartbeat, seq, input, at})
       when not is_nil(box),
       do: enqueue_heartbeat(state, {:box, seq, input, at}, true)

  defp incoming(%{phase: :open, opts: opts} = state, {:test_frame, frame}) do
    if opts[:test_frames],
      do: enqueue(state, {:test, frame}, true),
      else: discard(state, :action_unavailable)
  end

  defp incoming(state, _), do: discard(state, :action_unavailable)

  defp discard(state, reason) do
    Admission.release(state.gate)
    trace(state, {:action_refused, reason})
    {:noreply, state}
  end

  defp command_context(nil, _), do: %{}

  defp command_context(snapshot, action) when action in ~w(move select_rune),
    do: Map.take(snapshot, @context_fields)

  defp command_context(snapshot, "release_role"), do: Map.take(snapshot, ~w(role control_epoch))
  defp command_context(_, _), do: %{}

  defp enqueue_message(state, message) do
    case Protocol.encode(message, :device_to_server) do
      {:ok, bytes} -> enqueue(state, {:text, bytes}, false)
      _ -> retire(state, :invalid_outbound_message)
    end
  end

  defp enqueue(state, item, reserved?) do
    case if(reserved?, do: :ok, else: Admission.reserve(state.gate)) do
      :ok ->
        {:noreply, schedule_turn(%{state | queue: :queue.in(item, state.queue)}, 0)}

      {:error, reason} ->
        retire(state, reason)
    end
  end

  defp enqueue_heartbeat(state, _item, reserved?) when is_nil(state.challenge) do
    if reserved?, do: Admission.release(state.gate)
    {:noreply, state}
  end

  defp enqueue_heartbeat(%{heartbeat: nil} = state, item, reserved?) do
    case if(reserved?, do: :ok, else: Admission.reserve(state.gate)) do
      :ok -> {:noreply, schedule_turn(%{state | heartbeat: item}, 0)}
      {:error, reason} -> retire(state, reason)
    end
  end

  defp enqueue_heartbeat(state, item, reserved?) do
    if reserved?, do: Admission.release(state.gate)
    {:noreply, %{state | heartbeat: item}}
  end

  defp schedule_turn(%{turn: nil} = state, delay) do
    token = make_ref()
    Process.send_after(self(), {:turn, token}, delay)
    %{state | turn: token}
  end

  defp schedule_turn(state, _delay), do: state

  defp drop_queue(state) do
    count = :queue.len(state.queue) + if(state.heartbeat, do: 1, else: 0)
    if count > 0, do: Enum.each(1..count, fn _ -> Admission.release(state.gate) end)
    %{state | queue: :queue.new()}
  end

  defp send_one(state) do
    {item, next} =
      case :queue.out(state.queue) do
        {{:value, item}, queue} -> {item, %{state | queue: queue}}
        {:empty, _} -> {state.heartbeat, %{state | heartbeat: nil}}
      end

    case item do
      nil ->
        {:noreply, state}

      item ->
        {credits, budget_now} = refill(state.budget)
        state = %{state | budget: {credits, budget_now}}
        next = %{next | budget: state.budget}

        cond do
          text_work?(item) and credits < 1_000 ->
            {:noreply, schedule_turn(state, div(1_029 - credits, 30))}

          true ->
            dispatch(next, item)
        end
    end
  end

  defp text_work?({kind, _}) when kind in [:text, :heartbeat], do: true
  defp text_work?({:command_write, _, _}), do: true
  defp text_work?({:box, _, _, _}), do: true
  defp text_work?(:controller), do: true
  defp text_work?(_), do: false

  defp refill({previous, at}) do
    now = now()
    {min(10_000, previous + max(0, now - at) * 30), now}
  end

  defp dispatch(state, {:command_write, seq, bytes}) do
    if state.pending && state.pending.sequence == seq do
      write(state, {:text, bytes}, {:command, seq})
    else
      Admission.release(state.gate)
      {:noreply, next_turn(state)}
    end
  end

  defp dispatch(state, :controller) do
    {seq, observed} = state.challenge

    cond do
      now() >= observed + 400 ->
        Admission.release(state.gate)
        {:noreply, next_turn(state)}

      state.input_seq == @max_int ->
        retire(state, :counter_exhausted)

      true ->
        input_seq = state.input_seq + 1
        input = complete_input(state)

        # Record the oldest outstanding neutral sample; every later accepted
        # neutral sample on this context is also sufficient for a baseline.
        state = %{state | input_seq: input_seq}

        state =
          if input && !input["pressed"] && !state.neutral,
            do: %{state | neutral_seq: state.neutral_seq || input_seq},
            else: state

        send_heartbeat(state, seq, input_seq, input)
    end
  end

  defp dispatch(state, {:box, seq, input_seq, observed}) do
    if box_now(state) < observed + 400,
      do: send_heartbeat(state, seq, input_seq, nil),
      else: {:noreply, next_turn(release_slot(state))}
  end

  defp dispatch(state, {:test, frame}), do: write(state, frame, :test_frame)
  defp dispatch(state, {:close, _, _} = frame), do: write(state, frame, :close)
  defp dispatch(state, {kind, _} = frame), do: write(state, frame, kind)

  defp complete_input(%{snapshot: %{"projection" => "controller"} = snapshot} = state) do
    Map.merge(Map.take(snapshot, @context_fields), %{
      "pressed" => state.pressed != nil,
      "press_id" => state.pressed
    })
  end

  defp complete_input(_), do: nil

  defp send_heartbeat(state, seq, input_seq, input) do
    heartbeat = %{
      "v" => 1,
      "type" => "heartbeat",
      "connection_id" => state.welcome["connection_id"],
      "heartbeat_seq" => seq,
      "input_seq" => input_seq,
      "input" => input
    }

    case Protocol.encode(heartbeat, :device_to_server) do
      {:ok, bytes} -> write(state, {:text, bytes}, :heartbeat)
      _ -> retire(state, :invalid_outbound_message)
    end
  end

  defp write(state, operation, kind) do
    id = make_ref()

    case Runner.start_write(state.runner, state.generation, id, kind) do
      :ok ->
        trace(state, {:write_enter, kind, now()})

        result =
          try do
            state.driver.write(state.transport, operation)
          rescue
            _ -> {:error, state.transport, :write_failed}
          catch
            _, _ -> {:error, state.transport, :write_failed}
          end

        {state, outcome} =
          case result do
            {:ok, transport} -> {%{state | transport: transport}, :ok}
            {:error, transport, reason} -> {%{state | transport: transport}, {:error, reason}}
          end

        trace(state, {:write_return, kind, outcome, now()})

        case Runner.complete_write(state.runner, state.generation, id, outcome) do
          :ok -> after_write(state, kind, operation)
          :close -> local_close(state)
          _ -> {:stop, :normal, state}
        end

      _ ->
        {:stop, :normal, state}
    end
  end

  defp after_write(state, :upgrade, _), do: {:noreply, release_slot(state)}

  defp after_write(state, kind, operation) do
    state = release_slot(state)

    state =
      if kind != :test_frame and match?({:text, _}, operation) do
        {credits, at} = state.budget
        %{state | budget: {max(0, credits - 1_000), at}}
      else
        state
      end

    state =
      case kind do
        {:command, sequence} ->
          token = make_ref()
          Process.send_after(self(), {:retry, token}, @retry_ms)

          if state.pending && state.pending.sequence == sequence do
            pending = %{
              state.pending
              | token: token,
                queued: false,
                attempts: state.pending.attempts + 1
            }

            %{state | pending: pending}
          else
            state
          end

        _ ->
          state
      end

    with :ok <- check_deadlines(state) do
      if kind == :close, do: retire(state, :peer_close), else: {:noreply, next_turn(state)}
    else
      {:error, reason} -> retire(state, reason)
    end
  end

  defp release_slot(state) do
    Admission.release(state.gate)
    state
  end

  defp next_turn(state) do
    if state.heartbeat || !:queue.is_empty(state.queue), do: schedule_turn(state, 0), else: state
  end

  defp clear_press(state), do: %{state | pressed: nil, neutral: false, neutral_seq: nil}

  defp set_phase(state, phase, timeout) do
    due = now() + timeout
    schedule_phase_timer(%{state | phase: phase, phase_due: due})
  end

  defp schedule_phase_timer(%{phase_due: nil} = state), do: state

  defp schedule_phase_timer(state) do
    token = make_ref()
    Process.send_after(self(), {:phase_deadline, token}, state.phase_due, abs: true)
    %{state | phase_token: token}
  end

  defp renew_silence(state, observed), do: %{state | phase_due: observed + @silence_ms}

  defp check_deadlines(%{phase_due: nil}), do: :ok

  defp check_deadlines(%{phase_due: due, phase: phase}) do
    if now() >= due do
      {:error, if(phase == :open, do: :server_silence, else: :handshake_timeout)}
    else
      :ok
    end
  end

  defp retire(state, reason) do
    case Runner.retire(state.runner, state.generation, reason) do
      :close -> local_close(state)
      _ -> {:stop, :normal, state}
    end
  end

  defp local_close(state) do
    if state.transport, do: state.driver.close(state.transport)
    {:stop, :normal, state}
  end

  defp trace(state, event) do
    if is_pid(state.opts[:client_trace]),
      do: send(state.opts[:client_trace], {:simulator_client, state.generation, event})
  end

  defp box_now(state),
    do: Vault.Clock.now_ms(Keyword.get(state.opts, :box_clock, Vault.Clock.system()))

  defp now, do: System.monotonic_time(:millisecond)
end
