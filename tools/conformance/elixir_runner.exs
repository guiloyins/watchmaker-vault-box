alias Vault.Protocol

# Inputs are public, bounded conformance records supplied over stdin. Echo only
# fixed categories, normalized schema-known data and bounded comparison bytes.
initial_apps = Application.started_applications() |> Enum.map(&elem(&1, 0)) |> MapSet.new()

for app <- [:vault, :phoenix, :ecto_sql, :exqlite, :mint] do
  if MapSet.member?(initial_apps, app),
    do: raise("Unexpected runtime application in no-start runner")
end

IO.stream(:stdio, :line)
|> Enum.each(fn line ->
  [direction, encoded] = line |> String.trim_trailing("\n") |> String.split("\t", parts: 2)

  direction =
    case direction do
      "in" -> :device_to_server
      "out" -> :server_to_device
    end

  bytes = Base.decode64!(encoded)

  observation =
    case Protocol.decode(bytes, direction) do
      {:ok, %{message: message, comparison: comparison, original_json: ^bytes}} ->
        {:ok, reencoded} = Protocol.encode(message, direction)

        {:ok, %{message: ^message, original_json: ^reencoded}} =
          Protocol.decode(reencoded, direction)

        %{
          message: message,
          comparison: Base.encode64(comparison),
          encoded: Base.encode64(reencoded)
        }

      {:error, category} ->
        %{error: category}
    end

  IO.puts("VAULT_JSON " <> Jason.encode!(observation))
end)

final_apps = Application.started_applications() |> Enum.map(&elem(&1, 0)) |> MapSet.new()
if initial_apps != final_apps, do: raise("Conformance runner changed runtime application set")

if Enum.any?(Process.registered(), &String.starts_with?(Atom.to_string(&1), "Elixir.Vault")) do
  raise("Unexpected named Vault runtime resource")
end

IO.puts("VAULT_JSON_NO_START_OK")
