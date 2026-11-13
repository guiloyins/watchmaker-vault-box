defmodule Vault.Test.ReconciliationCases do
  @moduledoc false

  import ExUnit.Assertions

  alias Exqlite.Sqlite3
  alias Vault.{Games, GameStore, Repo}
  alias Vault.GameStore.{Operation, ReleaseDisposition, ReleaseObservation}
  alias Vault.Test.{FakeClock, ReleaseRecovery, TimingCases}

  def close_and_reset(fixture, command_id, kind) do
    original = TimingCases.fetch(fixture).session_id

    assert {:error, %{code: :unresolved_release}} =
             Games.host(fixture.host, fixture.game, "unresolved_reset", original, :reset)

    args = %{command_id: command_id, expected_session_id: original}

    assert {:ok, preparation} =
             Games.begin_recovery(fixture.host, fixture.game, "begin_recovery", args)

    assert {:ok, ^preparation} =
             Games.begin_recovery(fixture.host, fixture.game, "begin_recovery", args)

    assert preparation["recovery_generation"] == 1
    fixture = %{fixture | session_id: preparation["current_session_id"]}
    fixture = fresh_box(fixture)
    previous_boot = TimingCases.fetch(fixture).box_binding.boot_id

    assert {:ok, %{receipt: %{"status" => "ok"}}} =
             Games.recovery_step(fixture.host, fixture.game, :enter)

    record = inspect_recovery(fixture)
    expected_journal = if kind == :absent, do: "not_present_current_journal", else: "present"
    assert record["journal_observation"] == expected_journal
    assert record["intent"]["command_id"] == command_id
    assert record["seal"] == nil
    assert record["acknowledgement"] == nil

    assert {:ok, %{receipt: %{"status" => "rejected"}}} =
             Games.recovery_step(fixture.host, fixture.game, :seal)

    assert {:ok, %{receipt: %{"status" => "ok"}}} =
             Games.recovery_step(fixture.host, fixture.game, :reboot)

    TimingCases.wait(fn ->
      view = TimingCases.fetch(fixture)
      view.box.connected and view.box_binding.boot_id != previous_boot
    end)

    fixture = fresh_box(fixture)

    assert {:ok, %{receipt: %{"status" => "ok"}}} =
             Games.recovery_step(fixture.host, fixture.game, :seal)

    evidence = close_evidence(fixture)
    assert evidence.current_session_id == fixture.session_id
    assert evidence.recovery_id == preparation["recovery_id"]
    assert evidence.box_boot_id != previous_boot

    assert %ReleaseObservation{
             command_id: ^command_id,
             classification: "admitted",
             query_id: query_id
           } = Repo.get!(ReleaseObservation, evidence.observation_id)

    assert evidence.query_id == query_id

    assert {:error, %{code: :unresolved_release}} =
             Games.host(
               fixture.host,
               fixture.game,
               "still_unresolved_reset",
               fixture.session_id,
               :reset
             )

    receipt = close(fixture, command_id, evidence)

    assert Repo.get_by!(ReleaseDisposition, command_id: command_id).disposition_id ==
             receipt["disposition_id"]

    assert {:ok, %{receipt: %{"status" => "ok"}}} =
             Games.recovery_step(fixture.host, fixture.game, :acknowledge)

    assert inspect_recovery(fixture)["acknowledgement"]["disposition_id"] ==
             receipt["disposition_id"]

    assert {:ok, %{session_id: session}} =
             Games.host(fixture.host, fixture.game, "reset_closed", fixture.session_id, :reset)

    assert %{phase: :lobby, session_id: ^session, release: nil} = TimingCases.fetch(fixture)
    assert session != fixture.session_id
    %{fixture | session_id: session}
  end

  def replacement_and_reseal(root) do
    TimingCases.with_game(root, fn fixture ->
      fixture = fixture |> TimingCases.to_seal() |> TimingCases.presses(2100)
      TimingCases.advance(fixture, 2200)
      TimingCases.wait(fn -> TimingCases.fetch(fixture).box.release_status == :accepted end)
      command = TimingCases.fetch(fixture).box.command_id

      begin_args = %{command_id: command, expected_session_id: fixture.session_id}

      assert {:ok, first} =
               Games.begin_recovery(fixture.host, fixture.game, "first_begin", begin_args)

      fixture = %{fixture | session_id: first["current_session_id"]} |> fresh_box()

      assert {:ok, %{receipt: %{"status" => "ok"}}} =
               Games.recovery_step(fixture.host, fixture.game, :enter)

      boot = TimingCases.fetch(fixture).box_binding.boot_id

      assert {:ok, %{receipt: %{"status" => "ok"}}} =
               Games.recovery_step(fixture.host, fixture.game, :reboot)

      TimingCases.wait(fn ->
        TimingCases.fetch(fixture).box_binding.boot_id not in [nil, boot]
      end)

      fixture = fresh_box(fixture)

      assert {:ok, %{receipt: %{"status" => "ok"}}} =
               Games.recovery_step(fixture.host, fixture.game, :seal)

      old_evidence = close_evidence(fixture)

      args = %{
        command_id: command,
        expected_session_id: fixture.session_id,
        expected_recovery_id: "wrong"
      }

      assert {:error, %{code: :recovery_replaced}} =
               Games.replace_recovery(fixture.host, fixture.game, "replace_wrong", args)

      args = %{args | expected_recovery_id: first["recovery_id"]}

      assert {:ok, second} =
               Games.replace_recovery(fixture.host, fixture.game, "replace_right", args)

      assert second["recovery_generation"] == 2
      assert second["prior_recovery_id"] == first["recovery_id"]

      assert {:ok, ^first} =
               Games.begin_recovery(fixture.host, fixture.game, "first_begin", begin_args)

      fixture = %{fixture | session_id: second["current_session_id"]} |> fresh_box()
      stale_close(fixture, command, old_evidence)

      assert {:ok, %{receipt: %{"status" => "ok"}}} =
               Games.recovery_step(fixture.host, fixture.game, :replace)

      replacement_boot = TimingCases.fetch(fixture).box_binding.boot_id

      assert {:ok, %{receipt: %{"status" => "ok"}}} =
               Games.recovery_step(fixture.host, fixture.game, :reboot)

      TimingCases.wait(fn ->
        TimingCases.fetch(fixture).box_binding.boot_id not in [nil, replacement_boot]
      end)

      fixture = fresh_box(fixture)

      assert {:ok, %{receipt: %{"status" => "ok"}}} =
               Games.recovery_step(fixture.host, fixture.game, :seal)

      pre_restart_evidence = close_evidence(fixture)

      fixture = fixture |> ReleaseRecovery.restart_authority() |> fresh_box()
      view = TimingCases.fetch(fixture)
      assert view.release.preparation == second
      assert view.session_id != second["current_session_id"]
      assert view.release.close_evidence == nil

      assert {:ok, %{result: ^second, current: %{session_id: session, recovery_generation: 2}}} =
               Games.read_operation(fixture.host, fixture.game, "replace_right")

      assert session == view.session_id
      fixture = %{fixture | session_id: session}
      stale_close(fixture, command, pre_restart_evidence)

      assert inspect_recovery(fixture)["recovery_id"] == second["recovery_id"]

      assert {:ok, %{receipt: %{"status" => "ok"}}} =
               Games.recovery_step(fixture.host, fixture.game, :seal)

      resealed = close_evidence(fixture)
      assert resealed.current_session_id == session
      assert resealed.recovery_id == second["recovery_id"]
      assert resealed.seal_operation_id != pre_restart_evidence.seal_operation_id

      assert %{"closed_session_id" => ^session, "recovery_generation" => 2} =
               close(fixture, command, resealed)

      assert {:ok, %{receipt: %{"status" => "ok"}}} =
               Games.recovery_step(fixture.host, fixture.game, :acknowledge)

      assert {:ok,
              %{preparation: %{generation: 2}, disposition: %{disposition: "closed_no_replay"}}} =
               GameStore.load(fixture.game)

      assert {:ok, %{result: %{"closed_session_id" => ^session}}} =
               Games.read_operation(fixture.host, fixture.game, "close_recorded")
    end)
  end

  def administrative_write_boundaries(root) do
    TimingCases.with_game(root, fn fixture ->
      fixture = fixture |> TimingCases.to_seal() |> TimingCases.presses(2100)
      TimingCases.advance(fixture, 2200)
      TimingCases.wait(fn -> TimingCases.fetch(fixture).box.release_status == :accepted end)
      command = TimingCases.fetch(fixture).box.command_id
      begin_args = %{command_id: command, expected_session_id: fixture.session_id}

      assert {:ok, writer} = Sqlite3.open(Path.join(root, "vault.sqlite3"), mode: :readwrite)

      try do
        assert :ok =
                 Sqlite3.execute(writer, """
                 CREATE TRIGGER test_reject_preparation BEFORE INSERT ON recovery_preparations
                 BEGIN SELECT RAISE(ABORT, 'test recovery write failure'); END
                 """)

        try do
          assert {:error, %{code: :storage_error}} =
                   Games.begin_recovery(fixture.host, fixture.game, "retry_begin", begin_args)

          assert {:ok,
                  %{
                    preparation: nil,
                    command: %{dispatch_retired: false},
                    checkpoint: %{session_id: session}
                  }} = GameStore.load(fixture.game)

          assert session == fixture.session_id
          assert Repo.get(Operation, "retry_begin") == nil
        after
          assert :ok = Sqlite3.execute(writer, "DROP TRIGGER test_reject_preparation")
        end

        assert {:ok, preparation} =
                 Games.begin_recovery(fixture.host, fixture.game, "retry_begin", begin_args)

        fixture = %{fixture | session_id: preparation["current_session_id"]} |> fresh_box()

        assert {:ok, %{receipt: %{"status" => "ok"}}} =
                 Games.recovery_step(fixture.host, fixture.game, :enter)

        entry_boot = TimingCases.fetch(fixture).box_binding.boot_id

        assert {:ok, %{receipt: %{"status" => "ok"}}} =
                 Games.recovery_step(fixture.host, fixture.game, :reboot)

        TimingCases.wait(fn ->
          TimingCases.fetch(fixture).box_binding.boot_id not in [nil, entry_boot]
        end)

        fixture = fresh_box(fixture)
        evidence = seal(fixture)
        args = close_args(command, evidence)
        close_at_expiry(fixture, writer, args)

        assert {:ok, %{disposition: nil, command: %{dispatch_retired: true}}} =
                 GameStore.load(fixture.game)

        assert Repo.get(Operation, "lost_close") == nil
        assert_frozen(fixture)

        fixture = fresh_box(fixture)
        evidence = seal(fixture)
        args = close_args(command, evidence)
        fixture = lose_close_reply(fixture, args)

        assert {:ok, %{result: %{"disposition" => "closed_no_replay"} = committed}} =
                 Games.read_operation(fixture.host, fixture.game, "lost_close")

        assert {:ok, ^committed} =
                 Games.close_recovery(fixture.host, fixture.game, "lost_close", args)

        assert Repo.aggregate(ReleaseDisposition, :count) == 1
        assert_frozen(fixture)

        assert {:ok, %{receipt: %{"status" => "ok"}}} =
                 Games.recovery_step(fixture.host, fixture.game, :acknowledge)

        assert inspect_recovery(fixture)["acknowledgement"]["disposition_id"] ==
                 committed["disposition_id"]

        assert_frozen(fixture)
      after
        :ok = Sqlite3.close(writer)
      end
    end)
  end

  defp close_at_expiry(fixture, writer, args) do
    # The first transaction is the historical-receipt check. Acquire the
    # writer lock after that transaction rolls back its not-found read, then
    # expire the original evidence after Close enters the actual commit path.
    authority = fixture.authority
    handler = {:close_lookup_barrier, make_ref()}

    assert :ok =
             :telemetry.attach(
               handler,
               [:vault, :repo, :query],
               &__MODULE__.after_lookup/4,
               {self(), authority}
             )

    assert 1 = :erlang.trace(authority, true, [:call])
    assert 1 = :erlang.trace_pattern({GameStore, :commit, 2}, true, [:local])

    try do
      caller =
        Task.async(fn ->
          Games.close_recovery(fixture.host, fixture.game, "lost_close", args)
        end)

      assert_receive {:close_lookup_done, ^authority}, 1_000
      assert :ok = Sqlite3.execute(writer, "BEGIN IMMEDIATE")
      send(authority, :continue_close)

      assert_receive {:trace, ^authority, :call,
                      {GameStore, :commit, [%{request_id: "lost_close"}, _]}},
                     1_000

      due = FakeClock.now_ms(fixture.clock) + 400
      assert :ok = FakeClock.advance_to(fixture.clock, due)
      assert :ok = Sqlite3.execute(writer, "ROLLBACK")
      assert {:error, %{code: code}} = Task.await(caller, 1_000)
      assert code in [:evidence_stale, :not_authorized]
    after
      :telemetry.detach(handler)
      :erlang.trace_pattern({GameStore, :commit, 2}, false, [:local])
      :erlang.trace(authority, false, [:call])
      Sqlite3.execute(writer, "ROLLBACK")
    end
  end

  def after_lookup(_event, _measurements, %{query: "rollback"}, {test, authority})
      when authority == self() do
    unless Process.get(:close_lookup_finished) do
      Process.put(:close_lookup_finished, true)
      send(test, {:close_lookup_done, authority})

      receive do
        :continue_close -> :ok
      after
        2_000 -> raise "test did not release the Close lookup barrier"
      end
    end
  end

  def after_lookup(_event, _measurements, _metadata, _fixture), do: :ok

  defp lose_close_reply(fixture, args) do
    authority = fixture.authority
    handler = {:close_commit_barrier, make_ref()}

    assert :ok =
             :telemetry.attach(
               handler,
               [:vault, :repo, :query],
               &ReleaseRecovery.after_sql/4,
               {self(), authority}
             )

    try do
      caller =
        Task.async(fn ->
          Games.close_recovery(fixture.host, fixture.game, "lost_close", args)
        end)

      assert_receive {:sqlite_committed, ^authority}, 1_000
      fixture = ReleaseRecovery.restart_authority(fixture)
      assert {:error, %{code: :readback_required}} = Task.await(caller, 1_000)
      fresh_box(fixture)
    after
      :telemetry.detach(handler)
    end
  end

  defp assert_frozen(fixture) do
    assert {:ok,
            %{
              receipt: %{
                "status" => "ok",
                "data" => %{
                  "service_inhibited" => true,
                  "motion_frozen" => true,
                  "motor_active" => false,
                  "readiness" => %{"arm_id" => nil}
                }
              }
            }} = Games.recovery_step(fixture.host, fixture.game, :inspect)

    assert {:ok, %{receipt: %{"status" => "rejected"}}} =
             Games.exit_simulated(fixture.host, fixture.game)
  end

  defp seal(fixture) do
    assert {:ok, %{receipt: %{"status" => "ok"}}} =
             Games.recovery_step(fixture.host, fixture.game, :seal)

    close_evidence(fixture)
  end

  defp fresh_box(fixture) do
    TimingCases.wait(fn -> TimingCases.fetch(fixture).box.connected end)
    TimingCases.advance(fixture, FakeClock.now_ms(fixture.clock) + 100)

    # The box's response is asynchronous. The fake clock is fixed while waiting
    # and the internal binding state is read only to synchronize this step.
    TimingCases.wait(fn ->
      box = :sys.get_state(fixture.authority).box
      is_integer(box.lease_until_ms) and FakeClock.now_ms(fixture.clock) < box.lease_until_ms
    end)

    fixture
  end

  defp close_evidence(fixture) do
    TimingCases.wait(fn -> TimingCases.fetch(fixture).release.close_evidence != nil end)
    TimingCases.fetch(fixture).release.close_evidence
  end

  defp inspect_recovery(fixture) do
    assert {:ok, %{receipt: %{"status" => "ok", "data" => %{"active_local_record_id" => id}}}} =
             Games.recovery_step(fixture.host, fixture.game, :inspect)

    assert is_binary(id)

    assert {:ok, %{receipt: %{"status" => "ok", "data" => %{"record" => record}}}} =
             Games.service_operation(fixture.host, fixture.game, "inspect", %{
               "section" => "recovery",
               "local_record_id" => id
             })

    record
  end

  defp stale_close(fixture, command, evidence) do
    assert {:error, _} =
             Games.close_recovery(fixture.host, fixture.game, "stale_close", %{
               command_id: command,
               expected_recovery_id: evidence.recovery_id,
               evidence: evidence,
               reason: "Review recorded stopped modeled actuator"
             })
  end

  defp close(fixture, command, evidence) do
    args = close_args(command, evidence)

    assert {:ok, %{"disposition" => "closed_no_replay"} = receipt} =
             Games.close_recovery(fixture.host, fixture.game, "close_recorded", args)

    assert {:ok, ^receipt} =
             Games.close_recovery(fixture.host, fixture.game, "close_recorded", args)

    receipt
  end

  defp close_args(command, evidence) do
    %{
      command_id: command,
      expected_recovery_id: evidence.recovery_id,
      evidence: evidence,
      reason: "Review recorded stopped modeled actuator"
    }
  end
end
