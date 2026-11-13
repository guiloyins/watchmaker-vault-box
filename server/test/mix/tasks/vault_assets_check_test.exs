defmodule Vault.AssetsCheckTest do
  use ExUnit.Case, async: true
  alias Mix.Tasks.Vault.Assets.Check

  test "metadata rejects server/private inputs and production maps" do
    root = Path.join(System.tmp_dir!(), "vault-assets-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "_build"))
    File.mkdir_p!(Path.join(root, "priv/static/assets"))
    on_exit(fn -> File.rm_rf!(root) end)

    write = fn inputs ->
      File.write!(
        Path.join(root, "_build/assets-meta.json"),
        Jason.encode!(%{
          "inputs" => Map.new(inputs, &{&1, %{}}),
          "outputs" => %{"../priv/static/assets/app.js" => %{}}
        })
      )
    end

    write.(["js/app.js", "../deps/phoenix/priv/static/phoenix.mjs"])
    assert :ok = Check.check(root, true)
    write.(["js/app.js", "../priv/puzzles/maze-v1.private.json"])
    assert {:error, _} = Check.check(root, false)
    write.(["../lib/vault/puzzle.ex"])
    assert {:error, _} = Check.check(root, false)
    write.(["js/app.js"])
    File.write!(Path.join(root, "priv/static/assets/app.js.map"), "{}")
    assert :ok = Check.check(root, false)
    assert {:error, _} = Check.check(root, true)
  end
end
