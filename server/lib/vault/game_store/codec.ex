defmodule Vault.GameStore.Codec do
  @moduledoc false

  alias Vault.JSON
  alias Vault.JSON.Number

  @max 9_007_199_254_740_991
  def max_integer, do: @max

  def id?(value) when is_binary(value) and byte_size(value) in 1..64,
    do: Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, value)

  def id?(_), do: false
  def n?(value), do: is_integer(value) and value in 0..@max
  def p?(value), do: is_integer(value) and value in 1..@max
  def audit?(value), do: is_integer(value) and value >= 0 and value <= 9_223_372_036_854_775_807

  def encode(value, maximum, depth \\ 8) do
    with {:ok, bytes} <- JSON.canonical(normalize(value)),
         {:ok, _} <- JSON.decode(bytes, %{max_bytes: maximum, max_depth: depth}) do
      {:ok, bytes}
    end
  end

  def decode(bytes, maximum, depth \\ 8) do
    with {:ok, parsed} <- JSON.decode_object(bytes, %{max_bytes: maximum, max_depth: depth}) do
      integers(parsed)
    end
  end

  def normalize(nil), do: nil
  def normalize(value) when is_boolean(value), do: value
  def normalize(value) when is_atom(value), do: Atom.to_string(value)

  def normalize(value) when is_map(value) do
    Map.new(value, fn {key, member} -> {normalize(key), normalize(member)} end)
  end

  def normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)
  def normalize(value), do: value

  defp integers({:json_number, _} = value), do: Number.integer(value, -@max, @max)

  defp integers(map) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, result} ->
      case integers(value) do
        {:ok, integer} -> {:cont, {:ok, Map.put(result, key, integer)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp integers(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn value, {:ok, result} ->
      case integers(value) do
        {:ok, integer} -> {:cont, {:ok, [integer | result]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp integers(value), do: {:ok, value}
end
