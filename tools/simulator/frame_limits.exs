defmodule Vault.Simulator.FrameLimits do
  @moduledoc false

  # Only a partial header and numeric counters are retained here. Mint receives
  # a chunk only after every frame declaration in that chunk has been checked.
  defstruct header: <<>>, remaining: 0, fragmented: nil
  @limit 8_192

  def scan(state, data), do: consume(state, data)

  defp consume(state, <<>>), do: {:ok, state}

  defp consume(%{remaining: count} = state, data) when count > 0 do
    used = min(count, byte_size(data))
    <<_::binary-size(used), rest::binary>> = data
    consume(%{state | remaining: count - used}, rest)
  end

  defp consume(%{header: header} = state, <<byte, rest::binary>>) do
    header = <<header::binary, byte>>

    case header(header) do
      :more ->
        consume(%{state | header: header}, rest)

      {:ok, fin, opcode, length} ->
        with {:ok, fragmented} <- declaration(state.fragmented, fin, opcode, length) do
          consume(%{state | header: <<>>, remaining: length, fragmented: fragmented}, rest)
        end

      :invalid ->
        {:error, :invalid_frame}
    end
  end

  defp header(<<fin::1, 0::3, opcode::4, 0::1, length::7>>)
       when opcode in [0, 1, 8, 9, 10] and length < 126,
       do: {:ok, fin, opcode, length}

  defp header(<<fin::1, 0::3, opcode::4, 0::1, 126::7, length::16>>)
       when opcode in [0, 1] and length >= 126,
       do: {:ok, fin, opcode, length}

  # A minimally encoded 64-bit frame length is always above the receive cap.
  defp header(<<_fin::1, 0::3, opcode::4, 0::1, 127::7>>) when opcode in [0, 1],
    do: :invalid

  defp header(<<_fin::1, 0::3, opcode::4, 0::1, 126::7, rest::binary>>)
       when opcode in [0, 1] and byte_size(rest) < 2,
       do: :more

  defp header(<<_>>), do: :more
  defp header(_), do: :invalid

  defp declaration(fragmented, 1, opcode, length)
       when opcode in [8, 9, 10] and not (opcode == 8 and length == 1),
       do: {:ok, fragmented}

  defp declaration(nil, fin, 1, length) when length <= @limit,
    do: {:ok, if(fin == 0, do: length)}

  defp declaration(used, fin, 0, length) when is_integer(used) and used + length <= @limit,
    do: {:ok, if(fin == 0, do: used + length)}

  defp declaration(_, _, _, _), do: {:error, :invalid_frame}
end
