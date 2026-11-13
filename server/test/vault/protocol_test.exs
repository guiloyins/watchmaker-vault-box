defmodule Vault.ProtocolTest do
  use ExUnit.Case, async: true

  alias Vault.Protocol

  @fixtures Path.expand("../../../contracts/fixtures/protocol-examples.json", __DIR__)
  @device_types ~w(hello command heartbeat box_status)

  test "the production decoder and encoder handle all unchanged wire fixtures" do
    fixtures = @fixtures |> File.read!() |> Jason.decode!()
    assert length(fixtures["valid_examples"]) == 51
    assert length(fixtures["invalid_examples"]) == 15

    for %{"direction" => direction, "message" => fixture, "name" => name} <-
          fixtures["valid_examples"] do
      {direction, opposite} =
        case direction do
          "client_to_server" -> {:device_to_server, :server_to_device}
          "server_to_client" -> {:server_to_device, :device_to_server}
        end

      raw = Jason.encode!(fixture)

      assert {:ok, %{message: message, original_json: ^raw}} = Protocol.decode(raw, direction),
             name

      assert {:ok, encoded} = Protocol.encode(message, direction), name
      assert {:ok, %{message: ^message}} = Protocol.decode(encoded, direction), name
      assert {:error, :shape} = Protocol.decode(raw, opposite), name
      assert {:error, :shape} = Protocol.encode(message, opposite), name
    end

    for %{"message" => fixture, "name" => name} <- fixtures["invalid_examples"] do
      direction =
        if fixture["type"] in @device_types, do: :device_to_server, else: :server_to_device

      assert {:error, _category} = Protocol.decode(Jason.encode!(fixture), direction), name
      assert {:error, _category} = Protocol.encode(fixture, direction), name
    end
  end

  test "routes only the active branch and capability allowlists" do
    hello =
      ~S|{"v":1.0,"type":"hello","device_id":"cyd","boot_id":"boot",| <>
        ~S|"firmware_version":"💡\u0000","device_class":"controller","capabilities":| <>
        ~S|{"touch":true,"screen_width":24e1,"screen_height":320,"max_message_bytes":8192,"arm":true},| <>
        ~S|"allowed_roles":["d"],"x":{"🪜":1e999999}}|

    assert {:ok, %{message: message, original_json: ^hello, comparison: original}} =
             Protocol.decode(hello)

    assert message == %{
             "v" => 1,
             "type" => "hello",
             "device_id" => "cyd",
             "boot_id" => "boot",
             "firmware_version" => "💡\0",
             "device_class" => "controller",
             "capabilities" => %{
               "touch" => true,
               "screen_width" => 240,
               "screen_height" => 320,
               "max_message_bytes" => 8192
             }
           }

    assert {:ok, encoded} = Protocol.encode(message, :device_to_server)
    assert {:ok, %{message: ^message, comparison: without_extensions}} = Protocol.decode(encoded)
    refute original == without_extensions
    assert Jason.decode!(encoded) == message
  end

  test "keeps required nulls and refuses malformed output DTOs" do
    query = %{"type" => "box_query", "v" => 1, "connection_id" => "abc", "command_id" => nil}
    assert {:ok, bytes} = Protocol.encode(query)
    assert Jason.decode!(bytes) == query
    assert {:error, :shape} = Protocol.encode(Map.delete(query, "command_id"))
    assert {:error, :shape} = Protocol.encode(%{query | "command_id" => "identifier\n"})
    assert {:error, :number} = Protocol.encode(%{query | "v" => true})
    assert {:error, :number} = Protocol.encode(%{query | "v" => 1.0})
  end

  test "enforces the respective assembled-message byte and depth limits" do
    for {raw, direction, size} <- [
          {~S|{"v":1,"type":"heartbeat","connection_id":"c","heartbeat_seq":1,"input_seq":1,"input":null}|,
           :device_to_server, 4096},
          {~S|{"v":1,"type":"heartbeat_request","connection_id":"c","heartbeat_seq":1}|,
           :server_to_device, 8192}
        ] do
      padded = String.pad_trailing(raw, size)
      assert {:ok, %{original_json: ^padded}} = Protocol.decode(padded, direction)
      assert {:error, :size} = Protocol.decode(padded <> " ", direction)

      root = String.trim_trailing(raw, "}") <> ~s|,"ext":|
      assert {:ok, _} = Protocol.decode(root <> arrays(7) <> "}", direction)
      assert {:error, :depth} = Protocol.decode(root <> arrays(8) <> "}", direction)
    end
  end

  defp arrays(depth), do: :binary.copy("[", depth) <> "null" <> :binary.copy("]", depth)
end
