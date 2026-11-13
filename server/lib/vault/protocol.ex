defmodule Vault.Protocol do
  @moduledoc "Version-one raw device message boundaries."

  alias Vault.{JSON, Protocol.V1}

  @device_types ~w(hello command heartbeat box_status)
  @server_types ~w(welcome command_result snapshot heartbeat_request heartbeat_ack box_arm
                   box_disarm box_command box_status_ack box_query box_feedback)

  @type direction :: :device_to_server | :server_to_device
  @type envelope :: %{message: map(), comparison: binary(), original_json: binary()}

  @spec decode(binary(), direction()) :: {:ok, envelope()} | {:error, JSON.reason()}
  def decode(bytes, direction \\ :device_to_server) do
    max_bytes = byte_limit(direction)

    with {:ok, parsed} <- JSON.decode_object(bytes, %{max_bytes: max_bytes, max_depth: 8}),
         :ok <- check_direction(parsed, direction),
         {:ok, message} <- V1.validate(parsed),
         {:ok, comparison} <- JSON.comparison(parsed, max_bytes) do
      {:ok, %{message: message, comparison: comparison, original_json: bytes}}
    end
  end

  @spec encode(map(), direction()) :: {:ok, binary()} | {:error, JSON.reason()}
  def encode(value, direction \\ :server_to_device) do
    with :ok <- check_direction(value, direction),
         {:ok, message} <- V1.validate(value) do
      bytes = :json.encode(message, &encode_value/2)

      if :erlang.iolist_size(bytes) <= byte_limit(direction) do
        {:ok, IO.iodata_to_binary(bytes)}
      else
        {:error, :size}
      end
    end
  end

  @spec byte_limit(direction()) :: pos_integer()
  def byte_limit(:device_to_server), do: 4_096
  def byte_limit(:server_to_device), do: 8_192

  defp check_direction(%{"type" => type}, :device_to_server) when type in @device_types,
    do: :ok

  defp check_direction(%{"type" => type}, :server_to_device) when type in @server_types,
    do: :ok

  defp check_direction(_, _), do: {:error, :shape}

  defp encode_value(nil, _encode), do: "null"
  defp encode_value(value, encode), do: :json.encode_value(value, encode)
end
