defmodule Vault.Test.ReleaseRecovery do
  @moduledoc false

  import ExUnit.Assertions
  import Ecto.Query

  alias Exqlite.Sqlite3
  alias Vault.{Games, GameStore, JSON, Repo, SimulatedBox}
  alias Vault.GameStore.{ActuatorCommand, Operation, ReleaseObservation}
  alias Vault.SimulatedBox.Store
  alias Vault.Test.{FakeClock, TimingCases, ReconciliationCases}

  def committed_before_dispatch(root) do
    TimingCases.with_game(root, fn fixture ->
      fixture = fixture |> TimingCases.to_seal() |> TimingCases.presses(2100)
      assert TimingCases.count_intents() == 0
      runtime = Process.whereis(SimulatedBox)
      assert 1 = :erlang.trace(runtime, true, [:receive])
      handler = {:watch_win_commit, make_ref()}

      assert :ok =
               :telemetry.attach(handler, [:vault, :repo, :query], &__MODULE__.after_sql/4, {
                 self(),
                 fixture.authority
               })

      try do
        assert :ok = FakeClock.advance_to(fixture.clock, 2200)
        authority = fixture.authority
        assert_receive {:sqlite_committed, ^authority}, 1_000
        [command_id, original_session, original_round] = read_committed_win(root)
        assert original_session == fixture.session_id
        assert original_round == 1
        assert box_journal() == []

        fixture = restart_authority(fixture)
        assert Process.whereis(SimulatedBox) == runtime
        assert_recovered_intent(fixture, command_id, false, :uncertain, "unknown_command")
        assert box_journal() == []
        fixture = ReconciliationCases.close_and_reset(fixture, command_id, :absent)
        assert original_solve_guard(fixture, command_id, original_session) == :ok
        assert box_journal() == []
        refute_release_delivery(runtime, command_id)
        solve_next_round(fixture, command_id, original_session, original_round, :absent)
      after
        :telemetry.detach(handler)
      end
    end)
  end

  # Ecto calls the telemetry handler in the committing process after SQLite
  # returns success and before GameStore.commit returns to GameSession.
  def after_sql(_event, _measurements, %{query: "commit", result: {:ok, _}}, {test, authority})
      when authority == self() do
    send(test, {:sqlite_committed, authority})

    receive do
      :release_commit_barrier -> :ok
    after
      2_000 -> raise "test did not terminate the authority at the commit barrier"
    end
  end

  def after_sql(_event, _measurements, _metadata, _fixture), do: :ok

  def dispatched_before_ack(root) do
    TimingCases.with_game(root, fn fixture ->
      fixture = fixture |> TimingCases.to_seal() |> TimingCases.presses(2100)
      runtime = Process.whereis(SimulatedBox)
      old_boot = TimingCases.fetch(fixture).box_binding.boot_id
      assert :ok = Games.fault_simulated(fixture.host, fixture.game, :lost_ack)
      TimingCases.advance(fixture, 2200)

      assert %{
               phase: :solved,
               box: %{command_id: command_id, release_status: :pending}
             } = TimingCases.fetch(fixture)

      TimingCases.wait(fn ->
        match?(
          [%{"command_id" => ^command_id, "outcomes" => [%{"kind" => "accepted"}]}],
          box_journal()
        )
      end)

      assert TimingCases.fetch(fixture).box.release_status == :pending

      assert Repo.aggregate(
               from(o in ReleaseObservation, where: o.command_id == ^command_id),
               :count
             ) == 0

      assert %ActuatorCommand{
               dispatch_claimed: true,
               original_session_id: original_session,
               original_round_id: original_round
             } =
               Repo.get!(ActuatorCommand, command_id)

      # Kill the box runtime with a durable but unreported acceptance. No step
      # timer has fired at the fixed monotonic clock at this boundary.
      kill(runtime)

      TimingCases.wait(fn ->
        pid = Process.whereis(SimulatedBox)
        is_pid(pid) and pid != runtime
      end)

      assert Process.alive?(fixture.authority)

      TimingCases.advance(fixture, 2300)

      TimingCases.wait(fn ->
        TimingCases.fetch(fixture).box_binding.boot_id not in [nil, old_boot]
      end)

      assert_recovered_intent(fixture, command_id, true, :uncertain, "reboot_interrupted")
      assert TimingCases.fetch(fixture).session_id == original_session
      assert_interrupted_journal(command_id)

      replacement_box = Process.whereis(SimulatedBox)
      assert 1 = :erlang.trace(replacement_box, true, [:receive])
      fixture = restart_authority(fixture)
      assert Process.whereis(SimulatedBox) == replacement_box
      assert_recovered_intent(fixture, command_id, true, :uncertain, "reboot_interrupted")
      assert TimingCases.fetch(fixture).session_id != original_session
      assert_interrupted_journal(command_id)

      fixture = ReconciliationCases.close_and_reset(fixture, command_id, :interrupted)
      assert_interrupted_journal(command_id)
      refute_release_delivery(replacement_box, command_id)
      solve_next_round(fixture, command_id, original_session, original_round, :interrupted)
    end)
  end

  def restart_authority(fixture) do
    previous = fixture.authority
    kill(previous)

    TimingCases.wait(fn ->
      case Registry.lookup(Vault.Registry, fixture.game) do
        [{pid, _}] when pid != previous -> Process.alive?(pid)
        _ -> false
      end
    end)

    assert {:ok, authority} = Games.ensure(fixture.game)
    fixture = %{fixture | authority: authority}
    assert %{paused: true, assignments: %{a: nil, b: nil}} = TimingCases.fetch(fixture)
    fixture
  end

  def box_journal do
    paths = Application.fetch_env!(:vault, :deployment)

    assert {:ok, handle} =
             Store.open_existing(
               paths.simulator_database,
               paths.simulator_instance_id,
               paths.simulator_device_id
             )

    try do
      assert {:ok, snapshot} = Store.load(handle)
      snapshot["journal"]
    after
      :ok = Store.close(handle)
    end
  end

  defp kill(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000
  end

  defp read_committed_win(root) do
    assert {:ok, reader} = Sqlite3.open(Path.join(root, "vault.sqlite3"), mode: :readonly)

    try do
      assert {:ok, statement} =
               Sqlite3.prepare(reader, """
               SELECT command_id, original_session_id, original_round_id
               FROM actuator_commands WHERE dispatch_claimed = 0
               """)

      try do
        assert {:row, row} = Sqlite3.step(reader, statement)
        assert :done = Sqlite3.step(reader, statement)
        row
      after
        :ok = Sqlite3.release(reader, statement)
      end
    after
      :ok = Sqlite3.close(reader)
    end
  end

  defp assert_recovered_intent(fixture, command_id, claimed, status, failure) do
    TimingCases.wait(fn ->
      view = TimingCases.fetch(fixture)

      view.box.connected and
        Enum.any?(view.release.observations, fn observation ->
          observation.classification == "admitted" and observation.failure_code == failure
        end)
    end)

    assert %{
             phase: :solved,
             box: %{command_id: ^command_id, release_status: ^status, motor_active: false}
           } =
             TimingCases.fetch(fixture)

    assert {:ok,
            %{
              checkpoint: %{phase: :solved, release_command_id: ^command_id},
              command: %ActuatorCommand{command_id: ^command_id, dispatch_claimed: ^claimed}
            }} = GameStore.load(fixture.game)

    assert TimingCases.count_intents() == 1
  end

  defp assert_interrupted_journal(command_id) do
    assert [
             %{
               "command_id" => ^command_id,
               "outcomes" => [
                 %{"kind" => "accepted"},
                 %{"kind" => "uncertain", "failure_code" => "reboot_interrupted"}
               ]
             }
           ] = box_journal()
  end

  defp original_solve_guard(fixture, command_id, original_session) do
    command = Repo.get!(ActuatorCommand, command_id)
    assert command.dispatch_retired
    assert {:ok, binding} = GameStore.Codec.decode(command.dispatch_binding_json, 1024)

    assert {:error, :unresolved_release} =
             GameStore.claim_dispatch(fixture.game, command_id, binding)

    refute GameStore.dispatch_current?(fixture.game, command_id, binding)

    operation = Repo.one!(from(op in Operation, where: op.operation == "win"))
    request = %{"command_id" => command_id}

    assert {:ok, request_bytes} =
             JSON.canonical(%{
               "operation" => "win",
               "game_id" => fixture.game,
               "operator_credential_id" => nil,
               "expected_session_id" => original_session,
               "request" => request
             })

    assert operation.request_sha256 == :crypto.hash(:sha256, request_bytes)

    assert {:ok, %{status: :replayed, result: %{"data" => %{"command_id" => ^command_id}}}} =
             GameStore.retry_operation(%{
               operation: :win,
               game_id: fixture.game,
               operator_credential_id: nil,
               request_id: operation.request_id,
               expected_session_id: original_session,
               request: request
             })

    # The row-level unique key still protects the original solve after restart,
    # Begin recovery and Reset, even when another command identity is supplied.
    assert {:error, %Exqlite.Error{message: message}} =
             Repo.query(
               """
               INSERT INTO actuator_commands (
                 command_id, game_id, original_session_id, original_round_id, puzzle_revision,
                 intended_box_id, action, target, dispatch_binding_json, created_at_ms
               )
               SELECT 'duplicate_original_solve', game_id, original_session_id, original_round_id,
                 puzzle_revision, intended_box_id, action, target, dispatch_binding_json, created_at_ms
               FROM actuator_commands WHERE command_id = ?
               """,
               [command_id]
             )

    assert message =~ "UNIQUE constraint failed"
    assert TimingCases.count_intents() == 1
    :ok
  end

  defp refute_release_delivery(runtime, id) do
    refute_received {:trace, ^runtime, :receive,
                     {:"$gen_cast", {:owner, _, _, {:release, _, _, _, _, ^id, _}}}}
  end

  defp solve_next_round(fixture, old, original_session, original_round, kind) do
    start = FakeClock.now_ms(fixture.clock) + 100
    fixture = fixture |> TimingCases.start_next_round(start) |> TimingCases.to_seal()
    assert TimingCases.count_intents() == 1

    fixture = TimingCases.presses(fixture, start + 100, start + 2000, 1, 1)
    TimingCases.advance(fixture, start + 2100)
    TimingCases.wait(fn -> TimingCases.fetch(fixture).box.release_status == :accepted end)

    assert %{phase: :solved, box: %{command_id: new, motor_active: true}} =
             TimingCases.fetch(fixture)

    refute old == new
    runtime = Process.whereis(SimulatedBox)

    assert_receive {:trace, ^runtime, :receive,
                    {:"$gen_cast", {:owner, _, _, {:release, _, _, _, _, ^new, _}}}},
                   1_000

    refute_release_delivery(runtime, old)
    refute_release_delivery(runtime, new)
    assert TimingCases.count_intents() == 2

    assert %ActuatorCommand{
             original_session_id: ^original_session,
             original_round_id: ^original_round,
             dispatch_retired: true,
             dispatch_claimed: old_claimed
           } = Repo.get!(ActuatorCommand, old)

    assert old_claimed == (kind == :interrupted)

    assert %ActuatorCommand{dispatch_claimed: true, original_session_id: session} =
             Repo.get!(ActuatorCommand, new)

    refute session == original_session

    assert Repo.aggregate(from(op in Operation, where: op.operation == "win"), :count) == 2
    journal = box_journal()
    assert length(journal) == if(kind == :absent, do: 1, else: 2)
    assert Enum.count(journal, &(&1["command_id"] == new)) == 1
    assert Enum.count(journal, &(&1["command_id"] == old)) == if(kind == :absent, do: 0, else: 1)
  end
end
