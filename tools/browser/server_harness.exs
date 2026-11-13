# Test-process stdin only. This script is never loaded by a normal Vault server.
unless Mix.env() == :test and
         Application.fetch_env!(:vault, :box_mode) == :simulated and
         Application.fetch_env!(:vault, :bind) == {127, 0, 0, 1} and
         Application.fetch_env!(:vault, :test_root) == Application.fetch_env!(:vault, :data_dir) do
  raise "Vault browser harness requires a prepared isolated loopback test root"
end

import Ecto.Query
alias Vault.GameStore.ActuatorCommand
alias Vault.{Games, Repo}

{:ok, game_id} = Games.active_id()
IO.puts("VAULT_HARNESS " <> Jason.encode!(%{ready: true, game_id: game_id}))

for line <- IO.stream(:stdio, :line), byte_size(line) <= 256 do
  case String.trim(line) do
    "outcomes" ->
      outcomes =
        from(c in ActuatorCommand,
          where: c.game_id == ^game_id,
          select: map(c, [:command_id, :dispatch_claimed, :dispatch_retired])
        )
        |> Repo.all()

      IO.puts("VAULT_HARNESS " <> Jason.encode!(%{outcomes: outcomes}))

    "restart_game_session" ->
      {:ok, pid} = Games.ensure(game_id)
      reference = Process.monitor(pid)
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^reference, :process, ^pid, :killed} ->
          IO.puts("VAULT_HARNESS " <> Jason.encode!(%{restarted: true}))
      after
        2_000 -> IO.puts("VAULT_HARNESS " <> Jason.encode!(%{restarted: false}))
      end

    "stop" ->
      :ok = Application.stop(:vault)
      System.stop(0)

    _ ->
      IO.puts("VAULT_HARNESS " <> Jason.encode!(%{error: "unknown_command"}))
  end
end
