defmodule Vault.Test.FakeClock do
  @moduledoc "Manually advanced clock that delivers due messages in deadline and insertion order."

  use Agent
  @behaviour Vault.Clock

  def start_link(initial_ms) when is_integer(initial_ms) do
    Agent.start_link(fn -> %{now_ms: initial_ms, next_order: 0, timers: %{}} end)
  end

  def handle(pid), do: {__MODULE__, pid}

  @impl true
  def now_ms(pid), do: Agent.get(pid, & &1.now_ms)

  @impl true
  def schedule_at(pid, destination, message, due_at_ms) do
    reference = make_ref()

    Agent.update(pid, fn state ->
      if due_at_ms <= state.now_ms do
        send(destination, message)
        state
      else
        timer = {due_at_ms, state.next_order, destination, message}

        %{
          state
          | timers: Map.put(state.timers, reference, timer),
            next_order: state.next_order + 1
        }
      end
    end)

    reference
  end

  @impl true
  def cancel(pid, reference) do
    Agent.get_and_update(pid, fn state ->
      {timer, timers} = Map.pop(state.timers, reference)
      {timer != nil, %{state | timers: timers}}
    end)
  end

  def advance_to(pid, next_ms) when is_integer(next_ms) do
    Agent.get_and_update(pid, fn state ->
      if next_ms < state.now_ms do
        {{:error, :clock_would_go_backwards}, state}
      else
        {due, pending} =
          Enum.split_with(state.timers, fn {_ref, {at, _, _, _}} -> at <= next_ms end)

        due
        |> Enum.sort_by(fn {_ref, {at, order, _, _}} -> {at, order} end)
        |> Enum.each(fn {_ref, {_, _, destination, message}} -> send(destination, message) end)

        {:ok, %{state | now_ms: next_ms, timers: Map.new(pending)}}
      end
    end)
  end
end
