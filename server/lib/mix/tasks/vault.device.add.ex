defmodule Mix.Tasks.Vault.Device.Add do
  use Mix.Task

  @shortdoc "Provisions a device bearer key during stopped maintenance"

  @impl true
  def run(args) do
    Mix.Task.run("app.config")

    case OptionParser.parse(args,
           strict: [
             id: :string,
             class: :string,
             roles: :string,
             output: :string,
             rotate: :boolean
           ]
         ) do
      {options, [], []} -> provision(options)
      _ -> usage()
    end
  end

  defp provision(options) do
    with id when is_binary(id) <- options[:id],
         class when is_binary(class) <- options[:class],
         output when is_binary(output) <- options[:output] do
      roles = String.split(options[:roles] || "", ",", trim: true)

      case Vault.Credentials.provision_device(id, class, roles, output, rotate: options[:rotate]) do
        :ok -> Mix.shell().info("Device credential stored in #{Path.expand(output)}.")
        {:error, code} -> Mix.raise("Vault device provisioning failed (#{code})")
      end
    else
      _ -> usage()
    end
  end

  defp usage do
    Mix.raise(
      "Usage: mix vault.device.add --id ID --class controller|box --output PATH [--roles a,b] [--rotate]"
    )
  end
end
