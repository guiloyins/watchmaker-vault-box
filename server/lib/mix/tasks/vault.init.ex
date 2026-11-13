defmodule Mix.Tasks.Vault.Init do
  use Mix.Task

  @shortdoc "Initializes the guarded local simulated deployment"

  @impl true
  def run(args) do
    Mix.Task.run("app.config")

    case OptionParser.parse(args, strict: [output: :string]) do
      {options, [], []} ->
        case Vault.Credentials.init(options) do
          {:ok, %{credential_paths: paths}} ->
            Mix.shell().info("Initialized Vault. Protected credential files:")

            Enum.each([:host, :player_a, :player_b, :secret_key_base], fn kind ->
              Mix.shell().info("  " <> Map.fetch!(paths, kind))
            end)

          {:ok, _} ->
            Mix.shell().info("Existing Vault setup verified.")

          {:error, code} ->
            Mix.raise("Vault initialization failed (#{code})")
        end

      _ ->
        Mix.raise("Usage: mix vault.init [--output PATH]")
    end
  end
end
