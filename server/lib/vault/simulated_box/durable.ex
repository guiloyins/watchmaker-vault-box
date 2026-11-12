defmodule Vault.SimulatedBox.Model.Durable do
  @moduledoc false

  alias Vault.JSON

  @maximum 9_007_199_254_740_991
  @keep %{"op" => "keep"}
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

  @root_fields ~w(schema_version instance_id device_id store_revision last_operation_id journal
                   service reconciliations absent_reconciliation clear_authorization service_receipts
                   simulator_configuration)
  @service_fields ~w(storage_version service_revision service_epoch service_inhibited motion_frozen
                     entry_operation_id preparation_operation_id exit_operation_id stop_reason
                     active_local_record_id clear_operation_id provisioning_operation_id
                     provisioning_reboot_required inflight_motion)
  @entry_fields ~w(schema_version command_id fingerprint reserved_arm_id accepted_boot_id
                   accept_operation_id outcomes conflicted)
  @record_fields ~w(storage_version local_record_id intent recovery_id recovery_generation
                    host_request_id recovery_session_id service_epoch entry_operation_id
                    entry_box_boot_id journal_observation observed_outcome operator seal acknowledgement replacement)
  @clear_header_fields ~w(storage_version clear_operation_id pre_clear_box_boot_id pre_clear_session_id
                          service_epoch retained_host_history entry_count phase fence_binding exit_operation_id)
  @clear_entry_fields ~w(intent local_record_id recovery_id recovery_generation service_epoch seal_operation_id
                         seal_binding disposition_id host_close_request_id status_seq
                         acknowledgement_operation_id operator_id)
  @receipt_fields ~w(storage_version operation_id request_sha256 expected_revision resulting_revision
                      command decision completion)
  @admit_fields ~w(kind expected_service_revision service_after reconciliation absent_reconciliation
                     clear_authorization receipt simulator_configuration)
  @complete_fields ~w(kind operation_id expected_service_revision service_after completion)
  @erase_fields ~w(kind clear_operation_id command_ids local_record_ids absent_local_record_id
                     service_after clear_after)
  @service_commands ~w(stop reboot recovery.enter recovery.seal recovery.attest_disposition
                       recovery.attest_replacement service.prepare history.clear history.fence service.exit
                       calibration.set reference.set position.confirm motion.jog motion.relock
                       motion.release_test motion.stop)
  @recovery_updates ~w(recovery.enter recovery.seal recovery.attest_disposition recovery.attest_replacement)
  @motion_commands ~w(motion.jog motion.relock motion.release_test)
  @uncertain ~w(connection_lost reboot_interrupted freshness_lost)
  @failed ~w(travel_timeout limit_fault driver_fault)

  def calibration, do: @calibration
  def keep, do: @keep

  def calibration_revision(durable),
    do: durable["simulator_configuration"]["calibration_revision"]

  def id?(value) when is_binary(value), do: Regex.match?(~r/\A[A-Za-z0-9_-]{1,64}\z/, value)
  def id?(_value), do: false
  def nonnegative?(value), do: is_integer(value) and value in 0..@maximum
  def positive?(value), do: is_integer(value) and value in 1..@maximum

  def fields?(map, fields) when is_map(map) and not is_struct(map),
    do: map_size(map) == length(fields) and Enum.all?(fields, &Map.has_key?(map, &1))

  def fields?(_value, _fields), do: false

  def sequence(value) when is_binary(value) do
    case value do
      <<"svc_", number::binary-size(16), "_", suffix::binary-size(32)>> ->
        if lower_hex?(number, 16) and lower_hex?(suffix, 32) do
          {sequence, ""} = Integer.parse(number, 16)
          if positive?(sequence), do: sequence
        end

      _ ->
        nil
    end
  end

  def sequence(_value), do: nil

  defp service_id?(value), do: not is_nil(sequence(value))

  defp store_id?(id, 0), do: id?(id)

  defp store_id?(<<"store_", number::binary-size(16), "_", suffix::binary-size(32)>>, revision) do
    lower_hex?(number, 16) and lower_hex?(suffix, 32) and
      Integer.parse(number, 16) == {revision, ""}
  end

  defp store_id?(_id, _revision), do: false

  defp lower_hex?(value, size) when is_binary(value) and byte_size(value) == size,
    do: Regex.match?(~r/\A[0-9a-f]+\z/, value)

  defp lower_hex?(_value, _size), do: false

  def fingerprint?(
        %{"session_id" => session, "action" => "set_latch", "target" => "released"} = value
      )
      when map_size(value) == 3,
      do: id?(session)

  def fingerprint?(_value), do: false

  def intent?(value) do
    fields?(
      value,
      ~w(game_id command_id intended_box_id original_session_id original_round_id fingerprint)
    ) and
      ids?(value, ~w(game_id command_id intended_box_id original_session_id)) and
      positive?(value["original_round_id"]) and fingerprint?(value["fingerprint"]) and
      value["original_session_id"] == value["fingerprint"]["session_id"]
  end

  def service_binding?(value) do
    fields?(value, ~w(box_boot_id connection_id current_session_id)) and
      ids?(value, ~w(box_boot_id connection_id current_session_id))
  end

  def operator?(value) do
    fields?(value, ~w(operator_id observation)) and id?(value["operator_id"]) and
      is_binary(value["observation"]) and byte_size(value["observation"]) <= 256 and
      String.valid?(value["observation"]) and
      not Regex.match?(~r/[\x{0000}-\x{001F}\x{007F}-\x{009F}]/u, value["observation"])
  end

  defp ids?(map, keys), do: Enum.all?(keys, &id?(map[&1]))
  defp service_ids?(map, keys), do: Enum.all?(keys, &service_id?(map[&1]))
  defp optional(nil, _validator), do: true
  defp optional(value, validator), do: validator.(value)

  def hash(value) do
    case JSON.canonical(value) do
      {:ok, bytes} -> {:ok, :crypto.hash(:sha256, bytes)}
      {:error, _} -> {:error, :invalid_store}
    end
  end

  def digest_prefix(value) do
    {:ok, <<prefix::binary-size(16), _::binary>>} = hash(value)
    Base.encode16(prefix, case: :lower)
  end

  def digest_hex(value) do
    {:ok, hash} = hash(value)
    Base.encode16(hash, case: :lower)
  end

  defp sized?(value, max) do
    case JSON.canonical(value) do
      {:ok, encoded} -> byte_size(encoded) <= max
      {:error, _} -> false
    end
  end

  def journal_entry(durable, id), do: Enum.find(durable["journal"], &(&1["command_id"] == id))

  def receipt(durable, id),
    do: Enum.find(durable["service_receipts"], &(&1["operation_id"] == id))

  def recovery_records(durable) do
    case durable["absent_reconciliation"] do
      nil -> durable["reconciliations"]
      record -> durable["reconciliations"] ++ [record]
    end
  end

  def reconciliation(durable, id),
    do: Enum.find(recovery_records(durable), &(&1["local_record_id"] == id))

  def observed_outcome(entry) do
    Enum.find(entry["outcomes"], &(&1["kind"] == "uncertain")) || List.last(entry["outcomes"])
  end

  def unfinished?(%{"outcomes" => [%{"kind" => "accepted"}]}), do: true
  def unfinished?(_entry), do: false

  def validate(document, config) do
    if fields?(document, @root_fields) and document["schema_version"] == 1 and
         document["device_id"] == config.device_id and
         document["instance_id"] == config.instance_id and
         nonnegative?(document["store_revision"]) and
         store_id?(document["last_operation_id"], document["store_revision"]) and
         depth?(document, 12) and valid_records?(document) and sized?(document, 524_288) do
      :ok
    else
      {:error, :invalid_store}
    end
  end

  defp depth?(value, remaining) when is_map(value) and remaining > 0,
    do: Enum.all?(value, fn {_key, child} -> depth?(child, remaining - 1) end)

  defp depth?(value, remaining) when is_list(value) and remaining > 0,
    do: Enum.all?(value, &depth?(&1, remaining - 1))

  defp depth?(value, _remaining), do: not is_map(value) and not is_list(value)

  defp valid_records?(document) do
    records = document["reconciliations"]
    journal = document["journal"]
    service = document["service"]
    receipts = document["service_receipts"]
    clear = document["clear_authorization"]

    bounded_records?(journal, 32, "command_id", &journal_valid?/1) and
      service_valid?(service) and service["service_revision"] <= document["store_revision"] and
      configuration_valid?(document["simulator_configuration"]) and
      bounded_records?(records, 32, "local_record_id", &reconciliation_valid?/1) and
      optional(document["absent_reconciliation"], &reconciliation_valid?/1) and
      optional(clear, &clear_valid?/1) and
      bounded_records?(receipts, 64, "operation_id", &receipt_valid?/1) and
      recovery_links?(document) and receipt_links?(document) and clear_links?(document) and
      root_size?(document)
  end

  defp bounded_records?(list, max, field, validator) do
    is_list(list) and length(list) <= max and Enum.all?(list, validator) and unique?(list, field)
  end

  defp unique?(records, field), do: Enum.uniq_by(records, & &1[field]) == records

  defp root_size?(document) do
    root =
      Map.drop(
        document,
        ~w(journal reconciliations absent_reconciliation clear_authorization service_receipts)
      )

    sized?(root, 16_384)
  end

  defp configuration_valid?(value) do
    fields?(value, ~w(schema_version calibration_revision calibration)) and
      value["schema_version"] == 1 and
      ((value["calibration_revision"] == 0 and is_nil(value["calibration"])) or
         (positive?(value["calibration_revision"]) and value["calibration"] == @calibration)) and
      sized?(value, 4_096)
  end

  defp journal_valid?(entry) do
    fields?(entry, @entry_fields) and entry["schema_version"] == 1 and
      ids?(entry, ~w(command_id reserved_arm_id accepted_boot_id accept_operation_id)) and
      fingerprint?(entry["fingerprint"]) and is_boolean(entry["conflicted"]) and
      bounded_records?(entry["outcomes"], 4, "kind", &outcome_valid?/1) and
      valid_acceptance?(entry) and sized?(entry, 2_048)
  end

  defp valid_acceptance?(%{"outcomes" => [%{"kind" => "accepted"} = accepted | rest]} = entry) do
    accepted["operation_id"] == entry["accept_operation_id"] and
      accepted["boot_id"] == entry["accepted_boot_id"] and
      entry["conflicted"] == length(rest) >= 2
  end

  defp valid_acceptance?(_entry), do: false

  defp outcome_valid?(value) do
    fields?(value, ~w(kind failure_code operation_id boot_id)) and
      ids?(value, ~w(operation_id boot_id)) and
      case {value["kind"], value["failure_code"]} do
        {kind, nil} when kind in ["accepted", "motion_complete"] -> true
        {"uncertain", code} -> code in @uncertain
        {"failed", code} -> code in @failed
        _ -> false
      end
  end

  defp service_valid?(value) do
    fields?(value, @service_fields) and value["storage_version"] == 1 and
      nonnegative?(value["service_revision"]) and positive?(value["service_epoch"]) and
      is_boolean(value["service_inhibited"]) and is_boolean(value["motion_frozen"]) and
      Enum.all?(
        ~w(entry_operation_id preparation_operation_id exit_operation_id clear_operation_id),
        &optional(value[&1], fn id ->
          service_id?(id) and sequence(id) <= value["service_revision"]
        end)
      ) and
      value["stop_reason"] in [nil, "maintenance", "lost_host_key", "history_clear", "recovery"] and
      optional(value["active_local_record_id"], &id?/1) and
      is_nil(value["provisioning_operation_id"]) and
      value["provisioning_reboot_required"] == false and
      optional(value["inflight_motion"], &service_motion_valid?/1) and service_mode_valid?(value) and
      sized?(value, 4_096)
  end

  defp service_mode_valid?(service) do
    cond do
      service["motion_frozen"] ->
        service["service_inhibited"] and is_nil(service["preparation_operation_id"]) and
          is_nil(service["inflight_motion"])

      service["service_inhibited"] ->
        service_id?(service["preparation_operation_id"])

      true ->
        service_id?(service["preparation_operation_id"]) and
          service_id?(service["exit_operation_id"]) and
          is_nil(service["inflight_motion"])
    end
  end

  defp service_motion_valid?(motion) do
    fields?(
      motion,
      ~w(operation_id command admission_box_boot_id service_epoch calibration_revision
                        reference_revision binding direction max_steps rate_steps_s timeout_ms home_sensor_id)
    ) and
      service_id?(motion["operation_id"]) and id?(motion["admission_box_boot_id"]) and
      motion["command"] in ~w(motion.jog motion.relock motion.release_test) and
      positive?(motion["service_epoch"]) and positive?(motion["calibration_revision"]) and
      nonnegative?(motion["reference_revision"]) and
      optional(motion["binding"], &service_binding?/1) and
      motion["direction"] in ~w(forward reverse) and
      integer_between?(motion["max_steps"], 1, 100) and
      integer_between?(motion["rate_steps_s"], 1, 100) and
      integer_between?(motion["timeout_ms"], 1, 8_000) and is_nil(motion["home_sensor_id"])
  end

  defp integer_between?(value, min, max), do: is_integer(value) and value >= min and value <= max

  defp reconciliation_valid?(record) do
    fields?(record, @record_fields) and record["storage_version"] == 1 and
      intent?(record["intent"]) and
      ids?(
        record,
        ~w(local_record_id recovery_id host_request_id recovery_session_id entry_box_boot_id)
      ) and
      positive?(record["recovery_generation"]) and positive?(record["service_epoch"]) and
      service_id?(record["entry_operation_id"]) and operator?(record["operator"]) and
      valid_observation?(record) and optional(record["seal"], &seal_valid?/1) and
      optional(record["acknowledgement"], &ack_valid?/1) and
      optional(record["replacement"], &replacement_valid?/1) and
      (is_nil(record["acknowledgement"]) or not is_nil(record["seal"])) and sized?(record, 4_096)
  end

  defp valid_observation?(%{"journal_observation" => "present", "observed_outcome" => outcome}),
    do: outcome in ~w(accepted motion_complete uncertain failed)

  defp valid_observation?(%{
         "journal_observation" => "not_present_current_journal",
         "observed_outcome" => nil
       }),
       do: true

  defp valid_observation?(_record), do: false

  defp seal_valid?(value) do
    fields?(value, ~w(operation_id binding operator)) and service_id?(value["operation_id"]) and
      service_binding?(value["binding"]) and operator?(value["operator"])
  end

  defp ack_valid?(value) do
    fields?(value, ~w(operation_id disposition_id host_request_id status_seq operator)) and
      service_id?(value["operation_id"]) and ids?(value, ~w(disposition_id host_request_id)) and
      positive?(value["status_seq"]) and operator?(value["operator"])
  end

  defp replacement_valid?(value) do
    fields?(
      value,
      ~w(operation_id prior_recovery_id prior_recovery_generation prior_seal_operation_id)
    ) and
      service_id?(value["operation_id"]) and id?(value["prior_recovery_id"]) and
      positive?(value["prior_recovery_generation"]) and
      optional(value["prior_seal_operation_id"], &service_id?/1)
  end

  defp clear_valid?(value) do
    fields?(value, ~w(header entries)) and clear_header_valid?(value["header"]) and
      bounded_records?(value["entries"], 33, "local_record_id", &clear_entry_valid?/1) and
      length(value["entries"]) == value["header"]["entry_count"] and sized?(value, 98_304)
  end

  defp clear_header_valid?(header) do
    fields?(header, @clear_header_fields) and header["storage_version"] == 1 and
      service_id?(header["clear_operation_id"]) and
      ids?(header, ~w(pre_clear_box_boot_id pre_clear_session_id)) and
      positive?(header["service_epoch"]) and
      header["retained_host_history"] == true and integer_between?(header["entry_count"], 0, 33) and
      case header["phase"] do
        phase when phase in ~w(prepared erasing awaiting_fence) ->
          is_nil(header["fence_binding"]) and is_nil(header["exit_operation_id"])

        phase when phase in ~w(fence_complete preparing exited) ->
          service_binding?(header["fence_binding"]) and
            header["fence_binding"]["box_boot_id"] != header["pre_clear_box_boot_id"] and
            header["fence_binding"]["current_session_id"] != header["pre_clear_session_id"] and
            if(phase == "exited",
              do: service_id?(header["exit_operation_id"]),
              else: is_nil(header["exit_operation_id"])
            )

        _ ->
          false
      end
  end

  defp clear_entry_valid?(entry) do
    fields?(entry, @clear_entry_fields) and intent?(entry["intent"]) and
      ids?(
        entry,
        ~w(local_record_id recovery_id disposition_id host_close_request_id operator_id)
      ) and
      service_ids?(entry, ~w(seal_operation_id acknowledgement_operation_id)) and
      Enum.all?(~w(recovery_generation service_epoch status_seq), &positive?(entry[&1])) and
      service_binding?(entry["seal_binding"]) and sized?(entry, 2_048)
  end

  defp receipt_valid?(receipt) do
    fields?(receipt, @receipt_fields) and receipt["storage_version"] == 1 and
      lower_hex?(receipt["request_sha256"], 64) and
      nonnegative?(receipt["expected_revision"]) and positive?(receipt["resulting_revision"]) and
      receipt["resulting_revision"] == receipt["expected_revision"] + 1 and
      sequence(receipt["operation_id"]) == receipt["resulting_revision"] and
      receipt["command"] in @service_commands and decision_valid?(receipt["decision"], receipt) and
      (is_nil(receipt["completion"]) or
         (receipt["decision"]["status"] == "pending" and completion_valid?(receipt["completion"]))) and
      sized?(receipt, 3_072)
  end

  defp decision_valid?(decision, receipt) do
    command = receipt["command"]
    status = if command in ["history.clear" | @motion_commands], do: "pending", else: "ok"

    fields?(decision, ~w(status code data)) and decision["status"] == status and
      decision["code"] == "ok" and is_map(decision["data"]) and not is_struct(decision["data"]) and
      decision["data"]["operation_id"] == receipt["operation_id"] and
      decision["data"]["resulting_revision"] == receipt["resulting_revision"] and
      decision_data_valid?(
        Map.drop(decision["data"], ~w(operation_id resulting_revision)),
        command,
        receipt
      ) and
      sized?(decision, 2_048)
  end

  defp decision_data_valid?(%{"service_epoch" => epoch} = data, command, _receipt)
       when command in ~w(stop motion.stop),
       do: map_size(data) == 1 and positive?(epoch)

  defp decision_data_valid?(
         %{"local_record_id" => id, "service_epoch" => epoch} = data,
         "recovery.enter",
         _receipt
       ),
       do: map_size(data) == 2 and id?(id) and positive?(epoch)

  defp decision_data_valid?(
         %{"local_record_id" => id, "seal_operation_id" => operation} = data,
         "recovery.seal",
         receipt
       ),
       do: map_size(data) == 2 and id?(id) and operation == receipt["operation_id"]

  defp decision_data_valid?(
         %{
           "local_record_id" => id,
           "disposition_id" => disposition,
           "acknowledgement_operation_id" => operation
         } = data,
         "recovery.attest_disposition",
         receipt
       ),
       do:
         map_size(data) == 3 and id?(id) and id?(disposition) and
           operation == receipt["operation_id"]

  defp decision_data_valid?(
         %{
           "local_record_id" => id,
           "recovery_id" => recovery,
           "recovery_generation" => generation
         } = data,
         "recovery.attest_replacement",
         _receipt
       ),
       do: map_size(data) == 3 and id?(id) and id?(recovery) and positive?(generation)

  defp decision_data_valid?(
         %{"clear_operation_id" => operation, "reboot_required" => true} = data,
         "history.clear",
         receipt
       ),
       do: map_size(data) == 2 and operation == receipt["operation_id"]

  defp decision_data_valid?(
         %{"clear_operation_id" => operation, "fence_complete" => true} = data,
         "history.fence",
         _receipt
       ),
       do: map_size(data) == 2 and service_id?(operation)

  defp decision_data_valid?(
         %{"service_epoch" => epoch, "exited" => true} = data,
         "service.exit",
         _receipt
       ),
       do: map_size(data) == 2 and positive?(epoch)

  defp decision_data_valid?(
         %{"calibration_revision" => revision} = data,
         "calibration.set",
         _receipt
       ),
       do: map_size(data) == 1 and positive?(revision)

  defp decision_data_valid?(%{"reference_revision" => revision} = data, "reference.set", receipt),
    do: map_size(data) == 1 and revision == receipt["resulting_revision"]

  defp decision_data_valid?(
         %{"modeled_position" => position, "position" => "unknown", "basis" => "unverified"} =
           data,
         "position.confirm",
         _receipt
       ),
       do: map_size(data) == 3 and position in ~w(locked released)

  defp decision_data_valid?(%{"motion_operation_id" => operation} = data, command, receipt)
       when command in @motion_commands,
       do: map_size(data) == 1 and operation == receipt["operation_id"]

  defp decision_data_valid?(data, "reboot", _receipt), do: data == %{"reboot_required" => true}
  defp decision_data_valid?(data, "service.prepare", _receipt), do: data == %{}
  defp decision_data_valid?(_data, _command, _receipt), do: false

  defp valid_completion_code?("complete", "ok"), do: true

  defp valid_completion_code?("uncertain", code),
    do: code in ~w(stopped reboot_interrupted freshness_lost storage_error commit_uncertain)

  defp valid_completion_code?("failed", code), do: code in (@failed ++ ~w(storage_error))
  defp valid_completion_code?(_state, _code), do: false

  defp completion_valid?(completion) do
    fields?(completion, ~w(state code steps_executed)) and
      valid_completion_code?(completion["state"], completion["code"]) and
      optional(completion["steps_executed"], &integer_between?(&1, 0, 100))
  end

  defp recovery_links?(document) do
    all = recovery_records(document)
    absent = document["absent_reconciliation"]
    device = document["device_id"]
    service = document["service"]

    unique?(all, "local_record_id") and
      (is_nil(service["active_local_record_id"]) or
         Enum.any?(all, &(&1["local_record_id"] == service["active_local_record_id"]))) and
      Enum.all?(all, fn record ->
        acknowledged?(record) or
          (service["service_inhibited"] and
             record["local_record_id"] == service["active_local_record_id"] and
             (is_nil(record["seal"]) or service["motion_frozen"]))
      end) and
      Enum.all?(all, fn record ->
        record["intent"]["intended_box_id"] == device and
          record["service_epoch"] <= service["service_epoch"] and
          recovery_identity_links?(record, service["service_revision"]) and
          retained_operation?(document, record["entry_operation_id"], ["recovery.enter"]) and
          retained_operation?(document, record["seal"]["operation_id"], ["recovery.seal"]) and
          retained_operation?(document, record["acknowledgement"]["operation_id"], [
            "recovery.attest_disposition"
          ]) and
          retained_operation?(document, record["replacement"]["operation_id"], [
            "recovery.attest_replacement"
          ])
      end) and
      Enum.all?(document["reconciliations"], fn record ->
        entry = journal_entry(document, record["intent"]["command_id"])

        (record["journal_observation"] == "present" and entry) &&
          record["intent"]["fingerprint"] == entry["fingerprint"]
      end) and
      Enum.uniq_by(document["reconciliations"], & &1["intent"]["command_id"]) ==
        document["reconciliations"] and
      (is_nil(absent) or
         (absent["journal_observation"] == "not_present_current_journal" and
            is_nil(journal_entry(document, absent["intent"]["command_id"]))))
  end

  defp recovery_identity_links?(record, revision) do
    entry = sequence(record["entry_operation_id"])
    seal = record["seal"]
    seal_seq = sequence(seal["operation_id"])
    ack_seq = sequence(record["acknowledgement"]["operation_id"])
    replacement = record["replacement"]
    replacement_seq = sequence(replacement["operation_id"])

    entry <= revision and
      (is_nil(replacement) or
         (entry < replacement_seq and replacement_seq <= revision and
            replacement["prior_recovery_generation"] + 1 == record["recovery_generation"] and
            replacement["prior_recovery_id"] != record["recovery_id"])) and
      (is_nil(seal) or
         ((replacement_seq || entry) < seal_seq and seal_seq <= revision and
            seal["binding"]["current_session_id"] == record["recovery_session_id"] and
            seal["binding"]["box_boot_id"] != record["entry_box_boot_id"])) and
      (is_nil(ack_seq) or (seal_seq < ack_seq and ack_seq <= revision))
  end

  defp receipt_links?(document) do
    service = document["service"]
    revision = service["service_revision"]
    receipts = document["service_receipts"]
    count = min(revision, 64)
    expected = if count == 0, do: [], else: Enum.to_list((revision - count + 1)..revision)
    motion = service["inflight_motion"]
    clear_operation = document["clear_authorization"]["header"]["clear_operation_id"]

    Enum.map(receipts, & &1["resulting_revision"]) == expected and
      retained_operation?(
        document,
        service["entry_operation_id"],
        ~w(stop motion.stop recovery.enter)
      ) and
      retained_operation?(
        document,
        service["preparation_operation_id"],
        ~w(service.prepare recovery.enter recovery.attest_replacement)
      ) and
      retained_operation?(document, service["exit_operation_id"], ["service.exit"]) and
      retained_operation?(document, clear_operation, ["history.clear"]) and
      Enum.all?(receipts, fn receipt ->
        if receipt["decision"]["status"] == "pending" and is_nil(receipt["completion"]) do
          if receipt["command"] == "history.clear",
            do: receipt["operation_id"] == clear_operation,
            else: receipt["operation_id"] == motion["operation_id"]
        else
          true
        end
      end) and
      (is_nil(motion) or
         case receipt(document, motion["operation_id"]) do
           %{"command" => command, "completion" => nil, "decision" => %{"status" => "pending"}} ->
             command == motion["command"] and
               motion["service_epoch"] == document["service"]["service_epoch"] and
               motion["calibration_revision"] == calibration_revision(document)

           _ ->
             false
         end)
  end

  defp retained_operation?(_document, nil, _commands), do: true

  defp retained_operation?(document, id, commands) do
    revision = document["service"]["service_revision"]
    operation_sequence = sequence(id)

    is_integer(operation_sequence) and operation_sequence <= revision and
      (operation_sequence <= revision - 64 or
         case receipt(document, id) do
           %{"command" => command} -> command in commands
           nil -> false
         end)
  end

  defp clear_links?(document) do
    service = document["service"]

    case document["clear_authorization"] do
      nil ->
        is_nil(service["clear_operation_id"])

      %{"header" => header, "entries" => entries} ->
        header["clear_operation_id"] == service["clear_operation_id"] and
          header["service_epoch"] <= service["service_epoch"] and
          retained_operation?(document, header["exit_operation_id"], ["service.exit"]) and
          Enum.all?(entries, fn entry ->
            entry["intent"]["intended_box_id"] == document["device_id"] and
              entry["service_epoch"] <= header["service_epoch"] and
              sequence(entry["seal_operation_id"]) <
                sequence(entry["acknowledgement_operation_id"]) and
              sequence(entry["acknowledgement_operation_id"]) <
                sequence(header["clear_operation_id"]) and
              retained_operation?(document, entry["seal_operation_id"], ["recovery.seal"]) and
              retained_operation?(document, entry["acknowledgement_operation_id"], [
                "recovery.attest_disposition"
              ])
          end) and
          case header["phase"] do
            phase when phase in ~w(prepared erasing) ->
              records = recovery_records(document)

              service["service_inhibited"] and service["motion_frozen"] and
                Enum.all?(records, &copied_acknowledgement?(&1, entries)) and
                Enum.all?(document["journal"], &clear_authorizes_command?(&1, entries)) and
                (phase != "prepared" or length(records) == length(entries))

            phase when phase in ~w(awaiting_fence fence_complete) ->
              service["service_inhibited"] and service["motion_frozen"] and
                history_erased?(document)

            "preparing" ->
              service["service_inhibited"] and history_erased?(document)

            "exited" ->
              true
          end
    end
  end

  defp history_erased?(document),
    do:
      document["journal"] == [] and document["reconciliations"] == [] and
        is_nil(document["absent_reconciliation"])

  def advance(document, patch, config) do
    revision = document["store_revision"] + 1

    if positive?(revision) do
      with {:ok, updated} <- apply_patch(document, patch),
           {:ok, <<prefix::binary-size(16), _::binary>>} <-
             hash(%{
               "instance_id" => config.instance_id,
               "next_revision" => revision,
               "patch" => patch
             }) do
        operation =
          "store_" <>
            (revision
             |> Integer.to_string(16)
             |> String.downcase()
             |> String.pad_leading(16, "0")) <>
            "_" <> Base.encode16(prefix, case: :lower)

        updated = %{updated | "store_revision" => revision, "last_operation_id" => operation}

        case validate(updated, config) do
          :ok -> {:ok, operation, updated}
          error -> error
        end
      end
    else
      {:error, :counter_exhausted}
    end
  end

  defp apply_patch(document, %{"kind" => "accept", "entry" => entry} = patch)
       when map_size(patch) == 2 do
    if journal_valid?(entry) and unfinished?(entry) and length(document["journal"]) < 32 and
         is_nil(journal_entry(document, entry["command_id"])) do
      {:ok, %{document | "journal" => document["journal"] ++ [entry]}}
    else
      {:error, :invalid_store}
    end
  end

  defp apply_patch(
         document,
         %{"kind" => "outcome", "command_id" => id, "outcome" => outcome} = patch
       )
       when map_size(patch) == 3 do
    entry = journal_entry(document, id)

    if (outcome_valid?(outcome) and entry) &&
         Enum.all?(entry["outcomes"], &(&1["kind"] != outcome["kind"])) do
      outcomes = entry["outcomes"] ++ [outcome]
      updated = %{entry | "outcomes" => outcomes, "conflicted" => length(outcomes) >= 3}
      journal = Enum.map(document["journal"], &if(&1["command_id"] == id, do: updated, else: &1))
      {:ok, %{document | "journal" => journal}}
    else
      {:error, :invalid_store}
    end
  end

  defp apply_patch(document, %{"kind" => "service_admit"} = patch) do
    previous = document["service"]
    receipt = patch["receipt"]
    service = patch["service_after"]

    with true <-
           fields?(patch, @admit_fields) and receipt_valid?(receipt) and service_valid?(service),
         true <-
           receipt["completion"] == nil and
             receipt["expected_revision"] == previous["service_revision"],
         true <-
           patch["expected_service_revision"] == previous["service_revision"] and
             service["service_revision"] == receipt["resulting_revision"],
         {:ok, records, absent} <- update_reconciliations(document, patch, receipt),
         {:ok, clear} <- update_clear(document, patch["clear_authorization"], receipt),
         {:ok, configuration} <-
           update_configuration(document, patch["simulator_configuration"], receipt),
         true <- valid_service_change?(previous, service, receipt) do
      receipts = Enum.take(document["service_receipts"] ++ [receipt], -64)

      {:ok,
       %{
         document
         | "service" => service,
           "reconciliations" => records,
           "absent_reconciliation" => absent,
           "service_receipts" => receipts,
           "clear_authorization" => clear,
           "simulator_configuration" => configuration
       }}
    else
      _ -> {:error, :invalid_store}
    end
  end

  defp apply_patch(document, %{"kind" => "service_complete", "operation_id" => id} = patch) do
    service = document["service"]
    completion = patch["completion"]

    with true <- fields?(patch, @complete_fields) and completion_valid?(completion),
         true <- patch["expected_service_revision"] == service["service_revision"],
         %{"completion" => nil, "decision" => %{"status" => "pending"}} = receipt <-
           receipt(document, id),
         {:ok, service_after} <- complete_service(document, service, receipt, completion),
         true <- service_after == patch["service_after"] do
      receipts =
        Enum.map(document["service_receipts"], fn
          %{"operation_id" => ^id} = receipt -> %{receipt | "completion" => completion}
          receipt -> receipt
        end)

      {:ok, %{document | "service" => service_after, "service_receipts" => receipts}}
    else
      _ -> {:error, :invalid_store}
    end
  end

  defp apply_patch(document, %{"kind" => "erase_journal"} = patch) do
    id = patch["clear_operation_id"]
    absent = document["absent_reconciliation"]

    with true <- fields?(patch, @erase_fields),
         %{
           "header" => %{"phase" => phase, "clear_operation_id" => ^id} = header,
           "entries" => entries
         } = clear <-
           document["clear_authorization"],
         true <- phase in ~w(prepared erasing),
         {:ok, journal} <-
           erase_subset(
             document["journal"],
             "command_id",
             patch["command_ids"],
             &clear_authorizes_command?(&1, entries)
           ),
         {:ok, records} <-
           erase_subset(
             document["reconciliations"],
             "local_record_id",
             patch["local_record_ids"],
             &copied_acknowledgement?(&1, entries)
           ),
         {:ok, absent_after} <- erase_absent(absent, patch["absent_local_record_id"], entries),
         true <- made_erase_progress?(document, journal, records, absent_after),
         service_after =
           clear_active_pointer(
             document["service"],
             patch["local_record_ids"],
             patch["absent_local_record_id"]
           ),
         true <- service_after == patch["service_after"],
         next_phase =
           if(journal == [] and records == [] and is_nil(absent_after),
             do: "awaiting_fence",
             else: "erasing"
           ),
         clear_after = %{clear | "header" => %{header | "phase" => next_phase}},
         true <- clear_after == patch["clear_after"] do
      {:ok,
       %{
         document
         | "service" => service_after,
           "clear_authorization" => clear_after,
           "journal" => journal,
           "reconciliations" => records,
           "absent_reconciliation" => absent_after
       }}
    else
      _ -> {:error, :invalid_store}
    end
  end

  defp apply_patch(_document, _patch), do: {:error, :invalid_store}

  defp update_reconciliations(document, patch, receipt) do
    records = document["reconciliations"]
    absent = document["absent_reconciliation"]
    command = receipt["command"]

    case {patch["reconciliation"], patch["absent_reconciliation"]} do
      {@keep, @keep} when command not in @recovery_updates ->
        {:ok, records, absent}

      {%{"op" => "upsert", "record" => record} = change, absent_change}
      when map_size(change) == 2 and command in @recovery_updates ->
        with true <-
               valid_record_change?(document, record, "present", receipt, patch["service_after"]),
             {:ok, absent_after} <- retire_absent(absent, absent_change, command) do
          {:ok, upsert_record(records, record), absent_after}
        end

      {@keep, %{"op" => "upsert", "record" => record} = change}
      when map_size(change) == 2 and command in @recovery_updates ->
        if valid_record_change?(
             document,
             record,
             "not_present_current_journal",
             receipt,
             patch["service_after"]
           ) and
             (is_nil(absent) or absent["local_record_id"] == record["local_record_id"] or
                acknowledged?(absent)) do
          {:ok, records, record}
        else
          :error
        end

      _ ->
        :error
    end
  end

  defp retire_absent(absent, @keep, _command), do: {:ok, absent}

  defp retire_absent(
         %{"local_record_id" => id} = absent,
         %{"op" => "retire", "local_record_id" => id} = change,
         "recovery.enter"
       )
       when map_size(change) == 2 do
    if acknowledged?(absent), do: {:ok, nil}, else: :error
  end

  defp retire_absent(_absent, _change, _command), do: :error

  defp upsert_record(records, record) do
    id = record["local_record_id"]

    if Enum.any?(records, &(&1["local_record_id"] == id)) do
      Enum.map(records, &if(&1["local_record_id"] == id, do: record, else: &1))
    else
      records ++ [record]
    end
  end

  defp valid_record_change?(document, record, observation, receipt, service_after) do
    if reconciliation_valid?(record) and record["journal_observation"] == observation do
      id = record["local_record_id"]
      data = receipt["decision"]["data"]
      old = reconciliation(document, id)

      data["local_record_id"] == id and id == service_after["active_local_record_id"] and
        record["service_epoch"] == service_after["service_epoch"] and
        record_change_matches?(document, old, record, receipt)
    else
      false
    end
  end

  defp record_change_matches?(document, nil, record, %{"command" => "recovery.enter"} = receipt) do
    id = record["intent"]["command_id"]
    journal = journal_entry(document, id)
    observed = if journal, do: observed_outcome(journal)["kind"]

    Enum.all?(recovery_records(document), &(&1["intent"]["command_id"] != id)) and
      record["entry_operation_id"] == receipt["operation_id"] and
      record["service_epoch"] == receipt["decision"]["data"]["service_epoch"] and
      record["recovery_generation"] == 1 and record["observed_outcome"] == observed and
      Enum.all?(~w(seal acknowledgement replacement), &is_nil(record[&1]))
  end

  defp record_change_matches?(
         _document,
         %{} = old,
         record,
         %{"command" => "recovery.seal"} = receipt
       ) do
    seal = record["seal"]
    data = receipt["decision"]["data"]

    ((is_nil(old["acknowledgement"]) and seal) && seal["operation_id"] == receipt["operation_id"]) and
      seal["operation_id"] == data["seal_operation_id"] and
      seal["binding"]["box_boot_id"] != old["entry_box_boot_id"] and
      seal["binding"]["current_session_id"] == record["recovery_session_id"] and
      same_except?(old, record, ~w(seal recovery_session_id))
  end

  defp record_change_matches?(
         _document,
         %{} = old,
         record,
         %{"command" => "recovery.attest_disposition"} = receipt
       ) do
    ack = record["acknowledgement"]
    data = receipt["decision"]["data"]

    ((is_nil(old["acknowledgement"]) and not is_nil(old["seal"]) and ack) &&
       ack["operation_id"] == receipt["operation_id"]) and
      ack["operation_id"] == data["acknowledgement_operation_id"] and
      ack["disposition_id"] == data["disposition_id"] and
      same_except?(old, record, ~w(acknowledgement))
  end

  defp record_change_matches?(
         _document,
         %{} = old,
         record,
         %{"command" => "recovery.attest_replacement"} = receipt
       ) do
    replacement = %{
      "operation_id" => receipt["operation_id"],
      "prior_recovery_id" => old["recovery_id"],
      "prior_recovery_generation" => old["recovery_generation"],
      "prior_seal_operation_id" => old["seal"]["operation_id"]
    }

    data = receipt["decision"]["data"]

    is_nil(old["acknowledgement"]) and is_nil(record["seal"]) and
      record["replacement"] == replacement and
      record["recovery_id"] == data["recovery_id"] and record["recovery_id"] != old["recovery_id"] and
      record["recovery_generation"] == old["recovery_generation"] + 1 and
      record["recovery_generation"] == data["recovery_generation"] and
      same_except?(
        old,
        record,
        ~w(recovery_id recovery_generation host_request_id recovery_session_id
                                   entry_box_boot_id operator seal replacement)
      )
  end

  defp record_change_matches?(_document, _old, _record, _receipt), do: false

  defp same_except?(old, new, keys), do: Map.drop(old, keys) == Map.drop(new, keys)

  defp acknowledged?(record), do: not is_nil(record["acknowledgement"])

  defp update_clear(document, @keep, receipt) do
    clear = document["clear_authorization"]
    phase = clear["header"]["phase"]
    command = receipt["command"]

    if command not in ~w(history.clear history.fence) and
         (command not in ~w(service.prepare service.exit recovery.enter) or
            (phase in [nil, "exited"] and Enum.all?(recovery_records(document), &acknowledged?/1))) do
      {:ok, clear}
    else
      :error
    end
  end

  defp update_clear(document, %{"op" => "set", "record" => record} = change, receipt)
       when map_size(change) == 2 do
    if clear_valid?(record) and valid_clear_change?(document, record, receipt),
      do: {:ok, record},
      else: :error
  end

  defp update_clear(_document, _change, _receipt), do: :error

  defp valid_clear_change?(
         document,
         %{"header" => header, "entries" => entries},
         %{"command" => "history.clear"} = receipt
       ) do
    current = document["clear_authorization"]
    records = recovery_records(document)
    data = receipt["decision"]["data"]

    current["header"]["phase"] in [nil, "exited"] and header["phase"] == "prepared" and
      header["service_epoch"] == document["service"]["service_epoch"] and
      header["clear_operation_id"] == receipt["operation_id"] and
      header["clear_operation_id"] == data["clear_operation_id"] and
      Enum.all?(records, &acknowledged?/1) and entries == Enum.map(records, &clear_entry/1) and
      Enum.all?(document["journal"], &clear_authorizes_command?(&1, entries))
  end

  defp valid_clear_change?(
         %{"clear_authorization" => %{"header" => old, "entries" => entries}},
         %{"header" => new, "entries" => entries},
         receipt
       ) do
    data = receipt["decision"]["data"]

    case {receipt["command"], old["phase"], new["phase"]} do
      {"history.fence", "awaiting_fence", "fence_complete"} ->
        data["clear_operation_id"] == old["clear_operation_id"] and
          same_except?(old, new, ~w(phase fence_binding))

      {"service.prepare", phase, "preparing"} when phase in ~w(fence_complete preparing) ->
        same_except?(old, new, ~w(phase))

      {"service.exit", "preparing", "exited"} ->
        new["exit_operation_id"] == receipt["operation_id"] and
          same_except?(old, new, ~w(phase exit_operation_id))

      _ ->
        false
    end
  end

  defp valid_clear_change?(_document, _record, _receipt), do: false

  defp update_configuration(document, @keep, %{"command" => command})
       when command != "calibration.set",
       do: {:ok, document["simulator_configuration"]}

  defp update_configuration(
         document,
         %{"op" => "set", "record" => new} = change,
         %{"command" => "calibration.set"} = receipt
       )
       when map_size(change) == 2 do
    revision = calibration_revision(document) + 1

    if configuration_valid?(new) and new["calibration"] == @calibration and
         new["calibration_revision"] == revision and
         receipt["decision"]["data"]["calibration_revision"] == revision do
      {:ok, new}
    else
      :error
    end
  end

  defp update_configuration(_document, _change, _receipt), do: :error

  defp valid_service_change?(old, new, receipt) do
    operation = receipt["operation_id"]
    data = receipt["decision"]["data"]
    next = %{old | "service_revision" => receipt["resulting_revision"]}
    epoch = if old["service_inhibited"], do: old["service_epoch"], else: old["service_epoch"] + 1

    case receipt["command"] do
      command when command in ~w(stop motion.stop) ->
        reason = new["stop_reason"]

        reason in ~w(maintenance lost_host_key history_clear) and epoch == data["service_epoch"] and
          new == %{
            freeze(next)
            | "service_epoch" => epoch,
              "entry_operation_id" => operation,
              "stop_reason" => reason
          }

      "recovery.enter" ->
        epoch == data["service_epoch"] and
          new == %{
            next
            | "service_epoch" => epoch,
              "service_inhibited" => true,
              "motion_frozen" => false,
              "preparation_operation_id" => operation,
              "entry_operation_id" => operation,
              "stop_reason" => "recovery",
              "active_local_record_id" => data["local_record_id"]
          }

      "recovery.seal" ->
        old["service_inhibited"] and new == freeze(next)

      "recovery.attest_disposition" ->
        old["service_inhibited"] and old["motion_frozen"] and new == next

      "history.clear" ->
        old["service_inhibited"] and new == %{freeze(next) | "clear_operation_id" => operation}

      command when command in ~w(recovery.attest_replacement service.prepare) ->
        old["service_inhibited"] and
          new == %{next | "motion_frozen" => false, "preparation_operation_id" => operation}

      "service.exit" ->
        old["service_inhibited"] and not old["motion_frozen"] and
          old["service_epoch"] == data["service_epoch"] and
          new == %{next | "service_inhibited" => false, "exit_operation_id" => operation}

      command when command in @motion_commands ->
        motion = new["inflight_motion"]

        ((old["service_inhibited"] and not old["motion_frozen"] and is_nil(old["inflight_motion"]) and
            motion) &&
           motion["operation_id"] == operation) and motion["command"] == command and
          new == %{next | "inflight_motion" => motion}

      command when command in ~w(calibration.set reference.set position.confirm) ->
        old["service_inhibited"] and not old["motion_frozen"] and new == next

      "reboot" ->
        old["service_inhibited"] and new == next

      _ ->
        new == next
    end
  end

  defp freeze(service),
    do: %{
      service
      | "service_inhibited" => true,
        "motion_frozen" => true,
        "preparation_operation_id" => nil
    }

  defp complete_service(
         document,
         service,
         %{"command" => "history.clear", "operation_id" => id},
         completion
       ) do
    header = document["clear_authorization"]["header"]

    if header["clear_operation_id"] == id and completion["steps_executed"] == 0 and
         (completion["state"] != "complete" or header["phase"] == "awaiting_fence") do
      {:ok, service}
    else
      :error
    end
  end

  defp complete_service(
         _document,
         service,
         %{"command" => command, "operation_id" => id},
         completion
       )
       when command in @motion_commands do
    case service["inflight_motion"] do
      %{"operation_id" => ^id, "max_steps" => max_steps} ->
        if is_nil(completion["steps_executed"]) or completion["steps_executed"] <= max_steps,
          do: {:ok, %{service | "inflight_motion" => nil}},
          else: :error

      _ ->
        :error
    end
  end

  defp complete_service(_document, _service, _receipt, _completion), do: :error

  defp erase_subset(records, field, ids, authorized?) when is_list(ids) do
    {remove, keep} = Enum.split_with(records, &(&1[field] in ids))

    if length(remove) == length(ids) and Enum.all?(remove, authorized?),
      do: {:ok, keep},
      else: :error
  end

  defp erase_subset(_records, _field, _ids, _authorized?), do: :error

  defp erase_absent(absent, nil, _entries), do: {:ok, absent}

  defp erase_absent(%{"local_record_id" => id} = absent, id, entries) do
    if copied_acknowledgement?(absent, entries), do: {:ok, nil}, else: :error
  end

  defp erase_absent(_absent, _id, _entries), do: :error

  defp clear_active_pointer(service, ids, absent_id) do
    if service["active_local_record_id"] in [absent_id | ids],
      do: %{service | "active_local_record_id" => nil},
      else: service
  end

  defp made_erase_progress?(document, journal, records, absent) do
    document["journal"] != journal or document["reconciliations"] != records or
      document["absent_reconciliation"] != absent or
      (journal == [] and records == [] and is_nil(absent))
  end

  defp copied_acknowledgement?(record, entries),
    do: acknowledged?(record) and clear_entry(record) in entries

  defp clear_authorizes_command?(entry, entries) do
    observed_outcome(entry)["kind"] not in ~w(accepted uncertain) or
      Enum.any?(entries, fn copy ->
        copy["intent"]["command_id"] == entry["command_id"] and
          copy["intent"]["fingerprint"] == entry["fingerprint"]
      end)
  end

  def rebase(document, {:outcome, command, outcome, purpose}) do
    case journal_entry(document, command) do
      nil ->
        :skip

      entry ->
        case Enum.find(entry["outcomes"], &(&1["kind"] == outcome["kind"])) do
          nil ->
            {:ok, %{"kind" => "outcome", "command_id" => command, "outcome" => outcome}, purpose}

          ^outcome ->
            :skip

          %{"kind" => "uncertain"} ->
            :skip

          _other ->
            {:error, :outcome_conflict}
        end
    end
  end

  def rebase(document, {:service_complete, id, completion, purpose}) do
    service = document["service"]

    case receipt(document, id) do
      %{"decision" => %{"status" => "pending"}, "completion" => nil} ->
        service_after =
          if service["inflight_motion"]["operation_id"] == id,
            do: %{service | "inflight_motion" => nil},
            else: service

        {:ok,
         %{
           "kind" => "service_complete",
           "operation_id" => id,
           "service_after" => service_after,
           "expected_service_revision" => service["service_revision"],
           "completion" => completion
         }, purpose}

      _ ->
        :skip
    end
  end

  def clear_work(document) do
    case document["clear_authorization"] do
      %{"header" => %{"phase" => phase}} = record when phase in ~w(prepared erasing) ->
        erase(document, record)

      %{"header" => %{"phase" => "awaiting_fence", "clear_operation_id" => id}} ->
        rebase(
          document,
          {:service_complete, id, %{"state" => "complete", "code" => "ok", "steps_executed" => 0},
           :clear}
        )

      _ ->
        :skip
    end
  end

  def clear_entry(record) do
    ack = record["acknowledgement"]
    seal = record["seal"]

    Map.take(record, ~w(intent local_record_id recovery_id recovery_generation service_epoch))
    |> Map.merge(%{
      "seal_operation_id" => seal["operation_id"],
      "seal_binding" => seal["binding"],
      "disposition_id" => ack["disposition_id"],
      "host_close_request_id" => ack["host_request_id"],
      "status_seq" => ack["status_seq"],
      "acknowledgement_operation_id" => ack["operation_id"],
      "operator_id" => ack["operator"]["operator_id"]
    })
  end

  defp erase(document, record) do
    records = recovery_records(document)
    journal = document["journal"]
    entries = record["entries"]

    if Enum.all?(records, &copied_acknowledgement?(&1, entries)) and
         Enum.all?(journal, &clear_authorizes_command?(&1, entries)) do
      ids = Enum.map(document["reconciliations"], & &1["local_record_id"])
      absent_id = document["absent_reconciliation"]["local_record_id"]
      header = record["header"]

      patch = %{
        "kind" => "erase_journal",
        "clear_operation_id" => header["clear_operation_id"],
        "command_ids" => Enum.map(journal, & &1["command_id"]),
        "local_record_ids" => ids,
        "absent_local_record_id" => absent_id,
        "service_after" => clear_active_pointer(document["service"], ids, absent_id),
        "clear_after" => %{record | "header" => %{header | "phase" => "awaiting_fence"}}
      }

      {:ok, patch, :clear}
    else
      {:error, :invalid_store}
    end
  end

  def clearable?(document, entry) do
    case observed_outcome(entry)["kind"] do
      kind when kind in ["accepted", "uncertain"] ->
        Enum.any?(document["reconciliations"], fn record ->
          record["intent"]["command_id"] == entry["command_id"] and
            not is_nil(record["acknowledgement"])
        end)

      _ ->
        true
    end
  end
end
