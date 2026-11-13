defmodule Vault.Simulator.BoxRuntime do
  @moduledoc false
  use GenServer

  alias Vault.SimulatedBox
  alias Vault.SimulatedBox.Adapter
  alias Vault.Simulator.{Admission, Client}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def boot_id(box), do: GenServer.call(box, :boot_id)

  def bind(box, client_gate, boot, welcome),
    do: GenServer.call(box, {:bind, client_gate, boot, welcome})

  def deliver(gate, message, observed)
      when is_map(message) and is_integer(observed) do
    # Known fields have already passed the bounded wire decoder; extensions
    # never travel into the motion mailbox.
    body =
      Map.take(message, ~w(type connection_id session_id box_boot_id heartbeat_seq
        status_seq arm_id command_id action target))

    Admission.offer(gate, {:wire, body, observed})
  end

  def retire(box, owner, generation), do: send(box, {:retire, owner, generation})

  def prepare(box), do: GenServer.call(box, :prepare, 3_000)
  def service(box, command, args), do: GenServer.call(box, {:service, command, args}, 3_000)
  def request(box, request), do: GenServer.call(box, {:request, request}, 3_000)
  def binding(box), do: GenServer.call(box, :binding)
  def fault(box, name), do: GenServer.call(box, {:fault, name})
  def shutdown(box), do: GenServer.call(box, :shutdown, 3_000)

  @impl true
  def init(opts) do
    with {:ok, runtime} <-
           SimulatedBox.start_link(Keyword.merge(opts, name: nil, maintenance_owner: self())) do
      {:ok,
       %{
         runtime: runtime,
         owner: nil,
         monitor: nil,
         gate: nil,
         client: nil,
         boot: nil,
         welcome: nil,
         highest: 0,
         replies: %{},
         challenge_times: %{},
         trace: opts[:trace]
       }}
    end
  end

  @impl true
  def handle_call(:shutdown, _from, state) do
    case stop_runtime(state.runtime) do
      :ok -> {:stop, :normal, :ok, %{state | runtime: nil}}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call(:boot_id, _from, state), do: {:reply, Adapter.boot_id(state.runtime), state}

  def handle_call(:binding, _from, state) do
    current =
      if state.welcome do
        %{
          "box_boot_id" => state.boot,
          "connection_id" => state.welcome["connection_id"],
          "current_session_id" => state.welcome["session_id"]
        }
      end

    {:reply, current, state}
  end

  def handle_call({:bind, client, boot, welcome}, {owner, _}, state) do
    generation = client.generation

    with true <- client.pid == owner and generation > state.highest,
         nil <- state.owner,
         :ok <-
           Adapter.bind(state.runtime, boot, %{
             connection_id: welcome["connection_id"],
             session_id: welcome["session_id"],
             binding_generation: generation
           }) do
      monitor = Process.monitor(owner)
      gate = Admission.new(self(), generation, client.fault_to)

      next = %{
        state
        | owner: owner,
          monitor: monitor,
          gate: gate,
          client: client,
          boot: boot,
          welcome: welcome,
          highest: generation
      }

      {:reply, {:ok, gate}, next}
    else
      _ -> {:reply, {:error, :invalid_binding}, state}
    end
  end

  def handle_call(:prepare, from, state), do: local(state, from, &Adapter.prepare_async/2)

  def handle_call({:service, command, args}, from, state),
    do:
      local(state, from, fn runtime, ref ->
        Adapter.service_operation_async(runtime, command, args, ref)
      end)

  def handle_call({:request, request}, from, state),
    do: local(state, from, fn runtime, ref -> Adapter.request_service(runtime, request, ref) end)

  def handle_call({:fault, name}, _from, state)
      when name in [:disconnect, :reboot, :lost_ack, :interrupt],
      do: {:reply, Adapter.fault(state.runtime, name), state}

  @impl true
  def handle_info({:admitted, g, {:wire, body, observed}}, %{gate: %{generation: g}} = state) do
    state =
      if matches?(state, body) do
        route(state.runtime, g, body, observed)
        Adapter.barrier(state.runtime)
        remember_challenge(state, body, observed)
      else
        state
      end

    Admission.release(state.gate)
    {:noreply, state}
  end

  def handle_info({:retire, owner, g}, %{owner: owner, gate: %{generation: g}} = state),
    do: {:noreply, detach(state, :connection_lost)}

  def handle_info({:DOWN, ref, :process, owner, _}, %{owner: owner, monitor: ref} = state),
    do: {:noreply, detach(state, :connection_lost)}

  def handle_info({:simulated_box, :unbound, g, reason}, %{gate: %{generation: g}} = state) do
    send(state.owner, {:box_unbound, g})
    {:noreply, detach(state, reason)}
  end

  def handle_info(
        {:simulated_box, :heartbeat, g, boot, seq, input_seq},
        %{gate: %{generation: g}, boot: boot, client: client, challenge_times: _} = state
      ) do
    Client.box_heartbeat(
      client,
      seq,
      input_seq,
      Map.get(state.challenge_times, seq, -9_223_372_036_854_775_808)
    )

    {:noreply, state}
  end

  def handle_info(
        {:simulated_box, :status, g, report, _context},
        %{gate: %{generation: g}} = state
      ) do
    Client.box_status(state.client, report.original_json)
    {:noreply, state}
  end

  def handle_info({:simulated_box, :boot, _device, boot}, state) do
    if is_pid(state.trace), do: send(state.trace, {:external_box_boot, boot})
    {:noreply, state}
  end

  def handle_info({:simulated_box, :service, tag, result}, state) do
    {from, replies} = Map.pop(state.replies, tag)
    if from, do: GenServer.reply(from, result)
    {:noreply, %{state | replies: replies}}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, _), do: :ok

  defp stop_runtime(runtime) do
    with {:ok, worker} <- Adapter.store_worker(runtime) do
      monitor = Process.monitor(worker)
      GenServer.stop(runtime, :normal, 1_000)

      receive do
        {:DOWN, ^monitor, :process, ^worker, :normal} -> :ok
        {:DOWN, ^monitor, :process, ^worker, _} -> {:error, :store_stop_uncertain}
      after
        1_000 ->
          Process.demonitor(monitor, [:flush])
          {:error, :store_stop_uncertain}
      end
    end
  catch
    :exit, _ -> {:error, :store_stop_uncertain}
  end

  defp local(%{owner: nil} = state, _from, _submit),
    do: {:reply, %{"status" => "error", "code" => "binding_mismatch"}, state}

  defp local(state, from, submit) when map_size(state.replies) < 10 do
    tag = make_ref()

    case submit.(state.runtime, tag) do
      :ok -> {:noreply, %{state | replies: Map.put(state.replies, tag, from)}}
      _ -> {:reply, %{"status" => "error", "code" => "binding_mismatch"}, state}
    end
  end

  defp local(state, _from, _submit), do: {:reply, %{"status" => "error", "code" => "busy"}, state}

  defp detach(state, reason) do
    Admission.retire(state.gate)
    Process.demonitor(state.monitor, [:flush])
    Adapter.unbind(state.runtime, state.gate.generation, reason)

    %{
      state
      | owner: nil,
        monitor: nil,
        gate: nil,
        client: nil,
        welcome: nil,
        boot: nil,
        challenge_times: %{}
    }
  end

  defp remember_challenge(
         state,
         %{"type" => "heartbeat_request", "heartbeat_seq" => seq},
         observed
       ) do
    times = state.challenge_times
    times = Map.put_new(times, seq, observed)
    times = if map_size(times) > 32, do: Map.delete(times, Enum.min(Map.keys(times))), else: times
    %{state | challenge_times: times}
  end

  defp remember_challenge(state, _, _), do: state

  defp matches?(state, body) do
    body["connection_id"] == state.welcome["connection_id"] and
      Map.get(body, "session_id", state.welcome["session_id"]) == state.welcome["session_id"] and
      Map.get(body, "box_boot_id", state.boot) == state.boot
  end

  defp route(runtime, g, %{"type" => "heartbeat_request", "heartbeat_seq" => seq}, observed),
    do: Adapter.challenge(runtime, g, seq, observed)

  defp route(runtime, g, %{"type" => "box_arm", "arm_id" => arm}, _),
    do: Adapter.arm(runtime, g, arm)

  defp route(runtime, g, %{"type" => "box_disarm", "arm_id" => arm}, _),
    do: Adapter.disarm(runtime, g, arm)

  defp route(runtime, g, %{"type" => "box_command"} = msg, _) do
    Adapter.release(
      runtime,
      g,
      msg["box_boot_id"],
      msg["arm_id"],
      msg["heartbeat_seq"],
      msg["command_id"],
      Map.take(msg, ~w(session_id action target))
    )
  end

  defp route(runtime, g, %{"type" => "box_query", "command_id" => command}, _),
    do: Adapter.query(runtime, g, command, nil)

  defp route(runtime, g, %{"type" => "box_status_ack", "status_seq" => seq}, _),
    do: Adapter.ack_status(runtime, g, seq)

  defp route(_, _, _, _), do: :ok
end
