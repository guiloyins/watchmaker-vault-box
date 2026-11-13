defmodule Vault.GameStoreTest do
  use ExUnit.Case, async: false

  alias Vault.{Credentials, GameStore, MaintenanceGuard, Repo, StorageFixture}

  alias Vault.GameStore.{
    ActuatorCommand,
    BrowserCredential,
    Checkpoint,
    Game,
    Operation,
    RecoveryPreparation,
    ReleaseDisposition,
    ReleaseObservation
  }

  setup do
    root = StorageFixture.temp_root()
    assert {"ok\n", 0} = StorageFixture.task(root, "prepare")
    StorageFixture.start_repo(root)
    {:ok, current} = GameStore.active()
    host = Repo.get_by!(BrowserCredential, kind: "host")
    %{root: root, current: current, host: host}
  end

  test "strict schema, checkpoint CAS and exact retry keep the original durable revision", %{
    current: current,
    host: host
  } do
    assert [[2]] = sql!("PRAGMA synchronous")
    assert [[1]] = sql!("PRAGMA foreign_keys")
    assert [[100]] = sql!("PRAGMA busy_timeout")
    assert [["wal"]] = sql!("PRAGMA journal_mode")
    assert length(sql!("PRAGMA foreign_key_list(assignments)")) == 3
    assert [] = sql!("PRAGMA foreign_key_check")

    checkpoint = %{current.checkpoint | phase: :maze, state_revision: 1}
    request = request(current, :start, host, checkpoint, "start_request")

    assert {:ok, %{status: :committed, checkpoint_revision: 1, result: result}} =
             GameStore.commit(request)

    assert {:ok, %{status: :replayed, checkpoint_revision: 1, result: ^result}} =
             GameStore.commit(request)

    assert {:error, :request_conflict} =
             GameStore.commit(%{request | request: %{"changed" => true}})

    assert {:error, :stale_session} = GameStore.commit(%{request | request_id: "stale_request"})
    assert nil == Repo.get(Operation, "stale_request")

    id = current.game.game_id
    assert %Game{checkpoint_revision: 1, checkpoint_json: persisted} = Repo.get(Game, id)
    assert {:ok, ^checkpoint} = Checkpoint.decode(persisted, id)
    assert {:error, _} = Checkpoint.encode(Map.put(checkpoint, :live_arm, "forbidden"))
    assert {:error, _} = Checkpoint.encode(%{checkpoint | paused: true})
    assert {:error, _} = sql("UPDATE games SET checkpoint_json = '{}' WHERE game_id = ?", [id])

    assert {:error, _} =
             sql(
               "UPDATE games SET game_id = 'changed', checkpoint_revision=2 WHERE game_id = ?",
               [id]
             )

    assert {:error, _} =
             sql("UPDATE game_operations SET result_json='{}' WHERE request_id='start_request'")

    assert {:error, _} = sql("UPDATE vault_metadata SET singleton=2")
    assert {:error, _} = sql("UPDATE devices SET allowed_roles_mask=1 WHERE transport='internal'")
  end

  test "writer-time authorization rejects a revoked browser before new writes and private replay",
       %{current: current, host: host, root: root} do
    checkpoint = %{current.checkpoint | phase: :maze, state_revision: 1}
    first = request(current, :start, host, checkpoint, "already_committed")
    assert {:ok, %{status: :committed}} = GameStore.commit(first)
    assert {:ok, current} = GameStore.load(current.game.game_id)
    paused = %{checkpoint | paused: true, pause_reasons: [:operator], state_revision: 2}
    second = request(current, :pause, host, paused, "not_committed")

    {:ok, locker} = Exqlite.Sqlite3.open(Path.join(root, "vault.sqlite3"), mode: :readwrite)
    assert :ok = Exqlite.Sqlite3.execute(locker, "BEGIN IMMEDIATE")
    authorized = :atomics.new(1, [])
    :atomics.put(authorized, 1, 1)
    dynamic_repo = Repo.get_dynamic_repo()
    parent = self()

    attempt =
      Task.async(fn ->
        Repo.put_dynamic_repo(dynamic_repo)
        send(parent, :admitted_before_wait)
        check = fn -> :atomics.get(authorized, 1) == 1 end
        {GameStore.commit(second, authorize: check), GameStore.retry_operation(first, check)}
      end)

    try do
      assert_receive :admitted_before_wait, 1_000
      :atomics.put(authorized, 1, 0)
    after
      assert :ok = Exqlite.Sqlite3.execute(locker, "ROLLBACK")
      :ok = Exqlite.Sqlite3.close(locker)
    end

    assert {{:error, :not_authorized}, {:error, :not_authorized}} = Task.await(attempt)
    assert nil == Repo.get(Operation, second.request_id)

    assert Repo.get!(Game, current.game.game_id).checkpoint_revision ==
             current.game.checkpoint_revision

    assert %Operation{} = Repo.get(Operation, first.request_id)
  end

  test "missing identity, incompatible SQL and invalid retained checkpoint fail closed", %{
    root: root,
    current: current
  } do
    manifest = Path.join(root, "deployment.json")
    assert {:ok, bytes} = MaintenanceGuard.read_protected(manifest, 2048)
    assert {:ok, deployment} = Vault.GameStore.Codec.decode(bytes, 2048)
    assert :ok = GameStore.verify_open(deployment["store_id"])
    assert {:error, :incompatible_store} = GameStore.verify_open("wrong")
    assert {:ok, _} = sql("DROP TRIGGER games_guard_delete")
    assert {:error, :incompatible_store} = GameStore.verify_open(deployment["store_id"])

    assert {:ok, _} =
             sql(
               "UPDATE games SET checkpoint_json='{}',checkpoint_revision=1 WHERE game_id = ?",
               [current.game.game_id]
             )

    assert {:error, :storage_error} = GameStore.active()
  end

  test "a committed solve has one immutable binding, exact observation history and serialized recovery",
       %{current: current, host: host, root: root} do
    {solved, binding} = solve(current, host)
    id = solved.game.game_id
    command = solved.command

    assert {:ok, :claimed} = GameStore.claim_dispatch(id, command.command_id, binding)
    assert GameStore.dispatch_current?(id, command.command_id, binding)

    assert {:error, :unresolved_release} =
             GameStore.claim_dispatch(id, command.command_id, binding)

    attrs = report_attrs(solved, command, 7, "accepted", false, nil)
    assert {:ok, %{status: :committed, observation: observation}} = GameStore.observe(attrs)

    assert {:ok, %{status: :replayed, observation: ^observation}} =
             GameStore.observe(%{attrs | observation_id: "different_receipt_id"})

    changed = report_attrs(solved, command, 7, "failed", false, nil)

    assert {:ok, %{observation: %{classification: "content_conflict"}}} =
             GameStore.observe(changed)

    assert Repo.aggregate(ReleaseObservation, :count) == 2
    assert Repo.get!(ActuatorCommand, command.command_id).history_revision == 2
    assert {:error, _} = sql("DELETE FROM release_observations")
    assert {:error, _} = sql("UPDATE actuator_commands SET dispatch_claimed=0")
    assert {:error, _} = sql("UPDATE actuator_commands SET original_round_id=2")

    {begin_request, begin_options} = prepare(solved, host, "begin_request", "recovery_1")

    assert {:ok, %{status: :committed, result: first_receipt}} =
             GameStore.commit(begin_request, begin_options)

    assert {:ok, current} = GameStore.load(id)
    refute GameStore.dispatch_current?(id, command.command_id, binding)
    assert current.command.dispatch_retired
    assert current.checkpoint.session_id != current.command.original_session_id

    {replacement, options} = prepare(current, host, "replace_request", "recovery_2")
    assert {:ok, %{status: :committed}} = GameStore.commit(replacement, options)

    assert {:ok, %{status: :replayed, result: ^first_receipt}} =
             GameStore.commit(begin_request, begin_options)

    assert {:ok, %{current: %{recovery_id: "recovery_2", recovery_generation: 2}}} =
             GameStore.read_operation(id, "begin_request", host.credential_id)

    assert {:ok, current} = GameStore.load(id)

    late_terminal = report_attrs(current, command, 8, "motion_complete", false, "query_current")
    assert {:ok, %{observation: observed}} = GameStore.observe(late_terminal)

    reset =
      request(
        current,
        :reset,
        host,
        Checkpoint.initial(id, "reset_before_close"),
        "blocked_reset"
      )

    assert {:error, :wrong_phase} = GameStore.commit(reset, qualify: fn -> true end)
    assert nil == Repo.get(Operation, "blocked_reset")
    assert {:ok, current} = GameStore.load(id)

    {close, close_options} = close(current, host, observed)
    {replace_again, replace_options} = prepare(current, host, "replace_racing", "recovery_3")
    dynamic_repo = Repo.get_dynamic_repo()

    attempt = fn attrs, options ->
      Task.async(fn ->
        Repo.put_dynamic_repo(dynamic_repo)
        GameStore.commit(attrs, options)
      end)
    end

    results =
      [
        attempt.(close, close_options),
        attempt.(replace_again, replace_options)
      ]
      |> Task.await_many(5_000)

    assert Enum.count(results, &match?({:ok, %{status: :committed}}, &1)) == 1

    assert Repo.aggregate(ReleaseDisposition, :count) +
             Repo.aggregate(RecoveryPreparation, :count) == 3

    assert Repo.aggregate(ReleaseObservation, :count) == 3
    assert Repo.aggregate(ActuatorCommand, :count) == 1
    assert {:error, _} = sql("DELETE FROM recovery_preparations")

    assert {:ok, manifest} =
             MaintenanceGuard.read_protected(Path.join(root, "deployment.json"), 2048)

    assert {:ok, %{"store_id" => store_id}} = Vault.GameStore.Codec.decode(manifest, 2048)
    assert :ok = GameStore.verify_open(store_id)
  end

  test "qualification is checked under the SQLite writer before any release row", %{
    current: current,
    host: host
  } do
    seal = seal_checkpoint(current, host)
    {args, opts, _} = win_request(seal)

    assert {:error, :not_ready} =
             GameStore.commit(args, Keyword.put(opts, :qualify, fn -> false end))

    assert Repo.aggregate(ActuatorCommand, :count) == 0
    assert Repo.get!(Game, seal.game.game_id).checkpoint_revision == seal.game.checkpoint_revision
  end

  for {reported, durable_status} <- [
        {"motion_complete", :motion_complete},
        {"accepted", :accepted}
      ] do
    @tag timeout: 30_000
    test "stopped lost-key replacement preserves the original #{reported} release and Reset rule",
         %{current: current, host: host, root: root} do
      {solved, binding} = solve(current, host)

      assert {:ok, :claimed} =
               GameStore.claim_dispatch(solved.game.game_id, solved.command.command_id, binding)

      attrs = report_attrs(solved, solved.command, 7, unquote(reported), false, nil)
      assert {:ok, %{observation: original}} = GameStore.observe(attrs)
      assert {:ok, before} = GameStore.load(solved.game.game_id)
      assert before.command.dispatch_claimed
      refute before.command.dispatch_retired

      assert GameStore.Records.release_summary(before.observations).status ==
               unquote(durable_status)

      assert :ok = Supervisor.stop(Repo.get_dynamic_repo())

      assert {"ok\n", 0} = StorageFixture.task(root, "stop")

      assert {"ok\n", 0} =
               StorageFixture.task(root, "rotate", [Path.join(root, "replacement.key")])

      StorageFixture.start_repo(root)
      assert {:ok, after_rotation} = GameStore.load(solved.game.game_id)
      assert after_rotation.checkpoint == before.checkpoint
      assert after_rotation.command == before.command
      assert after_rotation.observations == [original]
      assert after_rotation.preparation == nil
      assert after_rotation.disposition == nil

      old = after_rotation.checkpoint

      recovery = %{
        old
        | session_id: "restart_session",
          state_revision: 0,
          paused: true,
          pause_reasons: [:recovery]
      }

      assert {:ok, _} =
               GameStore.commit(request(after_rotation, :restart, nil, recovery, "restart"))

      refute GameStore.dispatch_current?(old.game_id, before.command.command_id, binding)

      assert {:error, :unresolved_release} =
               GameStore.claim_dispatch(old.game_id, before.command.command_id, binding)

      assert {:ok, reloaded} = GameStore.load(old.game_id)
      assert reloaded.checkpoint.paused
      assert reloaded.command.original_session_id == old.session_id
      assert reloaded.observations == [original]

      reset =
        request(reloaded, :reset, host, Checkpoint.initial(old.game_id, "reset"), "reset_request")

      if unquote(reported) == "motion_complete" do
        assert {:ok, _} = GameStore.commit(reset, qualify: fn -> true end)
        assert {:ok, %{checkpoint: %{phase: :lobby}, command: nil}} = GameStore.load(old.game_id)
      else
        assert {:error, :wrong_phase} = GameStore.commit(reset, qualify: fn -> true end)

        assert {:ok, %{checkpoint: %{phase: :solved}, command: %{command_id: "command"}}} =
                 GameStore.load(old.game_id)
      end

      assert Repo.aggregate(ActuatorCommand, :count) == 1
      assert Repo.aggregate(ReleaseObservation, :count) == 1
    end
  end

  defp solve(current, host) do
    seal = seal_checkpoint(current, host)
    {args, opts, binding} = win_request(seal)
    assert {:ok, %{status: :committed}} = GameStore.commit(args, opts)
    assert {:ok, %{status: :replayed}} = GameStore.commit(args, opts)

    assert {:ok, %{status: :replayed}} =
             GameStore.commit(%{args | request_id: "competing_win"}, opts)

    assert nil == Repo.get(Operation, "competing_win")
    assert {:ok, solved} = GameStore.load(current.game.game_id)
    {solved, binding}
  end

  defp seal_checkpoint(current, host) do
    lobby = current.checkpoint
    maze = %{lobby | phase: :maze, state_revision: 1}
    assert {:ok, _} = GameStore.commit(request(current, :start, host, maze, "start_request"))
    assert {:ok, current} = GameStore.load(lobby.game_id)

    seal = %{
      maze
      | phase: :seal,
        position: 3,
        board_version: 9,
        state_revision: 2,
        selected_runes: %{a: :star, b: :moon}
    }

    assert {:ok, _} =
             GameStore.commit(request(current, :checkpoint, nil, seal, "seal_checkpoint"))

    assert {:ok, current} = GameStore.load(lobby.game_id)
    current
  end

  defp win_request(current) do
    old = current.checkpoint

    binding = %{
      box_boot_id: "box_boot",
      connection_id: "connection",
      session_id: old.session_id,
      arm_id: "arm",
      heartbeat_seq: 1,
      binding_generation: 1
    }

    command = %{
      command_id: "command",
      game_id: old.game_id,
      original_session_id: old.session_id,
      original_round_id: old.round_id,
      puzzle_revision: old.puzzle_revision,
      intended_box_id: current.game.box_device_id,
      dispatch_binding: binding
    }

    won = %{old | phase: :solved, state_revision: 3, release_command_id: command.command_id}
    args = request(current, :win, nil, won, "win_request", %{command_id: command.command_id})
    {args, [command: command, qualify: fn -> true end], binding}
  end

  defp report_attrs(current, command, sequence, status, motor, query_id) do
    now = Credentials.audit_ms()
    current_session = current.checkpoint.session_id

    raw = %{
      "v" => 1,
      "type" => "box_status",
      "connection_id" => "connection",
      "box_boot_id" => "box_boot",
      "session_id" => current_session,
      "status_seq" => sequence,
      "command_id" => command.command_id,
      "command_session_id" => command.original_session_id,
      "release_status" => status,
      "motor_active" => motor,
      "latch_position" => "unknown",
      "position_basis" => "unverified",
      "readiness" => %{
        "arm_id" => nil,
        "armed_session_id" => nil,
        "calibration_valid" => false,
        "start_verified" => false
      },
      "failure_code" => if(status == "failed", do: "driver_fault"),
      "command_confirmation" => nil
    }

    {:ok, encoded} = Vault.JSON.canonical(raw)
    {:ok, comparison} = Vault.JSON.comparison(raw, 4096)

    %{
      observation_id: Credentials.id("obs_"),
      command_id: command.command_id,
      source_device_id: command.intended_box_id,
      box_boot_id: "box_boot",
      connection_id: "connection",
      current_session_id: current_session,
      status_seq: sequence,
      report_json: encoded,
      comparison: comparison,
      classification: "admitted",
      query_id: query_id,
      observed_at_ms: now
    }
  end

  defp prepare(current, host, request_id, id) do
    prior = current.preparation
    generation = if prior, do: prior.generation + 1, else: 1
    operation = if prior, do: :replace_recovery, else: :begin_recovery

    preparation = %{
      recovery_id: id,
      generation: generation,
      prior_recovery_id: prior && prior.recovery_id
    }

    next = %{
      current.checkpoint
      | session_id: "session_" <> id,
        state_revision: 0,
        paused: true,
        pause_reasons: [:recovery]
    }

    {request(current, operation, host, next, request_id, %{recovery_id: id}),
     [preparation: preparation, qualify: fn -> true end]}
  end

  defp close(current, host, observation) do
    evidence = %{
      local_record_id: "local",
      service_epoch: 2,
      seal_operation_id: "seal",
      recovery_id: current.preparation.recovery_id,
      recovery_generation: current.preparation.generation,
      box_boot_id: observation.box_boot_id,
      connection_id: observation.connection_id,
      current_session_id: observation.current_session_id,
      status_seq: observation.status_seq,
      observation_id: observation.observation_id,
      query_id: observation.query_id,
      operator_confirmed: true
    }

    proposed = %{
      disposition_id: "disposition",
      recovery_id: current.preparation.recovery_id,
      reason: "Observed stopped simulator",
      evidence: evidence,
      observation_id: observation.observation_id
    }

    {request(current, :close_recovery, host, nil, "close_request", %{
       disposition_id: "disposition"
     }), [disposition: proposed, qualify: fn -> true end]}
  end

  defp request(current, operation, host, checkpoint, id, extra \\ %{}) do
    result = Map.merge(%{request_id: id, operation: operation}, extra)

    %{
      game_id: current.game.game_id,
      expected_revision: current.game.checkpoint_revision,
      expected_session_id: current.checkpoint.session_id,
      request_id: id,
      operation: operation,
      operator_credential_id: host && host.credential_id,
      request: %{operation: operation},
      checkpoint: checkpoint,
      result: result
    }
  end

  defp sql!(statement), do: elem(sql(statement), 1).rows

  defp sql(statement, args \\ []),
    do: Ecto.Adapters.SQL.query(Repo.get_dynamic_repo(), statement, args, log: false)
end
