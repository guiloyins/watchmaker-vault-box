defmodule Vault.JSON.Number do
  @moduledoc """
  Converts exact JSON number tokens to bounded integers.
  """

  @safe_integer 9_007_199_254_740_991
  @safe_digits 16

  @doc "Returns the mathematical integer in the inclusive bounds."
  @spec integer(term(), integer(), integer()) :: {:ok, integer()} | {:error, :number}
  def integer({:json_number, lexeme}, min, max)
      when is_binary(lexeme) and is_integer(min) and is_integer(max) and
             min >= -@safe_integer and max <= @safe_integer and min <= max do
    with {:ok, {sign, coefficient, exponent_sign, exponent, adjustment}} <- parts(lexeme) do
      if coefficient == "0" do
        bounded_integer(0, "0", min, max)
      else
        cap = byte_size(lexeme) + @safe_digits
        scale = signed(exponent_sign, saturated_exponent(exponent, cap, 0)) + adjustment

        if scale >= 0 and byte_size(coefficient) + scale <= @safe_digits do
          digits = coefficient <> :binary.copy("0", scale)
          bounded_integer(sign, digits, min, max)
        else
          {:error, :number}
        end
      end
    end
  end

  def integer(_, _, _), do: {:error, :number}

  @doc false
  def comparison_parts({:json_number, lexeme}) when is_binary(lexeme) do
    with {:ok, {sign, coefficient, exponent_sign, exponent, adjustment}} <- parts(lexeme) do
      {exponent_sign, exponent} = adjust_exponent(exponent_sign, exponent, adjustment)
      {:ok, {sign, coefficient, exponent_sign, exponent}}
    end
  end

  def comparison_parts(integer) when is_integer(integer) do
    comparison_parts({:json_number, Integer.to_string(integer)})
  end

  def comparison_parts(_), do: {:error, :number}

  defp parts(lexeme) do
    {sign, unsigned} = split_sign(lexeme)

    {mantissa, exponent} =
      case :binary.split(unsigned, ["e", "E"]) do
        [mantissa] -> {mantissa, "0"}
        [mantissa, exponent] -> {mantissa, exponent}
      end

    with {:ok, {whole, fraction}} <- split_mantissa(mantissa),
         {:ok, {exponent_sign, exponent}} <- split_exponent(exponent) do
      coefficient = trim_leading_zeros(whole <> fraction)

      if coefficient == "" do
        {:ok, {0, "0", 0, "0", 0}}
      else
        length = byte_size(coefficient)
        significant = significant_length(coefficient, length)
        adjustment = length - significant - byte_size(fraction)

        {:ok,
         {sign, binary_part(coefficient, 0, significant), exponent_sign, exponent, adjustment}}
      end
    end
  end

  defp split_sign(<<?-, rest::binary>>), do: {1, rest}
  defp split_sign(unsigned), do: {0, unsigned}

  defp split_mantissa(mantissa) do
    case :binary.split(mantissa, ".") do
      [whole] ->
        if whole_digits?(whole), do: {:ok, {whole, ""}}, else: {:error, :number}

      [whole, fraction] ->
        if whole_digits?(whole) and fraction != "" and digits?(fraction) do
          {:ok, {whole, fraction}}
        else
          {:error, :number}
        end
    end
  end

  defp split_exponent(<<?+, rest::binary>>), do: exponent_magnitude(0, rest)

  defp split_exponent(exponent) do
    {sign, digits} = split_sign(exponent)
    exponent_magnitude(sign, digits)
  end

  defp exponent_magnitude(sign, digits) do
    if digits != "" and digits?(digits) do
      case trim_leading_zeros(digits) do
        "" -> {:ok, {0, "0"}}
        magnitude -> {:ok, {sign, magnitude}}
      end
    else
      {:error, :number}
    end
  end

  defp whole_digits?("0"), do: true
  defp whole_digits?(<<first, rest::binary>>) when first in ?1..?9, do: digits?(rest)
  defp whole_digits?(_), do: false

  defp digits?(<<digit, rest::binary>>) when digit in ?0..?9, do: digits?(rest)
  defp digits?(<<>>), do: true
  defp digits?(_), do: false

  defp trim_leading_zeros(<<?0, rest::binary>>), do: trim_leading_zeros(rest)
  defp trim_leading_zeros(digits), do: digits

  defp significant_length(digits, length) do
    if :binary.at(digits, length - 1) == ?0 do
      significant_length(digits, length - 1)
    else
      length
    end
  end

  # Once the exponent reaches the cap, even the largest coefficient adjustment
  # cannot bring it back into the range of a representable integral value.
  defp saturated_exponent(_, cap, value) when value >= cap, do: cap
  defp saturated_exponent(<<>>, _cap, value), do: value

  defp saturated_exponent(<<digit, rest::binary>>, cap, value) do
    saturated_exponent(rest, cap, 10 * value + digit - ?0)
  end

  defp bounded_integer(sign, digits, min, max) do
    {lower, upper} = if sign == 1, do: {-max, -min}, else: {min, max}

    if upper >= 0 and compare_magnitude(digits, Integer.to_string(upper)) != :gt and
         (lower <= 0 or compare_magnitude(digits, Integer.to_string(lower)) != :lt) do
      {:ok, signed(sign, String.to_integer(digits))}
    else
      {:error, :number}
    end
  end

  defp signed(0, magnitude), do: magnitude
  defp signed(1, magnitude), do: -magnitude

  defp adjust_exponent(sign, magnitude, 0), do: {sign, magnitude}

  defp adjust_exponent(sign, magnitude, adjustment) do
    adjustment_sign = if adjustment < 0, do: 1, else: 0
    adjustment_digits = Integer.to_string(abs(adjustment))

    if sign == adjustment_sign do
      {sign, combine_digits(magnitude, adjustment_digits, 1)}
    else
      case compare_magnitude(magnitude, adjustment_digits) do
        :eq -> {0, "0"}
        :gt -> {sign, combine_digits(magnitude, adjustment_digits, -1)}
        :lt -> {adjustment_sign, combine_digits(adjustment_digits, magnitude, -1)}
      end
    end
  end

  defp compare_magnitude(left, right) do
    cond do
      byte_size(left) < byte_size(right) -> :lt
      byte_size(left) > byte_size(right) -> :gt
      left < right -> :lt
      left > right -> :gt
      true -> :eq
    end
  end

  # Add or subtract the small adjustment one column at a time, carrying or
  # borrowing toward the most significant digit. The exponent stays in decimal.
  defp combine_digits(left, right, direction) do
    left_index = byte_size(left) - 1
    right_index = byte_size(right) - 1

    left
    |> combine_digits(left_index, right, right_index, direction, 0, [])
    |> :erlang.list_to_binary()
    |> trim_leading_zeros()
  end

  defp combine_digits(_left, -1, _right, -1, _direction, 0, digits), do: digits
  defp combine_digits(_left, -1, _right, -1, _direction, 1, digits), do: [?1 | digits]

  defp combine_digits(left, li, right, ri, direction, carry, digits) do
    total = decimal_at(left, li) + direction * decimal_at(right, ri) + carry
    digit = ?0 + Integer.mod(total, 10)

    combine_digits(
      left,
      max(li - 1, -1),
      right,
      max(ri - 1, -1),
      direction,
      Integer.floor_div(total, 10),
      [digit | digits]
    )
  end

  defp decimal_at(_digits, -1), do: 0
  defp decimal_at(digits, index), do: :binary.at(digits, index) - ?0
end
