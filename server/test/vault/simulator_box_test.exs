defmodule Vault.SimulatorBoxTest do
  use ExUnit.Case, async: false

  @compile {:no_warn_undefined,
            [
              Vault.Simulator.Admission,
              Vault.Simulator.BoxRuntime,
              Vault.Simulator.Client,
              Vault.Simulator.Runner
            ]}

  alias Vault.SimulatedBox.Store
  alias Vault.Simulator.{Admission, BoxRuntime, Runner}
  alias Vault.Test.{BoxConformance, BoxStoreGate, FakeClock}
  alias Vault.Test.SimulatorFixture, as: F

  setup_all do
    F.load_tools()
    {:ok, _} = Application.ensure_all_started(:mint_web_socket)
    {:ok, _} = Application.ensure_all_started(:exqlite)
    :ok
  end

  setup do
    root = F.root()
    path = Path.join(root, "independent-box.sqlite3")
    :ok = Store.init_new(path, BoxConformance.instance(), BoxConformance.device())
    clock = start_supervised!({FakeClock, BoxConformance.now()})
    %{path: path, clock: clock, credentials_file: F.credentials(root)}
  end

  test "real Mint and isolated SQLite runtime complete one modeled stroke and retain query history across reboot",
       fixture do
    peer = F.peer("ws")
    box = start_box(fixture, [])
    {runner, boot} = connect_box(fixture, box, peer)
    prepare_wire(box, peer, boot)

    wire_challenge(peer, 1)

    assert {%{"heartbeat_seq" => 1, "type" => "heartbeat", "input" => nil}, _} =
             F.receive_message(peer)

    F.send_message(peer, release(boot, "release_once"))
    assert_receive {:box_trace, {:storage_started, {:commit, _, :accept}}}, 1_000
    assert_receive {:box_trace, {:storage_finished, _, {:ok, _, _}}}, 1_000

    accepted =
      assert_status(peer, %{
        "release_status" => "accepted",
        "motor_active" => true,
        "command_id" => "release_once",
        "command_session_id" => "original"
      })

    assert accepted["readiness"] == readiness(nil, nil, true, false)
    assert [entry] = load(fixture)["journal"]
    assert entry["command_id"] == "release_once"
    assert Enum.map(entry["outcomes"], & &1["kind"]) == ["accepted"]

    for ordinal <- 1..100 do
      due = BoxConformance.now() + ordinal * 10
      BoxConformance.step(fixture.clock, due, ordinal)

      if rem(ordinal, 10) == 0 and ordinal < 100 do
        seq = div(ordinal, 10) + 1
        wire_challenge(peer, seq)
        assert {%{"heartbeat_seq" => ^seq, "type" => "heartbeat"}, _} = F.receive_message(peer)
      end
    end

    assert_receive {:box_trace, {:deactivate, :motion_complete}}, 1_000
    assert_receive {:box_trace, {:storage_started, {:commit, _, :outcome}}}, 1_000
    assert_status(peer, %{"release_status" => "not_requested", "motor_active" => false})

    assert_status(peer, %{
      "release_status" => "motion_complete",
      "motor_active" => false,
      "command_id" => "release_once",
      "command_session_id" => "original"
    })

    F.send_message(peer, release(boot, "release_once"))
    assert_status(peer, %{"release_status" => "motion_complete", "motor_active" => false})
    BoxConformance.assert_no_steps()

    :ok = BoxRuntime.fault(box, :reboot)
    assert_receive {:simulator_runner, {:retired, 1, :box_unbound, _}}, 1_000
    stop_supervised!(runner)
    assert_receive {:external_box_boot, fresh_boot}, 1_000
    assert {:ok, ^fresh_boot} = BoxRuntime.boot_id(box)

    # Start a new transport owner for the same box and boot-independent store.
    peer = F.peer("ws")
    {_, rebooted} = connect_box(fixture, box, peer, "conn_2", "after_reboot", 2)
    refute rebooted == boot
    F.send_message(peer, query("release_once", "conn_2"))

    assert_status(peer, %{
      "box_boot_id" => rebooted,
      "command_id" => "release_once",
      "release_status" => "motion_complete",
      "command_session_id" => "original",
      "session_id" => "after_reboot",
      "motor_active" => false,
      "readiness" => readiness(nil, nil, false, false)
    })

    assert [entry] = load(fixture)["journal"]
    assert Enum.map(entry["outcomes"], & &1["kind"]) == ["accepted", "motion_complete"]
    BoxConformance.assert_no_steps()
  end

  test "lost external status acknowledgements replay exact bytes three times; feedback is cosmetic",
       fixture do
    peer = F.peer("ws")
    box = start_box(fixture, [])
    {_, boot} = connect_box(fixture, box, peer)

    F.send_message(peer, query("absent", "conn_1"))
    {report, bytes} = F.receive_message(peer)

    assert_report(report, %{
      "command_id" => "absent",
      "release_status" => "uncertain",
      "failure_code" => "unknown_command",
      "motor_active" => false
    })

    for retry <- 1..3 do
      :ok = FakeClock.advance_to(fixture.clock, BoxConformance.now() + retry * 500)
      assert {^report, ^bytes} = F.receive_message(peer)
    end

    :ok = FakeClock.advance_to(fixture.clock, BoxConformance.now() + 2_000)
    assert {:error, :timeout} = F.recv(peer, 90)

    feedback = %{
      "v" => 1,
      "type" => "box_feedback",
      "connection_id" => "conn_1",
      "box_boot_id" => boot,
      "session_id" => "original",
      "feedback_seq" => 2,
      "light_mode" => "success",
      "progress_percent" => 100,
      "sound" => "success",
      "ttl_ms" => 100
    }

    F.send_message(peer, feedback)

    assert_receive {:simulator_client, 1,
                    {:feedback, %{"feedback_seq" => 2, "sound" => "success"}}}

    F.send_message(peer, feedback)
    F.send_message(peer, %{feedback | "feedback_seq" => 1})
    assert_receive {:simulator_client, 1, {:feedback, :quiet}}, 200
    refute_receive {:simulator_client, 1, {:feedback, %{"sound" => "success"}}}, 20
    assert load(fixture)["journal"] == []
    BoxConformance.assert_no_steps()
  end

  test "live blocked transport outlasts 1500 ms; silence wins over a queued late challenge and stops before the outcome write",
       fixture do
    box = start_box(fixture, [])
    {owner, incoming, boot} = stub_bind(box, 1, "conn_1", "original")
    prepare_stub(box, incoming, boot)
    send_wire(incoming, F.challenge(1), BoxConformance.now())
    assert_stub_heartbeat(owner, 1)
    send_wire(incoming, release(boot, "interrupted"), BoxConformance.now())
    assert_stub_status(owner, %{"release_status" => "accepted", "motor_active" => true})

    # The live owner deliberately cannot take any status or heartbeat sends.
    # Advance the model clock independently, one scheduled step at a time.
    send(owner, :block_writes)
    assert_receive {:stub_blocked, ^owner}
    BoxConformance.step(fixture.clock, BoxConformance.now() + 10, 1)
    BoxConformance.step(fixture.clock, BoxConformance.now() + 1_499, 2)
    runtime = :sys.get_state(box).runtime
    :sys.suspend(runtime)
    send_wire(incoming, F.challenge(2), BoxConformance.now() + 1_100)
    :ok = FakeClock.advance_to(fixture.clock, BoxConformance.now() + 1_500)
    :sys.resume(runtime)

    assert_receive {:box_trace, {:deactivate, :connection_lost}}, 1_000
    assert_receive {:box_trace, {:storage_started, {:commit, _, :outcome}}}, 1_000
    assert_receive {:box_trace, {:storage_finished, _, {:ok, _, _}}}, 1_000
    :ok = FakeClock.advance_to(fixture.clock, BoxConformance.now() + 1_511)
    assert Process.alive?(owner)
    refute_receive {:stub_out, ^owner, _}, 10
    assert [entry] = load(fixture)["journal"]
    assert Enum.map(entry["outcomes"], & &1["kind"]) == ["accepted", "uncertain"]
    BoxConformance.assert_no_steps()

    Process.exit(owner, :kill)
    assert_eventually_unbound(box)
    {replacement, new_gate, ^boot} = stub_bind(box, 2, "conn_2", "replacement")

    assert {:error, :retired} =
             BoxRuntime.deliver(incoming, F.challenge(3), BoxConformance.now() + 1_511)

    send_wire(new_gate, query("interrupted", "conn_2"), BoxConformance.now() + 1_511)

    assert_stub_status(replacement, %{
      "release_status" => "uncertain",
      "failure_code" => "connection_lost",
      "motor_active" => false,
      "command_session_id" => "original"
    })

    BoxConformance.assert_no_steps()
  end

  test "a final step queued before watchdog expiry cannot complete after the absolute deadline",
       fixture do
    box = start_box(fixture, [])
    {owner, ingress, boot} = stub_bind(box, 1, "conn_1", "original")
    prepare_stub(box, ingress, boot)
    send_wire(ingress, F.challenge(1), BoxConformance.now())
    assert_stub_heartbeat(owner, 1)
    send_wire(ingress, release(boot, "queued_final_step"), BoxConformance.now())
    assert_stub_status(owner, %{"release_status" => "accepted", "motor_active" => true})
    send(owner, :block_writes)
    assert_receive {:stub_blocked, ^owner}

    for ordinal <- 1..99 do
      BoxConformance.step(fixture.clock, BoxConformance.now() + ordinal * 10, ordinal)
    end

    runtime = :sys.get_state(box).runtime
    :sys.suspend(runtime)
    :ok = FakeClock.advance_to(fixture.clock, BoxConformance.now() + 1_000)
    :ok = FakeClock.advance_to(fixture.clock, BoxConformance.now() + 1_500)
    :sys.resume(runtime)
    assert_receive {:box_trace, {:deactivate, :connection_lost}}, 1_000
    assert_receive {:box_trace, {:storage_started, {:commit, terminal, :outcome}}}, 1_000
    assert_receive {:box_trace, {:storage_finished, ^terminal, {:ok, _, _}}}, 1_000
    refute_receive {:box_trace, {:step, _, 100}}, 20
    refute_receive {:box_trace, {:deactivate, :motion_complete}}, 20
    assert [entry] = load(fixture)["journal"]
    assert Enum.map(entry["outcomes"], & &1["kind"]) == ["accepted", "uncertain"]
  end

  test "intent commit that returns after authority expired adopts history and starts zero steps",
       fixture do
    :yes = BoxStoreGate.register(fixture.path)
    box = start_box(fixture, store: BoxStoreGate)
    {owner, incoming, boot} = stub_bind(box, 1, "conn_1", "original")
    prepare_stub(box, incoming, boot)
    send_wire(incoming, F.challenge(1), BoxConformance.now())
    assert_stub_heartbeat(owner, 1)
    send_wire(incoming, release(boot, "delayed"), BoxConformance.now())
    assert_receive {:box_write_gate, worker, :before_commit}, 1_000
    send(worker, {:box_write_gate, self(), :commit})
    assert_receive {:box_write_gate, ^worker, :after_commit, {:ok, _, _}}, 1_000
    :ok = FakeClock.advance_to(fixture.clock, BoxConformance.now() + 1_500)
    send(worker, {:box_write_gate, self(), :deliver})

    assert_receive {:box_trace, {:storage_started, {:commit, outcome_id, :outcome}}}, 1_000
    assert_receive {:box_trace, {:storage_finished, ^outcome_id, {:ok, _, _}}}, 1_000

    await_stub_status(owner, %{
      "release_status" => "uncertain",
      "command_id" => "delayed",
      "motor_active" => false
    })

    assert [entry] = load(fixture)["journal"]
    assert Enum.map(entry["outcomes"], & &1["kind"]) == ["accepted", "uncertain"]
    BoxConformance.assert_no_steps()
  end

  test "terminated Mint owner and terminated box instance retain the same interrupted command in the independent database",
       fixture do
    box = start_box(fixture, [])
    {owner, incoming, boot} = stub_bind(box, 1, "conn_1", "original")
    prepare_stub(box, incoming, boot)
    send_wire(incoming, F.challenge(1), BoxConformance.now())
    assert_stub_heartbeat(owner, 1)
    send_wire(incoming, release(boot, "runtime_loss"), BoxConformance.now())
    assert_stub_status(owner, %{"release_status" => "accepted", "motor_active" => true})
    BoxConformance.step(fixture.clock, BoxConformance.now() + 10, 1)
    runtime = :sys.get_state(box).runtime
    monitor = Process.monitor(box)
    Process.exit(runtime, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^box, _}
    Process.exit(owner, :kill)

    reloaded = start_box(fixture, [])
    assert_receive {:box_trace, {:storage_started, {:commit, reconcile, :boot_reconcile}}}, 1_000
    assert_receive {:box_trace, {:storage_finished, ^reconcile, {:ok, _, _}}}, 1_000
    {new_owner, new_gate, new_boot} = stub_bind(reloaded, 1, "conn_2", "reloaded")
    refute new_boot == boot
    send_wire(new_gate, query("runtime_loss", "conn_2"), BoxConformance.now() + 10)

    assert_stub_status(new_owner, %{
      "release_status" => "uncertain",
      "command_id" => "runtime_loss",
      "failure_code" => "reboot_interrupted",
      "motor_active" => false,
      "command_session_id" => "original",
      "readiness" => readiness(nil, nil, false, false)
    })

    BoxConformance.assert_no_steps()
  end

  @recovery_boundaries ~w(recovery.enter recovery.seal recovery.attest_disposition recovery.attest_replacement service.prepare service.exit)

  for command <- @recovery_boundaries,
      fault <- [
        :rollback,
        :lost_before_commit,
        :lost_reply,
        :crash_before_commit,
        :crash_after_commit
      ] do
    test "#{command} preserves recovery across #{fault}", fixture do
      recovery_write_fault(fixture, unquote(command), unquote(fault))
    end
  end

  defp recovery_write_fault(fixture, command, fault) do
    box = start_box(fixture, store: BoxStoreGate)
    {owner, ingress, boot} = stub_bind(box, 1, "conn_1", "original")
    prepare_stub(box, ingress, boot)
    send_wire(ingress, F.challenge(1), BoxConformance.now())
    assert_stub_heartbeat(owner, 1)
    send_wire(ingress, release(boot, "retired_release"), BoxConformance.now())
    assert_stub_status(owner, %{"release_status" => "accepted", "motor_active" => true})
    BoxConformance.step(fixture.clock, BoxConformance.now() + 10, 1)

    Process.exit(owner, :kill)
    assert_receive {:box_trace, {:deactivate, :connection_lost}}, 1_000
    assert_receive {:box_trace, {:storage_started, {:commit, interrupted, :outcome}}}, 1_000
    assert_receive {:box_trace, {:storage_finished, ^interrupted, {:ok, _, _}}}, 1_000
    assert_eventually_unbound(box)

    ctx = recovery_boundary(box, command)
    before = load(fixture)
    request = recovery_request(before, ctx.boot, command, ctx.args)
    operation = request["operation_id"]
    :yes = BoxStoreGate.register_service(fixture.path, command)
    {request_pid, request_monitor} = submit_fault_request(box, request)
    assert_receive {:service_write_gate, worker, :before_commit, write_id, ^operation}, 1_000
    refute_receive {:local_result, ^request_pid, _}, 5
    assert load(fixture) == before

    expected =
      case fault do
        :rollback ->
          send(worker, {:box_write_gate, self(), :rollback})
          assert_receive {:local_result, ^request_pid, %{"code" => "storage_error"}}, 1_000
          assert load(fixture) == before
          before

        :lost_before_commit ->
          send(worker, {:box_write_gate, self(), :lose_before_commit})

          assert_receive {:local_result, ^request_pid,
                          %{"status" => "uncertain", "code" => "commit_uncertain"}},
                         1_000

          assert_receive {:box_trace, {:storage_readback, ^write_id, :not_committed}}, 1_000
          assert load(fixture) == before
          before

        :crash_before_commit ->
          before

        after_commit ->
          send(worker, {:box_write_gate, self(), :commit})
          assert_receive {:service_write_gate, ^worker, :after_commit, {:ok, _, _}}, 1_000
          refute_receive {:local_result, ^request_pid, _}, 5
          committed = load(fixture)
          assert committed["store_revision"] == before["store_revision"] + 1
          assert committed["last_operation_id"] == write_id
          assert_committed_boundary(committed, command, operation)

          if after_commit == :lost_reply do
            send(worker, {:box_write_gate, self(), :lose_reply})

            assert_receive {:local_result, ^request_pid,
                            %{"status" => "uncertain", "code" => "commit_uncertain"}},
                           1_000

            assert_receive {:box_trace, {:storage_readback, ^write_id, :committed}}, 1_000
          end

          committed
      end

    assert before["journal"] == expected["journal"]
    assert [entry] = expected["journal"]
    assert entry["command_id"] == "retired_release"
    assert Enum.map(entry["outcomes"], & &1["kind"]) == ["accepted", "uncertain"]
    refute_receive {:box_trace, {:step, _, _}}, 5

    if fault in [:crash_before_commit, :crash_after_commit] do
      crash_runtime(box, worker)
      assert_receive {:local_result, ^request_pid, :lost}, 1_000
    else
      assert :ok = BoxRuntime.shutdown(box)
    end

    assert_receive {:DOWN, ^request_monitor, :process, ^request_pid, :normal}, 1_000
    assert load(fixture) == expected

    fresh = start_box(fixture, [])
    {new_owner, ingress, fresh_boot} = stub_bind(fresh, 1, "conn_restart", "after_recovery_crash")
    refute fresh_boot == ctx.boot

    # Read the exact receipt and retry the original request after reload.
    # Stored receipts replay before boot/revision checks, with no new write.
    lookup = BoxRuntime.service(fresh, "operation.get", %{"operation_id" => operation})

    if fault in [:rollback, :lost_before_commit, :crash_before_commit] do
      assert %{"code" => "operation_unknown"} = lookup
      assert %{"code" => "stale_boot"} = BoxRuntime.request(fresh, request)
    else
      assert %{
               "status" => "ok",
               "data" => %{"receipt" => %{"operation_id" => ^operation, "command" => ^command}}
             } = lookup

      assert BoxRuntime.request(fresh, request) == lookup
    end

    assert load(fixture) == expected
    send_wire(ingress, F.challenge(1, "conn_restart"), BoxConformance.now() + 10)
    assert_stub_heartbeat(new_owner, 1)

    binding = %{
      "connection_id" => "conn_restart",
      "box_boot_id" => fresh_boot,
      "session_id" => "after_recovery_crash",
      "arm_id" => "fresh_arm"
    }

    send_wire(
      ingress,
      Map.merge(binding, %{"v" => 1, "type" => "box_arm"}),
      BoxConformance.now() + 10
    )

    assert_stub_status(new_owner, %{"readiness" => readiness(nil, nil, false, false)})
    send_wire(ingress, release(boot, "retired_release"), BoxConformance.now() + 10)

    duplicate =
      Map.merge(binding, %{
        "v" => 1,
        "type" => "box_command",
        "heartbeat_seq" => 1,
        "command_id" => "retired_release",
        "action" => "set_latch",
        "target" => "released"
      })

    send_wire(ingress, duplicate, BoxConformance.now() + 10)
    send_wire(ingress, query("retired_release", "conn_restart"), BoxConformance.now() + 10)

    assert_stub_status(new_owner, %{
      "command_id" => "retired_release",
      "command_session_id" => "original",
      "release_status" => "uncertain",
      "failure_code" => "connection_lost",
      "motor_active" => false
    })

    assert load(fixture) == expected
    BoxConformance.assert_no_steps()
  end

  defp submit_fault_request(box, request) do
    test = self()

    spawn_monitor(fn ->
      result =
        try do
          BoxRuntime.request(box, request)
        catch
          :exit, _ -> :lost
        end

      send(test, {:local_result, self(), result})
    end)
  end

  defp crash_runtime(box, worker) do
    runtime = :sys.get_state(box).runtime
    ref = Process.monitor(box)
    worker_ref = Process.monitor(worker)
    Process.exit(runtime, :kill)
    assert_receive {:DOWN, ^ref, :process, ^box, :killed}, 1_000
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}, 1_000
  end

  defp recovery_boundary(box, target) do
    {_, _, boot} = stub_bind(box, 2, "conn_2", "recovery_session")
    prep = BoxConformance.recovery_preparation("retired_release")
    current = BoxConformance.recovery_current()
    operator = BoxConformance.operator()
    enter = %{"preparation" => prep, "host_current" => current, "operator" => operator}

    if target == "recovery.enter" do
      %{boot: boot, args: enter}
    else
      entered = recovery_service!(box, "recovery.enter", enter)
      local = entered["decision"]["data"]["local_record_id"]
      epoch = entered["decision"]["data"]["service_epoch"]
      assert_eventually_unbound(box)

      stub_bind(box, 3, "conn_3", "recovery_session")
      recovery_service!(box, "reboot", %{"reason" => "recovery"})
      assert_receive {:external_box_boot, rebooted}, 1_000
      assert_eventually_unbound(box)
      {_, _, ^rebooted} = stub_bind(box, 4, "conn_4", "recovery_session")
      welcome = BoxConformance.binding(4, "recovery_session")
      binding = BoxRuntime.binding(box)

      seal = %{
        "local_record_id" => local,
        "recovery_id" => prep["recovery_id"],
        "recovery_generation" => 1,
        "binding" => binding,
        "host_current" => current,
        "operator" => operator
      }

      if target == "recovery.seal" do
        %{boot: rebooted, args: seal}
      else
        sealed = recovery_service!(box, "recovery.seal", seal)

        disposition =
          BoxConformance.disposition(
            prep,
            local,
            sealed["operation_id"],
            epoch,
            rebooted,
            welcome,
            1
          )

        attestation = %{
          "local_record_id" => local,
          "disposition" => disposition,
          "operator" => operator
        }

        recovery_after_seal(box, target, rebooted, prep, current, local, attestation)
      end
    end
  end

  defp recovery_after_seal(_box, "recovery.attest_disposition", boot, _, _, _, attestation),
    do: %{boot: boot, args: attestation}

  defp recovery_after_seal(_box, "recovery.attest_replacement", boot, prep, current, local, _) do
    replacement = %{
      prep
      | "prior_recovery_id" => prep["recovery_id"],
        "recovery_id" => "replacement_recovery",
        "recovery_generation" => 2,
        "current_session_id" => "replacement_session",
        "request_id" => "replace"
    }

    next = %{
      current
      | "session_id" => "replacement_session",
        "recovery_id" => "replacement_recovery",
        "recovery_generation" => 2
    }

    %{
      boot: boot,
      args: %{
        "local_record_id" => local,
        "preparation" => replacement,
        "host_current" => next,
        "operator" => BoxConformance.operator()
      }
    }
  end

  defp recovery_after_seal(box, target, boot, _, _, _, attestation) do
    recovery_service!(box, "recovery.attest_disposition", attestation)
    operator = BoxConformance.operator()

    prepare = %{
      "authorization" => "disposition",
      "authorization_id" => "disposition",
      "operator" => operator
    }

    if target == "service.prepare" do
      %{boot: boot, args: prepare}
    else
      recovery_service!(box, "service.prepare", prepare)

      recovery_service!(box, "reference.set", %{
        "calibration_revision" => 1,
        "reference" => "locked_zero",
        "method" => "manual_verified",
        "operator" => operator
      })

      recovery_service!(box, "position.confirm", %{
        "position" => "locked",
        "basis" => "manual_verified",
        "command_id" => nil,
        "operator" => operator
      })

      %{boot: boot, args: %{"binding" => BoxRuntime.binding(box)}}
    end
  end

  defp recovery_service!(box, command, args) do
    assert %{"status" => "ok", "data" => %{"receipt" => receipt}} =
             BoxRuntime.service(box, command, args)

    receipt
  end

  defp recovery_request(durable, boot, command, args) do
    revision = durable["service"]["service_revision"]

    seq =
      (revision + 1) |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(16, "0")

    operation = "svc_" <> seq <> "_0123456789abcdef0123456789abcdef"

    %{
      "sv" => 1,
      "type" => "request",
      "request_id" => "fault_request",
      "device_id" => BoxConformance.device(),
      "box_boot_id" => boot,
      "operation_id" => operation,
      "expected_revision" => revision,
      "command" => command,
      "args" => args
    }
  end

  defp assert_committed_boundary(document, command, operation) do
    service = document["service"]
    [record] = document["reconciliations"]

    case command do
      "recovery.enter" ->
        assert %{"service_inhibited" => true, "active_local_record_id" => ^operation} = service

        assert %{
                 "local_record_id" => ^operation,
                 "observed_outcome" => "uncertain",
                 "seal" => nil
               } = record

      "recovery.seal" ->
        assert %{"service_inhibited" => true, "motion_frozen" => true} = service
        assert %{"seal" => %{"operation_id" => ^operation}, "acknowledgement" => nil} = record

      "recovery.attest_disposition" ->
        assert %{"service_inhibited" => true, "motion_frozen" => true} = service

        assert %{
                 "acknowledgement" => %{
                   "operation_id" => ^operation,
                   "disposition_id" => "disposition"
                 }
               } = record

      "recovery.attest_replacement" ->
        assert %{"service_inhibited" => true, "motion_frozen" => false} = service

        assert %{
                 "recovery_generation" => 2,
                 "seal" => nil,
                 "replacement" => %{
                   "operation_id" => ^operation,
                   "prior_recovery_generation" => 1
                 }
               } = record

      "service.prepare" ->
        assert %{
                 "service_inhibited" => true,
                 "motion_frozen" => false,
                 "preparation_operation_id" => ^operation
               } = service

        assert %{"acknowledgement" => %{"disposition_id" => "disposition"}} = record

      "service.exit" ->
        assert %{
                 "service_inhibited" => false,
                 "motion_frozen" => false,
                 "exit_operation_id" => ^operation
               } = service

        assert %{"acknowledgement" => %{"disposition_id" => "disposition"}} = record
    end
  end

  defp connect_box(fixture, box, peer, conn \\ "conn_1", session \\ "original", generation \\ 1) do
    id = make_ref()
    # Runner generations are monotonic within a CLI session. Reattach the
    # controlled peer with a test driver that preserves the same sequence.
    opts = [
      uri: peer.uri,
      credentials_file: fixture.credentials_file,
      device_id: BoxConformance.device(),
      box: box,
      box_clock: FakeClock.handle(fixture.clock),
      client_trace: self(),
      trace: self(),
      reconnect: false,
      initial_generation: generation - 1
    ]

    start_supervised!({Runner, opts}, id: id)

    assert {%{"type" => "hello", "boot_id" => boot, "device_class" => "box"}, _} =
             F.receive_message(peer)

    :ok = F.send_message(peer, box_welcome(conn, session))
    assert_receive {:simulator_client, ^generation, {:welcome, _, _}}, 1_000
    assert_status(peer, %{"release_status" => "not_requested", "motor_active" => false})
    {id, boot}
  end

  defp stub_bind(box, generation, conn, session) do
    test = self()
    {:ok, boot} = BoxRuntime.boot_id(box)

    owner =
      spawn(fn ->
        outgoing = Admission.new(self(), generation, test)
        {:ok, ingress} = BoxRuntime.bind(box, outgoing, boot, box_welcome(conn, session))
        send(test, {:stub_ready, self(), ingress})
        stub_loop(test, outgoing)
      end)

    on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)
    assert_receive {:stub_ready, ^owner, incoming}, 1_000
    assert_stub_status(owner, %{"release_status" => "not_requested", "motor_active" => false})
    {owner, incoming, boot}
  end

  defp stub_loop(test, gate) do
    receive do
      {:admitted, generation, item} when generation == gate.generation ->
        Admission.release(gate)
        send(test, {:stub_out, self(), item})
        stub_loop(test, gate)

      :block_writes ->
        send(test, {:stub_blocked, self()})

        receive do
          :release -> stub_loop(test, gate)
        end

      {:box_unbound, _} ->
        :ok
    end
  end

  defp prepare_wire(box, peer, boot) do
    assert %{"status" => "ok"} = BoxRuntime.prepare(box)
    assert_status(peer, %{"readiness" => readiness(nil, nil, true, false)})
    assert_status(peer, %{"readiness" => readiness(nil, nil, true, true)})
    F.send_message(peer, control(boot, "box_arm"))
    assert_status(peer, %{"readiness" => readiness(nil, nil, true, true)})

    assert %{"status" => "ok"} =
             BoxRuntime.service(box, "service.exit", %{"binding" => BoxRuntime.binding(box)})

    assert_status(peer, %{"readiness" => readiness(nil, nil, true, true)})
    F.send_message(peer, control(boot, "box_arm"))
    assert_status(peer, %{"readiness" => readiness("arm_first", "original", true, true)})
  end

  defp prepare_stub(box, incoming, boot) do
    %{pid: owner} = :sys.get_state(box).client
    assert %{"status" => "ok"} = BoxRuntime.prepare(box)
    assert_stub_status(owner, %{"readiness" => readiness(nil, nil, true, false)})
    assert_stub_status(owner, %{"readiness" => readiness(nil, nil, true, true)})

    assert %{"status" => "ok"} =
             BoxRuntime.service(box, "service.exit", %{"binding" => BoxRuntime.binding(box)})

    assert_stub_status(owner, %{"readiness" => readiness(nil, nil, true, true)})
    send_wire(incoming, control(boot, "box_arm"), BoxConformance.now())
    assert_stub_status(owner, %{"readiness" => readiness("arm_first", "original", true, true)})
  end

  defp box_welcome(conn, session) do
    F.welcome(%{
      "connection_id" => conn,
      "session_id" => session,
      "required_roles" => [],
      "allowed_roles" => []
    })
  end

  defp control(boot, type) do
    %{
      "v" => 1,
      "type" => type,
      "connection_id" => "conn_1",
      "session_id" => "original",
      "box_boot_id" => boot,
      "arm_id" => "arm_first"
    }
  end

  defp release(boot, command) do
    Map.merge(control(boot, "box_command"), %{
      "heartbeat_seq" => 1,
      "command_id" => command,
      "action" => "set_latch",
      "target" => "released"
    })
  end

  defp query(command, conn) do
    %{"v" => 1, "type" => "box_query", "connection_id" => conn, "command_id" => command}
  end

  defp readiness(arm, session, calibration, start) do
    %{
      "arm_id" => arm,
      "armed_session_id" => session,
      "calibration_valid" => calibration,
      "start_verified" => start
    }
  end

  defp wire_challenge(peer, seq), do: F.send_message(peer, F.challenge(seq))

  defp send_wire(gate, message, at), do: assert(:ok == BoxRuntime.deliver(gate, message, at))

  defp assert_stub_heartbeat(owner, seq) do
    assert_receive {:stub_out, ^owner, {:box_heartbeat, ^seq, _, _}}, 1_000
  end

  defp assert_stub_status(owner, expected) do
    assert_receive {:stub_out, ^owner, {:box_status, encoded}}, 1_000
    assert {:ok, %{message: msg}} = Vault.Protocol.decode(encoded, :device_to_server)
    assert_report(msg, expected)
    msg
  end

  defp await_stub_status(owner, expected, remaining \\ 16)
  defp await_stub_status(_, _, 0), do: flunk("expected terminal report was not published")

  defp await_stub_status(owner, expected, remaining) do
    assert_receive {:stub_out, ^owner, {:box_status, encoded}}, 1_000
    assert {:ok, %{message: msg}} = Vault.Protocol.decode(encoded, :device_to_server)

    if Map.take(msg, Map.keys(expected)) == expected,
      do: assert_report(msg, expected),
      else: await_stub_status(owner, expected, remaining - 1)
  end

  defp assert_status(peer, expected) do
    {msg, _} = F.receive_message(peer)
    assert_report(msg, expected)

    F.send_message(peer, %{
      "v" => 1,
      "type" => "box_status_ack",
      "connection_id" => msg["connection_id"],
      "status_seq" => msg["status_seq"],
      "accepted" => true,
      "code" => "ok"
    })

    msg
  end

  defp assert_report(msg, expected) do
    assert msg["type"] == "box_status"
    assert msg["latch_position"] == "unknown"
    assert msg["position_basis"] == "unverified"
    assert msg["command_confirmation"] == nil
    assert Map.take(msg, Map.keys(expected)) == expected
  end

  defp start_box(fixture, extra) do
    opts = [
      path: fixture.path,
      instance_id: BoxConformance.instance(),
      device_id: BoxConformance.device(),
      clock: FakeClock.handle(fixture.clock),
      trace: self()
    ]

    # Transient box instance so intentional runtime death does not create a
    # replacement automatically behind the scenario.
    child =
      Supervisor.child_spec({BoxRuntime, Keyword.merge(opts, extra)},
        id: make_ref(),
        restart: :temporary
      )

    start_supervised!(child)
  end

  defp load(fixture) do
    {:ok, handle} =
      Store.open_existing(fixture.path, BoxConformance.instance(), BoxConformance.device())

    try do
      assert {:ok, document} = Store.load(handle)
      document
    after
      Store.close(handle)
    end
  end

  defp assert_eventually_unbound(box, attempts \\ 100)
  defp assert_eventually_unbound(_, 0), do: flunk("box relay did not retire its old binding")

  defp assert_eventually_unbound(box, attempts) do
    if BoxRuntime.binding(box) do
      Process.sleep(5)
      assert_eventually_unbound(box, attempts - 1)
    end
  end
end
