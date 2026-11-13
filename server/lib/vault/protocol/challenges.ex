defmodule Vault.Protocol.Challenges do
  @moduledoc "Bounded issue times and sample ordering for connection-local challenges."

  @limit 32
  @lease_ms 400
  @safe_integer 9_007_199_254_740_991

  @doc "Records a server-owned monotonic issue time and drops expired records."
  def issue(records, seq, issued_ms) do
    records =
      records
      |> Map.filter(fn {_seq, at} -> issued_ms < at + @lease_ms end)
      |> Map.put(seq, issued_ms)

    if map_size(records) > @limit do
      Map.delete(records, records |> Map.keys() |> Enum.min())
    else
      records
    end
  end

  @doc """
  Checks a sample against the last accepted sample and challenge.
  The connection owner still has to validate actor and game context before updating
  either accepted counter or liveness.
  """
  def check(records, heartbeat_seq, input_seq, last_heartbeat_seq, last_input_seq, now_ms) do
    cond do
      not valid_sequence?(input_seq) or input_seq <= last_input_seq ->
        {:error, :stale_sample}

      not valid_sequence?(heartbeat_seq) or heartbeat_seq < last_heartbeat_seq ->
        {:error, :stale_challenge}

      true ->
        deadline(records, heartbeat_seq, now_ms)
    end
  end

  @doc "Returns the fixed deadline of a currently live challenge."
  def deadline(records, heartbeat_seq, now_ms) do
    case Map.fetch(records, heartbeat_seq) do
      {:ok, at} when at <= now_ms and now_ms < at + @lease_ms ->
        {:ok, at + @lease_ms}

      _ ->
        {:error, :stale_challenge}
    end
  end

  defp valid_sequence?(sequence),
    do: is_integer(sequence) and sequence >= 1 and sequence <= @safe_integer
end
