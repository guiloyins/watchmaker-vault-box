defmodule Vault.RecoveryTest do
  use ExUnit.Case, async: false

  alias Vault.StorageFixture

  @moduletag timeout: 30_000

  for {function, boundary} <- [
        {:committed_before_dispatch, "after commit and before dispatch"},
        {:dispatched_before_ack, "after dispatch and before acknowledgement"}
      ] do
    test "recover and solve a new round after crashing #{boundary}" do
      root = StorageFixture.temp_root()
      assert {"ok\n", 0} = StorageFixture.task(root, "prepare")
      function = unquote(function)

      source = """
      Vault.Test.ReleaseRecovery.#{function}(root)
      IO.puts("release recovery passed")
      """

      assert {"release recovery passed\n", 0} = StorageFixture.vm(root, source)
    end
  end
end
