defmodule Vault.GameStore.Records do
  @moduledoc false

  import Bitwise
  import Ecto.Query

  alias Vault.{GameStore, JSON, Repo}

  alias GameStore.{
    ActuatorCommand,
    Assignment,
    BrowserCredential,
    Checkpoint,
    Codec,
    Device,
    Game,
    Operation,
    RecoveryPreparation,
    ReleaseDisposition,
    ReleaseObservation
  }

  alias Vault.JSON.Number

  @terminal ~w(motion_complete position_confirmed failed)
  @refusal ~w(not_armed unknown_position stale_binding busy history_full)
  @failure @refusal ++
             ~w(unknown_command connection_lost reboot_interrupted freshness_lost travel_timeout limit_fault driver_fault)
  @close_ids ~w(local_record_id seal_operation_id recovery_id box_boot_id connection_id current_session_id observation_id query_id)
  @close_positive ~w(service_epoch recovery_generation status_seq)

  def load(game) do
    with {:ok, checkpoint} <- Checkpoint.decode(game.checkpoint_json, game.game_id),
         true <- checkpoint.puzzle_revision == 1 and checkpoint_intent?(game, checkpoint),
         true <- box_registration?(game.box_mode, game.box_device_id),
         assignments <- Repo.all(from a in Assignment, where: a.game_id == ^game.game_id),
         true <- Enum.all?(assignments, &assignment_scope?/1) do
      command =
        checkpoint.release_command_id && Repo.get(ActuatorCommand, checkpoint.release_command_id)

      {preparation, disposition, observations} = release_history(command)

      {:ok,
       %{
         game: game,
         checkpoint: checkpoint,
         assignments: assignments,
         command: command,
         preparation: preparation,
         disposition: disposition,
         observations: observations
       }}
    else
      _ -> {:error, :storage_error}
    end
  end

  defp release_history(nil), do: {nil, nil, []}

  defp release_history(command) do
    id = command.command_id

    preparation =
      Repo.one(
        from p in RecoveryPreparation,
          where: p.command_id == ^id,
          order_by: [desc: p.generation],
          limit: 1
      )

    disposition = Repo.get_by(ReleaseDisposition, command_id: id)

    observations =
      Repo.all(
        from o in ReleaseObservation,
          where: o.command_id == ^id,
          order_by: [asc: fragment("?.rowid", o)]
      )

    {preparation, disposition, observations}
  end

  def current_context(state) do
    %{
      session_id: state.checkpoint.session_id,
      recovery_id: state.preparation && state.preparation.recovery_id,
      recovery_generation: if(state.preparation, do: state.preparation.generation, else: 0),
      disposition_id: state.disposition && state.disposition.disposition_id
    }
  end

  def box_registration?(mode, id) do
    case Repo.get(Device, id) do
      %Device{device_class: "box", transport: "internal"} ->
        mode in ["simulated", :simulated]

      %Device{device_class: "box", transport: "raw"} ->
        mode in ["simulated", :simulated, "physical", :physical]

      _ ->
        false
    end
  end

  def checkpoint_intent?(_game, %{release_command_id: nil}), do: true

  def checkpoint_intent?(game, checkpoint) do
    case Repo.get(ActuatorCommand, checkpoint.release_command_id) do
      %ActuatorCommand{} = command ->
        command.game_id == game.game_id and command.intended_box_id == game.box_device_id and
          command.original_round_id == checkpoint.round_id and
          command.puzzle_revision == checkpoint.puzzle_revision

      _ ->
        false
    end
  end

  def assignment_scope?(assignment) do
    role = to_string(assignment.role)
    device_id = Map.get(assignment, :device_id)
    browser_id = Map.get(assignment, :browser_credential_id)

    case {role, device_id, browser_id} do
      {role, id, nil} when role in ["a", "b"] and is_binary(id) ->
        case Repo.get(Device, id) do
          %Device{device_class: "controller", allowed_roles_mask: roles} ->
            (roles &&& if(role == "a", do: 1, else: 2)) != 0

          _ ->
            false
        end

      {role, nil, id} when role in ["a", "b"] and is_binary(id) ->
        case Repo.get(BrowserCredential, id) do
          %BrowserCredential{kind: "host"} ->
            true

          %BrowserCredential{kind: "player", game_id: game, role: ^role} ->
            game == assignment.game_id

          _ ->
            false
        end

      _ ->
        false
    end
  end

  def dispatch_binding_from(%{dispatch_binding: binding}), do: dispatch_binding(binding)

  def dispatch_binding_from(%{dispatch_binding_json: json}) do
    with {:ok, decoded} <- Codec.decode(json, 1024), do: dispatch_binding(decoded)
  end

  def dispatch_binding_from(_), do: {:error, :evidence_mismatch}

  def dispatch_binding(binding) do
    normalized = Codec.normalize(binding)

    with %{
           "box_boot_id" => boot,
           "connection_id" => connection,
           "session_id" => session,
           "arm_id" => arm,
           "heartbeat_seq" => heartbeat,
           "binding_generation" => generation
         } <- normalized,
         true <- map_size(normalized) == 6,
         true <- Enum.all?([boot, connection, session, arm], &Codec.id?/1),
         true <- Codec.p?(heartbeat) and Codec.p?(generation) do
      Codec.encode(normalized, 1024)
    else
      _ -> {:error, :evidence_mismatch}
    end
  end

  def win_identity?(%{checkpoint: old, game: game}, next, command, binding) do
    with {:ok, %{"session_id" => session}} <- Codec.decode(binding, 1024) do
      session == old.session_id and
        command.game_id == game.game_id and command.intended_box_id == game.box_device_id and
        command.original_session_id == old.session_id and
        command.original_round_id == old.round_id and
        command.puzzle_revision == old.puzzle_revision and
        command.command_id == next.release_command_id and
        next.session_id == old.session_id and not next.paused and
        Map.take(next, [:position, :round_id, :puzzle_revision, :board_version, :selected_runes]) ==
          Map.take(old, [:position, :round_id, :puzzle_revision, :board_version, :selected_runes])
    else
      _ -> false
    end
  end

  def original_win(command) do
    rows =
      Repo.all(
        from op in Operation, where: op.game_id == ^command.game_id and op.operation == "win"
      )

    matches =
      Enum.flat_map(rows, fn row ->
        with {:ok, %{result: result} = value} <- GameStore.receipt_value(row),
             true <- receipt_command?(result, command.command_id) do
          [value]
        else
          _ -> []
        end
      end)

    case matches do
      [value] -> {:ok, value}
      _ -> {:error, :storage_error}
    end
  end

  defp receipt_command?(result, command_id) do
    result["command_id"] == command_id or
      match?(%{"command_id" => ^command_id}, result["data"])
  end

  def observation_key(attrs) do
    from row in ReleaseObservation,
      where:
        row.command_id == ^attrs.command_id and row.source_device_id == ^attrs.source_device_id and
          row.box_boot_id == ^attrs.box_boot_id and row.connection_id == ^attrs.connection_id and
          row.status_seq == ^attrs.status_seq
  end

  def classify_report(attrs, report, command, same_sequence?) do
    cond do
      attrs.source_device_id != command.intended_box_id ->
        "identity_conflict"

      not report_matches_intent?(attrs, report, command) ->
        "identity_conflict"

      same_sequence? ->
        "content_conflict"

      Map.get(attrs, :classification) in ["stale", :stale] ->
        "stale"

      Map.get(attrs, :classification) in ["identity_conflict", :identity_conflict] ->
        "identity_conflict"

      true ->
        "admitted"
    end
  end

  defp report_matches_intent?(
         _attrs,
         %{"command_session_id" => session},
         %{original_session_id: session}
       )
       when is_binary(session),
       do: true

  defp report_matches_intent?(
         _attrs,
         %{
           "command_session_id" => nil,
           "release_status" => "uncertain",
           "failure_code" => "unknown_command"
         },
         _command
       ),
       do: true

  # A refusal has no journal fingerprint. Attribute it to the captured
  # dispatch binding, which cannot be reconstructed on another connection.
  defp report_matches_intent?(
         %{box_boot_id: boot, connection_id: connection, current_session_id: session},
         %{"command_session_id" => nil, "release_status" => "failed", "failure_code" => code},
         %{dispatch_claimed: true, original_session_id: session, dispatch_binding_json: binding}
       )
       when code in @refusal do
    match?(
      {:ok, %{"box_boot_id" => ^boot, "connection_id" => ^connection, "session_id" => ^session}},
      Codec.decode(binding, 1024)
    )
  end

  defp report_matches_intent?(_, _, _), do: false

  def report(json) do
    with {:ok,
          %{
            "v" => version,
            "type" => "box_status",
            "box_boot_id" => boot,
            "connection_id" => connection,
            "session_id" => session,
            "command_id" => command,
            "command_session_id" => original,
            "status_seq" => sequence,
            "release_status" => status,
            "motor_active" => motor,
            "latch_position" => position,
            "position_basis" => basis,
            "readiness" => readiness,
            "failure_code" => failure,
            "command_confirmation" => confirmation
          } = parsed} <- JSON.decode_object(json, %{max_bytes: 4096, max_depth: 8}),
         {:ok, 1} <- Number.integer(version, 1, 1),
         {:ok, _seq} <- Number.integer(sequence, 1, Codec.max_integer()),
         true <- Enum.all?([boot, connection, session, command], &Codec.id?/1),
         true <- is_nil(original) or Codec.id?(original),
         true <- status in ["accepted", "uncertain" | @terminal],
         true <-
           is_boolean(motor) and position in ~w(locked released unknown) and
             basis in ~w(endstop manual_verified unverified),
         true <-
           failure in [nil | @failure] and readiness?(readiness) and
             confirmation?(status, confirmation) do
      {:ok, parsed}
    else
      _ -> {:error, :invalid_report}
    end
  end

  defp readiness?(
         %{
           "arm_id" => arm,
           "armed_session_id" => session,
           "calibration_valid" => valid,
           "start_verified" => verified
         } = readiness
       ) do
    map_size(readiness) == 4 and is_boolean(valid) and is_boolean(verified) and
      if(is_nil(arm),
        do: is_nil(session),
        else: Codec.id?(arm) and Codec.id?(session) and valid and verified
      )
  end

  defp readiness?(_), do: false

  defp confirmation?(
         "position_confirmed",
         %{"basis" => basis, "box_boot_id" => boot} = confirmation
       ),
       do:
         map_size(confirmation) == 2 and basis in ~w(endstop manual_verified) and Codec.id?(boot)

  defp confirmation?(status, nil), do: status != "position_confirmed"
  defp confirmation?(_, _), do: false

  def report_identity(parsed, attrs) do
    if parsed["command_id"] == attrs.command_id and parsed["box_boot_id"] == attrs.box_boot_id and
         parsed["connection_id"] == attrs.connection_id and
         parsed["session_id"] == attrs.current_session_id and
         Number.integer(parsed["status_seq"], 1, Codec.max_integer()) == {:ok, attrs.status_seq} do
      :ok
    else
      {:error, :evidence_mismatch}
    end
  end

  def preparation_receipt(preparation, command) do
    command_identity(command)
    |> Map.merge(%{
      request_id: preparation.request_id,
      recovery_id: preparation.recovery_id,
      recovery_generation: preparation.generation,
      current_session_id: preparation.prepared_session_id,
      prior_recovery_id: preparation.prior_recovery_id,
      committed_at_ms: preparation.created_at_ms
    })
  end

  def disposition_receipt(disposition, command, preparation, evidence) do
    command_identity(command)
    |> Map.merge(%{
      request_id: disposition.request_id,
      disposition_id: disposition.disposition_id,
      disposition: "closed_no_replay",
      recovery_id: preparation.recovery_id,
      recovery_generation: preparation.generation,
      closed_session_id: evidence["current_session_id"],
      local_record_id: evidence["local_record_id"],
      service_epoch: evidence["service_epoch"],
      seal_operation_id: evidence["seal_operation_id"],
      box_boot_id: evidence["box_boot_id"],
      connection_id: evidence["connection_id"],
      status_seq: evidence["status_seq"],
      committed_at_ms: disposition.created_at_ms
    })
  end

  defp command_identity(command) do
    %{
      game_id: command.game_id,
      command_id: command.command_id,
      intended_box_id: command.intended_box_id,
      original_session_id: command.original_session_id,
      original_round_id: command.original_round_id,
      fingerprint: %{
        session_id: command.original_session_id,
        action: "set_latch",
        target: "released"
      }
    }
  end

  def close_evidence(proposed) do
    with {:ok, bytes} <- evidence_bytes(proposed),
         {:ok, evidence} <- Codec.decode(bytes, 8192),
         true <- evidence?(evidence) do
      {:ok, bytes}
    else
      _ -> {:error, :evidence_mismatch}
    end
  end

  defp evidence_bytes(%{evidence: evidence}), do: Codec.encode(evidence, 8192)
  defp evidence_bytes(%{evidence_json: bytes}), do: {:ok, bytes}
  defp evidence_bytes(_), do: {:error, :evidence_mismatch}

  defp evidence?(evidence) do
    map_size(evidence) == 12 and evidence["operator_confirmed"] == true and
      Enum.all?(@close_ids, &Codec.id?(evidence[&1])) and
      Enum.all?(@close_positive, &Codec.p?(evidence[&1]))
  end

  def close_predicates(current, proposed, bytes) do
    with {:ok, evidence} <- Codec.decode(bytes, 8192),
         %ReleaseObservation{} = row <-
           Enum.find(current.observations, &(&1.observation_id == proposed.observation_id)),
         true <- evidence_matches?(current.command, current.preparation, row, evidence),
         true <- row.current_session_id == current.checkpoint.session_id,
         false <- Enum.any?(current.observations, &newer_contradiction?(&1, row)) do
      :ok
    else
      _ -> {:error, :evidence_stale}
    end
  end

  defp evidence_matches?(command, preparation, row, evidence) do
    row.command_id == command.command_id and row.source_device_id == command.intended_box_id and
      row.classification == "admitted" and not is_nil(row.query_id) and
      row.observation_id == evidence["observation_id"] and row.query_id == evidence["query_id"] and
      row.box_boot_id == evidence["box_boot_id"] and
      row.connection_id == evidence["connection_id"] and
      row.current_session_id == evidence["current_session_id"] and
      row.status_seq == evidence["status_seq"] and
      preparation.recovery_id == evidence["recovery_id"] and
      preparation.generation == evidence["recovery_generation"] and
      stopped_report?(row)
  end

  defp stopped_report?(row) do
    case report(row.report_json) do
      {:ok, %{"motor_active" => false, "readiness" => %{"arm_id" => nil}}} -> true
      _ -> false
    end
  end

  defp newer_contradiction?(row, reference) do
    row.classification in ["admitted", "content_conflict"] and
      row.source_device_id == reference.source_device_id and
      row.box_boot_id == reference.box_boot_id and
      row.connection_id == reference.connection_id and
      row.current_session_id == reference.current_session_id and
      ((row.status_seq > reference.status_seq and not stopped_report?(row)) or
         (row.status_seq == reference.status_seq and row.classification == "content_conflict"))
  end

  def reset_allowed?(%{preparation: %RecoveryPreparation{}, disposition: %ReleaseDisposition{}}),
    do: true

  def reset_allowed?(%{preparation: %RecoveryPreparation{}}), do: false

  def reset_allowed?(%{observations: observations}) do
    release_summary(observations).status in [:motion_complete, :position_confirmed, :failed]
  end

  def release_summary(observations) do
    initial = %{status: :pending, uncertain: false, command_confirmation: nil, failure_code: nil}

    observations
    |> Enum.reduce(initial, &reduce_report/2)
    |> case do
      %{uncertain: true} = summary -> %{summary | status: :uncertain}
      summary -> summary
    end
  end

  defp reduce_report(%{classification: conflict}, summary)
       when conflict in ["identity_conflict", "content_conflict"] do
    %{summary | uncertain: true}
  end

  defp reduce_report(%{classification: "admitted", report_json: json}, summary) do
    case report(json) do
      {:ok, parsed} -> advance_history(summary, parsed)
      _ -> %{summary | uncertain: true}
    end
  end

  defp reduce_report(_stale, summary), do: summary

  defp advance_history(summary, %{"release_status" => "accepted"}) do
    if summary.status == :pending, do: %{summary | status: :accepted}, else: summary
  end

  defp advance_history(summary, %{"release_status" => "uncertain", "failure_code" => failure}) do
    %{summary | uncertain: true, failure_code: summary.failure_code || failure}
  end

  defp advance_history(summary, %{
         "release_status" => status,
         "command_confirmation" => confirmation,
         "failure_code" => failure
       })
       when status in @terminal do
    outcome = terminal_status(status)

    cond do
      summary.status in [:pending, :accepted] or
          (summary.status == :motion_complete and outcome == :position_confirmed) ->
        %{
          summary
          | status: outcome,
            command_confirmation: confirmation,
            failure_code: summary.failure_code || failure
        }

      summary.status == :position_confirmed and outcome == :motion_complete ->
        summary

      summary.status == outcome and summary.command_confirmation == confirmation and
          (summary.uncertain or summary.failure_code == failure) ->
        summary

      true ->
        %{summary | uncertain: true}
    end
  end

  defp terminal_status("motion_complete"), do: :motion_complete
  defp terminal_status("position_confirmed"), do: :position_confirmed
  defp terminal_status("failed"), do: :failed

  def verify_all do
    valid =
      Enum.all?(Repo.all(Game), &match?({:ok, _}, load(&1))) and
        Enum.all?(Repo.all(Device), &match?({:ok, _}, Codec.decode(&1.capabilities_json, 2048))) and
        Enum.all?(Repo.all(ActuatorCommand), &valid_command?/1) and
        Enum.all?(Repo.all(ReleaseObservation), &valid_observation?/1) and
        Enum.all?(Repo.all(RecoveryPreparation), &valid_preparation?/1) and
        Enum.all?(Repo.all(ReleaseDisposition), &valid_disposition?/1) and
        Enum.all?(Repo.all(Operation), &valid_receipt?/1)

    if valid, do: :ok, else: {:error, :incompatible_store}
  end

  defp valid_command?(command) do
    game = Repo.get(Game, command.game_id)

    observation_count =
      Repo.aggregate(
        from(o in ReleaseObservation, where: o.command_id == ^command.command_id),
        :count
      )

    recovery? =
      Repo.exists?(from p in RecoveryPreparation, where: p.command_id == ^command.command_id)

    command.intended_box_id == game.box_device_id and command.puzzle_revision == 1 and
      command.history_revision == observation_count and command.dispatch_retired == recovery? and
      match?(
        {:ok, %{"session_id" => session}} when session == command.original_session_id,
        Codec.decode(command.dispatch_binding_json, 1024)
      ) and
      dispatch_binding_from(command) == {:ok, command.dispatch_binding_json} and
      match?({:ok, _}, original_win(command))
  end

  defp valid_observation?(row) do
    with {:ok, parsed} <- report(row.report_json),
         :ok <- report_identity(parsed, row),
         {:ok, comparison} <- JSON.comparison(parsed, 4096),
         true <- :crypto.hash(:sha256, comparison) == row.report_sha256 do
      true
    else
      _ -> false
    end
  end

  defp valid_preparation?(preparation) do
    command = Repo.get(ActuatorCommand, preparation.command_id)

    prior =
      preparation.prior_recovery_id &&
        Repo.get(RecoveryPreparation, preparation.prior_recovery_id)

    receipt = Repo.get(Operation, preparation.request_id)

    correct_chain =
      case prior do
        nil ->
          preparation.generation == 1 and receipt.operation == "begin_recovery"

        previous ->
          previous.command_id == command.command_id and
            previous.generation + 1 == preparation.generation and
            receipt.operation == "replace_recovery"
      end

    with {:ok, %{result: result}} <- GameStore.receipt_value(receipt) do
      command.dispatch_retired and correct_chain and receipt.game_id == command.game_id and
        receipt.operator_credential_id == preparation.operator_credential_id and
        result == Codec.normalize(preparation_receipt(preparation, command))
    else
      _ -> false
    end
  end

  defp valid_disposition?(disposition) do
    command = Repo.get(ActuatorCommand, disposition.command_id)
    preparation = Repo.get(RecoveryPreparation, disposition.recovery_id)
    observation = Repo.get(ReleaseObservation, disposition.observation_id)
    receipt = Repo.get(Operation, disposition.request_id)

    newer_preparation? =
      Repo.exists?(
        from p in RecoveryPreparation, where: p.prior_recovery_id == ^preparation.recovery_id
      )

    with {:ok, evidence} <- Codec.decode(disposition.evidence_json, 8192),
         true <- String.valid?(disposition.reason) and evidence?(evidence),
         true <- evidence_matches?(command, preparation, observation, evidence),
         {:ok, %{result: result}} <- GameStore.receipt_value(receipt) do
      result == Codec.normalize(disposition_receipt(disposition, command, preparation, evidence)) and
        command.dispatch_retired and not newer_preparation? and
        preparation.command_id == command.command_id and receipt.game_id == command.game_id and
        receipt.operator_credential_id == disposition.operator_credential_id and
        receipt.operation == "close_recovery"
    else
      _ -> false
    end
  end

  defp valid_receipt?(receipt) do
    with {:ok, %{result: result}} <- GameStore.receipt_value(receipt),
         %Game{checkpoint_revision: revision} <- Repo.get(Game, receipt.game_id) do
      map_size(result) > 0 and receipt.checkpoint_revision <= revision and
        case receipt.operator_credential_id do
          nil -> true
          id -> match?(%BrowserCredential{kind: "host"}, Repo.get(BrowserCredential, id))
        end
    else
      _ -> false
    end
  end
end
