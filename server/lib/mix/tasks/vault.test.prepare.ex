defmodule Mix.Tasks.Vault.Test.Prepare do
  use Mix.Task

  @shortdoc "Prepares a wrapper-owned isolated Vault test root"

  @impl true
  def run(args) do
    options =
      case OptionParser.parse(args, strict: [external_simulator: :boolean]) do
        {options, [], []} -> options
        _ -> Mix.raise("Usage: MIX_ENV=test mix vault.test.prepare [--external-simulator]")
      end

    if Mix.env() != :test, do: Mix.raise("Vault test preparation requires MIX_ENV=test.")
    Mix.Task.run("app.config")

    case Vault.Credentials.prepare_test(options) do
      {:ok, _} -> Mix.shell().info("Vault test stores prepared.")
      {:error, code} -> Mix.raise("Vault test preparation failed (#{code})")
    end
  end
end
