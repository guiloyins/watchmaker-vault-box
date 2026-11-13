defmodule Mix.Tasks.Vault.Host.Status do
  use Mix.Task

  @shortdoc "Checks a protected key file against the current host credential"

  @impl true
  def run(["--file", path]) do
    Mix.Task.run("app.config")

    case Vault.Credentials.host_status(path) do
      {:ok, %{active?: active?, auth_epoch: epoch}} ->
        match_status = if active?, do: "active", else: "inactive"
        Mix.shell().info("Host key file is #{match_status} at authentication epoch #{epoch}.")

      {:error, code} ->
        Mix.raise("Vault host status failed (#{code})")
    end
  end

  def run(_), do: Mix.raise("Usage: mix vault.host.status --file PATH")
end
