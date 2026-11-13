defmodule Vault.Simulator.Scenarios do
  @moduledoc false
  @compile {:no_warn_undefined, Vault.Simulator.CLI}

  alias Vault.{Credentials, MaintenanceGuard, Protocol}
  alias Vault.Simulator.{BoxRuntime, Client, FaultTransport, Runner}

  def run("controller-smoke", opts), do: controller(opts, [])
  def run("controller-script", opts), do: controller(opts, opts[:steps])
  def run("box", opts), do: box(opts, :prepare)
  def run("box-inspect", opts), do: box(opts, :inspect)
  def run("box-service", opts), do: box(opts, {:service, opts[:service_request]})
  def run("box-console", opts), do: box(opts, :console)
  def run("fault-fragments", opts), do: fragments(opts)

  defp controller(opts, steps) do
    with_runner(opts, fn ->
      with {:ok, g, gate, welcome} <- welcome(),
           true <- opts[:role] in welcome["allowed_roles"],
           :ok <- command(g, gate, "claim_role", %{"role" => opts[:role]}),
           {:ok, snapshot} <- snapshot(g, fn state -> state["role"] == opts[:role] end),
           {:ok, snapshot} <- actions(g, gate, snapshot, steps),
           :ok <- command(g, gate, "request_snapshot", %{}),
           :ok <- alive(g, opts[:duration_ms]) do
        IO.puts("Controller role #{opts[:role]} connected; observed phase #{snapshot["phase"]}.")
        :ok
      else
        _ -> {:error, :controller_scenario_failed}
      end
    end)
  end

  defp actions(_g, _gate, state, []), do: {:ok, state}

  defp actions(g, gate, state, [step | rest]) when step in ~w(up down left right) do
    with :ok <-
           command(g, gate, "move", %{
             "direction" => step,
             "expected_board_version" => state["board_version"]
           }),
         {:ok, next} <- snapshot(g, &(&1["state_revision"] > state["state_revision"])) do
      actions(g, gate, next, rest)
    end
  end

  defp actions(g, gate, state, [step | rest]) when step in ~w(star moon sun wave) do
    with :ok <- command(g, gate, "select_rune", %{"rune" => step}),
         {:ok, next} <- snapshot(g, &(get_in(&1, ["seal", "selected_rune"]) == step)) do
      actions(g, gate, Map.merge(state, next), rest)
    end
  end

  defp actions(g, gate, state, ["hold" | rest]) do
    with :ok <- neutral_ack(g),
         :ok <- Client.hold(gate, true),
         :ok <- alive(g, 2_200),
         :ok <- Client.hold(gate, false) do
      actions(g, gate, state, rest)
    end
  end

  defp neutral_ack(g) do
    await(fn
      {:simulator_client, ^g, {:heartbeat_ack, %{"input_accepted" => true}}} -> {:ok, :accepted}
      {:simulator_runner, {:retired, ^g, _, _}} -> {:error, :disconnected}
      _ -> :skip
    end)
    |> case do
      {:ok, :accepted} -> :ok
      error -> error
    end
  end

  defp box(opts, mode) do
    with_runner(opts, fn ->
      with {:ok, g, _gate, welcome} <- welcome(),
           [] <- welcome["allowed_roles"],
           {:ok, snapshot} <- snapshot(g, &(&1["projection"] == "box")),
           true <- get_in(snapshot, ["box", "simulated"]),
           :ok <- box_action(opts[:box], mode),
           :ok <- if(mode == :console, do: :ok, else: alive(g, opts[:duration_ms])) do
        IO.puts("Simulation box connected; latch position remains unknown and unverified.")
        :ok
      else
        _ -> {:error, :box_scenario_failed}
      end
    end)
  end

  defp box_action(box, :inspect) do
    service_output(BoxRuntime.service(box, "inspect", %{"section" => "status"}))
  end

  defp box_action(box, {:service, %{"command" => command, "args" => args} = request}) do
    # A modeled provisioning call is unsupported. Do not echo or forward
    # credentials contained in a caller-supplied service request.
    if command == "provision.set" do
      {:error, :unsupported_service_operation}
    else
      result =
        if map_size(request) == 2,
          do: BoxRuntime.service(box, command, args),
          else: BoxRuntime.request(box, request)

      service_output(result)
    end
  end

  defp box_action(box, :console) do
    IO.puts("Simulation console. Send one JSON service request per line; EOF stops.")
    console(box)
  end

  defp box_action(box, :prepare) do
    with %{"status" => "ok"} <- BoxRuntime.prepare(box),
         %{} = binding <- BoxRuntime.binding(box),
         %{"status" => "ok"} <- BoxRuntime.service(box, "service.exit", %{"binding" => binding}) do
      IO.puts("Modeled service preparation and explicit exit completed.")
      :ok
    else
      _ -> {:error, :preparation_refused}
    end
  end

  defp console(box) do
    case read_line(<<>>) do
      :eof ->
        :ok

      {:error, _} = error ->
        error

      {:ok, line} ->
        case Vault.Simulator.CLI.decode_service(line) do
          {:ok, request} ->
            case box_action(box, {:service, request}) do
              :ok -> :ok
              {:error, reason} -> IO.puts(:stderr, "Simulation operation refused: #{reason}.")
            end

          {:error, _} ->
            IO.puts(:stderr, "Invalid simulation service request.")
        end

        console(box)
    end
  end

  defp read_line(bytes) when byte_size(bytes) <= 4_096 do
    case IO.binread(:stdio, 1) do
      :eof when bytes == <<>> -> :eof
      :eof -> {:ok, bytes}
      "\n" -> {:ok, bytes}
      byte when is_binary(byte) -> read_line(bytes <> byte)
      _ -> {:error, :service_input_unreadable}
    end
  end

  defp read_line(_), do: {:error, :service_request_too_large}

  defp service_output(result) do
    with {:ok, encoded} <- Vault.JSON.canonical(result),
         true <- byte_size(encoded) <= 8_192 do
      IO.puts(encoded)
      if result["status"] == "ok", do: :ok, else: {:error, :service_operation_refused}
    else
      _ -> {:error, :invalid_service_response}
    end
  end

  defp with_runner(opts, run) do
    scenario = self()
    # Keep CLI observation bounded during an interactive console wait. The
    # runner owns deadlines and reconnection independently of the console.
    trace = if opts[:scenario] == "box-console", do: start_console_trace(scenario), else: scenario

    opts =
      Keyword.merge(opts,
        trace: trace,
        client_trace: trace,
        reconnect: opts[:scenario] == "box-console"
      )

    with {:ok, runner} <- Runner.start_link(opts) do
      try do
        run.()
      after
        :ok = Runner.shutdown(runner)
        if trace != scenario, do: send(trace, :stop)
      end
    end
  end

  defp start_console_trace(scenario) do
    spawn_link(fn -> console_trace(scenario, true, true) end)
  end

  defp console_trace(scenario, welcome, snapshot) do
    receive do
      :stop ->
        :ok

      {:simulator_client, _, {:welcome, _, _}} = event when welcome ->
        send(scenario, event)
        console_trace(scenario, false, snapshot)

      {:simulator_client, _, {:snapshot, %{"projection" => "box"}}} = event
      when snapshot and not welcome ->
        send(scenario, event)
        console_trace(scenario, welcome, false)

      {:simulator_runner, {:retired, _, _, _}} = event when welcome or snapshot ->
        send(scenario, event)
        console_trace(scenario, false, false)

      _ ->
        console_trace(scenario, welcome, snapshot)
    end
  end

  defp welcome do
    await(fn
      {:simulator_client, g, {:welcome, gate, msg}} -> {:ok, g, gate, msg}
      {:simulator_runner, {:retired, _, reason, _}} -> {:error, reason}
      _ -> :skip
    end)
  end

  defp command(g, gate, action, payload) do
    with :ok <- Client.command(gate, action, payload) do
      await(fn
        {:simulator_client, ^g, {:command_result, %{"status" => "applied"}}} -> :ok
        {:simulator_client, ^g, {:command_result, _}} -> {:error, :command_rejected}
        {:simulator_client, ^g, {:action_refused, reason}} -> {:error, reason}
        {:simulator_runner, {:retired, ^g, reason, _}} -> {:error, reason}
        _ -> :skip
      end)
    end
  end

  defp snapshot(g, accept) do
    remembered = Process.get({__MODULE__, :snapshot})

    case remembered do
      {^g, msg} ->
        if accept.(msg), do: {:ok, msg}, else: await_snapshot(g, accept)

      _ ->
        await_snapshot(g, accept)
    end
  end

  defp await_snapshot(g, accept) do
    await(fn
      {:simulator_client, ^g, {:snapshot, msg}} -> if accept.(msg), do: {:ok, msg}, else: :skip
      {:simulator_runner, {:retired, ^g, reason, _}} -> {:error, reason}
      _ -> :skip
    end)
  end

  defp alive(g, duration) do
    await(
      fn
        {:simulator_runner, {:retired, ^g, reason, _}} -> {:error, reason}
        {:simulator_client, ^g, {:action_refused, reason}} -> {:error, reason}
        _ -> :skip
      end,
      duration
    )
    |> case do
      {:error, :timeout} -> :ok
      error -> error
    end
  end

  defp await(match, timeout \\ 3_000), do: receive_until(match, now() + timeout)

  defp receive_until(match, due) do
    remaining = due - now()

    if remaining <= 0 do
      {:error, :timeout}
    else
      receive do
        event ->
          remember_snapshot(event)

          case match.(event) do
            :skip -> receive_until(match, due)
            result -> result
          end
      after
        remaining -> {:error, :timeout}
      end
    end
  end

  defp fragments(opts) do
    with {:ok, <<secret::binary-size(64), "\n">>} <-
           MaintenanceGuard.read_protected(opts[:credentials_file], 65),
         true <- Credentials.device_key?(secret),
         {:ok, socket} <- FaultTransport.connect(opts[:uri], secret) do
      try do
        fragment_exchange(socket, opts)
      after
        :gen_tcp.close(socket)
      end
    else
      _ -> {:error, :fault_scenario_failed}
    end
  end

  defp fragment_exchange(socket, opts) do
    hello = %{
      "v" => 1,
      "type" => "hello",
      "device_id" => opts[:device_id],
      "boot_id" => Credentials.id("boot_"),
      "device_class" => "controller",
      "firmware_version" => "0.1.0",
      "capabilities" => %{
        "touch" => true,
        "screen_width" => 240,
        "screen_height" => 320,
        "max_message_bytes" => 8_192
      }
    }

    {:ok, encoded} = Protocol.encode(hello, :device_to_server)
    <<part::binary-size(29), rest::binary>> = encoded

    with :ok <- FaultTransport.split_send(socket, FaultTransport.frame(1, part, fin: false), 1),
         :ok <- :gen_tcp.send(socket, FaultTransport.frame(9, "interleaved")),
         :ok <- FaultTransport.split_send(socket, FaultTransport.frame(0, rest), 7),
         {:ok, {1, 10, "interleaved"}} <- FaultTransport.recv_frame(socket, :gen_tcp),
         {:ok, {1, 1, bytes}} <- FaultTransport.recv_frame(socket, :gen_tcp),
         {:ok, %{message: %{"type" => "welcome"}}} <- Protocol.decode(bytes, :server_to_device) do
      IO.puts("Split fragmented hello accepted; interleaved ping received its pong.")
      :ok
    else
      _ -> {:error, :fragment_exchange_failed}
    end
  end

  defp remember_snapshot({:simulator_client, g, {:snapshot, msg}}),
    do: Process.put({__MODULE__, :snapshot}, {g, msg})

  defp remember_snapshot(_), do: :ok

  defp now, do: System.monotonic_time(:millisecond)
end
