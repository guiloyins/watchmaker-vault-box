defmodule Vault.SimulatedBox.Adapter do
  @moduledoc "Trusted, in-process transport for the server-selected simulated box."

  alias Vault.JSON
  alias Vault.SimulatedBox.Model
  alias Vault.SimulatedBox.Model.{Durable, Service}

  @statuses ~w(accepted motion_complete uncertain failed not_requested)a
  @maximum 9_007_199_254_740_991
  @failures ~w(not_armed unknown_position stale_binding busy history_full connection_lost
               reboot_interrupted freshness_lost travel_timeout limit_fault driver_fault
               unknown_command)a

  @operator %{"operator_id" => "simulation", "observation" => "Modeled service operation"}
  @service_fields ~w(sv type request_id device_id box_boot_id operation_id expected_revision command args)
  @service_args %{
    "inspect" => :inspect,
    "operation.get" => ~w(operation_id),
    "provision.set" => ~w(configuration),
    "stop" => ~w(reason operator),
    "recovery.enter" => ~w(preparation host_current operator),
    "reboot" => ~w(reason),
    "recovery.seal" =>
      ~w(local_record_id recovery_id recovery_generation binding host_current operator),
    "recovery.attest_disposition" => ~w(local_record_id disposition operator),
    "recovery.attest_replacement" => ~w(local_record_id preparation host_current operator),
    "service.prepare" => ~w(authorization authorization_id operator),
    "history.clear" => ~w(retained_host_history operator),
    "history.fence" => ~w(clear_operation_id binding),
    "service.exit" => ~w(binding),
    "calibration.set" => ~w(calibration operator),
    "reference.set" => ~w(calibration_revision reference method operator),
    "position.confirm" => ~w(position basis command_id operator),
    "motion.jog" => ~w(direction steps rate_steps_s timeout_ms),
    "motion.home" => ~w(calibration_revision),
    "motion.relock" => ~w(calibration_revision),
    "motion.release_test" => ~w(calibration_revision),
    "motion.stop" => ~w(operator)
  }

  def boot_id(runtime), do: call(runtime, :boot_id)

  def bind(runtime, boot, binding) do
    with :ok <- call(runtime, {:bind, boot, binding}),
         {:ok, owner_id} <- call(runtime, :adapter_owner) do
      Process.put({__MODULE__, runtime}, owner_id)
      :ok
    end
  end

  def barrier(runtime), do: call(runtime, :adapter_barrier)
  def store_worker(runtime), do: call(runtime, :adapter_store_worker)

  def challenge(runtime, generation, heartbeat_seq, original_issue_ms),
    do: deliver(runtime, {:challenge, generation, heartbeat_seq, original_issue_ms})

  def arm(runtime, generation, arm_id), do: deliver(runtime, {:arm, generation, arm_id})
  def disarm(runtime, generation, arm_id), do: deliver(runtime, {:disarm, generation, arm_id})

  def release(runtime, generation, boot, arm_id, heartbeat_seq, command_id, fingerprint),
    do:
      deliver(
        runtime,
        {:release, generation, boot, arm_id, heartbeat_seq, command_id, fingerprint}
      )

  def query(runtime, generation, command_id, query_context),
    do: deliver(runtime, {:query, generation, command_id, query_context})

  def ack_status(runtime, generation, status_seq),
    do: deliver(runtime, {:ack_status, generation, status_seq})

  def local_control_lost(runtime, effect_generation, motion_generation),
    do: deliver(runtime, {:local_control_lost, effect_generation, motion_generation})

  def unbind(runtime, generation, reason), do: deliver(runtime, {:unbind, generation, reason})
  def fault(runtime, fault), do: deliver(runtime, {:fault, fault})
  def service(runtime, request), do: call(runtime, {:service, request})
  def request_service(runtime, request, tag), do: deliver(runtime, {:service, request, tag})
  def prepare(runtime), do: call(runtime, :prepare)
  def prepare_async(runtime, tag), do: deliver(runtime, {:prepare, tag})

  def service_operation(runtime, command, args),
    do: call(runtime, {:service_operation, command, args})

  def service_operation_async(runtime, command, args, tag),
    do: deliver(runtime, {:service_operation, command, args, tag})

  def inspect(runtime, section), do: call(runtime, {:inspect, section})

  defp call(runtime, message) do
    GenServer.call(runtime, message, 3_000)
  catch
    :exit, {:timeout, _} ->
      case message do
        {:bind, _, _} ->
          {:error, :unavailable}

        call when call in [:boot_id, :adapter_owner, :adapter_barrier, :adapter_store_worker] ->
          {:error, :unavailable}

        _ ->
          Service.error(:commit_uncertain)
      end

    :exit, _ ->
      case message do
        {:bind, _, _} ->
          {:error, :unavailable}

        call when call in [:boot_id, :adapter_owner, :adapter_barrier, :adapter_store_worker] ->
          {:error, :unavailable}

        _ ->
          Service.error(:storage_error)
      end
  end

  defp deliver(runtime, event) do
    case Process.get({__MODULE__, runtime}) do
      owner_id when is_reference(owner_id) ->
        GenServer.cast(runtime, {:owner, self(), owner_id, event})

      _ ->
        {:error, :invalid_binding}
    end
  end

  @doc false
  def service_request(model, command, args) do
    base = %{
      "sv" => 1,
      "type" => "request",
      "request_id" => id("req"),
      "device_id" => model.config.device_id,
      "box_boot_id" => model.boot_id,
      "command" => command,
      "args" => args
    }

    {operation_id, revision} =
      if command in ~w(inspect operation.get) do
        {nil, nil}
      else
        revision = Model.durable(model)["service"]["service_revision"]

        sequence =
          (revision + 1)
          |> Integer.to_string(16)
          |> String.downcase()
          |> String.pad_leading(16, "0")

        {"svc_" <> sequence <> "_" <> random_suffix(), revision}
      end

    Map.merge(base, %{"operation_id" => operation_id, "expected_revision" => revision})
  end

  @doc false
  def valid_service?(request) do
    Durable.fields?(request, @service_fields) and request["sv"] == 1 and
      request["type"] == "request" and Durable.id?(request["request_id"]) and
      Durable.id?(request["device_id"]) and
      (is_nil(request["box_boot_id"]) or Durable.id?(request["box_boot_id"])) and
      is_binary(request["command"]) and
      Durable.id?(String.replace(request["command"], ".", "_")) and
      valid_args?(request["command"], request["args"]) and valid_local_value?(request, 0) and
      bounded_service?(request)
  end

  defp bounded_service?(request) do
    with {:ok, encoded} <- JSON.canonical(request),
         {:ok, _} <- JSON.decode_object(encoded, %{max_bytes: 4_096, max_depth: 8}) do
      true
    else
      _ -> false
    end
  end

  defp valid_args?(command, args) when is_map(args) and not is_struct(args) do
    case @service_args[command] do
      :inspect -> inspect_args?(args)
      nil -> true
      fields -> Durable.fields?(args, fields) and valid_arg_values?(command, args)
    end
  end

  defp valid_args?(_command, _args), do: false

  defp valid_arg_values?("service.prepare", args),
    do:
      args["authorization"] in ~w(ordinary disposition clear) and
        (is_nil(args["authorization_id"]) or Durable.id?(args["authorization_id"]))

  defp valid_arg_values?("recovery.enter", args),
    do: is_map(args["preparation"]) and is_map(args["host_current"])

  defp valid_arg_values?("recovery.seal", args),
    do:
      Durable.id?(args["local_record_id"]) and Durable.id?(args["recovery_id"]) and
        Durable.positive?(args["recovery_generation"]) and is_map(args["host_current"]) and
        Durable.service_binding?(args["binding"])

  defp valid_arg_values?("recovery.attest_disposition", args),
    do: Durable.id?(args["local_record_id"]) and is_map(args["disposition"])

  defp valid_arg_values?("recovery.attest_replacement", args),
    do:
      Durable.id?(args["local_record_id"]) and is_map(args["preparation"]) and
        is_map(args["host_current"])

  defp valid_arg_values?("history.fence", args),
    do:
      Durable.sequence(args["clear_operation_id"]) != nil and
        Durable.service_binding?(args["binding"])

  defp valid_arg_values?("service.exit", args), do: Durable.service_binding?(args["binding"])

  defp valid_arg_values?("motion.jog", args),
    do:
      args["direction"] in ~w(toward_locked toward_released) and
        Enum.all?(~w(steps rate_steps_s timeout_ms), &Durable.positive?(args[&1]))

  defp valid_arg_values?(command, args)
       when command in ~w(motion.home motion.relock motion.release_test),
       do: Durable.positive?(args["calibration_revision"])

  defp valid_arg_values?(_command, _args), do: true

  defp valid_local_value?(value, depth)
       when is_map(value) and depth < 8 and map_size(value) <= 32,
       do:
         Enum.all?(value, fn {key, element} ->
           Durable.id?(key) and valid_local_value?(element, depth + 1)
         end)

  defp valid_local_value?(value, depth) when is_list(value) and depth < 8,
    do: length(value) <= 32 and Enum.all?(value, &valid_local_value?(&1, depth + 1))

  defp valid_local_value?(value, _depth) when is_integer(value), do: value in 0..@maximum
  defp valid_local_value?(value, _depth) when is_boolean(value) or is_nil(value), do: true

  defp valid_local_value?(value, _depth) when is_binary(value),
    do:
      byte_size(value) <= 256 and String.valid?(value) and
        not Regex.match?(~r/[\x{0000}-\x{001F}\x{007F}-\x{009F}]/u, value)

  defp valid_local_value?(_value, _depth), do: false

  defp inspect_args?(%{"section" => section} = args)
       when section in ~w(status calibration provisioning clear),
       do: map_size(args) == 1

  defp inspect_args?(%{"section" => "command", "command_id" => id} = args),
    do: map_size(args) == 2 and Durable.id?(id)

  defp inspect_args?(%{"section" => "recovery", "local_record_id" => id} = args),
    do: map_size(args) == 2 and Durable.id?(id)

  defp inspect_args?(%{"section" => "journal", "after_command_id" => id} = args),
    do: map_size(args) == 2 and (is_nil(id) or Durable.id?(id))

  defp inspect_args?(%{"section" => "clear_entry", "index" => index} = args),
    do: map_size(args) == 2 and Durable.nonnegative?(index)

  defp inspect_args?(_args), do: false

  @doc false
  def ordinary_preparation(model) do
    durable = Model.durable(model)
    service = durable["service"]
    calibration_revision = Durable.calibration_revision(durable)

    stop =
      if service["service_inhibited"],
        do: [],
        else: [{"stop", %{"reason" => "maintenance", "operator" => @operator}}]

    calibration =
      if calibration_revision == 0,
        do: [
          {"calibration.set", %{"calibration" => Durable.calibration(), "operator" => @operator}}
        ],
        else: []

    stop ++
      [
        {"service.prepare",
         %{"authorization" => "ordinary", "authorization_id" => nil, "operator" => @operator}}
      ] ++
      calibration ++
      [
        {"reference.set",
         %{
           "calibration_revision" => max(calibration_revision, 1),
           "reference" => "locked_zero",
           "method" => "manual_verified",
           "operator" => @operator
         }},
        {"position.confirm",
         %{
           "position" => "locked",
           "basis" => "manual_verified",
           "command_id" => nil,
           "operator" => @operator
         }}
      ]
  end

  @doc false
  def report(model, status_seq, command_id, refusal) do
    {release_status, failure_code, original_session} = outcome(model, command_id, refusal)

    status = %{
      connection_id: model.binding.connection_id,
      box_boot_id: model.boot_id,
      session_id: model.binding.session_id,
      status_seq: status_seq,
      command_id: command_id,
      release_status: release_status,
      failure_code: failure_code,
      command_session_id: original_session,
      motor_active: Model.motor_active?(model),
      latch_position: :unknown,
      position_basis: :unverified,
      command_confirmation: nil,
      readiness: readiness(model)
    }

    wire = status |> stringify() |> Map.merge(%{"v" => 1, "type" => "box_status"})
    {:ok, original_json} = JSON.canonical(wire)
    {:ok, parsed} = JSON.decode_object(original_json, %{max_bytes: 4_096, max_depth: 8})
    {:ok, comparison} = JSON.comparison(parsed, 4_096)
    %{status: status, original_json: original_json, comparison: comparison}
  end

  defp outcome(_model, _command, refusal) when refusal in @failures, do: {:failed, refusal, nil}
  defp outcome(_model, nil, _refusal), do: {:not_requested, nil, nil}

  defp outcome(model, command, _refusal) do
    case Durable.journal_entry(Model.durable(model), command) do
      nil ->
        {:uncertain, :unknown_command, nil}

      entry ->
        observed = Durable.observed_outcome(entry)

        {known_atom(observed["kind"], @statuses), known_atom(observed["failure_code"], @failures),
         entry["fingerprint"]["session_id"]}
    end
  end

  @doc false
  def readiness(model) do
    Map.merge(model.readiness, %{
      arm_id: if(model.arm, do: model.arm.arm_id),
      armed_session_id: if(model.arm, do: model.arm.binding.session_id)
    })
  end

  defp known_atom(value, choices), do: Enum.find(choices, &(Atom.to_string(&1) == value))

  defp stringify(value) when is_map(value),
    do: Map.new(value, fn {key, element} -> {Atom.to_string(key), stringify(element)} end)

  defp stringify(value) when is_atom(value) and value not in [true, false, nil],
    do: Atom.to_string(value)

  defp stringify(value), do: value

  @doc false
  def id(prefix), do: prefix <> "_" <> random_suffix()

  defp random_suffix, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
end
