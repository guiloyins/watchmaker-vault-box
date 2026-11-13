defmodule Vault.Protocol.CommandWindow do
  @moduledoc "Connection-local history of the last 128 consumed discrete commands."

  @limit 128

  defstruct high_water: 0, entries: %{}

  def new, do: %__MODULE__{}

  def check(%__MODULE__{high_water: high_water}, seq, _comparison) when seq == high_water + 1,
    do: :next

  def check(%__MODULE__{high_water: high_water}, seq, _comparison) when seq > high_water + 1,
    do: {:gap, high_water + 1}

  def check(%__MODULE__{entries: entries}, seq, comparison) do
    case Map.fetch(entries, seq) do
      {:ok, {^comparison, result}} -> {:replay, result}
      {:ok, _entry} -> :conflict
      :error -> :expired
    end
  end

  @doc "Records the result of the expected command, including a domain rejection."
  def put(%__MODULE__{high_water: high_water, entries: entries} = window, seq, comparison, result)
      when seq == high_water + 1 and is_binary(comparison) do
    entries = entries |> Map.delete(seq - @limit) |> Map.put(seq, {comparison, result})
    %{window | high_water: seq, entries: entries}
  end
end
