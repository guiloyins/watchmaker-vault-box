Code.require_file("durable_cases.exs", __DIR__)

defmodule Vault.SimulatedBox.ModelTest do
  use ExUnit.Case, async: true

  alias Vault.SimulatedBox.Model

  @moduletag :m0
  @config %{
    device_id: "box",
    instance_id: "instance",
    step_interval_ms: 10,
    release_steps: 100,
    motion_timeout_ms: 8_000
  }
  @binding %{
    connection_id: "connection",
    session_id: "session",
    binding_generation: 1,
    owner_id: "owner"
  }
  @fingerprint %{session_id: "session", action: "set_latch", target: "released"}
  @boot "boot"
  @operator %{"operator_id" => "operator", "observation" => "Modeled verification"}
  @calibration %{
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

  test "first boot is inactive and validates the exact durable root" do
    initial = initial()
    assert {:ok, state, [{:deactivate, :boot}]} = Model.new(@config, initial, @boot, -5_000)
    assert state.binding == nil
    assert state.last_local_control_ms == nil
    assert Model.durable(state) == initial

    assert {:error, :invalid_store} =
             Model.new(@config, Map.delete(initial, "clear_authorization"), @boot, -5_000)

    assert {:error, :invalid_configuration} =
             Model.new(%{@config | release_steps: 101}, initial, @boot, -5_000)
  end

  test "commit consumes the arm and the fixed stroke emits exactly 100 ordered steps" do
    state = ready_for_game()

    {reserved, [{:persist, intent}, {:schedule, %{kind: :watchdog, due_at_ms: -3_500}}]} =
      Model.transition(state, command(), -4_990)

    assert reserved.motion == nil
    assert Model.durable(reserved)["journal"] == []
    assert intent.purpose == :accept
    assert intent.base_revision == 5
    assert intent.next_revision == 6

    assert intent.patch["entry"]["fingerprint"] == %{
             "session_id" => "session",
             "action" => "set_latch",
             "target" => "released"
           }

    assert intent.patch["entry"]["outcomes"] == [
             %{
               "kind" => "accepted",
               "failure_code" => nil,
               "boot_id" => "boot",
               "operation_id" => "outcome_987e88e1680534d4d5df9cfd6744e7af"
             }
           ]

    {state, [{:status, "command"}, {:schedule, %{kind: :step, due_at_ms: -4_970}}]} =
      commit(reserved, intent, -4_980)

    assert state.arm == nil
    refute state.readiness.start_verified
    assert Model.durable(state)["journal"] == [intent.patch["entry"]]

    state =
      Enum.reduce(1..99, state, fn ordinal, state ->
        due = -4_980 + ordinal * 10

        assert {next,
                [{:step, %{ordinal: ^ordinal}}, {:schedule, %{kind: :step, due_at_ms: next_due}}]} =
                 Model.transition(state, timer(state, :step, due), due)

        assert next_due == due + 10
        next
      end)

    assert {stopped,
            [
              {:step, %{ordinal: 100}},
              {:deactivate, :motion_complete},
              {:cancel_timers, _},
              {:persist, terminal}
            ]} = Model.transition(state, timer(state, :step, -3_980), -3_980)

    assert stopped.motion == nil
    assert terminal.patch["outcome"]["kind"] == "motion_complete"
    {stopped, [{:status, "command"}]} = commit(stopped, terminal, -3_979)
    assert {^stopped, [{:status, "command"}]} = Model.transition(stopped, command(), -3_978)

    assert {^stopped, [{:diagnostic, :identity_mismatch}]} =
             Model.transition(
               stopped,
               command("command", %{@fingerprint | session_id: "different"}),
               -3_978
             )

    current =
      Model.transition(
        stopped,
        {:service, read("inspect", %{"section" => "command", "command_id" => "command"})},
        -3_978
      )

    assert {_,
            [
              {:service_reply, nil,
               %{
                 "data" => %{
                   "record" => %{"outcome" => "motion_complete", "command_confirmation" => nil},
                   "current" => %{
                     "position" => %{
                       "latch_position" => "unknown",
                       "position_basis" => "unverified"
                     }
                   }
                 }
               }}
            ]} = current
  end

  test "400 ms command expiry and deadline equality beat queued completion and stale challenge" do
    state = ready_for_game()

    assert {^state, [{:diagnostic, :stale_binding}, {:status, "command"}]} =
             Model.transition(state, command(), -4_600)

    {reserved, [{:persist, intent}, _]} = Model.transition(state, command(), -4_601)
    {expired, [{:status, "command"}, {:persist, outcome}]} = commit(reserved, intent, -4_600)
    assert expired.motion == nil
    assert outcome.patch["outcome"]["failure_code"] == "freshness_lost"

    {reserved, [{:persist, intent}, _]} = Model.transition(state, command(), -4_999)
    {renewed, []} = Model.transition(reserved, {:challenge, 1, 2, -4_950}, -4_949)

    {renewed, [{:schedule, %{kind: :watchdog, due_at_ms: -3_450}}]} =
      Model.transition(renewed, timer(renewed, :watchdog, -3_500), -3_500)

    assert {_,
            [
              {:deactivate, :connection_lost},
              {:cancel_timers, _},
              {:status, "command"},
              {:persist, outcome}
            ]} = commit(renewed, intent, -3_450)

    assert outcome.patch["outcome"]["failure_code"] == "connection_lost"
  end

  test "a fresh completion cannot authorize a first step at the original challenge expiry" do
    state = ready_for_game()
    {state, [{:persist, intent}, _]} = Model.transition(state, command(), -4_999)

    {state, [{:status, "command"}, {:schedule, %{kind: :step, due_at_ms: -4_600}}]} =
      commit(state, intent, -4_610)

    assert {inactive, [{:deactivate, :freshness_lost}, {:cancel_timers, _}, {:persist, outcome}]} =
             Model.transition(state, timer(state, :step, -4_600), -4_600)

    assert inactive.motion == nil
    assert outcome.patch["outcome"]["failure_code"] == "freshness_lost"
  end

  test "replacement invalidates a reservation, but exact late commit adopts its original history" do
    state = ready_for_game()
    {reserved, [{:persist, intent}, _]} = Model.transition(state, command(), -4_990)

    replacement = %{
      @binding
      | connection_id: "connection2",
        session_id: "session2",
        binding_generation: 2
    }

    {rebound, [{:deactivate, :connection_lost}, {:cancel_timers, 3}, {:status, nil}]} =
      Model.transition(reserved, {:bind, replacement}, -4_989)

    assert {^rebound, []} = Model.transition(rebound, {:challenge, 1, 2, -4_990}, -4_988)
    assert {^rebound, []} = commit(rebound, %{intent | payload_sha256: <<0::256>>}, -4_988)
    {rebound, [{:status, "command"}, {:persist, outcome}]} = commit(rebound, intent, -4_987)
    assert rebound.motion == nil
    assert outcome.base_revision == intent.next_revision
    assert outcome.patch["outcome"]["failure_code"] == "connection_lost"
    assert {^rebound, []} = Model.transition(rebound, timer(reserved, :step, -4_986), -4_986)
  end

  test "ambiguous acceptance requires exact readback and never starts motion" do
    state = ready_for_game()
    {reserved, [{:persist, intent}, _]} = Model.transition(state, command(), -4_990)

    {quarantine,
     [
       {:deactivate, :storage_error},
       {:cancel_timers, _},
       {:diagnostic, :commit_uncertain},
       {:read_store, expectation}
     ]} =
      Model.transition(reserved, failed(intent, :unknown), -4_989)

    assert expectation.instance_id == "instance"
    assert expectation.base_revision == 5
    assert expectation.next_revision == 6
    assert expectation.expected_sha256 == intent.expected_sha256
    assert expectation.payload_sha256 == intent.payload_sha256
    assert {^quarantine, []} = commit(quarantine, intent, -4_988)
    old = Model.durable(state)

    assert {inactive, []} =
             Model.transition(
               quarantine,
               {:readback, intent.operation_id, old, 5, intent.expected_sha256},
               -4_987
             )

    assert inactive.motion == nil
    assert inactive.arm == nil
    assert Model.durable(inactive)["journal"] == []

    stored = %{
      old
      | "journal" => [intent.patch["entry"]],
        "store_revision" => 6,
        "last_operation_id" => intent.operation_id
    }

    assert {inactive, [{:status, "command"}, {:persist, outcome}]} =
             Model.transition(
               quarantine,
               {:readback, intent.operation_id, stored, 6, intent.payload_sha256},
               -4_987
             )

    assert inactive.motion == nil
    assert outcome.patch["outcome"]["kind"] == "uncertain"
  end

  test "local watchdog is signed, independent, renewable by a valid local read, and wins at equality" do
    state = prepared_service()

    jog =
      request(3, "motion.jog", %{
        "direction" => "toward_locked",
        "steps" => 10,
        "rate_steps_s" => 1,
        "timeout_ms" => 8_000
      })

    {reserved, [{:persist, pending}, {:schedule, %{kind: :local_watchdog, due_at_ms: -3_500}}]} =
      Model.transition(state, {:service, jog}, -5_000)

    assert reserved.last_local_control_ms == -5_000

    {state,
     [
       {:service_reply, _, %{"status" => "pending"}},
       {:schedule, %{kind: :step, due_at_ms: -4_000}}
     ]} =
      commit(reserved, pending, -5_000)

    {state, [{:step, %{ordinal: 1}}, _]} =
      Model.transition(state, timer(state, :step, -4_000), -4_000)

    {state, []} = Model.transition(state, {:challenge, 1, 10, -3_999}, -3_999)
    assert state.local_control_deadline_ms == -3_500

    {state, [{:service_reply, nil, %{"status" => "ok"}}]} =
      Model.transition(state, {:service, read("inspect", %{"section" => "status"})}, -3_600)

    {state, [{:schedule, %{kind: :local_watchdog, due_at_ms: -2_100}}]} =
      Model.transition(state, timer(state, :local_watchdog, -3_500), -3_500)

    assert {inactive,
            [
              {:deactivate, :freshness_lost},
              {:cancel_timers, _},
              {:service_reply, nil, _},
              {:persist, completion}
            ]} =
             Model.transition(
               state,
               {:service, read("inspect", %{"section" => "status"})},
               -2_100
             )

    assert inactive.motion == nil
    assert inactive.local_control_deadline_ms == nil

    assert completion.patch["completion"] == %{
             "state" => "uncertain",
             "code" => "freshness_lost",
             "steps_executed" => 1
           }
  end

  test "renewing local control cannot extend a reserved service travel deadline" do
    state = prepared_service()

    jog =
      request(3, "motion.jog", %{
        "direction" => "toward_locked",
        "steps" => 10,
        "rate_steps_s" => 1,
        "timeout_ms" => 1_000
      })

    {reserved, [{:persist, pending}, {:schedule, %{kind: :local_watchdog, due_at_ms: -3_500}}]} =
      Model.transition(state, {:service, jog}, -5_000)

    refute Model.motor_active?(reserved)
    assert {^reserved, []} = Model.transition(reserved, timer(reserved, :step, -4_999), -4_999)

    {reserved, [{:service_reply, nil, %{"data" => %{"motor_active" => false}}}]} =
      Model.transition(reserved, {:service, read("inspect", %{"section" => "status"})}, -4_001)

    assert reserved.local_control_deadline_ms == -2_501

    assert {inactive,
            [
              {:deactivate, :travel_timeout},
              {:cancel_timers, _},
              {:service_reply, _, _},
              {:persist, completion}
            ]} = commit(reserved, pending, -4_000)

    refute Model.motor_active?(inactive)

    assert completion.patch["completion"] == %{
             "state" => "failed",
             "code" => "travel_timeout",
             "steps_executed" => 0
           }
  end

  test "urgent stop during acceptance rebases its next write behind committed interruption evidence" do
    state = ready_for_game()
    {state, [{:persist, intent}, _]} = Model.transition(state, command(), -4_999)
    stop = request(6, "stop", %{"reason" => "maintenance", "operator" => @operator})

    {state, [{:deactivate, :stopped}, {:cancel_timers, _}]} =
      Model.transition(state, {:service, stop}, -4_998)

    {state, [{:status, "command"}, {:persist, interrupted}]} = commit(state, intent, -4_997)
    assert interrupted.patch["outcome"]["failure_code"] == "freshness_lost"

    assert {_,
            [
              {:status, "command"},
              {:deactivate, :stopped},
              {:cancel_timers, _},
              {:persist, stop_effect}
            ]} =
             commit(state, interrupted, -4_996)

    assert stop_effect.base_revision == 7
    assert stop_effect.patch["service_after"]["service_inhibited"]
    assert stop_effect.patch["service_after"]["motion_frozen"]
  end

  test "queued urgent stops resolve in admission order after durable evidence" do
    state = ready_for_game()
    {state, [{:persist, intent}, _]} = Model.transition(state, command(), -4_999)
    first = request(6, "stop", %{"reason" => "maintenance", "operator" => @operator})
    other_id = "svc_0000000000000006_1123456789abcdef0123456789abcdef"
    second = %{first | "operation_id" => other_id}
    {state, _} = Model.transition(state, {:service, first}, -4_998)
    {state, _} = Model.transition(state, {:service, second}, -4_997)
    {state, [{:status, "command"}, {:persist, outcome}]} = commit(state, intent, -4_996)

    {state,
     [{:status, "command"}, {:deactivate, :stopped}, {:cancel_timers, _}, {:persist, stop}]} =
      commit(state, outcome, -4_995)

    first_id = first["operation_id"]
    assert stop.patch["receipt"]["operation_id"] == first_id

    assert {state,
            [
              {:service_reply, ^first_id, %{"status" => "ok"}},
              {:service_reply, ^other_id, %{"code" => "receipt_expired"}}
            ]} =
             commit(state, stop, -4_994)

    assert state.pending_durable == []
  end

  test "an ambiguous outcome with a full service queue retries evidence against the verified base first" do
    state = ready_for_game()
    {state, [{:persist, accept}, _]} = Model.transition(state, command(), -4_999)
    replacement = %{@binding | connection_id: "replacement", binding_generation: 2}
    {state, _} = Model.transition(state, {:bind, replacement}, -4_998)
    {state, [{:status, "command"}, {:persist, outcome}]} = commit(state, accept, -4_997)
    base = Model.durable(state)

    state =
      Enum.reduce(1..32, state, fn number, state ->
        suffix = String.pad_leading(Integer.to_string(number), 32, "0")
        stop = request(6, "stop", %{"reason" => "maintenance", "operator" => @operator})
        stop = %{stop | "operation_id" => "svc_0000000000000006_" <> suffix}
        {state, _} = Model.transition(state, {:service, stop}, -4_996)
        state
      end)

    assert length(state.pending_durable) == 32
    {state, effects} = Model.transition(state, failed(outcome, :unknown), -4_995)
    assert {:read_store, _} = List.last(effects)

    assert {state, [{:persist, retry}]} =
             Model.transition(
               state,
               {:readback, outcome.operation_id, base, outcome.base_revision,
                outcome.expected_sha256},
               -4_994
             )

    assert retry.operation_id == outcome.operation_id
    assert retry.patch == outcome.patch
    assert length(state.pending_durable) == 32
    assert state.fault == nil
  end

  test "an absent recovery at journal capacity remains distinct through seal, acknowledgement and clear" do
    initial = %{initial() | "journal" => terminal_journal()}
    {:ok, state, _} = Model.new(@config, initial, @boot, -5_000)
    {state, _} = Model.transition(state, {:bind, @binding}, -5_000)

    assert {^state, [{:diagnostic, :history_full}, {:status, "command"}]} =
             Model.transition(state, command(), -5_000)

    prep = %{
      "request_id" => "begin",
      "recovery_id" => "recovery",
      "recovery_generation" => 1,
      "current_session_id" => "recovery_session",
      "game_id" => "game",
      "command_id" => "command",
      "intended_box_id" => "box",
      "original_session_id" => "session",
      "original_round_id" => 1,
      "fingerprint" => %{
        "session_id" => "session",
        "action" => "set_latch",
        "target" => "released"
      },
      "prior_recovery_id" => nil,
      "committed_at_ms" => 123
    }

    current = %{
      "session_id" => "recovery_session",
      "recovery_id" => "recovery",
      "recovery_generation" => 1,
      "disposition_id" => nil
    }

    state =
      mutate(
        state,
        request(1, "recovery.enter", %{
          "preparation" => prep,
          "host_current" => current,
          "operator" => @operator
        })
      )

    local = service_id(1)
    assert length(Model.durable(state)["journal"]) == 32
    assert Model.durable(state)["absent_reconciliation"]["local_record_id"] == local
    assert Model.durable(state)["absent_reconciliation"]["observed_outcome"] == nil

    seal = %{
      "local_record_id" => local,
      "recovery_id" => "recovery",
      "recovery_generation" => 1,
      "binding" => %{
        "box_boot_id" => "boot2",
        "connection_id" => "connection2",
        "current_session_id" => "recovery_session"
      },
      "host_current" => current,
      "operator" => @operator
    }

    {state, _} = Model.transition(state, {:reboot, "boot2"}, -5_000)

    welcome = %{
      @binding
      | connection_id: "connection2",
        session_id: "recovery_session",
        binding_generation: 2
    }

    {state, _} = Model.transition(state, {:bind, welcome}, -5_000)
    state = mutate(state, request(2, "recovery.seal", seal, "boot2"))
    assert Model.durable(state)["service"]["motion_frozen"]

    close =
      Map.merge(
        Map.take(prep, ~w(game_id command_id intended_box_id original_session_id
      original_round_id fingerprint recovery_id recovery_generation)),
        %{
          "request_id" => "close",
          "disposition_id" => "disposition",
          "disposition" => "closed_no_replay",
          "closed_session_id" => "recovery_session",
          "local_record_id" => local,
          "service_epoch" => 1,
          "seal_operation_id" => service_id(2),
          "box_boot_id" => "boot2",
          "connection_id" => "connection2",
          "status_seq" => 12,
          "committed_at_ms" => 321
        }
      )

    state =
      mutate(
        state,
        request(
          3,
          "recovery.attest_disposition",
          %{"local_record_id" => local, "disposition" => close, "operator" => @operator},
          "boot2"
        )
      )

    assert Model.durable(state)["service"]["motion_frozen"]
    clear_id = service_id(4)

    {state, effects} =
      Model.transition(
        state,
        {:service,
         request(
           4,
           "history.clear",
           %{"retained_host_history" => true, "operator" => @operator},
           "boot2"
         )},
        -5_000
      )

    assert [{:persist, authorization}] = Enum.filter(effects, &match?({:persist, _}, &1))
    {state, [{:read_store, _}]} = commit(state, authorization)
    assert {^state, []} = commit(state, authorization)
    assert {^state, []} = Model.transition(state, failed(authorization, :unknown), -5_000)
    snapshot = Model.durable(state)
    assert snapshot["clear_authorization"]["header"]["phase"] == "prepared"

    assert [%{"local_record_id" => ^local, "disposition_id" => "disposition"}] =
             snapshot["clear_authorization"]["entries"]

    {state, [{:service_reply, ^clear_id, %{"status" => "pending"}}, {:persist, erase}]} =
      Model.transition(
        state,
        {:readback, authorization.operation_id, snapshot, authorization.next_revision,
         authorization.payload_sha256},
        -5_000
      )

    assert erase.patch["absent_local_record_id"] == local
    assert erase.patch["service_after"]["active_local_record_id"] == nil
    assert length(erase.patch["command_ids"]) == 32
    {state, [{:persist, finished}]} = commit(state, erase)
    {state, [{:service_reply, ^clear_id, _}]} = commit(state, finished)
    assert Model.durable(state)["absent_reconciliation"] == nil
    assert Model.durable(state)["journal"] == []

    {state, _} = Model.transition(state, {:reboot, "boot3"}, -5_000)

    later = %{
      welcome
      | connection_id: "connection3",
        session_id: "new_session",
        binding_generation: 3
    }

    {state, _} = Model.transition(state, {:bind, later}, -5_000)

    service_binding = %{
      "box_boot_id" => "boot3",
      "connection_id" => "connection3",
      "current_session_id" => "new_session"
    }

    state =
      mutate(
        state,
        request(
          5,
          "history.fence",
          %{"clear_operation_id" => clear_id, "binding" => service_binding},
          "boot3"
        )
      )

    state =
      mutate(
        state,
        request(
          6,
          "service.prepare",
          %{"authorization" => "clear", "authorization_id" => clear_id, "operator" => @operator},
          "boot3"
        )
      )

    state =
      mutate(
        state,
        request(
          7,
          "calibration.set",
          %{"calibration" => @calibration, "operator" => @operator},
          "boot3"
        )
      )

    state = mutate(state, request(8, "reference.set", reference_args(), "boot3"))
    state = mutate(state, request(9, "position.confirm", position_args(), "boot3"))
    state = mutate(state, request(10, "service.exit", %{"binding" => service_binding}, "boot3"))

    assert Model.durable(state)["clear_authorization"]["entries"] ==
             snapshot["clear_authorization"]["entries"]

    assert Model.durable(state)["clear_authorization"]["header"]["phase"] == "exited"
    assert Model.durable(state)["service"]["service_revision"] == 10
    assert state.arm == nil
  end

  defp terminal_journal do
    Enum.map(1..32, fn number ->
      id = "old_#{number}"

      %{
        "schema_version" => 1,
        "command_id" => id,
        "fingerprint" => %{
          "session_id" => "old_session",
          "action" => "set_latch",
          "target" => "released"
        },
        "reserved_arm_id" => "old_arm",
        "accepted_boot_id" => "old_boot",
        "accept_operation_id" => "accept_#{number}",
        "conflicted" => false,
        "outcomes" => [
          %{
            "kind" => "accepted",
            "failure_code" => nil,
            "operation_id" => "accept_#{number}",
            "boot_id" => "old_boot"
          },
          %{
            "kind" => "motion_complete",
            "failure_code" => nil,
            "operation_id" => "finish_#{number}",
            "boot_id" => "old_boot"
          }
        ]
      }
    end)
  end

  defp ready_for_game do
    state = prepared_service()
    state = mutate(state, request(3, "reference.set", reference_args()))
    state = mutate(state, request(4, "position.confirm", position_args()))

    state =
      mutate(
        state,
        request(5, "service.exit", %{
          "binding" => %{
            "box_boot_id" => @boot,
            "connection_id" => "connection",
            "current_session_id" => "session"
          }
        })
      )

    {state, [{:status, nil}]} = Model.transition(state, {:arm, @binding, "arm"}, -5_000)
    {state, []} = Model.transition(state, {:challenge, 1, 1, -5_000}, -5_000)
    state
  end

  defp prepared_service do
    {:ok, state, _} = Model.new(@config, initial(), @boot, -5_000)
    {state, _} = Model.transition(state, {:bind, @binding}, -5_000)

    state =
      mutate(
        state,
        request(1, "service.prepare", %{
          "authorization" => "ordinary",
          "authorization_id" => nil,
          "operator" => @operator
        })
      )

    mutate(
      state,
      request(2, "calibration.set", %{"calibration" => @calibration, "operator" => @operator})
    )
  end

  defp reference_args,
    do: %{
      "calibration_revision" => 1,
      "reference" => "locked_zero",
      "method" => "manual_verified",
      "operator" => @operator
    }

  defp position_args,
    do: %{
      "position" => "locked",
      "basis" => "manual_verified",
      "command_id" => nil,
      "operator" => @operator
    }

  defp initial do
    %{
      "schema_version" => 1,
      "instance_id" => "instance",
      "device_id" => "box",
      "store_revision" => 0,
      "last_operation_id" => "init",
      "journal" => [],
      "service" => %{
        "storage_version" => 1,
        "service_revision" => 0,
        "service_epoch" => 1,
        "service_inhibited" => true,
        "motion_frozen" => true,
        "entry_operation_id" => nil,
        "preparation_operation_id" => nil,
        "exit_operation_id" => nil,
        "stop_reason" => nil,
        "active_local_record_id" => nil,
        "clear_operation_id" => nil,
        "provisioning_operation_id" => nil,
        "provisioning_reboot_required" => false,
        "inflight_motion" => nil
      },
      "reconciliations" => [],
      "absent_reconciliation" => nil,
      "clear_authorization" => nil,
      "service_receipts" => [],
      "simulator_configuration" => %{
        "schema_version" => 1,
        "calibration_revision" => 0,
        "calibration" => nil
      }
    }
  end

  defp mutate(state, request) do
    {state, effects} = Model.transition(state, {:service, request}, -5_000)
    assert [{:persist, persist}] = Enum.filter(effects, &match?({:persist, _}, &1))
    {state, effects} = commit(state, persist)
    id = request["operation_id"]
    assert {:service_reply, ^id, %{"status" => "ok"}} = List.first(effects)
    state
  end

  defp commit(state, persist, now \\ -5_000) do
    Model.transition(
      state,
      {:persisted, persist.instance_id, persist.operation_id, persist.base_revision,
       persist.next_revision, persist.payload_sha256, persist.effect_generation},
      now
    )
  end

  defp failed(persist, certainty) do
    {:persist_failed, persist.instance_id, persist.operation_id, persist.base_revision,
     persist.effect_generation, certainty}
  end

  defp timer(state, kind, due),
    do: {:timer, state.effect_generation, state.motion_generation, kind, due}

  defp command(id \\ "command", fingerprint \\ @fingerprint),
    do: {:command, @binding, @boot, "arm", 1, id, fingerprint}

  defp request(sequence, command, args, boot \\ @boot) do
    read(command, args, boot)
    |> Map.merge(%{"operation_id" => service_id(sequence), "expected_revision" => sequence - 1})
  end

  defp read(command, args, boot \\ @boot) do
    %{
      "sv" => 1,
      "type" => "request",
      "request_id" => "request",
      "device_id" => "box",
      "box_boot_id" => boot,
      "operation_id" => nil,
      "expected_revision" => nil,
      "command" => command,
      "args" => args
    }
  end

  defp service_id(sequence) do
    prefix = sequence |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(16, "0")
    "svc_" <> prefix <> "_0123456789abcdef0123456789abcdef"
  end
end
