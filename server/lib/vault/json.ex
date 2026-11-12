defmodule Vault.JSON do
  @moduledoc """
  Bounded JSON decoding and deterministic encodings for Vault data.
  """

  import Bitwise, only: [band: 2, bor: 2, bsr: 2]
  alias Vault.JSON.Number

  @typep number_token :: {:json_number, binary()}
  @typep value(number) ::
           nil
           | boolean()
           | binary()
           | number
           | [value(number)]
           | %{binary() => value(number)}

  @type parsed :: value(number_token())

  @type limits :: %{
          required(:max_bytes) => non_neg_integer(),
          required(:max_depth) => non_neg_integer()
        }
  @type reason ::
          :size
          | :depth
          | :syntax
          | :utf8
          | :duplicate_key
          | :root_type
          | :shape
          | :number
          | :resource

  @doc "Decodes one JSON value within the caller's byte and container depth limits."
  @spec decode(binary(), limits()) :: {:ok, parsed()} | {:error, reason()}
  def decode(bytes, %{max_bytes: max_bytes, max_depth: max_depth})
      when is_binary(bytes) and is_integer(max_bytes) and max_bytes >= 0 and
             is_integer(max_depth) and max_depth >= 0 do
    if byte_size(bytes) <= max_bytes do
      with {:ok, numbers} <- preflight(bytes, max_depth, 0, []),
           :ok <- valid_utf8(bytes) do
        parse(bytes, numbers)
      end
    else
      {:error, :size}
    end
  end

  def decode(_, _), do: {:error, :shape}

  @doc "Decodes a JSON value and requires an object root."
  @spec decode_object(binary(), limits()) :: {:ok, map()} | {:error, reason()}
  def decode_object(bytes, limits) do
    case decode(bytes, limits) do
      {:ok, object} when is_map(object) -> {:ok, object}
      {:ok, _value} -> {:error, :root_type}
      {:error, _reason} = error -> error
    end
  end

  @doc "Encodes complete decoded content for exact retry comparison."
  @spec comparison(value(number_token() | integer()), non_neg_integer()) ::
          {:ok, binary()} | {:error, reason()}
  def comparison(value, max_bytes) when is_integer(max_bytes) and max_bytes >= 0 do
    # BEAM integer arithmetic keeps the bound exact for every caller limit.
    encode(fn ->
      {chunks, _remaining} = compare_value(value, {[], 8 * max_bytes + 64})
      Enum.reverse(chunks)
    end)
  end

  def comparison(_, _), do: {:error, :shape}

  @doc "Encodes structurally validated integer-only JSON for durable or request digests."
  @spec canonical(term()) :: {:ok, binary()} | {:error, reason()}
  def canonical(value), do: encode(fn -> canonical_value(value) end)

  defp preflight(<<>>, _limit, _depth, numbers), do: {:ok, Enum.reverse(numbers)}

  defp preflight(<<open, _rest::binary>>, limit, limit, _numbers) when open in [?{, ?[] do
    {:error, :depth}
  end

  defp preflight(<<open, rest::binary>>, limit, depth, numbers) when open in [?{, ?[] do
    preflight(rest, limit, depth + 1, numbers)
  end

  defp preflight(<<close, rest::binary>>, limit, depth, numbers) when close in [?}, ?]] do
    preflight(rest, limit, max(depth - 1, 0), numbers)
  end

  defp preflight(<<?", rest::binary>>, limit, depth, numbers) do
    preflight_string(rest, limit, depth, numbers)
  end

  defp preflight(<<first, _rest::binary>> = input, limit, depth, numbers)
       when first in ?0..?9 or first == ?- do
    {rest, length} = number_prefix(input, 0)
    preflight(rest, limit, depth, [binary_part(input, 0, length) | numbers])
  end

  defp preflight(<<_byte, rest::binary>>, limit, depth, numbers) do
    preflight(rest, limit, depth, numbers)
  end

  defp preflight_string(<<?\\, _escaped, rest::binary>>, limit, depth, numbers) do
    preflight_string(rest, limit, depth, numbers)
  end

  defp preflight_string(<<?", rest::binary>>, limit, depth, numbers) do
    preflight(rest, limit, depth, numbers)
  end

  defp preflight_string(<<_byte, rest::binary>>, limit, depth, numbers) do
    preflight_string(rest, limit, depth, numbers)
  end

  defp preflight_string(<<>>, limit, depth, numbers), do: preflight(<<>>, limit, depth, numbers)

  defp number_prefix(<<byte, rest::binary>>, length)
       when byte in ?0..?9 or byte in [?-, ?+, ?., ?e, ?E] do
    number_prefix(rest, length + 1)
  end

  defp number_prefix(rest, length), do: {rest, length}

  defp valid_utf8(bytes) do
    if String.valid?(bytes), do: :ok, else: {:error, :utf8}
  end

  defp parse(bytes, numbers) do
    decoders = %{
      object_start: fn {_parent, numbers} -> {%{}, numbers} end,
      object_push: &push_member/3,
      object_finish: &finish_container/2,
      array_start: fn {_parent, numbers} -> {[], numbers} end,
      array_push: &push_element/2,
      array_finish: fn {array, numbers}, parent ->
        finish_container({Enum.reverse(array), numbers}, parent)
      end,
      string: &Function.identity/1,
      integer: &{:json_number, &1},
      float: &{:json_number, &1},
      null: nil
    }

    case :json.decode(bytes, {:root, numbers}, decoders) do
      {value, {:root, remaining}, <<>>} ->
        case restore_number(value, remaining) do
          {value, []} -> {:ok, value}
          {_value, _remaining} -> {:error, :syntax}
        end

      {_value, _accumulator, _trailing} ->
        {:error, :syntax}
    end
  catch
    {__MODULE__, reason} -> {:error, reason}
    :error, {:invalid_byte, _byte} -> {:error, :syntax}
    :error, {:unexpected_sequence, _bytes} -> {:error, :syntax}
    :error, :unexpected_end -> {:error, :syntax}
    :error, :system_limit -> {:error, :resource}
  end

  defp push_member(key, value, {object, numbers}) do
    if Map.has_key?(object, key) do
      throw({__MODULE__, :duplicate_key})
    end

    {value, numbers} = restore_number(value, numbers)
    {Map.put(object, key, value), numbers}
  end

  defp push_element(value, {array, numbers}) do
    {value, numbers} = restore_number(value, numbers)
    {[value | array], numbers}
  end

  defp finish_container({value, numbers}, {parent, _parent_numbers}) do
    {value, {parent, numbers}}
  end

  # OTP rewrites some tokens before its numeric callbacks. The accumulator
  # carries the original number spans through object and array traversal.
  defp restore_number({:json_number, _otp_lexeme}, [original | numbers]) do
    {{:json_number, original}, numbers}
  end

  defp restore_number({:json_number, _otp_lexeme}, []), do: throw({__MODULE__, :syntax})
  defp restore_number(value, numbers), do: {value, numbers}

  defp encode(to_iodata) do
    {:ok, IO.iodata_to_binary(to_iodata.())}
  catch
    {__MODULE__, reason} -> {:error, reason}
    :error, :system_limit -> {:error, :resource}
  end

  defp compare_value(nil, output), do: append(output, "n")
  defp compare_value(true, output), do: append(output, "t")
  defp compare_value(false, output), do: append(output, "f")

  defp compare_value(string, output) when is_binary(string) do
    output = append(output, ["s", uleb128(byte_size(string)), string])

    case valid_utf8(string) do
      :ok -> output
      {:error, reason} -> throw({__MODULE__, reason})
    end
  end

  defp compare_value(value, output) when is_integer(value) or is_tuple(value) do
    case Number.comparison_parts(value) do
      {:ok, {sign, coefficient, exponent_sign, exponent}} ->
        append(output, [
          <<?d, sign>>,
          uleb128(byte_size(coefficient)),
          coefficient,
          <<exponent_sign>>,
          uleb128(byte_size(exponent)),
          exponent
        ])

      {:error, reason} ->
        throw({__MODULE__, reason})
    end
  end

  defp compare_value(array, {_chunks, remaining} = output) when is_list(array) do
    count = count_array(array, remaining, 0)
    output = append(output, ["a", uleb128(count)])
    Enum.reduce(array, output, &compare_value/2)
  end

  defp compare_value(object, {_chunks, remaining} = output)
       when is_map(object) and not is_struct(object) do
    count = map_size(object)

    # Each entry requires at least two key bytes and one value byte.
    if count * 3 > remaining do
      throw({__MODULE__, :resource})
    end

    output = append(output, ["o", uleb128(count)])

    Enum.reduce(sorted_members(object), output, fn
      {key, value}, output when is_binary(key) ->
        output = compare_value(key, output)
        compare_value(value, output)

      _entry, _output ->
        throw({__MODULE__, :shape})
    end)
  end

  defp compare_value(_value, _output), do: throw({__MODULE__, :shape})

  defp count_array([], _remaining, count), do: count
  defp count_array([_ | _], 0, _count), do: throw({__MODULE__, :resource})
  defp count_array([_ | tail], remaining, count), do: count_array(tail, remaining - 1, count + 1)
  defp count_array(_improper, _remaining, _count), do: throw({__MODULE__, :shape})

  defp append({chunks, remaining}, chunk) do
    size = :erlang.iolist_size(chunk)

    if size <= remaining do
      {[chunk | chunks], remaining - size}
    else
      throw({__MODULE__, :resource})
    end
  end

  defp uleb128(value) when value < 128, do: [value]
  defp uleb128(value), do: [bor(band(value, 127), 128) | uleb128(bsr(value, 7))]

  defp sorted_members(object), do: :lists.keysort(1, Map.to_list(object))

  defp canonical_value(nil), do: "null"
  defp canonical_value(true), do: "true"
  defp canonical_value(false), do: "false"
  defp canonical_value(value) when is_integer(value), do: Integer.to_string(value)
  defp canonical_value(value) when is_binary(value), do: canonical_string(value)

  defp canonical_value(array) when is_list(array) and length(array) >= 0 do
    [?[, Enum.map_intersperse(array, ?,, &canonical_value/1), ?]]
  end

  defp canonical_value(object) when is_map(object) and not is_struct(object) do
    members =
      object
      |> sorted_members()
      |> Enum.map_intersperse(?,, fn {key, value} ->
        if is_binary(key) and ascii?(key) do
          [canonical_string(key), ?:, canonical_value(value)]
        else
          throw({__MODULE__, :shape})
        end
      end)

    [?{, members, ?}]
  end

  defp canonical_value(_), do: throw({__MODULE__, :shape})

  defp ascii?(<<byte, rest::binary>>) when byte <= 127, do: ascii?(rest)
  defp ascii?(<<>>), do: true
  defp ascii?(_), do: false

  defp canonical_string(string) do
    case valid_utf8(string) do
      :ok -> [?", escape_string(string, string, 0, 0, []), ?"]
      {:error, reason} -> throw({__MODULE__, reason})
    end
  end

  defp escape_string(<<byte, rest::binary>>, original, offset, length, parts)
       when byte < 32 or byte in [?", ?\\] do
    plain = binary_part(original, offset, length)
    escape_string(rest, original, offset + length + 1, 0, [escaped(byte), plain | parts])
  end

  defp escape_string(<<_byte, rest::binary>>, original, offset, length, parts) do
    escape_string(rest, original, offset, length + 1, parts)
  end

  defp escape_string(<<>>, original, offset, length, parts) do
    Enum.reverse([binary_part(original, offset, length) | parts])
  end

  defp escaped(?"), do: "\\\""
  defp escaped(?\\), do: "\\\\"
  defp escaped(?\b), do: "\\b"
  defp escaped(?\t), do: "\\t"
  defp escaped(?\n), do: "\\n"
  defp escaped(?\f), do: "\\f"
  defp escaped(?\r), do: "\\r"
  defp escaped(control), do: ["\\u00", Base.encode16(<<control>>, case: :lower)]
end
