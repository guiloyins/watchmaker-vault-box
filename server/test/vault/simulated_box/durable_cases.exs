defmodule Vault.SimulatedBox.DurableTest do
  use ExUnit.Case, async: true

  alias Vault.SimulatedBox.Model.Durable

  @moduletag :m0
  @config %{instance_id: "instance", device_id: "box"}
  @keep %{"op" => "keep"}
  @fingerprint %{"session_id" => "original", "action" => "set_latch", "target" => "released"}
  @binding %{
    "box_boot_id" => "boot2",
    "connection_id" => "conn",
    "current_session_id" => "recovery_session"
  }
  @operator %{"operator_id" => "operator", "observation" => "Reviewed the modeled evidence"}

  test "accept and outcome patches cannot manufacture or overwrite journal history" do
    initial = initial()
    accepted = entry()
    terminal = outcome("motion_complete", nil, "terminal")

    assert {:error, :invalid_store} =
             Durable.advance(
               initial,
               accept_patch(%{accepted | "outcomes" => accepted["outcomes"] ++ [terminal]}),
               @config
             )

    assert {:error, :invalid_store} =
             Durable.advance(initial, outcome_patch("absent", terminal), @config)

    assert {:ok, "store_0000000000000001_" <> _, document} =
             Durable.advance(initial, accept_patch(accepted), @config)

    assert {:error, :invalid_store} = Durable.advance(document, accept_patch(accepted), @config)

    uncertainty = outcome("uncertain", "freshness_lost", "first_uncertainty")
    document = advance(document, outcome_patch("command", uncertainty))

    assert {:error, :invalid_store} =
             Durable.advance(
               document,
               outcome_patch("command", %{uncertainty | "operation_id" => "other"}),
               @config
             )

    assert :skip = Durable.rebase(document, {:outcome, "command", uncertainty, :outcome})
    document = advance(document, outcome_patch("command", terminal))
    assert [entry] = document["journal"]
    assert entry["outcomes"] == accepted["outcomes"] ++ [uncertainty, terminal]
    assert entry["conflicted"]
  end

  test "a service completion cannot rewrite an earlier uncertain receipt or any unrelated field" do
    initial = initial()
    prepared = prepare(initial)
    calibrated = calibrate(prepared)
    motion = admit_motion(calibrated)
    id = service_id(3)

    completion = %{
      "state" => "uncertain",
      "code" => "reboot_interrupted",
      "steps_executed" => nil
    }

    assert {:ok, patch, :service} =
             Durable.rebase(motion, {:service_complete, id, completion, :service})

    assert {:error, :invalid_store} =
             Durable.advance(motion, %{patch | "expected_service_revision" => 2}, @config)

    assert {:error, :invalid_store} =
             Durable.advance(motion, %{patch | "operation_id" => service_id(2)}, @config)

    assert {:error, :invalid_store} =
             Durable.advance(
               motion,
               put_in(patch, ["service_after", "service_epoch"], 2),
               @config
             )

    settled = advance(motion, patch)
    assert settled["service"]["inflight_motion"] == nil
    assert settled["service"]["service_revision"] == 3
    assert Durable.receipt(settled, id)["completion"] == completion

    success = %{"state" => "complete", "code" => "ok", "steps_executed" => 10}

    assert {:error, :invalid_store} =
             Durable.advance(settled, %{patch | "completion" => success}, @config)

    assert :skip = Durable.rebase(settled, {:service_complete, id, success, :service})
  end

  test "store validation rejects missing, mismatched, or unapproved durable identities and fields" do
    document = prepare(initial())
    assert :ok = Durable.validate(document, @config)

    for corrupt <- [
          Map.delete(document, "absent_reconciliation"),
          put_in(document, ["service", "storage_version"], 2),
          %{
            document
            | "last_operation_id" => "store_0000000000000002_" <> String.duplicate("a", 32)
          },
          put_in(
            document,
            ["service_receipts", Access.at(0), "decision", "data", "secret"],
            "unexpected"
          )
        ] do
      assert {:error, :invalid_store} = Durable.validate(corrupt, @config)
    end

    assert {:error, :invalid_store} =
             Durable.validate(document, %{@config | instance_id: "other"})
  end

  test "receipt eviction preserves the service high-water mark and the independent journal" do
    accepted = entry()
    initial = advance(initial(), accept_patch(accepted))

    document =
      Enum.reduce(1..65, initial, fn revision, current ->
        service = %{
          current["service"]
          | "service_revision" => revision,
            "entry_operation_id" => service_id(revision),
            "stop_reason" => "maintenance"
        }

        advance(
          current,
          admission(receipt(revision, "stop", "ok", %{"service_epoch" => 1}), service)
        )
      end)

    assert document["service"]["service_revision"] == 65
    assert document["store_revision"] == 66
    assert document["journal"] == [accepted]
    assert Durable.receipt(document, service_id(1)) == nil

    assert Enum.map(document["service_receipts"], & &1["resulting_revision"]) ==
             Enum.to_list(2..65)

    assert {:error, :invalid_store} =
             Durable.advance(
               document,
               admission(receipt(1, "stop", "ok", %{"service_epoch" => 1}), document["service"]),
               @config
             )
  end

  test "partial erasure requires committed matching authorization and preserves the absent acknowledgement copy" do
    document = acknowledged_absent()
    document = advance(document, accept_patch(entry()))

    document =
      advance(document, outcome_patch("command", outcome("motion_complete", nil, "complete")))

    id = service_id(4)
    absent = document["absent_reconciliation"]

    copy = %{
      "intent" => absent["intent"],
      "local_record_id" => "absent_record",
      "recovery_id" => "recovery",
      "recovery_generation" => 1,
      "service_epoch" => 1,
      "seal_operation_id" => service_id(2),
      "seal_binding" => @binding,
      "disposition_id" => "disposition",
      "host_close_request_id" => "close",
      "status_seq" => 8,
      "acknowledgement_operation_id" => service_id(3),
      "operator_id" => "operator"
    }

    clear = %{
      "entries" => [copy],
      "header" => %{
        "storage_version" => 1,
        "clear_operation_id" => id,
        "pre_clear_box_boot_id" => "boot2",
        "pre_clear_session_id" => "recovery_session",
        "service_epoch" => 1,
        "retained_host_history" => true,
        "entry_count" => 1,
        "phase" => "prepared",
        "fence_binding" => nil,
        "exit_operation_id" => nil
      }
    }

    service = %{document["service"] | "clear_operation_id" => id, "service_revision" => 4}

    receipt =
      receipt(4, "history.clear", "pending", %{
        "clear_operation_id" => id,
        "reboot_required" => true
      })

    admit = %{
      admission(receipt, service)
      | "clear_authorization" => %{"op" => "set", "record" => clear}
    }

    prepared = advance(document, admit)
    assert {:ok, erase, :clear} = Durable.clear_work(prepared)

    assert {:error, :invalid_store} = Durable.advance(document, erase, @config)

    assert {:error, :invalid_store} =
             Durable.advance(prepared, %{erase | "absent_local_record_id" => "another"}, @config)

    assert {:error, :invalid_store} =
             Durable.advance(prepared, put_in(erase, ["clear_after", "entries"], []), @config)

    assert {:error, :invalid_store} =
             Durable.advance(prepared, %{erase | "service_after" => service}, @config)

    assert {:error, :invalid_store} =
             Durable.advance(prepared, %{erase | "command_ids" => []}, @config)

    partial = %{
      erase
      | "absent_local_record_id" => nil,
        "service_after" => service,
        "clear_after" => put_in(clear, ["header", "phase"], "erasing")
    }

    half_erased = advance(prepared, partial)
    assert half_erased["journal"] == []
    assert half_erased["absent_reconciliation"] == absent
    assert half_erased["service"]["active_local_record_id"] == "absent_record"

    assert {:ok, resume_erase, :clear} = Durable.clear_work(half_erased)
    erased = advance(half_erased, resume_erase)
    assert erased["service"] == %{service | "active_local_record_id" => nil}
    assert erased["absent_reconciliation"] == nil
    assert erased["clear_authorization"] == put_in(clear, ["header", "phase"], "awaiting_fence")
    assert erased["service_receipts"] == prepared["service_receipts"]
    assert erased["simulator_configuration"] == prepared["simulator_configuration"]
  end

  defp advance(document, patch) do
    assert {:ok, _operation, next} = Durable.advance(document, patch, @config)
    next
  end

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

  defp entry do
    %{
      "schema_version" => 1,
      "command_id" => "command",
      "fingerprint" => @fingerprint,
      "reserved_arm_id" => "arm",
      "accepted_boot_id" => "boot",
      "accept_operation_id" => "accepted",
      "outcomes" => [outcome("accepted", nil, "accepted")],
      "conflicted" => false
    }
  end

  defp outcome(kind, code, operation),
    do: %{
      "kind" => kind,
      "failure_code" => code,
      "operation_id" => operation,
      "boot_id" => "boot"
    }

  defp accept_patch(entry), do: %{"kind" => "accept", "entry" => entry}

  defp outcome_patch(id, outcome),
    do: %{"kind" => "outcome", "command_id" => id, "outcome" => outcome}

  defp service_id(sequence) do
    prefix = sequence |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(16, "0")
    "svc_" <> prefix <> "_" <> String.duplicate("a", 32)
  end

  defp receipt(revision, command, status, additions) do
    id = service_id(revision)

    %{
      "storage_version" => 1,
      "operation_id" => id,
      "request_sha256" => String.duplicate("a", 64),
      "expected_revision" => revision - 1,
      "resulting_revision" => revision,
      "command" => command,
      "decision" => %{
        "status" => status,
        "code" => "ok",
        "data" => Map.merge(additions, %{"operation_id" => id, "resulting_revision" => revision})
      },
      "completion" => nil
    }
  end

  defp admission(receipt, service) do
    %{
      "kind" => "service_admit",
      "expected_service_revision" => receipt["expected_revision"],
      "service_after" => service,
      "reconciliation" => @keep,
      "absent_reconciliation" => @keep,
      "clear_authorization" => @keep,
      "simulator_configuration" => @keep,
      "receipt" => receipt
    }
  end

  defp prepare(document) do
    service = %{
      document["service"]
      | "service_revision" => 1,
        "motion_frozen" => false,
        "preparation_operation_id" => service_id(1)
    }

    advance(document, admission(receipt(1, "service.prepare", "ok", %{}), service))
  end

  defp calibrate(document) do
    service = %{document["service"] | "service_revision" => 2}
    receipt = receipt(2, "calibration.set", "ok", %{"calibration_revision" => 1})

    config = %{
      "schema_version" => 1,
      "calibration_revision" => 1,
      "calibration" => Durable.calibration()
    }

    advance(document, %{
      admission(receipt, service)
      | "simulator_configuration" => %{"op" => "set", "record" => config}
    })
  end

  defp admit_motion(document) do
    id = service_id(3)

    motion = %{
      "operation_id" => id,
      "command" => "motion.jog",
      "admission_box_boot_id" => "boot",
      "service_epoch" => 1,
      "calibration_revision" => 1,
      "reference_revision" => 0,
      "binding" => nil,
      "direction" => "forward",
      "max_steps" => 10,
      "rate_steps_s" => 50,
      "timeout_ms" => 1000,
      "home_sensor_id" => nil
    }

    service = %{document["service"] | "service_revision" => 3, "inflight_motion" => motion}

    advance(
      document,
      admission(receipt(3, "motion.jog", "pending", %{"motion_operation_id" => id}), service)
    )
  end

  defp acknowledged_absent do
    initial = initial()

    record = %{
      "storage_version" => 1,
      "local_record_id" => "absent_record",
      "recovery_id" => "recovery",
      "recovery_generation" => 1,
      "host_request_id" => "prepare",
      "recovery_session_id" => "recovery_session",
      "service_epoch" => 1,
      "entry_operation_id" => service_id(1),
      "entry_box_boot_id" => "boot1",
      "journal_observation" => "not_present_current_journal",
      "observed_outcome" => nil,
      "intent" => %{
        "game_id" => "game",
        "command_id" => "absent_command",
        "intended_box_id" => "box",
        "original_session_id" => "original",
        "original_round_id" => 1,
        "fingerprint" => @fingerprint
      },
      "operator" => @operator,
      "seal" => nil,
      "acknowledgement" => nil,
      "replacement" => nil
    }

    service = %{
      initial["service"]
      | "service_revision" => 1,
        "entry_operation_id" => service_id(1),
        "stop_reason" => "recovery",
        "motion_frozen" => false,
        "preparation_operation_id" => service_id(1),
        "active_local_record_id" => "absent_record"
    }

    enter =
      receipt(1, "recovery.enter", "ok", %{
        "service_epoch" => 1,
        "local_record_id" => "absent_record"
      })

    entered = advance(initial, with_absent(admission(enter, service), record))

    record = %{
      record
      | "seal" => %{
          "operation_id" => service_id(2),
          "binding" => @binding,
          "operator" => @operator
        }
    }

    service = %{
      service
      | "service_revision" => 2,
        "motion_frozen" => true,
        "preparation_operation_id" => nil
    }

    seal =
      receipt(2, "recovery.seal", "ok", %{
        "seal_operation_id" => service_id(2),
        "local_record_id" => "absent_record"
      })

    sealed = advance(entered, with_absent(admission(seal, service), record))

    record = %{
      record
      | "acknowledgement" => %{
          "operation_id" => service_id(3),
          "disposition_id" => "disposition",
          "host_request_id" => "close",
          "status_seq" => 8,
          "operator" => @operator
        }
    }

    service = %{service | "service_revision" => 3}

    ack =
      receipt(3, "recovery.attest_disposition", "ok", %{
        "acknowledgement_operation_id" => service_id(3),
        "disposition_id" => "disposition",
        "local_record_id" => "absent_record"
      })

    advance(sealed, with_absent(admission(ack, service), record))
  end

  defp with_absent(patch, record),
    do: %{patch | "absent_reconciliation" => %{"op" => "upsert", "record" => record}}
end
