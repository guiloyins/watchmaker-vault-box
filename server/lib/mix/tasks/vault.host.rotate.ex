defmodule Mix.Tasks.Vault.Host.Rotate do
  use Mix.Task

  @shortdoc "Activates a new generated host key during stopped maintenance"

  @impl true
  def run(args) do
    Mix.Task.run("app.config")

    case OptionParser.parse(args,
           strict: [
             output: :string,
             physical_stop_operation: :string,
             physical_stop_status: :string,
             confirm_physical_stopped: :boolean
           ]
         ) do
      {opts, [], []} ->
        case Enum.sort(opts) do
          [output: path] ->
            rotate(path, nil)

          [
            confirm_physical_stopped: true,
            output: path,
            physical_stop_operation: operation,
            physical_stop_status: status
          ] ->
            rotate(path, {operation, status, true})

          _ ->
            usage()
        end

      _ ->
        usage()
    end
  end

  defp rotate(path, attestation) do
    case Vault.Credentials.rotate_host(path, attestation) do
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

  defp usage do
    Mix.raise(
      "Usage: mix vault.host.rotate --output PATH " <>
        "[--physical-stop-operation PATH --physical-stop-status PATH --confirm-physical-stopped]"
    )
  end
end
