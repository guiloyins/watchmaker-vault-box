defmodule Vault.Simulator.Admission do
  @moduledoc false

  # Reserve slots before sending mail. The slot is held through the write
  # completion. Each slot is at most 4,128 encoded bytes (text + mask/header).
  defstruct [:pid, :generation, :slots, :fault_to, limit: 10]

  def new(pid, generation, fault_to, limit \\ 10),
    do: %__MODULE__{
      pid: pid,
      generation: generation,
      slots: :atomics.new(2, []),
      fault_to: fault_to,
      limit: limit
    }

  def offer(gate, event) do
    with :ok <- reserve(gate) do
      send(gate.pid, {:admitted, gate.generation, event})
      :ok
    end
  end

  def reserve(gate) do
    cond do
      :atomics.get(gate.slots, 2) != 0 -> {:error, :retired}
      not Process.alive?(gate.pid) -> {:error, :retired}
      true -> reserve(gate, :atomics.get(gate.slots, 1))
    end
  end

  defp reserve(gate, used) when used >= gate.limit do
    if :atomics.compare_exchange(gate.slots, 2, 0, 1) == :ok do
      send(gate.fault_to, {:admission_fault, gate.generation})
    end

    {:error, :overflow}
  end

  defp reserve(gate, used) do
    case :atomics.compare_exchange(gate.slots, 1, used, used + 1) do
      :ok -> :ok
      current -> reserve(gate, current)
    end
  end

  def release(gate), do: :atomics.sub(gate.slots, 1, 1)
  def retire(gate), do: :atomics.put(gate.slots, 2, 1)
  def used(gate), do: :atomics.get(gate.slots, 1)
end
