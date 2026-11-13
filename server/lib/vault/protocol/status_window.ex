defmodule Vault.Protocol.StatusWindow do
  @moduledoc "Connection-local history of the last 16 admitted status reports."

  @limit 16

  defstruct high_water: 0, entries: %{}, order: {[], []}

  def new, do: %__MODULE__{}

  def high_water(%__MODULE__{high_water: high_water}), do: high_water

  def check(%__MODULE__{high_water: high_water}, seq, _comparison) when seq > high_water,
    do: :next

  def check(%__MODULE__{entries: entries}, seq, comparison) do
    case Map.fetch(entries, seq) do
      {:ok, {^comparison, ack}} -> {:replay, ack}
      {:ok, _entry} -> :conflict
      :error -> :stale
    end
  end

  @doc "Records the acknowledgement of a newly processed status report."
  def put(
        %__MODULE__{high_water: high_water, entries: entries, order: order} = window,
        seq,
        comparison,
        ack
      )
      when seq > high_water and is_binary(comparison) do
    {entries, order} = evict(entries, order)

    %{
      window
      | high_water: seq,
        entries: Map.put(entries, seq, {comparison, ack}),
        order: :queue.in(seq, order)
    }
  end

  defp evict(entries, order) when map_size(entries) == @limit do
    {{:value, oldest}, order} = :queue.out(order)
    {Map.delete(entries, oldest), order}
  end

  defp evict(entries, order), do: {entries, order}
end
