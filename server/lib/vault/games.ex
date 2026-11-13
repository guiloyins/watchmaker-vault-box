defmodule Vault.Games do
  @moduledoc "Authorized API for an explicitly initialized, single authoritative game."
  alias Vault.Controllers

  defmodule Error do
    defstruct [:code, data: %{}]
  end

  defmodule Receipt do
    defstruct [:request_id, :operation, :game_id, :session_id, :state_revision, data: %{}]
  end

  defmodule CommandResult do
    defstruct [:command_seq, :status, :code, :session_id, :state_revision, data: %{}]
  end

  defmodule InputResult do
    defstruct [:heartbeat_seq, :input_seq, :input_accepted, :code]
  end

  def create(host, request_id, config), do: Vault.Recovery.create(host, request_id, config)
  def fetch(principal, game_id, audience), do: call(game_id, {:fetch, principal, audience})
  def scope(principal, game_id, audience), do: call(game_id, {:scope, principal, audience})
  def bind(principal, game_id, options), do: call(game_id, {:bind, principal, options})

  def command(actor, game_id, seq, context, action),
    do: call(game_id, {:command, actor, seq, context, action})

  def sample(actor, game_id, input), do: call(game_id, {:sample, actor, input})

  def host(host, game_id, request_id, session_id, action),
    do: call(game_id, {:host, host, request_id, session_id, action})

  def begin_recovery(host, game_id, request_id, args),
    do: call(game_id, {:recovery, :begin_recovery, host, request_id, args})

  def replace_recovery(host, game_id, request_id, args),
    do: call(game_id, {:recovery, :replace_recovery, host, request_id, args})

  def close_recovery(host, game_id, request_id, args),
    do: call(game_id, {:recovery, :close_recovery, host, request_id, args})

  def read_operation(host, game_id, request_id),
    do: call(game_id, {:read_operation, host, request_id})

  def disconnect(actor, game_id, reason), do: call(game_id, {:disconnect, actor, reason})

  def box_observation(actor, game_id, report, query),
    do: call(game_id, {:box_observation, actor, report, query})

  def simulated_service(host, game_id, request), do: call(game_id, {:service, host, request})
  def prepare_simulated(host, game_id), do: call(game_id, {:prepare_simulated, host})
  def exit_simulated(host, game_id), do: call(game_id, {:exit_simulated, host})

  def service_operation(host, game_id, command, args),
    do: call(game_id, {:service_operation, host, command, args})

  def recovery_step(host, game_id, step, args \\ %{}),
    do: call(game_id, {:recovery_step, host, step, args})

  def simulated_controller(host, game_id, role, action),
    do: Vault.SimulatedController.action(host, game_id, role, action)

  def fault_simulated(host, game_id, fault), do: call(game_id, {:fault_simulated, host, fault})

  def active_id do
    case Vault.GameStore.active() do
      {:ok, %{game: game}} -> {:ok, game.game_id}
      _ -> error(:not_found)
    end
  end

  def ensure(game_id) do
    if Controllers.id?(game_id) do
      case Registry.lookup(Vault.Registry, game_id) do
        [{pid, _}] ->
          {:ok, pid}

        [] ->
          case Vault.GameStore.load(game_id) do
            {:ok, record} ->
              case DynamicSupervisor.start_child(
                     Vault.GameSupervisor,
                     {Vault.GameSession,
                      record: record,
                      clock: Application.get_env(:vault, :clock, Vault.Clock.system())}
                   ) do
                {:ok, pid} -> {:ok, pid}
                {:error, {:already_started, pid}} -> {:ok, pid}
                _ -> error(:storage_error)
              end

            _ ->
              error(:not_found)
          end
      end
    else
      error(:not_found)
    end
  end

  def error(code, data \\ %{}), do: {:error, %Error{code: code, data: data}}

  defp call(game_id, message) do
    with {:ok, pid} <- ensure(game_id), do: GenServer.call(pid, message, 10_000)
  catch
    :exit, _ -> error(:readback_required)
  end
end
