defmodule Mix.Tasks.Vault.Assets.Clean do
  use Mix.Task
  @shortdoc "Remove only generated asset outputs before a deployment build"
  def run(_) do
    File.rm_rf!(Path.expand("priv/static/assets"))
    File.rm(Path.expand("priv/static/cache_manifest.json"))
    File.rm(Path.expand("_build/assets-meta.json"))
  end
end
