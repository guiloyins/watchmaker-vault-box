defmodule Mix.Tasks.Vault.Host.Rotate do
  use Mix.Task

  @shortdoc "Activates a new generated host key during stopped maintenance"

  @impl true
  def run(["--output", path]) do
    Mix.Task.run("app.config")

    case Vault.Credentials.rotate_host(path) do
      :ok ->
        Mix.shell().info("Host key replaced. Protected file: #{Path.expand(path)}")

      {:error, :readback_required} ->
        Mix.raise(
          "Host activation needs readback. Retain both files and run mix vault.host.status."
        )

      {:error, code} ->
        Mix.raise("Vault host replacement failed (#{code})")
    end
  end

  def run(_), do: Mix.raise("Usage: mix vault.host.rotate --output PATH")
end
