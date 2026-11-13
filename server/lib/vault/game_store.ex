defmodule Vault.GameStore do
  @moduledoc "Versioned durable game state and immutable operation evidence."

  import Ecto.Query
  alias Vault.{Credentials, GameStore, Repo}

  alias GameStore.{
    ActuatorCommand,
    Assignment,
    BrowserCredential,
    Checkpoint,
    Codec,
    Game,
    Metadata,
    Operation,
    Records,
    RecoveryPreparation,
    ReleaseDisposition,
    ReleaseObservation,
    SchemaVersionOne
  }

  @internal ~w(checkpoint win restart)a
  @admin ~w(create start pause resume reset arm disarm replace_controller begin_recovery replace_recovery close_recovery)a

  def operation_id(parts) do
    {:ok, bytes} = Codec.encode(parts, 8192)
    <<id::binary-size(16), _::binary>> = :crypto.hash(:sha256, bytes)
    Base.encode16(id, case: :lower)
  end

  def verify_open(expected_store_id) do
    guarded(fn ->
      with true <- query_rows("PRAGMA user_version") == [[1]],
           true <- query_rows("PRAGMA integrity_check") == [["ok"]],
           true <- query_rows("PRAGMA foreign_key_check") == [],
           true <-
             query_rows("SELECT version FROM schema_migrations") == [[SchemaVersionOne.version()]],
           true <- declared_schema?(),
           [%Metadata{singleton: 1, schema_version: 1, store_id: ^expected_store_id}] <-
             Repo.all(Metadata),
           [%BrowserCredential{}] <-
             Repo.all(from c in BrowserCredential, where: c.kind == "host"),
           [%Game{}] <- Repo.all(from g in Game, where: g.active_slot == 1),
           :ok <- Records.verify_all() do
        :ok
      else
        _ -> {:error, :incompatible_store}
      end
    end)
  end

  defp declared_schema? do
    declared =
      query_rows("""
      SELECT type, name, sql FROM sqlite_master
      WHERE name NOT LIKE 'sqlite_%' AND name <> 'schema_migrations'
      """)
      |> Enum.sort()

    Enum.sort(SchemaVersionOne.objects()) == declared
  end

  defp query_rows(statement),
    do: Ecto.Adapters.SQL.query!(Repo.get_dynamic_repo(), statement, [], log: false).rows

  def active do
    guarded(fn ->
      case Repo.one(from g in Game, where: g.active_slot == 1) do
        nil -> {:error, :not_found}
        row -> Records.load(row)
      end
    end)
  end

  def load(game_id) do
    guarded(fn ->
      case Repo.get(Game, game_id) do
        nil -> {:error, :not_found}
        row -> Records.load(row)
      end
    end)
  end

  def create(game_id, box_mode, box_id, operator_id, request_id, request) do
    transaction(fn ->
      hash = operation_hash(:create, game_id, operator_id, nil, request)
      authorize!(:create, operator_id)

      case existing(request_id, hash, game_id, operator_id, :create) do
        nil ->
          if Repo.exists?(from g in Game, where: g.active_slot == 1), do: rollback(:not_ready)
          if not Records.box_registration?(box_mode, box_id), do: rollback(:not_ready)

          now = Credentials.audit_ms()
          checkpoint = Checkpoint.initial(game_id, Credentials.id("session_"))
          {:ok, checkpoint_json} = Checkpoint.encode(checkpoint)

          insert!(Game, %{
            game_id: game_id,
            active_slot: 1,
            box_mode: to_string(box_mode),
            box_device_id: box_id,
            checkpoint_version: 1,
            checkpoint_revision: 0,
            checkpoint_json: checkpoint_json,
            created_at_ms: now,
            updated_at_ms: now
          })

          result = %{
            request_id: request_id,
            operation: :create,
            game_id: game_id,
            session_id: checkpoint.session_id,
            state_revision: 0,
            data: %{game_id: game_id}
          }

          put_operation(game_id, operator_id, request_id, :create, hash, result, 0, now)

        replay ->
          replay
      end
    end)
  end

  def commit(attrs, opts \\ []) do
    transaction(fn ->
      %{
        game_id: game_id,
        expected_session_id: expected_session,
        request_id: request_id,
        operation: operation,
        operator_credential_id: operator_id,
        request: request,
        checkpoint: next,
        result: result
      } = attrs

      authorize!(operation, operator_id)

      unless qualifies?(Keyword.get(opts, :authorize, fn -> true end)),
        do: rollback(:not_authorized)

      hash = operation_hash(operation, game_id, operator_id, expected_session, request)

      case existing(request_id, hash, game_id, operator_id, operation) do
        nil ->
          case existing_win(operation, game_id, expected_session, opts) do
            nil -> commit_new(attrs, opts, hash, next, result)
            original -> original
          end

        replay ->
          replay
      end
    end)
  end

  defp commit_new(attrs, opts, hash, next, result) do
    current = get_current!(attrs.game_id)

    if current.game.checkpoint_revision != attrs.expected_revision or
         current.checkpoint.session_id != attrs.expected_session_id,
       do: rollback(:stale_session)

    if attrs.operation not in [:win, :close_recovery, :reset] and
         not qualifies?(Keyword.get(opts, :qualify, fn -> true end)),
       do: rollback(:not_authorized)

    now = Credentials.audit_ms()

    result =
      case apply_transition(attrs.operation, current, next, opts, attrs, now) do
        :ok -> result
        {:receipt, historical} -> historical
      end

    revision = store_checkpoint(current, next, now)

    put_operation(
      attrs.game_id,
      attrs.operator_credential_id,
      attrs.request_id,
      attrs.operation,
      hash,
      result,
      revision,
      now
    )
  end

  def retry_operation(attrs, authorized? \\ fn -> true end) do
    transaction(fn ->
      authorize!(attrs.operation, attrs.operator_credential_id)
      unless qualifies?(authorized?), do: rollback(:not_authorized)

      hash =
        operation_hash(
          attrs.operation,
          attrs.game_id,
          attrs.operator_credential_id,
          attrs.expected_session_id,
          attrs.request
        )

      existing(
        attrs.request_id,
        hash,
        attrs.game_id,
        attrs.operator_credential_id,
        attrs.operation
      ) ||
        rollback(:not_found)
    end)
  end

  def replay(game_id, operator_id, request_id, operation, expected_session, request) do
    retry_operation(%{
      game_id: game_id,
      operator_credential_id: operator_id,
      request_id: request_id,
      operation: operation,
      expected_session_id: expected_session,
      request: request
    })
  end

  defp existing_win(:win, game_id, session, opts) do
    round = Keyword.fetch!(opts, :command).original_round_id

    case Repo.one(
           from c in ActuatorCommand,
             where:
               c.game_id == ^game_id and
                 c.original_session_id == ^session and c.original_round_id == ^round and
                 c.action == "set_latch" and c.target == "released"
         ) do
      nil ->
        nil

      existing ->
        case Records.original_win(existing) do
          {:ok, receipt} -> receipt
          _ -> rollback(:storage_error)
        end
    end
  end

  defp existing_win(_, _, _, _), do: nil

  def read_operation(game_id, request_id, operator_id) do
    guarded(fn ->
      with true <- host?(operator_id),
           %Operation{game_id: ^game_id, operator_credential_id: ^operator_id} = receipt <-
             Repo.get(Operation, request_id),
           {:ok, current} <- load(game_id),
           {:ok, result} <- receipt_value(receipt) do
        {:ok, Map.put(result, :current, Records.current_context(current))}
      else
        false -> {:error, :not_authorized}
        _ -> {:error, :not_found}
      end
    end)
  end

  def claim_dispatch(game_id, command_id, dispatch_binding) do
    transaction(fn ->
      current = get_current!(game_id)

      with %ActuatorCommand{
             command_id: ^command_id,
             dispatch_claimed: false,
             dispatch_retired: false
           } = command <- current.command,
           {:ok, encoded} <- Records.dispatch_binding(dispatch_binding),
           true <- encoded == command.dispatch_binding_json,
           true <- current.checkpoint.session_id == command.original_session_id do
        query =
          from c in ActuatorCommand,
            where:
              c.command_id == ^command_id and not c.dispatch_claimed and not c.dispatch_retired

        case Repo.update_all(query, set: [dispatch_claimed: true]) do
          {1, _} -> :claimed
          _ -> rollback(:unresolved_release)
        end
      else
        _ -> rollback(:unresolved_release)
      end
    end)
  end

  def dispatch_current?(game_id, command_id, dispatch_binding) do
    with {:ok,
          %{
            command:
              %ActuatorCommand{
                command_id: ^command_id,
                dispatch_claimed: true,
                dispatch_retired: false
              } = command,
            checkpoint: checkpoint
          }} <- load(game_id),
         {:ok, binding} <- Records.dispatch_binding(dispatch_binding) do
      binding == command.dispatch_binding_json and
        checkpoint.session_id == command.original_session_id
    else
      _ -> false
    end
  end

  def observe(attrs) do
    transaction(fn ->
      with {:ok, parsed} <- Records.report(attrs.report_json),
           :ok <- Records.report_identity(parsed, attrs),
           {:ok, comparison} <- Vault.JSON.comparison(parsed, 4096),
           true <- comparison == attrs.comparison,
           %ActuatorCommand{} = command <- Repo.get(ActuatorCommand, attrs.command_id) do
        digest = :crypto.hash(:sha256, comparison)
        same_sequence = Records.observation_key(attrs)

        case Repo.one(from row in same_sequence, where: row.report_sha256 == ^digest) do
          nil ->
            classification =
              Records.classify_report(attrs, parsed, command, Repo.exists?(same_sequence))

            record =
              attrs
              |> Map.delete(:comparison)
              |> Map.put(:classification, classification)
              |> Map.put(:report_sha256, digest)
              |> then(&insert!(ReleaseObservation, &1))

            {1, _} =
              Repo.update_all(
                from(c in ActuatorCommand, where: c.command_id == ^attrs.command_id),
                inc: [history_revision: 1]
              )

            %{status: :committed, observation: record}

          existing ->
            %{status: :replayed, observation: existing}
        end
      else
        _ -> rollback(:evidence_mismatch)
      end
    end)
  end

  defp apply_transition(:win, current, next, opts, _attrs, now) do
    command = Keyword.fetch!(opts, :command)
    old = current.checkpoint

    if old.phase != :seal or old.paused or not is_map(next) or next.phase != :solved or
         not qualifies?(Keyword.fetch!(opts, :qualify)),
       do: rollback(:not_ready)

    with {:ok, encoded} <- Records.dispatch_binding_from(command),
         true <- Records.win_identity?(current, next, command, encoded) do
      command
      |> Map.drop([:dispatch_binding])
      |> Map.merge(%{
        dispatch_binding_json: encoded,
        action: "set_latch",
        target: "released",
        dispatch_claimed: false,
        dispatch_retired: false,
        retired_at_ms: nil,
        history_revision: 0,
        created_at_ms: now
      })
      |> then(&insert!(ActuatorCommand, &1))

      :ok
    else
      _ -> rollback(:evidence_mismatch)
    end
  end

  defp apply_transition(operation, current, next, opts, attrs, now)
       when operation in [:begin_recovery, :replace_recovery] do
    with %ActuatorCommand{} = command <- current.command,
         nil <- current.disposition,
         true <- recovery_checkpoint?(current.checkpoint, next) do
      preparation = Keyword.fetch!(opts, :preparation)
      prior = current.preparation

      case {operation, prior} do
        {:begin_recovery, %RecoveryPreparation{}} -> rollback(:recovery_exists)
        {:replace_recovery, nil} -> rollback(:recovery_replaced)
        _ -> :ok
      end

      if preparation.prior_recovery_id != (prior && prior.recovery_id) or
           preparation.generation != if(prior, do: prior.generation + 1, else: 1),
         do: rollback(:recovery_replaced)

      inserted =
        insert!(
          RecoveryPreparation,
          Map.merge(preparation, %{
            command_id: command.command_id,
            request_id: attrs.request_id,
            prepared_session_id: next.session_id,
            operator_credential_id: attrs.operator_credential_id,
            created_at_ms: now
          })
        )

      if not command.dispatch_retired do
        {1, _} =
          Repo.update_all(
            from(c in ActuatorCommand,
              where:
                c.command_id == ^command.command_id and
                  not c.dispatch_retired
            ),
            set: [dispatch_retired: true, retired_at_ms: now]
          )
      end

      {:receipt, Records.preparation_receipt(inserted, command)}
    else
      %ReleaseDisposition{} -> rollback(:already_closed)
      _ -> rollback(:unresolved_release)
    end
  end

  defp apply_transition(:close_recovery, current, nil, opts, attrs, now) do
    proposed = Keyword.fetch!(opts, :disposition)

    with %ActuatorCommand{dispatch_retired: true} = command <- current.command,
         %RecoveryPreparation{} = preparation <- current.preparation,
         nil <- current.disposition,
         true <- proposed.recovery_id == preparation.recovery_id,
         true <- qualifies?(Keyword.get(opts, :qualify, fn -> false end)),
         {:ok, evidence} <- Records.close_evidence(proposed),
         :ok <- Records.close_predicates(current, proposed, evidence),
         {:ok, document} <- Codec.decode(evidence, 8192) do
      inserted =
        insert!(
          ReleaseDisposition,
          Map.merge(Map.drop(proposed, [:evidence]), %{
            command_id: command.command_id,
            request_id: attrs.request_id,
            operator_credential_id: attrs.operator_credential_id,
            disposition: "closed_no_replay",
            evidence_json: evidence,
            created_at_ms: now
          })
        )

      {:receipt, Records.disposition_receipt(inserted, command, preparation, document)}
    else
      %ReleaseDisposition{} -> rollback(:already_closed)
      {:error, code} -> rollback(code)
      _ -> rollback(:evidence_stale)
    end
  end

  defp apply_transition(operation, current, next, opts, _attrs, now)
       when operation in [
              :start,
              :pause,
              :resume,
              :reset,
              :arm,
              :disarm,
              :replace_controller,
              :checkpoint,
              :restart
            ] do
    if not ordinary_transition?(operation, current, next, opts), do: rollback(:wrong_phase)

    if assignment = Keyword.get(opts, :assignment) do
      if operation != :replace_controller or assignment.game_id != current.game.game_id or
           not Records.assignment_scope?(assignment),
         do: rollback(:not_authorized)

      upsert_assignment(assignment, now)
    end

    :ok
  end

  defp apply_transition(_, _, _, _, _, _), do: rollback(:storage_error)

  defp ordinary_transition?(:arm, _, nil, _), do: true
  defp ordinary_transition?(:disarm, _, nil, _), do: true
  defp ordinary_transition?(:replace_controller, _, nil, _), do: true

  defp ordinary_transition?(operation, %{checkpoint: old} = current, next, opts)
       when is_map(next) do
    case operation do
      :start ->
        old.phase == :lobby and not old.paused and next.phase == :maze

      :pause ->
        old.phase != :solved and next.paused and next.phase == old.phase

      :resume ->
        old.paused and not next.paused and next.phase == old.phase

      :restart ->
        recovery_checkpoint?(old, next)

      :reset ->
        released = is_nil(current.command) or Records.reset_allowed?(current)

        released and qualifies?(Keyword.get(opts, :qualify, fn -> false end)) and
          next.session_id != old.session_id and
          next == Checkpoint.initial(old.game_id, next.session_id)

      :checkpoint ->
        old.phase != :solved and next.phase != :solved and next.session_id == old.session_id

      :replace_controller ->
        next.phase == old.phase and next.session_id == old.session_id

      :arm ->
        next.phase == old.phase and next.session_id == old.session_id

      :disarm ->
        next.phase == old.phase and next.session_id == old.session_id
    end
  end

  defp ordinary_transition?(_, _, _, _), do: false

  defp recovery_checkpoint?(old, next) when is_map(next) do
    historical =
      ~w(game_id round_id puzzle_revision phase position board_version selected_runes release_command_id)a

    next.session_id != old.session_id and next.state_revision == 0 and next.paused and
      :recovery in next.pause_reasons and Map.take(old, historical) == Map.take(next, historical)
  end

  defp recovery_checkpoint?(_, _), do: false

  defp store_checkpoint(current, nil, _now), do: current.game.checkpoint_revision

  defp store_checkpoint(%{game: game, checkpoint: old}, next, now) do
    revision = game.checkpoint_revision + 1

    legal_revision =
      if next.session_id == old.session_id,
        do: next.state_revision > old.state_revision,
        else: next.state_revision == 0

    with true <- next.game_id == game.game_id and legal_revision and Codec.n?(revision),
         {:ok, encoded} <- Checkpoint.encode(next),
         true <- Records.checkpoint_intent?(game, next) do
      query =
        from g in Game,
          where:
            g.game_id == ^game.game_id and
              g.checkpoint_revision == ^game.checkpoint_revision and
              g.checkpoint_json == ^game.checkpoint_json

      case Repo.update_all(query,
             set: [checkpoint_revision: revision, checkpoint_json: encoded, updated_at_ms: now]
           ) do
        {1, _} -> revision
        _ -> rollback(:stale_session)
      end
    else
      _ -> rollback(:storage_error)
    end
  end

  defp upsert_assignment(assignment, now) do
    entry =
      Map.merge(%{device_id: nil, browser_credential_id: nil, updated_at_ms: now}, assignment)

    role = to_string(entry.role)
    record = struct!(Assignment, %{entry | role: role, updated_at_ms: now})

    Repo.insert!(record,
      conflict_target: [:game_id, :role],
      on_conflict: {:replace, [:device_id, :browser_credential_id, :updated_at_ms]}
    )
  end

  defp get_current!(game_id) do
    case load(game_id) do
      {:ok, current} -> current
      {:error, code} -> rollback(code)
    end
  end

  defp operation_hash(operation, game_id, operator_id, expected_session, request) do
    case Codec.encode(
           %{
             operation: operation,
             game_id: game_id,
             operator_credential_id: operator_id,
             expected_session_id: expected_session,
             request: request
           },
           8192
         ) do
      {:ok, encoded} -> :crypto.hash(:sha256, encoded)
      _ -> rollback(:storage_error)
    end
  end

  defp existing(request_id, hash, game_id, operator_id, operation) do
    operation = to_string(operation)

    case Repo.get(Operation, request_id) do
      nil ->
        nil

      %Operation{
        game_id: ^game_id,
        operator_credential_id: ^operator_id,
        operation: ^operation,
        request_sha256: ^hash
      } = row ->
        case receipt_value(row) do
          {:ok, result} -> result
          _ -> rollback(:storage_error)
        end

      _ ->
        rollback(:request_conflict)
    end
  end

  def receipt_value(%Operation{} = row) do
    with {:ok, decoded} <- Codec.decode(row.result_json, 8192) do
      {:ok, %{status: :replayed, result: decoded, checkpoint_revision: row.checkpoint_revision}}
    end
  end

  defp put_operation(game_id, operator_id, request_id, operation, hash, result, revision, now) do
    with {:ok, encoded} <- Codec.encode(result, 8192),
         {:ok, decoded} <- Codec.decode(encoded, 8192) do
      insert!(Operation, %{
        request_id: request_id,
        game_id: game_id,
        operator_credential_id: operator_id,
        operation: to_string(operation),
        request_sha256: hash,
        result_json: encoded,
        checkpoint_revision: revision,
        created_at_ms: now
      })

      %{status: :committed, result: decoded, checkpoint_revision: revision}
    else
      _ -> rollback(:storage_error)
    end
  end

  defp qualifies?(predicate), do: predicate.() == true

  defp authorize!(operation, operator_id) do
    unless (operation in @internal and is_nil(operator_id)) or
             (operation in @admin and host?(operator_id)),
           do: rollback(:not_authorized)
  end

  defp host?(id) when is_binary(id) do
    match?(%BrowserCredential{kind: "host", enabled: true}, Repo.get(BrowserCredential, id))
  end

  defp host?(_), do: false

  def insert!(schema, attrs), do: Repo.insert!(struct!(schema, attrs))

  def rollback(code), do: Repo.rollback(code)

  def transaction(fun) do
    # Errors inside the callback roll back known work. A connection failure on
    # the boundary can also be a lost commit reply and requires operation readback.
    case Repo.transaction(
           fn ->
             case guarded(fun) do
               {:error, :storage_error} -> rollback(:storage_error)
               result -> result
             end
           end,
           mode: :immediate,
           log: false,
           timeout: 1_000
         ) do
      {:error, %DBConnection.ConnectionError{}} -> {:error, :readback_required}
      {:error, %Exqlite.Error{}} -> {:error, :readback_required}
      result -> result
    end
  rescue
    _ in [DBConnection.ConnectionError, Exqlite.Error] -> {:error, :readback_required}
  catch
    :exit, _ -> {:error, :readback_required}
  end

  def guarded(fun) do
    fun.()
  rescue
    _ in [
      Exqlite.Error,
      DBConnection.ConnectionError,
      Ecto.ConstraintError,
      Ecto.MultipleResultsError
    ] ->
      {:error, :storage_error}
  catch
    :exit, _ -> {:error, :storage_error}
  end
end
