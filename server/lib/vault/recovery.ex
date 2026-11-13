defmodule Vault.Recovery do
  @moduledoc "Restart fences and immutable administrative closure; never motor replay."
  use GenServer
  import Kernel, except: [binding: 1]
  alias Vault.{Clock, Controllers, Games, GameSession, GameStore, Updates}
  alias Vault.SimulatedBox.Adapter

  @seal_readback_ms 3_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  @impl true
  def init(_opts) do
    with {:ok, %{game: game}} <- GameStore.active(), {:ok, _} <- Games.ensure(game.game_id) do
      {:ok, nil}
    else
      _ -> {:stop, :invalid_game_store}
    end
  end

  def create(host, id, %{box_mode: mode, box_device_id: box})
      when mode in [:simulated, :physical] do
    if host.kind == :host and Controllers.valid?(host) and Controllers.id?(id) and
         Controllers.id?(box) do
      game =
        "game_" <> GameStore.operation_id(%{"request_id" => id, "operator" => host.subject_id})

      case GameStore.create(game, Atom.to_string(mode), box, host.subject_id, id, %{
             "box_mode" => Atom.to_string(mode),
             "box_device_id" => box
           }) do
        {:ok, receipt} -> {:ok, receipt.result}
        {:error, code} -> Games.error(code)
      end
    else
      Games.error(:not_authorized)
    end
  end

  def create(_, _, _), do: Games.error(:not_authorized)

  def restart(
        %{
          game: %{checkpoint_revision: 0},
          checkpoint: %{phase: :lobby, state_revision: 0, paused: false}
        } = record
      ) do
    # The explicit initialization has never hosted a runtime. Commit admission so
    # even a crash before the first player action takes the recovery path next time.
    old = record.checkpoint
    next = %{old | state_revision: 1}

    attrs = %{
      game_id: old.game_id,
      expected_revision: 0,
      expected_session_id: old.session_id,
      request_id: Controllers.id("request"),
      operation: :checkpoint,
      operator_credential_id: nil,
      request: %{"first_runtime_admission" => true},
      checkpoint: next,
      result: %{"session_id" => next.session_id}
    }

    with {:ok, _} <- GameStore.commit(attrs), do: GameStore.load(old.game_id)
  end

  def restart(record) do
    old = record.checkpoint

    next = %{
      old
      | session_id: Controllers.id("session"),
        state_revision: 0,
        paused: true,
        pause_reasons: Enum.uniq(old.pause_reasons ++ [:recovery])
    }

    attrs = %{
      game_id: old.game_id,
      expected_revision: record.game.checkpoint_revision,
      expected_session_id: old.session_id,
      request_id: Controllers.id("request"),
      operation: :restart,
      operator_credential_id: nil,
      request: %{"previous_session" => old.session_id},
      checkpoint: next,
      result: %{"session_id" => next.session_id}
    }

    with {:ok, _} <- GameStore.commit(attrs), {:ok, loaded} <- GameStore.load(old.game_id) do
      Updates.session_changed(old.game_id, old.session_id, next.session_id)
      {:ok, loaded}
    end
  end

  def release(%{command: nil}), do: nil

  def release(record) do
    reports =
      Enum.map(record.observations, fn row ->
        {:ok, json} = Vault.JSON.decode(row.report_json, %{max_bytes: 4096, max_depth: 8})

        %{
          observation_id: row.observation_id,
          classification: row.classification,
          release_status: json["release_status"],
          failure_code: json["failure_code"],
          command_confirmation: json["command_confirmation"],
          observed_at_ms: row.observed_at_ms,
          box_boot_id: row.box_boot_id,
          status_seq: row.status_seq
        }
      end)

    summary = GameStore.Records.release_summary(record.observations)

    Map.merge(summary, %{
      command_id: record.command.command_id,
      preparation: receipt(record.preparation),
      disposition: receipt(record.disposition),
      observations: reports,
      close_evidence: nil,
      original: intent(record.command)
    })
  end

  defp receipt(nil), do: nil

  defp receipt(row) do
    case GameStore.read_operation(row_game(row), row.request_id, row.operator_credential_id) do
      {:ok, %{result: value}} -> value
      _ -> nil
    end
  end

  defp row_game(row) do
    case Vault.Repo.get(GameStore.ActuatorCommand, row.command_id) do
      nil -> nil
      command -> command.game_id
    end
  end

  def reset_allowed?(s) do
    stopped = s.box.connected and is_map(s.box.report) and s.box.report.motor_active == false

    if s.record.preparation do
      stopped and s.record.disposition != nil and s.box.report.readiness.arm_id == nil and
        fresh?(s)
    else
      stopped and s.release.status in [:motion_complete, :position_confirmed, :failed] and
        not s.release.uncertain and fresh?(s)
    end
  end

  def perform(s, operation, host, id, args) do
    if Controllers.id?(id) and is_map(args) do
      evidence = normalize_evidence(args[:evidence])

      expected =
        if operation == :close_recovery,
          do: evidence && evidence.current_session_id,
          else: args[:expected_session_id]

      lookup = %{
        game_id: s.checkpoint.game_id,
        operator_credential_id: host.subject_id,
        request_id: id,
        operation: operation,
        expected_session_id: expected,
        request: GameSession.json_value(args)
      }

      case GameStore.retry_operation(lookup, fn -> Controllers.valid?(host) end) do
        {:ok, %{result: saved}} ->
          {{:ok, saved}, s}

        {:error, :not_found} ->
          if s.record.command != nil and args[:command_id] == s.record.command.command_id do
            case operation do
              op when op in [:begin_recovery, :replace_recovery] -> prepare(s, op, host, id, args)
              :close_recovery -> close(s, host, id, args)
            end
          else
            {Games.error(:unresolved_release), s}
          end

        {:error, code} ->
          {Games.error(code), s}
      end
    else
      {Games.error(:not_authorized), s}
    end
  end

  defp prepare(s, operation, host, id, args) do
    old = s.record.preparation

    replay? =
      match?({:ok, _}, GameStore.read_operation(s.checkpoint.game_id, id, host.subject_id))

    code =
      cond do
        replay? ->
          nil

        args[:expected_session_id] != s.checkpoint.session_id ->
          :stale_session

        s.record.disposition != nil ->
          :already_closed

        operation == :begin_recovery and old != nil ->
          :recovery_exists

        operation == :replace_recovery and
            (old == nil or args[:expected_recovery_id] != old.recovery_id) ->
          :recovery_replaced

        true ->
          nil
      end

    if code do
      {Games.error(
         code,
         if(code == :recovery_exists, do: %{recovery_id: old.recovery_id}, else: %{})
       ), s}
    else
      recovery_id = Controllers.id("recovery")
      session = Controllers.id("session")
      generation = if old, do: old.generation + 1, else: 1
      prior = if operation == :replace_recovery and old, do: old.recovery_id

      result =
        Map.merge(intent(s.record.command), %{
          request_id: id,
          recovery_id: recovery_id,
          recovery_generation: generation,
          current_session_id: session,
          prior_recovery_id: prior,
          committed_at_ms: System.system_time(:millisecond)
        })

      preparation = %{recovery_id: recovery_id, generation: generation, prior_recovery_id: prior}
      rules = %{s.rules | paused: true, pause_reasons: [:recovery]}

      opts = [
        new_session: session,
        preparation: preparation,
        result: GameSession.json_value(result),
        expected_session: args[:expected_session_id],
        qualify: fn -> Controllers.valid?(host) end
      ]

      case GameSession.commit(s, rules, operation, host, id, GameSession.json_value(args), opts) do
        {:ok, next, saved} ->
          next =
            if replay?,
              do: next,
              else:
                GameSession.rotate_session(next, s.checkpoint.session_id)
                |> GameSession.invalidate(:session_changed)
                |> GameSession.visible(false)

          {{:ok, saved}, next}

        {:error, next, failure} ->
          {Games.error(failure), next}
      end
    end
  end

  defp close(s, host, id, args) do
    evidence = normalize_evidence(args[:evidence])
    reason = args[:reason]

    replay? =
      match?({:ok, _}, GameStore.read_operation(s.checkpoint.game_id, id, host.subject_id))

    if not replay? and
         (not valid_close?(s, host, evidence, args[:expected_recovery_id]) or
            not valid_reason?(reason)) do
      {Games.error(:evidence_stale), s}
    else
      prep = s.record.preparation

      result =
        Map.merge(intent(s.record.command), %{
          request_id: id,
          disposition_id: Controllers.id("disposition"),
          disposition: "closed_no_replay",
          recovery_id: prep.recovery_id,
          recovery_generation: prep.generation,
          closed_session_id: s.checkpoint.session_id,
          committed_at_ms: System.system_time(:millisecond)
        })

      result =
        Map.merge(
          result,
          Map.take(evidence || %{}, [
            :local_record_id,
            :service_epoch,
            :seal_operation_id,
            :box_boot_id,
            :connection_id,
            :status_seq
          ])
        )

      proposed = %{
        disposition_id: result.disposition_id,
        recovery_id: prep.recovery_id,
        reason: reason,
        evidence: GameSession.json_value(evidence),
        observation_id: evidence && evidence.observation_id
      }

      qualify = fn -> valid_close?(s, host, evidence, args[:expected_recovery_id]) end

      options = [
        no_checkpoint: true,
        disposition: proposed,
        result: GameSession.json_value(result),
        qualify: qualify,
        expected_session:
          if(evidence, do: evidence.current_session_id, else: s.checkpoint.session_id)
      ]

      case GameSession.commit(
             s,
             s.rules,
             :close_recovery,
             host,
             id,
             GameSession.json_value(args),
             options
           ) do
        {:ok, next, saved} -> {{:ok, saved}, GameSession.visible(next)}
        {:error, next, code} -> {Games.error(code), next}
      end
    end
  end

  @evidence_fields ~w(local_record_id service_epoch seal_operation_id recovery_id recovery_generation box_boot_id connection_id current_session_id status_seq observation_id query_id operator_confirmed)a
  defp normalize_evidence(map) when is_map(map) and map_size(map) == 12 do
    result = Map.new(@evidence_fields, &{&1, Map.get(map, &1, Map.get(map, Atom.to_string(&1)))})

    if Enum.all?(result, fn {key, value} ->
         cond do
           key == :operator_confirmed ->
             value == true

           key in [:service_epoch, :recovery_generation, :status_seq] ->
             Controllers.number?(value, 1)

           true ->
             Controllers.id?(value)
         end
       end),
       do: result
  end

  defp normalize_evidence(_), do: nil

  defp valid_close?(s, host, evidence, expected) do
    selected = s.close_evidence
    prep = s.record.preparation

    evidence != nil and selected != nil and evidence == selected and Controllers.valid?(host) and
      prep != nil and expected == prep.recovery_id and s.record.disposition == nil and
      s.record.command.dispatch_retired and fresh?(s) and s.box.report != nil and
      s.box.report.motor_active == false and s.box.report.readiness.arm_id == nil and
      evidence.box_boot_id == s.box.boot_id and evidence.connection_id == s.box.connection_id and
      evidence.current_session_id == s.checkpoint.session_id
  end

  defp valid_reason?(value),
    do: is_binary(value) and String.valid?(value) and byte_size(value) in 1..512

  def query_observation(s, attrs, report, query) do
    evidence = s.seal_attestation

    if is_map(query) and query == s.query and evidence != nil and
         report.command_id == s.checkpoint.release_command_id and
         report.status_seq > query.minimum_status_seq and report.motor_active == false and
         report.readiness.arm_id == nil and
         evidence["box_boot_id"] == report.box_boot_id and
         evidence["connection_id"] == report.connection_id and
         evidence["current_session_id"] == s.checkpoint.session_id do
      close =
        evidence
        |> Map.take(
          ~w(local_record_id service_epoch seal_operation_id recovery_id recovery_generation box_boot_id connection_id current_session_id)
        )
        |> Map.merge(%{
          "status_seq" => report.status_seq,
          "observation_id" => attrs.observation_id,
          "query_id" => query.query_id,
          "operator_confirmed" => true
        })
        |> normalize_evidence()

      %{s | close_evidence: close}
    else
      s
    end
  end

  def service_completed(s, kind, %{"status" => "ok"} = result) do
    receipt = get_in(result, ["data", "receipt"])
    data = if receipt, do: receipt["decision"]["data"], else: result["data"]

    command =
      case kind do
        {:operation, command, _args} -> command
        {:request, request} -> request["command"]
        _ -> nil
      end

    context =
      Map.merge(
        s.service_context,
        Map.take(data || %{}, ~w(local_record_id service_epoch seal_operation_id))
      )

    context =
      case data do
        %{"record" => %{"local_record_id" => _} = record} ->
          Map.merge(context, %{
            "local_record_id" => record["local_record_id"],
            "service_epoch" => record["service_epoch"],
            "record" => record
          })

        %{"active_local_record_id" => id, "service_epoch" => epoch} ->
          Map.merge(context, %{"local_record_id" => id, "service_epoch" => epoch})

        _ ->
          context
      end

    s = %{s | service_context: context}

    if command == "recovery.seal" and s.record.preparation != nil and receipt do
      args =
        case kind do
          {:operation, _, args} -> args
          {:request, request} -> request["args"]
        end

      p = s.record.preparation

      if args["binding"] == binding(s) and args["recovery_id"] == p.recovery_id and
           args["recovery_generation"] == p.generation and
           args["host_current"]["session_id"] == s.checkpoint.session_id and
           args["host_current"]["disposition_id"] == nil and s.record.disposition == nil do
        tag = {:seal_readback, make_ref()}
        s = clear_seal_authority(s)

        case Adapter.service_operation_async(
               s.runtime,
               "inspect",
               %{"section" => "recovery", "local_record_id" => args["local_record_id"]},
               tag
             ) do
          :ok ->
            deadline = GameSession.now(s) + @seal_readback_ms
            timer = Clock.schedule_at(s.clock, self(), {:seal_readback_timeout, tag}, deadline)

            %{
              s
              | seal_check: %{
                  tag: tag,
                  operation_id: receipt["operation_id"],
                  args: args,
                  binding: binding(s),
                  deadline: deadline,
                  timer: timer
                }
            }

          {:error, _} ->
            s
        end
      else
        s
      end
    else
      s
    end
  end

  def service_completed(s, _, _), do: s

  def seal_readback(%{seal_check: %{tag: tag} = check} = s, tag, result) do
    s = clear_seal_authority(s)

    if GameSession.now(s) < check.deadline do
      verify_seal_readback(s, check, result)
    else
      s
    end
  end

  def seal_readback(s, _tag, _result), do: s

  def seal_readback_timeout(%{seal_check: %{tag: tag, deadline: deadline}} = s, tag) do
    if GameSession.now(s) >= deadline, do: clear_seal_authority(s), else: s
  end

  def seal_readback_timeout(s, _tag), do: s

  defp clear_seal_authority(s) do
    if s.seal_check, do: Clock.cancel(s.clock, s.seal_check.timer)
    %{s | seal_check: nil, seal_attestation: nil, close_evidence: nil, query: nil}
  end

  defp verify_seal_readback(s, check, %{"status" => "ok", "data" => %{"record" => record}}) do
    prep = s.record.preparation
    seal = record["seal"]

    if check.binding == binding(s) and s.box.connected and prep != nil and
         record["recovery_id"] == prep.recovery_id and
         record["recovery_generation"] == prep.generation and
         record["intent"] == GameSession.json_value(intent(s.record.command)) and seal != nil and
         seal["operation_id"] == check.operation_id and seal["binding"] == binding(s) and
         record["local_record_id"] == check.args["local_record_id"] and
         s.record.disposition == nil do
      evidence =
        Map.merge(binding(s), %{
          "local_record_id" => record["local_record_id"],
          "service_epoch" => record["service_epoch"],
          "seal_operation_id" => seal["operation_id"],
          "recovery_id" => prep.recovery_id,
          "recovery_generation" => prep.generation
        })

      query = %{
        query_id: Controllers.id("query"),
        binding_generation: s.box.binding_generation,
        minimum_status_seq: s.box.status_seq
      }

      case Adapter.query(s.runtime, s.box.binding_generation, s.record.command.command_id, query) do
        :ok -> %{s | seal_attestation: evidence, query: query}
        {:error, _} -> s
      end
    else
      s
    end
  end

  defp verify_seal_readback(s, _check, _result), do: s

  def service_step(s, host, step, args) do
    if host.kind == :host and Controllers.valid?(host) and s.record.game.box_mode == "simulated" do
      operator = %{
        "operator_id" => host.subject_id,
        "observation" => Map.get(args, :observation, "Explicit modeled service observation")
      }

      current = %{
        "session_id" => s.checkpoint.session_id,
        "recovery_id" => s.record.preparation && s.record.preparation.recovery_id,
        "recovery_generation" =>
          if(s.record.preparation, do: s.record.preparation.generation, else: 0),
        "disposition_id" => s.record.disposition && s.record.disposition.disposition_id
      }

      local_id = s.service_context["local_record_id"]

      case step do
        :inspect ->
          {:ok, "inspect", %{"section" => "status"}}

        :inspect_recovery when is_binary(local_id) ->
          {:ok, "inspect", %{"section" => "recovery", "local_record_id" => local_id}}

        :stop ->
          {:ok, "stop", %{"reason" => "maintenance", "operator" => operator}}

        :enter when not is_nil(s.record.preparation) ->
          {:ok, "recovery.enter",
           %{
             "preparation" => s.release.preparation,
             "host_current" => current,
             "operator" => operator
           }}

        :reboot ->
          {:ok, "reboot", %{"reason" => "recovery"}}

        :seal when is_binary(local_id) and not is_nil(s.record.preparation) ->
          {:ok, "recovery.seal",
           %{
             "local_record_id" => local_id,
             "recovery_id" => current["recovery_id"],
             "recovery_generation" => current["recovery_generation"],
             "binding" => binding(s),
             "host_current" => current,
             "operator" => operator
           }}

        :acknowledge when is_binary(local_id) and not is_nil(s.record.disposition) ->
          {:ok, "recovery.attest_disposition",
           %{
             "local_record_id" => local_id,
             "disposition" => s.release.disposition,
             "operator" => operator
           }}

        :replace when is_binary(local_id) and not is_nil(s.record.preparation) ->
          {:ok, "recovery.attest_replacement",
           %{
             "local_record_id" => local_id,
             "preparation" => s.release.preparation,
             "host_current" => current,
             "operator" => operator
           }}

        :prepare_disposition when not is_nil(s.record.disposition) ->
          {:ok, "service.prepare",
           %{
             "authorization" => "disposition",
             "authorization_id" => s.record.disposition.disposition_id,
             "operator" => operator
           }}

        _ ->
          {:error, :evidence_stale}
      end
    else
      {:error, :not_authorized}
    end
  end

  def binding(s),
    do: %{
      "box_boot_id" => s.box.boot_id,
      "connection_id" => s.box.connection_id,
      "current_session_id" => s.checkpoint.session_id
    }

  def intent(command),
    do: %{
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

  defp fresh?(s),
    do:
      s.box.connected and s.box.lease_until_ms != nil and
        GameSession.now(s) < s.box.lease_until_ms
end
