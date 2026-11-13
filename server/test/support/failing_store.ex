defmodule Vault.Test.FailingStore do
  @moduledoc false

  import ExUnit.Assertions
  import Ecto.Query
  alias Exqlite.Sqlite3
  alias Vault.{Games, GameStore, Repo}
  alias Vault.GameStore.{Operation, ReleaseObservation}
  alias Vault.Test.TimingCases

  def lock_rejects_pause(root) do
    TimingCases.with_game(root, fn fixture ->
      before = stored(fixture)
      initial = TimingCases.fetch(fixture)
      assert initial.panels.a.maze.position == 12
      assert [[100]] = Repo.query!("PRAGMA busy_timeout").rows

      with_writer(root, "BEGIN IMMEDIATE", "ROLLBACK", fn ->
        start = System.monotonic_time(:millisecond)

        assert {:error, %{code: code}} =
                 Games.host(fixture.host, fixture.game, "lock_test", fixture.session_id, :pause)

        assert code in [:storage_error, :readback_required]

        elapsed = System.monotonic_time(:millisecond) - start
        assert elapsed >= 75 and elapsed < 400
        IO.puts("server SQLite lock error in #{elapsed} ms")
      end)

      assert_committed_unchanged(fixture, before)
      after_fault = TimingCases.fetch(fixture)
      assert after_fault.panels.a.maze.position == 12
      assert after_fault.panels.a.board_version == 0
      assert_storage_pause(after_fault)
    end)
  end

  def checkpoint_write_rejects_win(root) do
    TimingCases.with_game(root, fn fixture ->
      fixture = fixture |> TimingCases.to_seal() |> TimingCases.presses(2100)
      before = stored(fixture)
      assert TimingCases.fetch(fixture).panels.a.hold.active
      assert TimingCases.count_intents() == 0

      with_writer(
        root,
        """
        CREATE TRIGGER test_reject_checkpoint_update
        BEFORE UPDATE OF checkpoint_json ON games
        BEGIN
          SELECT RAISE(ABORT, 'injected test checkpoint write error');
        END
        """,
        "DROP TRIGGER test_reject_checkpoint_update",
        fn ->
          TimingCases.advance(fixture, 2200)
          assert_storage_pause(TimingCases.fetch(fixture))
          assert_committed_unchanged(fixture, before)
        end
      )

      assert %{phase: :seal, release: nil, panels: %{a: %{hold: %{active: false}}}} =
               TimingCases.fetch(fixture)

      assert {:ok, %{receipt: %{"data" => %{"motor_active" => false, "journal_count" => 0}}}} =
               Games.service_operation(fixture.host, fixture.game, "inspect", %{
                 "section" => "status"
               })
    end)
  end

  defp with_writer(root, begin_statement, end_statement, fun) do
    assert {:ok, writer} = Sqlite3.open(Path.join(root, "vault.sqlite3"), mode: :readwrite)

    try do
      assert :ok = Sqlite3.execute(writer, begin_statement)

      try do
        fun.()
      after
        assert :ok = Sqlite3.execute(writer, end_statement)
      end
    after
      :ok = Sqlite3.close(writer)
    end
  end

  defp stored(fixture) do
    assert {:ok, row} = GameStore.load(fixture.game)

    %{
      checkpoint: row.checkpoint,
      revision: row.game.checkpoint_revision,
      operations:
        Repo.aggregate(from(op in Operation, where: op.game_id == ^fixture.game), :count),
      observations: Repo.aggregate(ReleaseObservation, :count)
    }
  end

  defp assert_committed_unchanged(fixture, before) do
    assert stored(fixture) == before
    assert TimingCases.count_intents() == 0
  end

  defp assert_storage_pause(snapshot) do
    assert snapshot.paused
    assert :recovery in snapshot.pause_reasons
    assert Enum.any?(snapshot.diagnostics, &(&1.code == :storage_error))
    refute Enum.any?(snapshot.peers, & &1.held)
    refute snapshot.box.motor_active
    assert snapshot.release == nil
  end
end
