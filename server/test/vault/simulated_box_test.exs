defmodule Vault.SimulatedBoxTest do
  use ExUnit.Case, async: true

  alias Vault.SimulatedBox
  alias Vault.SimulatedBox.{Adapter, Store}
  alias Vault.Test.{BoxConformance, FakeClock}

  @moduletag :m1

  setup do
    directory = Path.join(System.tmp_dir!(), "vault_box_#{System.unique_integer([:positive])}")
    File.mkdir!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    path = Path.join(directory, "box.sqlite3")
    :ok = Store.init_new(path, BoxConformance.instance(), BoxConformance.device())
    clock = start_supervised!({FakeClock, BoxConformance.now()})
    %{path: path, clock: clock}
  end

  test "durable acceptance precedes every step and a lost status does not replay movement",
       fixture do
    box = start_box(fixture)
    {boot, welcome} = BoxConformance.setup_binding(box, 1)
    Adapter.arm(box, 1, "arm_first")

    BoxConformance.assert_status(box, 1, %{
      readiness: BoxConformance.readiness(nil, nil, false, false)
    })

    BoxConformance.challenge(box, 1, boot, 1, BoxConformance.now(), 1)
    release(box, boot, "cold")

    BoxConformance.assert_status(box, 1, %{
      command_id: "cold",
      command_session_id: nil,
      release_status: :failed,
      failure_code: :unknown_position
    })

    BoxConformance.query(box, 1, "cold", %{
      command_session_id: nil,
      release_status: :uncertain,
      failure_code: :unknown_command
    })

    BoxConformance.prepare(box, boot, welcome)
    Adapter.fault(box, :lost_ack)
    release(box, boot, "release_once")
    assert_receive {:box_trace, {:storage_started, {:commit, _, :accept}}}, 1_000
    assert_receive {:box_trace, {:storage_finished, _, {:ok, _, _}}}, 1_000
    assert_receive {:box_trace, {:status_dropped, _, "release_once"}}, 1_000

    assert [accepted] = load(fixture)["journal"]
    assert accepted["command_id"] == "release_once"
    assert accepted["reserved_arm_id"] == "arm_first"
    assert Enum.map(accepted["outcomes"], & &1["kind"]) == ["accepted"]

    assert accepted["fingerprint"] == %{
             "session_id" => "original",
             "action" => "set_latch",
             "target" => "released"
           }

    for ordinal <- 1..100 do
      due = BoxConformance.now() + ordinal * 10
      BoxConformance.step(fixture.clock, due, ordinal)

      if rem(ordinal, 10) == 0 and ordinal < 100 do
        BoxConformance.challenge(box, 1, boot, div(ordinal, 10) + 1, due)
      end
    end

    assert_receive {:box_trace, {:deactivate, :motion_complete}}, 1_000
    assert_receive {:box_trace, {:storage_started, {:commit, _, :outcome}}}, 1_000
    BoxConformance.assert_status(box, 1, %{release_status: :not_requested, motor_active: false})
    assert_receive {:box_trace, {:status_dropped, _, "release_once"}}, 1_000
    refute_receive {:simulated_box, :status, 1, %{status: %{command_id: "release_once"}}, _}, 10

    BoxConformance.query(box, 1, "release_once", %{
      command_session_id: "original",
      release_status: :motion_complete,
      motor_active: false,
      readiness: BoxConformance.readiness(nil, nil, true, false)
    })

    release(box, boot, "release_once")
    BoxConformance.assert_status(box, 1, %{release_status: :motion_complete, motor_active: false})

    release(box, boot, "release_once", BoxConformance.fingerprint("different"))
    assert_receive {:box_trace, {:diagnostic, :identity_mismatch}}, 1_000
    BoxConformance.assert_no_steps()

    Adapter.fault(box, :reboot)
    assert_receive {:simulated_box, :unbound, 1, :reboot}, 1_000
    assert_receive {:simulated_box, :boot, _, new_boot}, 1_000
    assert new_boot != boot
    {^new_boot, _} = BoxConformance.setup_binding(box, 2, "after_reboot")

    BoxConformance.query(box, 2, "release_once", %{
      command_session_id: "original",
      release_status: :motion_complete,
      motor_active: false,
      readiness: BoxConformance.readiness(nil, nil, false, false)
    })

    assert [reloaded] = load(fixture)["journal"]
    assert Enum.map(reloaded["outcomes"], & &1["kind"]) == ["accepted", "motion_complete"]
  end

  test "silence expires at equality despite a queued old challenge and owner replacement",
       fixture do
    box = start_box(fixture)
    {boot, welcome} = BoxConformance.setup_binding(box, 1)
    BoxConformance.prepare(box, boot, welcome)
    BoxConformance.challenge(box, 1, boot, 1, BoxConformance.now())
    release(box, boot, "interrupted")

    BoxConformance.assert_status(box, 1, %{
      command_id: "interrupted",
      command_session_id: "original",
      release_status: :accepted,
      motor_active: true,
      readiness: BoxConformance.readiness(nil, nil, true, false)
    })

    BoxConformance.step(fixture.clock, BoxConformance.now() + 10, 1)
    BoxConformance.step(fixture.clock, BoxConformance.now() + 1_499, 2)
    assert %{"data" => %{"motor_active" => true}} = Adapter.inspect(box, "status")

    :sys.suspend(box)
    Adapter.challenge(box, 1, 2, BoxConformance.now() + 1_100)
    :ok = FakeClock.advance_to(fixture.clock, BoxConformance.now() + 1_500)
    :sys.resume(box)

    assert_receive {:box_trace, {:deactivate, :connection_lost}}, 1_000
    BoxConformance.assert_status(box, 1, %{release_status: :not_requested, motor_active: false})

    BoxConformance.assert_status(box, 1, %{
      command_id: "interrupted",
      release_status: :uncertain,
      failure_code: :connection_lost,
      motor_active: false
    })

    refute_receive {:simulated_box, :heartbeat, _, _, 2, _}, 10

    Adapter.unbind(box, 1, :replaced)
    assert_receive {:simulated_box, :unbound, 1, :replaced}, 1_000
    {^boot, _} = BoxConformance.setup_binding(box, 2, "replacement")

    Adapter.challenge(box, 1, 3, BoxConformance.now() + 1_500)
    BoxConformance.challenge(box, 2, boot, 1, BoxConformance.now() + 1_500, 1)
    refute_receive {:simulated_box, :heartbeat, 1, _, 3, _}, 10

    BoxConformance.query(box, 2, "interrupted", %{
      command_session_id: "original",
      release_status: :uncertain,
      failure_code: :connection_lost,
      motor_active: false
    })

    BoxConformance.assert_no_steps()
  end

  test "a dead bound server owner stops motion while the independent box keeps its boot and journal",
       fixture do
    box = start_box(fixture)
    parent = self()

    owner =
      spawn(fn ->
        {boot, welcome} = BoxConformance.setup_binding(box, 1)
        BoxConformance.prepare(box, boot, welcome)
        BoxConformance.challenge(box, 1, boot, 1, BoxConformance.now())
        release(box, boot, "owner_died")
        BoxConformance.assert_status(box, 1, %{release_status: :accepted})
        send(parent, {:accepted, boot})

        receive do
          :finished -> :ok
        end
      end)

    assert_receive {:accepted, boot}, 1_000
    BoxConformance.step(fixture.clock, BoxConformance.now() + 10, 1)
    drain_trace()
    Process.exit(owner, :kill)
    assert_receive {:box_trace, {:deactivate, :connection_lost}}, 1_000
    assert_receive {:box_trace, {:storage_started, {:commit, _, :outcome}}}, 1_000
    assert_receive {:box_trace, {:storage_finished, _, {:ok, _, _}}}, 1_000

    assert Process.alive?(box)
    {^boot, _} = BoxConformance.setup_binding(box, 2, "restarted_server")

    BoxConformance.query(box, 2, "owner_died", %{
      command_session_id: "original",
      release_status: :uncertain,
      failure_code: :connection_lost,
      motor_active: false
    })

    assert [journal] = load(fixture)["journal"]
    assert Enum.map(journal["outcomes"], & &1["kind"]) == ["accepted", "uncertain"]
    BoxConformance.assert_no_steps()
  end

  test "a real SQLite lock rejects admission and never starts a modeled step", fixture do
    box = start_box(fixture)
    {boot, welcome} = BoxConformance.setup_binding(box, 1)
    BoxConformance.prepare(box, boot, welcome)
    BoxConformance.challenge(box, 1, boot, 1, BoxConformance.now())
    drain_trace()

    {:ok, writer} = Exqlite.Sqlite3.open(fixture.path, mode: :readwrite)
    :ok = Exqlite.Sqlite3.execute(writer, "BEGIN IMMEDIATE")

    try do
      started = System.monotonic_time(:millisecond)
      release(box, boot, "locked")

      assert_receive {:box_trace, {:storage_finished, _, {:error, :rolled_back}}}, 1_000
      elapsed = System.monotonic_time(:millisecond) - started
      assert elapsed >= 75 and elapsed < 750
      assert_receive {:box_trace, {:deactivate, :storage_error}}, 1_000

      assert %{"data" => %{"motor_active" => false, "storage_fault" => "storage_error"}} =
               Adapter.inspect(box, "status")

      assert load(fixture)["journal"] == []
      BoxConformance.assert_no_steps()
    after
      Exqlite.Sqlite3.execute(writer, "ROLLBACK")
      Exqlite.Sqlite3.close(writer)
    end
  end

  test "a commit reply queued before its exact deadline cannot start an expired reservation",
       fixture do
    alias Vault.Test.BoxStoreGate
    assert :yes = BoxStoreGate.register(fixture.path)
    box = start_box(fixture, store: BoxStoreGate)
    {boot, welcome} = BoxConformance.setup_binding(box, 1)
    BoxConformance.prepare(box, boot, welcome)
    BoxConformance.challenge(box, 1, boot, 1, BoxConformance.now())
    drain_trace()

    release(box, boot, "late_commit")
    assert_receive {:box_write_gate, worker, :before_commit}, 1_000
    send(worker, {:box_write_gate, self(), :commit})
    assert_receive {:box_write_gate, ^worker, :after_commit, {:ok, _, _}}, 1_000

    assert [%{"command_id" => "late_commit", "outcomes" => [%{"kind" => "accepted"}]}] =
             load(fixture)["journal"]

    :sys.suspend(box)
    send(worker, {:box_write_gate, self(), :deliver})

    wait_until(fn ->
      {:messages, messages} = Process.info(box, :messages)
      Enum.any?(messages, &match?({:box_store, ^worker, _, {:ok, _, _}}, &1))
    end)

    :ok = FakeClock.advance_to(fixture.clock, BoxConformance.now() + 200)
    :sys.resume(box)

    assert_receive {:box_trace, {:deactivate, :storage_error}}, 1_000
    assert_receive {:box_trace, {:storage_readback, _, :committed}}, 1_000
    BoxConformance.assert_status(box, 1, %{release_status: :not_requested, motor_active: false})
    BoxConformance.assert_status(box, 1, %{release_status: :accepted, motor_active: false})

    BoxConformance.assert_status(box, 1, %{
      release_status: :uncertain,
      failure_code: :freshness_lost,
      motor_active: false
    })

    BoxConformance.assert_no_steps()
  end

  test "urgent stop and watchdog work while a reservation write remains blocked", fixture do
    alias Vault.Test.BoxStoreGate
    assert :yes = BoxStoreGate.register(fixture.path)
    box = start_box(fixture, store: BoxStoreGate)
    {boot, welcome} = BoxConformance.setup_binding(box, 1)
    BoxConformance.prepare(box, boot, welcome)
    BoxConformance.challenge(box, 1, boot, 1, BoxConformance.now())
    drain_trace()

    release(box, boot, "blocked_then_stopped")
    assert_receive {:box_write_gate, worker, :before_commit}, 1_000

    :ok =
      Adapter.service_operation_async(
        box,
        "stop",
        %{
          "reason" => "maintenance",
          "operator" => BoxConformance.operator()
        },
        :stop
      )

    assert_receive {:box_trace, {:deactivate, :stopped}}, 1_000

    assert %{"data" => %{"motor_active" => false, "outputs_disabled" => true}} =
             Adapter.inspect(box, "status")

    refute_receive {:simulated_box, :service, :stop, _}, 10

    :ok = FakeClock.advance_to(fixture.clock, BoxConformance.now() + 1_500)
    assert_receive {:box_trace, {:deactivate, :storage_error}}, 1_000

    assert %{"data" => %{"storage_fault" => "commit_uncertain", "motor_active" => false}} =
             Adapter.inspect(box, "status")

    send(worker, {:box_write_gate, self(), :lose_before_commit})
    assert_receive {:box_trace, {:storage_readback, _, :not_committed}}, 1_000
    assert_receive {:simulated_box, :service, :stop, %{"status" => "ok"}}, 1_000

    durable = load(fixture)
    assert durable["journal"] == []
    assert durable["service"]["service_inhibited"]
    assert durable["service"]["motion_frozen"]
    BoxConformance.assert_no_steps()
  end

  test "a runtime crash during a committed stroke reconciles the same journal on boot", fixture do
    opts = [
      name: nil,
      path: fixture.path,
      device_id: BoxConformance.device(),
      instance_id: BoxConformance.instance(),
      clock: FakeClock.handle(fixture.clock),
      trace: self()
    ]

    {:ok, box} = SimulatedBox.start_link(opts)
    Process.unlink(box)
    {boot, welcome} = BoxConformance.setup_binding(box, 1)
    BoxConformance.prepare(box, boot, welcome)
    BoxConformance.challenge(box, 1, boot, 1, BoxConformance.now())
    release(box, boot, "power_loss")
    BoxConformance.assert_status(box, 1, %{release_status: :accepted})
    BoxConformance.step(fixture.clock, BoxConformance.now() + 10, 1)

    monitor = Process.monitor(box)
    Process.exit(box, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^box, :killed}, 1_000
    assert [%{"outcomes" => [%{"kind" => "accepted"}]}] = load(fixture)["journal"]

    drain_trace()
    restarted = start_box(fixture)
    assert_receive {:box_trace, {:storage_started, {:commit, _, :boot_reconcile}}}, 1_000
    assert_receive {:box_trace, {:storage_finished, _, {:ok, _, _}}}, 1_000
    {new_boot, _} = BoxConformance.setup_binding(restarted, 2, "power_returned")
    assert new_boot != boot

    BoxConformance.query(restarted, 2, "power_loss", %{
      command_session_id: "original",
      release_status: :uncertain,
      failure_code: :reboot_interrupted,
      motor_active: false
    })

    assert [
             %{
               "outcomes" => [_, %{"kind" => "uncertain", "failure_code" => "reboot_interrupted"}]
             }
           ] =
             load(fixture)["journal"]

    BoxConformance.assert_no_steps()
  end

  test "full journal still permits absent-ID recovery, durable erase and a new-session fence",
       fixture do
    fill_terminal_journal(fixture)
    box = start_box(fixture)
    {boot, _welcome} = BoxConformance.setup_binding(box, 1, "recovery_session")
    BoxConformance.challenge(box, 1, boot, 1, BoxConformance.now())

    Adapter.release(
      box,
      1,
      boot,
      "arm_unused",
      1,
      "absent",
      BoxConformance.fingerprint("recovery_session")
    )

    BoxConformance.assert_status(box, 1, %{
      command_id: "absent",
      release_status: :failed,
      failure_code: :history_full,
      command_session_id: nil
    })

    BoxConformance.query(box, 1, "earlier_32", %{
      release_status: :motion_complete,
      command_session_id: "original",
      motor_active: false
    })

    BoxConformance.query(box, 1, "absent", %{
      release_status: :uncertain,
      failure_code: :unknown_command,
      command_session_id: nil
    })

    preparation = BoxConformance.recovery_preparation("absent")
    current = BoxConformance.recovery_current()
    operator = BoxConformance.operator()

    assert %{
             "status" => "ok",
             "data" => %{
               "receipt" => %{
                 "decision" => %{
                   "data" => %{
                     "local_record_id" => local,
                     "service_epoch" => service_epoch
                   }
                 }
               }
             }
           } =
             service(box, "recovery.enter", %{
               "preparation" => preparation,
               "host_current" => current,
               "operator" => operator
             })

    assert_receive {:simulated_box, :unbound, 1, :service}, 1_000

    assert %{
             "data" => %{
               "record" => %{
                 "journal_observation" => "not_present_current_journal",
                 "observed_outcome" => nil,
                 "seal" => nil
               }
             }
           } =
             service(box, "inspect", %{"section" => "recovery", "local_record_id" => local})

    assert length(load(fixture)["journal"]) == 32

    {^boot, same_boot_welcome} = BoxConformance.setup_binding(box, 2, "recovery_session")

    seal_args = %{
      "local_record_id" => local,
      "recovery_id" => "recovery",
      "recovery_generation" => 1,
      "binding" => BoxConformance.local_binding(boot, same_boot_welcome),
      "host_current" => current,
      "operator" => operator
    }

    assert %{"code" => "reboot_required"} = service(box, "recovery.seal", seal_args)
    new_boot = service_reboot(box, 2, "recovery")
    assert new_boot != boot
    {^new_boot, welcome} = BoxConformance.setup_binding(box, 3, "recovery_session")

    seal_args = %{seal_args | "binding" => BoxConformance.local_binding(new_boot, welcome)}

    assert %{"status" => "ok", "data" => %{"receipt" => %{"operation_id" => seal}}} =
             service(box, "recovery.seal", seal_args)

    assert %{"code" => "motion_frozen"} =
             service(box, "motion.jog", %{
               "direction" => "toward_locked",
               "steps" => 1,
               "rate_steps_s" => 100,
               "timeout_ms" => 50
             })

    assert %{"code" => "unreconciled_history"} =
             service(box, "history.clear", %{
               "retained_host_history" => true,
               "operator" => operator
             })

    status =
      BoxConformance.query(box, 3, "absent", %{
        release_status: :uncertain,
        failure_code: :unknown_command,
        command_session_id: nil,
        motor_active: false,
        readiness: BoxConformance.readiness(nil, nil, false, false)
      })

    close =
      BoxConformance.disposition(
        preparation,
        local,
        seal,
        service_epoch,
        new_boot,
        welcome,
        status.status_seq
      )

    assert %{"status" => "ok"} =
             service(box, "recovery.attest_disposition", %{
               "local_record_id" => local,
               "disposition" => close,
               "operator" => operator
             })

    assert %{"status" => "pending", "data" => %{"receipt" => %{"operation_id" => clear}}} =
             service(box, "history.clear", %{
               "retained_host_history" => true,
               "operator" => operator
             })

    assert_receive {:box_trace, {:storage_readback, _, :committed}}, 1_000

    wait_until(fn ->
      match?(
        %{"data" => %{"receipt" => %{"completion" => %{"state" => "complete"}}}},
        service(box, "operation.get", %{"operation_id" => clear})
      )
    end)

    durable = load(fixture)
    assert durable["journal"] == []
    assert durable["absent_reconciliation"] == nil
    assert durable["service"]["active_local_record_id"] == nil
    assert durable["clear_authorization"]["header"]["phase"] == "awaiting_fence"

    assert [
             %{
               "local_record_id" => ^local,
               "disposition_id" => "disposition",
               "seal_operation_id" => ^seal
             }
           ] =
             durable["clear_authorization"]["entries"]

    assert %{"code" => "invalid_args"} =
             service(box, "inspect", %{"section" => "recovery", "local_record_id" => local})

    fence_args = %{
      "clear_operation_id" => clear,
      "binding" => BoxConformance.local_binding(new_boot, welcome)
    }

    assert %{"code" => "reboot_required"} = service(box, "history.fence", fence_args)
    fenced_boot = service_reboot(box, 3, "history_clear")
    {^fenced_boot, same_session} = BoxConformance.setup_binding(box, 4, "recovery_session")

    assert %{"code" => "session_fence_required"} =
             service(box, "history.fence", %{
               fence_args
               | "binding" => BoxConformance.local_binding(fenced_boot, same_session)
             })

    {^fenced_boot, replacement} = BoxConformance.setup_binding(box, 5, "new_session")
    binding = BoxConformance.local_binding(fenced_boot, replacement)

    assert %{"status" => "ok"} =
             service(box, "history.fence", %{fence_args | "binding" => binding})

    assert %{"code" => "motion_frozen"} = service(box, "service.exit", %{"binding" => binding})

    assert %{"status" => "ok"} =
             service(box, "service.prepare", %{
               "authorization" => "clear",
               "authorization_id" => clear,
               "operator" => operator
             })

    assert %{"code" => "reference_required"} =
             service(box, "service.exit", %{"binding" => binding})

    assert %{"status" => "ok"} =
             service(box, "calibration.set", %{
               "calibration" => calibration(),
               "operator" => operator
             })

    assert %{"status" => "ok"} =
             service(box, "reference.set", %{
               "calibration_revision" => 1,
               "reference" => "locked_zero",
               "method" => "manual_verified",
               "operator" => operator
             })

    BoxConformance.assert_status(box, 5, %{
      readiness: BoxConformance.readiness(nil, nil, true, false)
    })

    assert %{"status" => "ok"} =
             service(box, "position.confirm", %{
               "position" => "locked",
               "basis" => "manual_verified",
               "command_id" => nil,
               "operator" => operator
             })

    BoxConformance.assert_status(box, 5, %{
      readiness: BoxConformance.readiness(nil, nil, true, true)
    })

    assert %{"status" => "ok"} = service(box, "service.exit", %{"binding" => binding})

    BoxConformance.assert_status(box, 5, %{
      readiness: BoxConformance.readiness(nil, nil, true, true)
    })

    Adapter.arm(box, 5, "new_arm")

    BoxConformance.assert_status(box, 5, %{
      readiness: BoxConformance.readiness("new_arm", "new_session", true, true)
    })

    assert %{"header" => %{"phase" => "exited"}, "entries" => [%{"local_record_id" => ^local}]} =
             load(fixture)["clear_authorization"]

    BoxConformance.assert_no_steps()
  end

  test "local motion watchdog expires independently of valid server challenges", fixture do
    box = start_box(fixture)
    {boot, _welcome} = BoxConformance.setup_binding(box, 1)
    assert %{"status" => "ok"} = Adapter.prepare(box)

    BoxConformance.assert_status(box, 1, %{
      readiness: BoxConformance.readiness(nil, nil, true, false)
    })

    BoxConformance.assert_status(box, 1, %{
      readiness: BoxConformance.readiness(nil, nil, true, true)
    })

    assert %{"code" => "sensor_unavailable"} =
             service(box, "motion.home", %{"calibration_revision" => 1})

    assert %{"status" => "pending", "data" => %{"receipt" => %{"operation_id" => motion}}} =
             service(box, "motion.jog", %{
               "direction" => "toward_released",
               "steps" => 100,
               "rate_steps_s" => 50,
               "timeout_ms" => 4_000
             })

    assert_receive {:box_trace, {:scheduled, :local_watchdog, effect, motion_generation, _}},
                   1_000

    Adapter.local_control_lost(box, effect, motion_generation - 1)

    BoxConformance.assert_status(box, 1, %{
      motor_active: true,
      readiness: BoxConformance.readiness(nil, nil, true, false)
    })

    BoxConformance.step(fixture.clock, BoxConformance.now() + 20, 1)
    BoxConformance.step(fixture.clock, BoxConformance.now() + 1_499, 2)
    BoxConformance.challenge(box, 1, boot, 1, BoxConformance.now() + 1_499)

    :ok = FakeClock.advance_to(fixture.clock, BoxConformance.now() + 1_500)
    assert_receive {:box_trace, {:deactivate, :freshness_lost}}, 1_000

    BoxConformance.assert_status(box, 1, %{
      motor_active: false,
      readiness: BoxConformance.readiness(nil, nil, false, false)
    })

    wait_until(fn ->
      match?(
        %{
          "data" => %{
            "receipt" => %{
              "completion" => %{
                "state" => "uncertain",
                "code" => "freshness_lost",
                "steps_executed" => 2
              }
            }
          }
        },
        service(box, "operation.get", %{"operation_id" => motion})
      )
    end)

    assert load(fixture)["journal"] == []
    BoxConformance.assert_no_steps()
  end

  test "identical local motion retry reads its receipt, and eviction never permits replay",
       fixture do
    box = start_box(fixture)
    {boot, _} = BoxConformance.setup_binding(box, 1)
    assert %{"status" => "ok"} = Adapter.prepare(box)

    BoxConformance.assert_status(box, 1, %{
      readiness: BoxConformance.readiness(nil, nil, true, false)
    })

    BoxConformance.assert_status(box, 1, %{
      readiness: BoxConformance.readiness(nil, nil, true, true)
    })

    motion = "svc_0000000000000005_" <> String.duplicate("a", 32)

    request = %{
      "sv" => 1,
      "type" => "request",
      "request_id" => "request_a",
      "device_id" => BoxConformance.device(),
      "box_boot_id" => boot,
      "operation_id" => motion,
      "expected_revision" => 4,
      "command" => "motion.jog",
      "args" => %{
        "direction" => "toward_locked",
        "steps" => 1,
        "rate_steps_s" => 100,
        "timeout_ms" => 50
      }
    }

    assert %{"status" => "pending", "data" => %{"receipt" => receipt}} =
             Adapter.service(box, request)

    refute Map.has_key?(receipt, "request_sha256")
    assert receipt["completion"] == nil

    BoxConformance.assert_status(box, 1, %{motor_active: true})
    BoxConformance.step(fixture.clock, BoxConformance.now() + 10, 1)
    BoxConformance.assert_status(box, 1, %{motor_active: false})

    wait_until(fn ->
      match?(
        %{"data" => %{"receipt" => %{"completion" => %{"state" => "complete"}}}},
        service(box, "operation.get", %{"operation_id" => motion})
      )
    end)

    assert %{
             "status" => "pending",
             "data" => %{
               "receipt" => %{
                 "completion" => %{
                   "state" => "complete",
                   "steps_executed" => 1
                 }
               }
             }
           } = Adapter.service(box, %{request | "request_id" => "another_exchange"})

    assert %{"code" => "operation_conflict"} =
             Adapter.service(box, put_in(request, ["args", "steps"], 2))

    assert %{"code" => "invalid_args"} =
             Adapter.service(box, put_in(request, ["args", "extra"], 2))

    for _ <- 1..64 do
      assert %{"status" => "ok"} =
               service(box, "stop", %{
                 "reason" => "maintenance",
                 "operator" => BoxConformance.operator()
               })
    end

    durable = load(fixture)
    assert durable["service"]["service_revision"] == 69
    assert length(durable["service_receipts"]) == 64
    assert durable["journal"] == []

    assert %{"code" => "receipt_expired"} =
             service(box, "operation.get", %{"operation_id" => motion})

    assert %{"code" => "receipt_expired"} = Adapter.service(box, request)
    BoxConformance.assert_no_steps()
  end

  test "in-process status retries preserve the exact report and stop after three", fixture do
    box = start_box(fixture)
    {:ok, boot} = Adapter.boot_id(box)
    :ok = Adapter.bind(box, boot, BoxConformance.binding(1))

    assert_receive {:simulated_box, :status, 1, %{status: %{status_seq: 1}} = original, nil},
                   1_000

    for retry <- 1..3 do
      :ok = FakeClock.advance_to(fixture.clock, BoxConformance.now() + retry * 500)
      assert_receive {:simulated_box, :status, 1, ^original, nil}, 1_000
    end

    :ok = FakeClock.advance_to(fixture.clock, BoxConformance.now() + 2_000)
    refute_receive {:simulated_box, :status, 1, ^original, nil}, 10
  end

  defp service(box, command, args), do: Adapter.service_operation(box, command, args)

  defp service_reboot(box, generation, reason) do
    assert %{
             "status" => "ok",
             "data" => %{
               "receipt" => %{
                 "decision" => %{
                   "data" => %{
                     "reboot_required" => true
                   }
                 }
               }
             }
           } = service(box, "reboot", %{"reason" => reason})

    assert_receive {:simulated_box, :unbound, ^generation, :reboot}, 1_000
    assert_receive {:simulated_box, :boot, _, boot}, 1_000
    boot
  end

  defp fill_terminal_journal(fixture) do
    {:ok, handle} =
      Store.open_existing(fixture.path, BoxConformance.instance(), BoxConformance.device())

    try do
      for index <- 1..32 do
        command = "earlier_#{index}"

        persist_fixture(
          handle,
          %{
            "kind" => "accept",
            "entry" => %{
              "schema_version" => 1,
              "command_id" => command,
              "fingerprint" => %{
                "session_id" => "original",
                "action" => "set_latch",
                "target" => "released"
              },
              "reserved_arm_id" => "earlier_arm_#{index}",
              "accepted_boot_id" => "previous_boot",
              "accept_operation_id" => "accepted_#{index}",
              "conflicted" => false,
              "outcomes" => [
                %{
                  "kind" => "accepted",
                  "failure_code" => nil,
                  "boot_id" => "previous_boot",
                  "operation_id" => "accepted_#{index}"
                }
              ]
            }
          },
          :accept
        )

        persist_fixture(
          handle,
          %{
            "kind" => "outcome",
            "command_id" => command,
            "outcome" => %{
              "kind" => "motion_complete",
              "failure_code" => nil,
              "boot_id" => "previous_boot",
              "operation_id" => "complete_#{index}"
            }
          },
          :outcome
        )
      end
    after
      Store.close(handle)
    end
  end

  defp persist_fixture(handle, patch, purpose) do
    alias Vault.SimulatedBox.Model.{Durable, Persist}
    {:ok, base} = Store.load(handle)
    {:ok, operation, next} = Durable.advance(base, patch, handle.config)
    {:ok, base_hash} = Durable.hash(base)
    {:ok, hash} = Durable.hash(next)

    assert {:ok, _, ^hash} =
             Store.commit(handle, %Persist{
               instance_id: BoxConformance.instance(),
               operation_id: operation,
               base_revision: base["store_revision"],
               next_revision: next["store_revision"],
               expected_sha256: base_hash,
               payload_sha256: hash,
               patch: patch,
               purpose: purpose,
               effect_generation: 1,
               motion_generation: 1
             })
  end

  defp calibration do
    %{
      "storage_version" => 1,
      "profile_sha256" => "1bdb998204ed872b45a01ac845c672547448c0aa604418e843adaacc1115bf89",
      "mechanism_id" => "simulated_latch_v1",
      "mode" => "validated",
      "sequence_id" => "simulated_step_v1",
      "step_unit" => "sequence_transition",
      "release_direction" => "forward",
      "release_steps" => 100,
      "max_travel_steps" => 100,
      "max_rate_steps_s" => 100,
      "motion_timeout_ms" => 8_000,
      "home" => nil,
      "measurement_ref" => "simulated_model_v1"
    }
  end

  defp wait_until(predicate, tries \\ 100)
  defp wait_until(_predicate, 0), do: flunk("condition did not become true")

  defp wait_until(predicate, tries) do
    if predicate.() do
      :ok
    else
      Process.sleep(1)
      wait_until(predicate, tries - 1)
    end
  end

  defp start_box(fixture, extra \\ []) do
    start_supervised!(
      {SimulatedBox,
       Keyword.merge(
         [
           name: nil,
           path: fixture.path,
           device_id: BoxConformance.device(),
           instance_id: BoxConformance.instance(),
           clock: FakeClock.handle(fixture.clock),
           trace: self()
         ],
         extra
       )}
    )
  end

  defp release(box, boot, command, fingerprint \\ BoxConformance.fingerprint()),
    do: Adapter.release(box, 1, boot, "arm_first", 1, command, fingerprint)

  defp load(fixture) do
    {:ok, handle} =
      Store.open_existing(fixture.path, BoxConformance.instance(), BoxConformance.device())

    try do
      {:ok, durable} = Store.load(handle)
      durable
    after
      Store.close(handle)
    end
  end

  defp drain_trace do
    receive do
      {:box_trace, _} -> drain_trace()
    after
      0 -> :ok
    end
  end
end
