defmodule Mix.Tasks.Vault.Simulator.Stop do
  use Mix.Task

  @shortdoc "Inhibits the stopped local simulator for maintenance"

  @impl true
  def run(args) do
    Mix.Task.run("app.config")

    case OptionParser.parse(args,
           strict: [reason: :string, operator: :string, observation: :string]
         ) do
      {options, [], []} -> stop(options)
      _ -> usage()
    end
  end

  defp stop(options) do
    with reason when reason in ["maintenance", "lost_host_key"] <- options[:reason],
         operator when is_binary(operator) <- options[:operator],
         observation when is_binary(observation) <- options[:observation] do
      reason = if reason == "maintenance", do: :maintenance, else: :lost_host_key

      case Vault.Credentials.stop_simulator(reason, operator, observation) do
        {:ok, %{"status" => "ok"}} -> Mix.shell().info("Simulated motion stopped and inhibited.")
        {:ok, %{status: :applied}} -> Mix.shell().info("Simulated motion stopped and inhibited.")
        {:error, code} when is_atom(code) -> Mix.raise("Vault simulator stop failed (#{code})")
        _ -> Mix.raise("Vault simulator stop was rejected.")
      end
    else
      _ -> usage()
    end
  end

  defp usage do
    Mix.raise(
      "Usage: mix vault.simulator.stop --reason maintenance|lost_host_key --operator ID --observation TEXT"
    )
  end
end
