defmodule Vault.SimulatedController do
  @moduledoc "Explicitly labeled simulated CYD, driven through the ordinary actor API."
  use GenServer
  alias Vault.{Auth, Controllers, Games}
  alias Vault.Controllers.Input

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts,
      name:
        {:via, Registry, {Vault.Registry, {:simulated_controller, opts[:game_id], opts[:role]}}}
    )
  end

  def child_spec(opts),
    do: %{
      id: {__MODULE__, opts[:game_id], opts[:role]},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }

  def action(host, game, role, action) when role in [:a, :b] do
    with {:ok, principal} <- Auth.simulated_principal(host, game, role) do
      case {Registry.lookup(Vault.Registry, {:simulated_controller, game, role}), action} do
        {[], :connect} ->
          case DynamicSupervisor.start_child(
                 Vault.ControllerSupervisor,
                 {__MODULE__, game_id: game, role: role, principal: principal}
               ) do
            {:ok, _} -> :ok
            _ -> Games.error(:not_ready)
          end

        {[{pid, _}], :disconnect} ->
          DynamicSupervisor.terminate_child(Vault.ControllerSupervisor, pid)

        {[{_pid, _}], :connect} ->
          :ok

        {[{pid, _}], other} ->
          GenServer.call(pid, {:action, host, other})

        _ ->
          Games.error(:not_ready)
      end
    else
      _ -> Games.error(:not_authorized)
    end
  end

  def action(_, _, _, _), do: Games.error(:not_authorized)

  @impl true
  def init(opts) do
    state = %{
      game_id: opts[:game_id],
      role: opts[:role],
      principal: opts[:principal],
      boot_id: Controllers.id("boot"),
      actor: nil,
      context: nil,
      command_seq: 0,
      input_seq: 0,
      heartbeat_seq: nil,
      press_id: 0,
      held: false,
      neutral_sent: false,
      operator_monitor: nil
    }

    {:ok, state, {:continue, :bind}}
  end

  @impl true
  def handle_continue(:bind, s), do: bind(s)
  @impl true
  def handle_call({:action, host, action}, {caller, _}, s) do
    if host.kind == :host and Auth.valid?(host) and s.actor != nil do
      case action do
        {:hold, pressed} when is_boolean(pressed) ->
          if pressed and (not s.neutral_sent or s.context.role != s.role) do
            {:reply, Games.error(:not_ready), s}
          else
            if s.operator_monitor, do: Process.demonitor(s.operator_monitor, [:flush])

            s = %{
              s
              | held: pressed,
                press_id: if(pressed and not s.held, do: s.press_id + 1, else: s.press_id),
                operator_monitor: if(pressed, do: Process.monitor(caller))
            }

            {:reply, :ok, sample(s)}
          end

        {:move, direction, board} ->
          command(s, {:move, direction, board})

        {:select_rune, rune} ->
          command(%{s | held: false}, {:select_rune, rune})

        :claim ->
          command(s, {:claim_role, s.role})

        _ ->
          {:reply, Games.error(:not_authorized), s}
      end
    else
      {:reply, Games.error(:not_authorized), s}
    end
  end

  @impl true
  def handle_info({:vault_challenge, actor, conn, generation, heartbeat}, s) do
    if s.actor != nil and actor == s.actor.actor_id and conn == s.actor.connection_id and
         generation == s.actor.binding_generation,
       do: {:noreply, sample(%{s | heartbeat_seq: heartbeat})},
       else: {:noreply, s}
  end

  def handle_info({:vault_context, actor, context, _reason}, s) do
    {:noreply, %{s | actor: actor, context: context, held: false, neutral_sent: false}}
  end

  def handle_info({:vault_disconnect, _id, :session_changed}, s) do
    send(self(), :rebind)
    {:noreply, %{s | actor: nil, context: nil, held: false, neutral_sent: false}}
  end

  def handle_info({:vault_disconnect, _id, _reason}, s), do: {:stop, :normal, s}
  def handle_info(:rebind, s), do: bind(s)

  def handle_info({:DOWN, ref, :process, _pid, _}, %{operator_monitor: ref} = s),
    do: {:noreply, sample(%{s | held: false, operator_monitor: nil})}

  def handle_info(_, s), do: {:noreply, s}

  defp bind(s) do
    with {:ok, {actor, context}} <-
           Games.bind(s.principal, s.game_id, %{
             owner_pid: self(),
             source: :cyd,
             boot_id: s.boot_id,
             panel: s.role
           }),
         {:ok, _} <- Games.command(actor, s.game_id, 1, context, {:claim_role, s.role}) do
      {:noreply,
       %{
         s
         | actor: actor,
           context: context,
           command_seq: 1,
           input_seq: 0,
           heartbeat_seq: nil,
           held: false,
           neutral_sent: false
       }}
    else
      _ -> {:stop, :not_ready, s}
    end
  end

  defp command(s, action) do
    seq = s.command_seq + 1
    result = Games.command(s.actor, s.game_id, seq, s.context, action)
    {:reply, result, %{s | command_seq: seq}}
  end

  defp sample(%{heartbeat_seq: nil} = s), do: s

  defp sample(s) do
    seq = s.input_seq + 1
    claimed = s.context.role != nil

    input = %Input{
      heartbeat_seq: s.heartbeat_seq,
      input_seq: seq,
      context: if(claimed, do: s.context),
      pressed: claimed and s.held,
      press_id: if(claimed and s.held, do: s.press_id)
    }

    result = Games.sample(s.actor, s.game_id, input)
    neutral = match?({:ok, %{input_accepted: true}}, result) and not input.pressed
    %{s | input_seq: seq, neutral_sent: s.neutral_sent or neutral}
  end
end
