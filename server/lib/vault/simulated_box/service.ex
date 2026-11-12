defmodule Vault.SimulatedBox.Model.Service do
  @moduledoc false

  alias Vault.SimulatedBox.Model
  alias Vault.SimulatedBox.Model.Durable

  @keep %{"op" => "keep"}
  @intent_fields ~w(game_id command_id intended_box_id original_session_id original_round_id fingerprint)
  @position %{"latch_position" => "unknown", "position_basis" => "unverified"}
  @motion_commands ~w(motion.jog motion.relock motion.release_test)
  @request_fields ~w(sv type request_id device_id box_boot_id operation_id expected_revision command args)
  @urgent_commands ~w(stop motion.stop recovery.enter recovery.seal)
  @maximum 9_007_199_254_740_991

  @type request :: %{required(String.t()) => term()}

  def reply(operation, result), do: {:service_reply, operation, result}

  def error(code, data \\ %{}) do
    status = if code == :commit_uncertain, do: "uncertain", else: "rejected"
    %{"status" => status, "code" => Atom.to_string(code), "data" => data}
  end

  defp ok(data, status \\ "ok"), do: %{"status" => status, "code" => "ok", "data" => data}

  def receipt_result(receipt),
    do: ok(%{"receipt" => Map.delete(receipt, "request_sha256")}, receipt["decision"]["status"])

  def plan(state, request) do
    cond do
      not Durable.fields?(request, @request_fields) or request["sv"] != 1 or
          request["type"] != "request" ->
        {:reply, error(:invalid_args)}

      request["device_id"] != state.config.device_id ->
        {:reply, error(:wrong_device, %{"actual_device_id" => state.config.device_id})}

      request["command"] in ~w(inspect operation.get) ->
        read(state, request)

      true ->
        mutation(state, request)
    end
  end

  defp read(state, request) do
    cond do
      not is_nil(request["operation_id"]) or not is_nil(request["expected_revision"]) ->
        {:reply, error(:invalid_args)}

      request["box_boot_id"] not in [nil, state.boot_id] ->
        {:reply, error(:stale_boot, %{"actual_box_boot_id" => state.boot_id})}

      true ->
        case {request["command"], request["args"]} do
          {"inspect", args} ->
            case inspect_state(state, args) do
              {:ok, data} -> {:read, ok(data), true}
              {:error, code} -> {:reply, error(code)}
            end

          {"operation.get", %{"operation_id" => id} = args} when map_size(args) == 1 ->
            if Durable.sequence(id) do
              case Durable.receipt(state.durable, id) do
                nil ->
                  code =
                    if Durable.sequence(id) <= revision(state),
                      do: :receipt_expired,
                      else: :operation_unknown

                  {:read, error(code), true}

                receipt ->
                  {:read, receipt_result(receipt), true}
              end
            else
              {:reply, error(:invalid_args)}
            end

          _ ->
            {:reply, error(:invalid_args)}
        end
    end
  end

  defp mutation(state, request) do
    operation = request["operation_id"]
    sequence = Durable.sequence(operation)
    command = request["command"]

    with true <- is_integer(sequence) and Durable.nonnegative?(request["expected_revision"]),
         {:ok, hash} <- Durable.hash(Map.drop(request, ~w(type request_id))) do
      hash = Base.encode16(hash, case: :lower)
      receipt = Durable.receipt(state.durable, operation)

      cond do
        receipt && receipt["request_sha256"] == hash ->
          {:reply, receipt_result(receipt)}

        receipt ->
          {:reply, error(:operation_conflict)}

        sequence <= revision(state) ->
          {:reply, error(:receipt_expired)}

        request["box_boot_id"] != state.boot_id and
            not (command == "stop" and is_nil(request["box_boot_id"])) ->
          {:reply, error(:stale_boot, %{"actual_box_boot_id" => state.boot_id})}

        request["expected_revision"] != revision(state) or sequence != revision(state) + 1 ->
          {:reply, error(:revision_conflict, %{"expected_revision" => revision(state)})}

        state.fault == :commit_uncertain and command not in @urgent_commands ->
          {:reply, error(:commit_uncertain)}

        state.fault && command not in @urgent_commands ->
          {:reply, error(:storage_error)}

        length(state.pending_durable) >= 32 and command not in @urgent_commands ->
          {:reply, error(:busy)}

        command == "provision.set" ->
          {:reply, error(:unsupported_command)}

        true ->
          plan_mutation(state, request, hash)
      end
    else
      _ -> {:reply, error(:invalid_args)}
    end
  end

  defp plan_mutation(state, request, hash) do
    service = state.durable["service"]
    command = request["command"]
    args = request["args"]
    operation = request["operation_id"]

    case decide(state, service, command, args, operation) do
      {:ok, service, additions, action, changes} ->
        expected = revision(state)
        service = %{service | "service_revision" => expected + 1}
        status = if action in [:local_motion, :clear], do: "pending", else: "ok"

        data =
          Map.merge(additions, %{
            "operation_id" => operation,
            "resulting_revision" => expected + 1
          })

        receipt = %{
          "storage_version" => 1,
          "operation_id" => operation,
          "request_sha256" => hash,
          "expected_revision" => expected,
          "resulting_revision" => expected + 1,
          "command" => command,
          "decision" => ok(data, status),
          "completion" => nil
        }

        patch = %{
          "kind" => "service_admit",
          "expected_service_revision" => expected,
          "service_after" => service,
          "reconciliation" => @keep,
          "absent_reconciliation" => @keep,
          "clear_authorization" => @keep,
          "simulator_configuration" => @keep,
          "receipt" => receipt
        }

        {:admit, Map.merge(patch, changes), action}

      {:error, code} ->
        {:reply, error(code)}
    end
  end

  defp decide(_state, service, "stop", %{"reason" => reason, "operator" => operator}, operation)
       when reason in ~w(maintenance lost_host_key history_clear) do
    if Durable.operator?(operator),
      do: stop(service, operation, reason),
      else: {:error, :invalid_args}
  end

  defp decide(_state, service, "motion.stop", %{"operator" => operator}, operation) do
    if Durable.operator?(operator),
      do: stop(service, operation, "maintenance"),
      else: {:error, :invalid_args}
  end

  defp decide(state, service, "recovery.enter", args, operation) do
    %{"preparation" => preparation, "host_current" => current, "operator" => operator} = args

    with true <- valid_preparation?(preparation) and host_matches?(current, preparation),
         true <-
           preparation["recovery_generation"] == 1 and is_nil(preparation["prior_recovery_id"]),
         true <- Durable.operator?(operator),
         :ok <- no_unfinished_clear(state),
         {:ok, record, existing} <- entry_record(state, preparation),
         true <- is_nil(existing) do
      if service["service_epoch"] == @maximum and not service["service_inhibited"] do
        {:error, :storage_error}
      else
        service = enter(service, operation, "recovery")
        present? = not is_nil(record)
        intent = Map.take(preparation, @intent_fields)
        # The entry operation has a fresh random suffix and already meets the ID limit.
        local_id = operation

        local = %{
          "storage_version" => 1,
          "local_record_id" => local_id,
          "intent" => intent,
          "recovery_id" => preparation["recovery_id"],
          "recovery_generation" => 1,
          "host_request_id" => preparation["request_id"],
          "recovery_session_id" => current["session_id"],
          "service_epoch" => service["service_epoch"],
          "entry_operation_id" => operation,
          "entry_box_boot_id" => state.boot_id,
          "journal_observation" =>
            if(present?, do: "present", else: "not_present_current_journal"),
          "observed_outcome" => if(present?, do: Durable.observed_outcome(record)["kind"]),
          "operator" => operator,
          "seal" => nil,
          "acknowledgement" => nil,
          "replacement" => nil
        }

        service = %{
          service
          | "motion_frozen" => false,
            "preparation_operation_id" => operation,
            "active_local_record_id" => local_id
        }

        change(
          service,
          %{"local_record_id" => local_id, "service_epoch" => service["service_epoch"]},
          :recovery_entry,
          local
        )
      end
    else
      {:error, code} -> {:error, code}
      _ -> {:error, :identity_mismatch}
    end
  end

  defp decide(state, service, "reboot", %{"reason" => reason}, _operation)
       when reason in ~w(service recovery history_clear) do
    with :ok <- stopped_in_service(state, service) do
      decision(service, %{"reboot_required" => true}, :reboot)
    end
  end

  defp decide(state, service, "recovery.seal", args, operation) do
    id = args["local_record_id"]
    record = Durable.reconciliation(state.durable, id)
    binding = args["binding"]
    current = args["host_current"]

    with :ok <- in_service(service),
         :ok <- active_recovery(service, record, id),
         true <- is_nil(record["acknowledgement"]),
         true <-
           args["recovery_id"] == record["recovery_id"] and
             args["recovery_generation"] == record["recovery_generation"],
         true <-
           host_matches?(current, record) and
             current["session_id"] == binding["current_session_id"],
         :ok <- current_binding(state, binding),
         :ok <- new_boot(state, record["entry_box_boot_id"]),
         true <- Durable.operator?(args["operator"]) do
      seal = %{"operation_id" => operation, "binding" => binding, "operator" => args["operator"]}
      record = %{record | "recovery_session_id" => current["session_id"], "seal" => seal}
      service = freeze(service)
      change(service, %{"local_record_id" => id, "seal_operation_id" => operation}, :seal, record)
    else
      {:error, code} -> {:error, code}
      _ -> {:error, :identity_mismatch}
    end
  end

  defp decide(state, service, "recovery.attest_disposition", args, operation) do
    id = args["local_record_id"]
    record = Durable.reconciliation(state.durable, id)
    disposition = args["disposition"]
    operator = args["operator"]

    with :ok <- stopped_in_service(state, service),
         :ok <- active_recovery(service, record, id),
         true <- service["motion_frozen"] and is_nil(record["acknowledgement"]),
         true <- Durable.operator?(operator) and disposition_matches?(disposition, record) do
      ack = %{
        "operation_id" => operation,
        "disposition_id" => disposition["disposition_id"],
        "host_request_id" => disposition["request_id"],
        "status_seq" => disposition["status_seq"],
        "operator" => operator
      }

      record = %{record | "acknowledgement" => ack}

      change(
        service,
        %{
          "local_record_id" => id,
          "disposition_id" => ack["disposition_id"],
          "acknowledgement_operation_id" => operation
        },
        :ordinary,
        record
      )
    else
      {:error, code} -> {:error, code}
      _ -> {:error, :identity_mismatch}
    end
  end

  defp decide(state, service, "recovery.attest_replacement", args, operation) do
    id = args["local_record_id"]
    record = Durable.reconciliation(state.durable, id)
    preparation = args["preparation"]
    current = args["host_current"]
    operator = args["operator"]

    with :ok <- stopped_in_service(state, service),
         :ok <- active_recovery(service, record, id),
         true <- is_nil(record["acknowledgement"]) and Durable.operator?(operator),
         true <- valid_preparation?(preparation) and host_matches?(current, preparation),
         true <-
           preparation["prior_recovery_id"] == record["recovery_id"] and
             preparation["recovery_id"] != record["recovery_id"] and
             preparation["recovery_generation"] == record["recovery_generation"] + 1 and
             Map.take(preparation, @intent_fields) == record["intent"] do
      replacement = %{
        "operation_id" => operation,
        "prior_recovery_id" => record["recovery_id"],
        "prior_recovery_generation" => record["recovery_generation"],
        "prior_seal_operation_id" => record["seal"]["operation_id"]
      }

      record = %{
        record
        | "recovery_id" => preparation["recovery_id"],
          "recovery_generation" => preparation["recovery_generation"],
          "host_request_id" => preparation["request_id"],
          "recovery_session_id" => current["session_id"],
          "entry_box_boot_id" => state.boot_id,
          "operator" => operator,
          "seal" => nil,
          "replacement" => replacement
      }

      service = %{service | "motion_frozen" => false, "preparation_operation_id" => operation}

      change(
        service,
        Map.take(record, ~w(local_record_id recovery_id recovery_generation)),
        :ordinary,
        record
      )
    else
      {:error, code} -> {:error, code}
      _ -> {:error, :identity_mismatch}
    end
  end

  defp decide(state, service, "service.prepare", args, operation) do
    with :ok <- stopped_in_service(state, service),
         true <- Durable.operator?(args["operator"]),
         {:ok, changes} <-
           preparation_authorized(state, args["authorization"], args["authorization_id"]) do
      service = %{service | "motion_frozen" => false, "preparation_operation_id" => operation}
      {:ok, service, %{}, :ordinary, changes}
    else
      {:error, code} -> {:error, code}
      _ -> {:error, :invalid_args}
    end
  end

  defp decide(
         state,
         service,
         "history.clear",
         %{"retained_host_history" => true, "operator" => operator},
         operation
       ) do
    with :ok <- stopped_in_service(state, service),
         :ok <- no_unfinished_clear(state),
         true <- not is_nil(state.binding),
         true <- Durable.operator?(operator),
         :ok <- history_clearable(state) do
      entries = Enum.map(Durable.recovery_records(state.durable), &Durable.clear_entry/1)

      header = %{
        "storage_version" => 1,
        "clear_operation_id" => operation,
        "pre_clear_box_boot_id" => state.boot_id,
        "pre_clear_session_id" => state.binding.session_id,
        "service_epoch" => service["service_epoch"],
        "retained_host_history" => true,
        "entry_count" => length(entries),
        "phase" => "prepared",
        "fence_binding" => nil,
        "exit_operation_id" => nil
      }

      clear = %{"header" => header, "entries" => entries}
      service = %{freeze(service) | "clear_operation_id" => operation}

      {:ok, service, %{"clear_operation_id" => operation, "reboot_required" => true}, :clear,
       set_clear(clear)}
    else
      {:error, code} -> {:error, code}
      _ -> {:error, :binding_mismatch}
    end
  end

  defp decide(
         state,
         service,
         "history.fence",
         %{"clear_operation_id" => id, "binding" => binding},
         _operation
       ) do
    clear = state.durable["clear_authorization"]
    header = clear && clear["header"]

    with :ok <- stopped_in_service(state, service),
         :ok <- current_binding(state, binding),
         true <-
           (header && header["clear_operation_id"] == id) and header["phase"] == "awaiting_fence",
         :ok <- new_boot(state, header["pre_clear_box_boot_id"]),
         true <- binding["current_session_id"] != header["pre_clear_session_id"] do
      clear = %{
        clear
        | "header" => %{header | "phase" => "fence_complete", "fence_binding" => binding}
      }

      {:ok, service, %{"clear_operation_id" => id, "fence_complete" => true}, :ordinary,
       set_clear(clear)}
    else
      {:error, code} -> {:error, code}
      _ -> {:error, :session_fence_required}
    end
  end

  defp decide(state, service, "service.exit", %{"binding" => binding}, operation) do
    with :ok <- stopped_in_service(state, service),
         :ok <- current_binding(state, binding),
         :ok <- unfrozen(service),
         :ok <- recovery_acknowledged(state),
         true <- not is_nil(service["preparation_operation_id"]),
         true <-
           current_reference?(state) and state.readiness.start_verified and
             state.local_reference.modeled_position == :locked,
         {:ok, changes} <- clear_exit(state, operation) do
      service = %{service | "exit_operation_id" => operation, "service_inhibited" => false}

      {:ok, service, %{"service_epoch" => service["service_epoch"], "exited" => true}, :ordinary,
       changes}
    else
      {:error, code} -> {:error, code}
      _ -> {:error, :reference_required}
    end
  end

  defp decide(
         state,
         service,
         "calibration.set",
         %{"calibration" => calibration, "operator" => operator},
         _operation
       ) do
    with :ok <- stopped_in_service(state, service),
         :ok <- unfrozen(service),
         true <- calibration == Durable.calibration() and Durable.operator?(operator),
         revision when revision <= @maximum <- Durable.calibration_revision(state.durable) + 1 do
      config = %{
        "schema_version" => 1,
        "calibration_revision" => revision,
        "calibration" => calibration
      }

      {:ok, service, %{"calibration_revision" => revision}, :ordinary,
       %{"simulator_configuration" => %{"op" => "set", "record" => config}}}
    else
      {:error, code} -> {:error, code}
      _ -> {:error, :calibration_invalid}
    end
  end

  defp decide(state, service, "reference.set", args, _operation) do
    with :ok <- stopped_in_service(state, service),
         :ok <- unfrozen(service),
         :ok <- manual(args["method"], "manual_verified"),
         true <- Durable.operator?(args["operator"]) and args["reference"] == "locked_zero",
         :ok <- calibrated(state, args["calibration_revision"]) do
      decision(service, %{"reference_revision" => revision(state) + 1})
    else
      {:error, code} -> {:error, code}
      _ -> {:error, :invalid_args}
    end
  end

  defp decide(state, service, "position.confirm", args, _operation) do
    with :ok <- stopped_in_service(state, service),
         :ok <- unfrozen(service),
         :ok <- manual(args["basis"], "manual_verified"),
         true <- is_nil(args["command_id"]),
         true <- args["position"] in ~w(locked released) and Durable.operator?(args["operator"]),
         true <- current_reference?(state) do
      decision(service, %{
        "modeled_position" => args["position"],
        "position" => "unknown",
        "basis" => "unverified"
      })
    else
      {:error, code} ->
        {:error, code}

      _ ->
        if(is_nil(args["command_id"]),
          do: {:error, :reference_required},
          else: {:error, :sensor_unavailable}
        )
    end
  end

  defp decide(_state, _service, "motion.home", _args, _operation),
    do: {:error, :sensor_unavailable}

  defp decide(state, service, command, args, operation) when command in @motion_commands do
    with :ok <- stopped_in_service(state, service),
         :ok <- unfrozen(service),
         :ok <-
           calibrated(
             state,
             args["calibration_revision"] || Durable.calibration_revision(state.durable)
           ),
         {:ok, budget} <- motion_budget(state, command, args) do
      motion = %{
        "operation_id" => operation,
        "command" => command,
        "admission_box_boot_id" => state.boot_id,
        "service_epoch" => service["service_epoch"],
        "calibration_revision" => Durable.calibration_revision(state.durable),
        "reference_revision" =>
          if(state.local_reference, do: state.local_reference.reference_revision, else: 0),
        "binding" => service_binding(state),
        "direction" => budget.direction,
        "max_steps" => budget.steps,
        "rate_steps_s" => budget.rate,
        "timeout_ms" => budget.timeout,
        "home_sensor_id" => nil
      }

      service = %{service | "inflight_motion" => motion}
      decision(service, %{"motion_operation_id" => operation}, :local_motion)
    end
  end

  defp decide(_state, _service, _command, _args, _operation), do: {:error, :unsupported_command}

  defp decision(service, data, action \\ :ordinary), do: {:ok, service, data, action, %{}}

  defp change(service, data, action, record) do
    key =
      if record["journal_observation"] == "present",
        do: "reconciliation",
        else: "absent_reconciliation"

    {:ok, service, data, action, %{key => %{"op" => "upsert", "record" => record}}}
  end

  defp set_clear(record), do: %{"clear_authorization" => %{"op" => "set", "record" => record}}

  defp stop(service, operation, reason) do
    if service["service_epoch"] == @maximum and not service["service_inhibited"] do
      {:error, :storage_error}
    else
      service = enter(service, operation, reason)
      decision(service, %{"service_epoch" => service["service_epoch"]}, :stop)
    end
  end

  defp enter(service, operation, reason) do
    epoch =
      if service["service_inhibited"],
        do: service["service_epoch"],
        else: service["service_epoch"] + 1

    %{
      freeze(service)
      | "service_epoch" => epoch,
        "entry_operation_id" => operation,
        "stop_reason" => reason
    }
  end

  defp freeze(service),
    do: %{
      service
      | "service_inhibited" => true,
        "motion_frozen" => true,
        "preparation_operation_id" => nil
    }

  defp in_service(%{"service_inhibited" => true}), do: :ok
  defp in_service(_service), do: {:error, :not_in_service}
  defp unfrozen(%{"motion_frozen" => false}), do: :ok
  defp unfrozen(_service), do: {:error, :motion_frozen}

  defp stopped_in_service(state, service) do
    if state.motion || state.reservation || state.arm || state.pending_write do
      {:error, :busy}
    else
      in_service(service)
    end
  end

  defp revision(state), do: state.durable["service"]["service_revision"]

  defp service_binding(%{binding: nil}), do: nil

  defp service_binding(state),
    do: %{
      "box_boot_id" => state.boot_id,
      "connection_id" => state.binding.connection_id,
      "current_session_id" => state.binding.session_id
    }

  defp current_binding(state, binding) do
    if Durable.service_binding?(binding) and binding == service_binding(state),
      do: :ok,
      else: {:error, :binding_mismatch}
  end

  defp new_boot(%{boot_id: boot}, boot), do: {:error, :reboot_required}
  defp new_boot(_state, _boot), do: :ok

  defp valid_preparation?(receipt) do
    fields =
      @intent_fields ++
        ~w(request_id recovery_id recovery_generation current_session_id prior_recovery_id committed_at_ms)

    Durable.fields?(receipt, fields) and Durable.intent?(Map.take(receipt, @intent_fields)) and
      Enum.all?(~w(request_id recovery_id current_session_id), &Durable.id?(receipt[&1])) and
      (is_nil(receipt["prior_recovery_id"]) or Durable.id?(receipt["prior_recovery_id"])) and
      Durable.positive?(receipt["recovery_generation"]) and
      Durable.nonnegative?(receipt["committed_at_ms"])
  end

  defp host_matches?(current, record) do
    Durable.fields?(current, ~w(session_id recovery_id recovery_generation disposition_id)) and
      Durable.id?(current["session_id"]) and current["recovery_id"] == record["recovery_id"] and
      current["recovery_generation"] == record["recovery_generation"] and
      is_nil(current["disposition_id"])
  end

  defp entry_record(state, preparation) do
    durable = state.durable
    id = preparation["command_id"]
    entry = Durable.journal_entry(durable, id)
    existing = Enum.find(Durable.recovery_records(durable), &(&1["intent"]["command_id"] == id))
    absent = durable["absent_reconciliation"]

    cond do
      preparation["intended_box_id"] != state.config.device_id ->
        {:error, :identity_mismatch}

      entry && entry["fingerprint"] != preparation["fingerprint"] ->
        {:error, :identity_mismatch}

      existing ->
        {:error, :recovery_required}

      is_nil(entry) && absent && is_nil(absent["acknowledgement"]) ->
        {:error, :unreconciled_history}

      recovery_acknowledged(state) != :ok ->
        {:error, :unreconciled_history}

      true ->
        {:ok, entry, nil}
    end
  end

  defp active_recovery(service, record, id) do
    if (record && service["active_local_record_id"] == id) and
         service["service_epoch"] == record["service_epoch"],
       do: :ok,
       else: {:error, :identity_mismatch}
  end

  defp disposition_matches?(receipt, record) do
    fields =
      @intent_fields ++
        ~w(request_id disposition_id disposition recovery_id recovery_generation
      closed_session_id local_record_id service_epoch seal_operation_id box_boot_id connection_id status_seq committed_at_ms)

    seal = record["seal"]

    Durable.fields?(receipt, fields) and not is_nil(seal) and
      Enum.all?(~w(request_id disposition_id), &Durable.id?(receipt[&1])) and
      Durable.positive?(receipt["status_seq"]) and
      Durable.nonnegative?(receipt["committed_at_ms"]) and
      receipt["disposition"] == "closed_no_replay" and
      Map.take(receipt, @intent_fields) == record["intent"] and
      Enum.all?(
        ~w(local_record_id recovery_id recovery_generation service_epoch),
        &(receipt[&1] == record[&1])
      ) and
      receipt["seal_operation_id"] == seal["operation_id"] and
      receipt["closed_session_id"] == seal["binding"]["current_session_id"] and
      receipt["box_boot_id"] == seal["binding"]["box_boot_id"] and
      receipt["connection_id"] == seal["binding"]["connection_id"]
  end

  defp preparation_authorized(state, "ordinary", nil) do
    with :ok <- no_unfinished_clear(state), :ok <- recovery_acknowledged(state), do: {:ok, %{}}
  end

  defp preparation_authorized(state, "disposition", id) when is_binary(id) do
    active =
      Durable.reconciliation(state.durable, state.durable["service"]["active_local_record_id"])

    with :ok <- no_unfinished_clear(state), :ok <- recovery_acknowledged(state) do
      if active && active["acknowledgement"]["disposition_id"] == id,
        do: {:ok, %{}},
        else: {:error, :identity_mismatch}
    end
  end

  defp preparation_authorized(state, "clear", id) when is_binary(id) do
    case state.durable["clear_authorization"] do
      %{"header" => %{"clear_operation_id" => ^id, "phase" => phase} = header} = clear
      when phase in ~w(fence_complete preparing) ->
        {:ok, set_clear(%{clear | "header" => %{header | "phase" => "preparing"}})}

      _ ->
        {:error, :session_fence_required}
    end
  end

  defp preparation_authorized(_state, _authorization, _id), do: {:error, :invalid_args}

  defp recovery_acknowledged(state) do
    if Enum.all?(Durable.recovery_records(state.durable), & &1["acknowledgement"]),
      do: :ok,
      else: {:error, :recovery_required}
  end

  defp no_unfinished_clear(state) do
    case state.durable["clear_authorization"]["header"]["phase"] do
      phase when phase in [nil, "exited"] -> :ok
      _ -> {:error, :session_fence_required}
    end
  end

  defp clear_exit(state, operation) do
    case state.durable["clear_authorization"] do
      %{"header" => %{"phase" => "preparing"} = header} = clear ->
        clear = %{
          clear
          | "header" => %{header | "phase" => "exited", "exit_operation_id" => operation}
        }

        {:ok, set_clear(clear)}

      _ ->
        with :ok <- no_unfinished_clear(state), do: {:ok, %{}}
    end
  end

  defp history_clearable(state) do
    durable = state.durable

    if recovery_acknowledged(state) == :ok and
         Enum.all?(durable["journal"], &Durable.clearable?(durable, &1)),
       do: :ok,
       else: {:error, :unreconciled_history}
  end

  defp manual(method, method), do: :ok
  defp manual(_method, _expected), do: {:error, :sensor_unavailable}

  defp calibrated(state, revision) do
    if Durable.positive?(revision) and revision == Durable.calibration_revision(state.durable),
      do: :ok,
      else: {:error, :calibration_invalid}
  end

  defp current_reference?(state) do
    reference = state.local_reference

    not is_nil(reference) and not is_nil(state.binding) and reference.binding == state.binding and
      reference.calibration_revision == Durable.calibration_revision(state.durable)
  end

  defp motion_budget(_state, "motion.jog", args) do
    %{"direction" => direction, "steps" => steps, "rate_steps_s" => rate, "timeout_ms" => timeout} =
      args

    if direction in ~w(toward_locked toward_released) and
         Durable.positive?(steps) and steps <= 100 and
         Durable.positive?(rate) and rate <= 100 and
         Durable.positive?(timeout) and timeout <= 8_000 do
      {:ok,
       %{
         direction: if(direction == "toward_released", do: "forward", else: "reverse"),
         steps: steps,
         rate: rate,
         timeout: timeout
       }}
    else
      {:error, :travel_limit}
    end
  end

  defp motion_budget(state, command, _args) do
    position = if command == "motion.relock", do: :released, else: :locked

    if current_reference?(state) and state.local_reference.modeled_position == position and
         (position == :released or state.readiness.start_verified) do
      {:ok,
       %{
         direction: if(position == :released, do: "reverse", else: "forward"),
         steps: 100,
         rate: 100,
         timeout: 8_000
       }}
    else
      {:error, :reference_required}
    end
  end

  defp inspect_state(state, %{"section" => "status"} = args) when map_size(args) == 1 do
    service = state.durable["service"]
    facts = current_facts(state)

    storage_fault =
      if state.fault,
        do: if(state.fault == :commit_uncertain, do: "commit_uncertain", else: "storage_error")

    {:ok,
     Map.merge(facts, %{
       "storage_version" => 1,
       "service_revision" => revision(state),
       "service_epoch" => service["service_epoch"],
       "device_id" => state.config.device_id,
       "box_boot_id" => state.boot_id,
       "service_inhibited" =>
         service["service_inhibited"] or not is_nil(state.fault) or state.binding == nil,
       "motion_frozen" => service["motion_frozen"],
       "active_motion_operation_id" => service["inflight_motion"]["operation_id"],
       "preparation_operation_id" => service["preparation_operation_id"],
       "journal_count" => length(state.durable["journal"]),
       "active_local_record_id" => service["active_local_record_id"],
       "clear_operation_id" => service["clear_operation_id"],
       "storage_fault" => storage_fault
     })}
  end

  defp inspect_state(state, %{"section" => "command", "command_id" => id} = args)
       when map_size(args) == 2 do
    entry = Durable.journal_entry(state.durable, id)

    {:ok,
     %{
       "command_id" => id,
       "journal_observation" => if(entry, do: "present", else: "not_present_current_journal"),
       "record" => if(entry, do: journal_record(state, entry)),
       "current" => current_facts(state)
     }}
  end

  defp inspect_state(state, %{"section" => "journal", "after_command_id" => id} = args)
       when map_size(args) == 2 do
    journal = state.durable["journal"]

    case if(is_nil(id), do: journal, else: Enum.drop_while(journal, &(&1["command_id"] != id))) do
      [] when not is_nil(id) -> {:error, :invalid_args}
      [_cursor | rest] when not is_nil(id) -> journal_page(state, rest)
      rest -> journal_page(state, rest)
    end
  end

  defp inspect_state(state, %{"section" => "recovery", "local_record_id" => id} = args)
       when map_size(args) == 2 do
    case Durable.reconciliation(state.durable, id) do
      nil -> {:error, :invalid_args}
      record -> {:ok, %{"record" => record}}
    end
  end

  defp inspect_state(state, %{"section" => "calibration"} = args) when map_size(args) == 1 do
    reference = state.local_reference

    {:ok,
     %{
       "configuration" => state.durable["simulator_configuration"]["calibration"],
       "calibration_revision" => Durable.calibration_revision(state.durable),
       "reference" =>
         if(reference,
           do: %{
             "revision" => reference.reference_revision,
             "box_boot_id" => state.boot_id,
             "calibration_revision" => reference.calibration_revision,
             "method" => "modeled"
           }
         ),
       "locked_verification" =>
         if(state.readiness.start_verified,
           do: %{
             "binding" => service_binding(state),
             "basis" => "unverified",
             "operation_id" => locked_verification_operation(state)
           }
         )
     }}
  end

  defp inspect_state(state, %{"section" => "clear"} = args) when map_size(args) == 1,
    do: {:ok, %{"clear" => state.durable["clear_authorization"]["header"]}}

  defp inspect_state(state, %{"section" => "clear_entry", "index" => index} = args)
       when map_size(args) == 2 and is_integer(index) and index >= 0 do
    entries = state.durable["clear_authorization"]["entries"] || []

    case Enum.at(entries, index) do
      nil -> {:error, :invalid_args}
      entry -> {:ok, %{"entry" => entry}}
    end
  end

  defp inspect_state(state, %{"section" => "provisioning"} = args) when map_size(args) == 1 do
    {:ok,
     %{
       "configured" => false,
       "device_id" => state.config.device_id,
       "device_class" => "box",
       "profile_sha256" => nil,
       "provisioning_operation_id" => nil,
       "reboot_required" => false
     }}
  end

  defp inspect_state(_state, _args), do: {:error, :invalid_args}

  defp current_facts(state) do
    active? = Model.motor_active?(state)

    %{
      "binding" => service_binding(state),
      "motor_active" => active?,
      "outputs_disabled" => not active?,
      "readiness" => %{
        "arm_id" => if(state.arm, do: state.arm.arm_id),
        "armed_session_id" => if(state.arm, do: state.arm.binding.session_id),
        "calibration_valid" => state.readiness.calibration_valid,
        "start_verified" => state.readiness.start_verified
      },
      "position" => @position
    }
  end

  defp journal_record(state, entry) do
    id = entry["command_id"]
    observed = Durable.observed_outcome(entry)
    recovery = Enum.find(state.durable["reconciliations"], &(&1["intent"]["command_id"] == id))

    %{
      "storage_version" => 1,
      "command_id" => id,
      "fingerprint" => entry["fingerprint"],
      "reserved_arm_id" => entry["reserved_arm_id"],
      "outcome" => observed["kind"],
      "failure_code" => observed["failure_code"],
      "command_confirmation" => nil,
      "local_record_id" => recovery && recovery["local_record_id"]
    }
  end

  defp journal_page(_state, []), do: {:ok, %{"entry" => nil, "next_after_command_id" => nil}}

  defp journal_page(state, [entry | rest]) do
    {:ok,
     %{
       "entry" => journal_record(state, entry),
       "next_after_command_id" => if(rest != [], do: entry["command_id"])
     }}
  end

  defp locked_verification_operation(state) do
    Enum.find_value(Enum.reverse(state.durable["service_receipts"]), fn receipt ->
      if receipt["command"] == "position.confirm", do: receipt["operation_id"]
    end)
  end
end
