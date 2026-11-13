defmodule Mix.Tasks.Vault.Assets.Check do
  @moduledoc "Audits esbuild's actual source inputs and generated public files."
  use Mix.Task
  @shortdoc "Check generated asset privacy and production source-map exclusion"
  def run(args) do
    production = "--production" in args

    case check(File.cwd!(), production) do
      :ok -> Mix.shell().info("Asset inputs and generated outputs passed the privacy check.")
      {:error, _} -> Mix.raise("Asset privacy check failed")
    end
  end

  def check(root, production) do
    with {:ok, metadata} <- File.read(Path.join(root, "_build/assets-meta.json")),
         {:ok, %{"inputs" => inputs, "outputs" => outputs}} <- Jason.decode(metadata),
         true <- map_size(inputs) > 0,
         true <- Enum.all?(Map.keys(inputs), &allowed_input?(root, &1)),
         true <- Enum.all?(Map.keys(outputs), &allowed_output?(root, &1)),
         maps <- Path.wildcard(Path.join(root, "priv/static/assets/**/*.map")),
         true <- not production or maps == [],
         true <- not File.exists?(Path.join(root, "priv/static/assets/meta.json")) do
      :ok
    else
      _ -> {:error, :private_asset_input}
    end
  end

  defp allowed_input?(root, path) do
    absolute = Path.expand(path, Path.join(root, "assets"))

    allowed = [
      "assets",
      "deps/phoenix/priv/static",
      "deps/phoenix_live_view/priv/static",
      "deps/phoenix_html/priv/static"
    ]

    Enum.any?(allowed, &String.starts_with?(absolute, Path.join(root, &1) <> "/")) and
      not Enum.any?(
        ["private.json", "/test/", "/fixtures/", "/lib/", "/docs/", "/priv/puzzles/"],
        &String.contains?(absolute, &1)
      )
  end

  defp allowed_output?(root, path),
    do:
      String.starts_with?(
        Path.expand(path, Path.join(root, "assets")),
        Path.join(root, "priv/static/assets/")
      )
end
