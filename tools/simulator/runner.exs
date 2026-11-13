defmodule Vault.Simulator.Runner do
  @moduledoc false
  use GenServer

  alias Vault.Clock
  alias Vault.SimulatedBox.Adapter
  alias Vault.Simulator.{Admission, BoxRuntime, Client}

  @whole_write_ms 200
  @close_ms 100
  @connect_ms 1_500

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def gate(runner), do: GenServer.call(runner, :gate)
  def shutdown(runner), do: GenServer.call(runner, :shutdown, 3_000)

  def start_write(runner, generation, id, kind),
    do: GenServer.call(runner, {:start_write, generation, id, kind})

  def complete_write(runner, generation, id, result),
    do: GenServer.call(runner, {:complete_write, generation, id, result})

  def connected(runner, generation), do: GenServer.call(runner, {:connected, generation})

  def retire(runner, generation, reason),
    do: GenServer.call(runner, {:retire, generation, reason})

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    opts = Keyword.put_new_lazy(opts, :boot_id, fn -> Adapter.id("boot") end)
    opts = Keyword.put_new_lazy(opts, :press_counter, fn -> :atomics.new(1, []) end)

    state = %{
      opts: opts,
      clock: Keyword.get(opts, :runner_clock, Clock.system()),
      generation: Keyword.get(opts, :initial_generation, 0),
      owner: nil,
      monitor: nil,
      gate: nil,
      deadline: nil,
      retired: false,
      stopping: nil
    }

    {:ok, state, {:continue, :launch}}
  end

  @impl true
  def handle_continue(:launch, state), do: {:noreply, launch(state)}

  @impl true
  def handle_call(:shutdown, _from, %{owner: nil} = state),
    do: {:stop, :normal, :ok, state}

  def handle_call(:shutdown, from, state) do
    {:noreply, kill_owner(%{state | stopping: from}, :shutdown)}
  end

  def handle_call(:gate, _from, state) do
    state = sweep(state)
    {:reply, if(state.retired, do: nil, else: state.gate), state}
  end

  def handle_call(message, {caller, _}, state) do
    state = sweep(state)

    if caller == state.owner and not state.retired do
      owner_call(message, state)
    else
      {:reply, {:error, :retired}, state}
    end
  end

  defp owner_call({:connected, g}, %{generation: g, deadline: %{kind: :connect}} = state),
    do: {:reply, :ok, clear_deadline(state)}

  defp owner_call({:start_write, g, id, kind}, %{generation: g, deadline: nil} = state) do
    state = deadline(state, {:write, id}, @whole_write_ms)
    trace(state, {:write_start, g, id, kind, state.deadline.due})
    {:reply, :ok, state}
  end

  defp owner_call(
         {:complete_write, g, id, outcome},
         %{generation: g, deadline: %{kind: {:write, id}}} = state
       ) do
    state = clear_deadline(state)
    trace(state, {:write_end, g, id, outcome, now(state)})

    case outcome do
      :ok -> {:reply, :ok, state}
      {:error, reason} -> {:reply, :close, close_window(state, reason)}
    end
  end

  defp owner_call({:retire, g, reason}, %{generation: g} = state),
    do: {:reply, :close, close_window(state, reason)}

  defp owner_call(_, state), do: {:reply, {:error, :retired}, kill_owner(state, :owner_protocol)}

  @impl true
  def handle_info({:deadline, _token}, state), do: {:noreply, sweep(state)}

  def handle_info({:admission_fault, g}, %{generation: g, retired: false} = state),
    do: {:noreply, kill_owner(sweep(state), :queue_overflow)}

  def handle_info({:DOWN, ref, :process, pid, _}, %{monitor: ref, owner: pid} = state) do
    state = state |> sweep() |> invalidate(:owner_down) |> clear_deadline()
    trace(state, {:owner_down, state.generation})
    state = %{state | owner: nil, monitor: nil, gate: nil}

    if state.stopping do
      GenServer.reply(state.stopping, :ok)
      {:stop, :normal, state}
    else
      if Keyword.get(state.opts, :reconnect, true) do
        Process.send_after(self(), {:reconnect, state.generation}, 250)
      end

      {:noreply, state}
    end
  end

  def handle_info({:reconnect, generation}, %{generation: generation, owner: nil} = state),
    do: {:noreply, launch(state)}

  def handle_info(_message, state), do: {:noreply, sweep(state)}

  @impl true
  def terminate(_reason, state) do
    if state.owner, do: Process.exit(state.owner, :kill)
    :ok
  end

  @impl true
  def format_status(status), do: Map.drop(status, [:state, :message, :log, :reason])

  defp launch(state) do
    generation = state.generation + 1
    {:ok, owner} = Client.start_link(self(), generation, state.opts)
    monitor = Process.monitor(owner)
    gate = Admission.new(owner, generation, self())
    send(owner, {:connect, gate})

    %{state | generation: generation, owner: owner, monitor: monitor, gate: gate, retired: false}
    |> deadline(:connect, @connect_ms)
  end

  defp close_window(state, reason) do
    state = state |> invalidate(reason) |> deadline(:close, @close_ms)
    trace(state, {:close_window, state.generation, state.deadline.due})
    state
  end

  defp invalidate(%{retired: true} = state, _), do: state

  defp invalidate(state, reason) do
    Admission.retire(state.gate)
    if state.opts[:box], do: BoxRuntime.retire(state.opts[:box], state.owner, state.generation)
    trace(state, {:retired, state.generation, reason, now(state)})
    %{state | retired: true}
  end

  defp kill_owner(state, reason) do
    state = state |> invalidate(reason) |> clear_deadline()
    trace(state, {:owner_kill, state.generation, reason, now(state)})
    if state.owner, do: Process.exit(state.owner, :kill)
    state
  end

  defp sweep(%{deadline: nil} = state), do: state

  defp sweep(%{deadline: %{due: due, kind: kind}} = state) do
    if now(state) >= due do
      reason =
        case kind do
          :connect -> :connect_deadline
          {:write, _} -> :write_deadline
          :close -> :close_deadline
        end

      kill_owner(state, reason)
    else
      state
    end
  end

  defp deadline(state, kind, duration) do
    state = clear_deadline(state)
    token = make_ref()
    due = now(state) + duration
    timer = Clock.schedule_at(state.clock, self(), {:deadline, token}, due)
    %{state | deadline: %{token: token, kind: kind, timer: timer, due: due}}
  end

  defp clear_deadline(%{deadline: nil} = state), do: state

  defp clear_deadline(state) do
    Clock.cancel(state.clock, state.deadline.timer)
    %{state | deadline: nil}
  end

  defp trace(state, event) do
    if is_pid(state.opts[:trace]), do: send(state.opts[:trace], {:simulator_runner, event})
  end

  defp now(state), do: Clock.now_ms(state.clock)
end
