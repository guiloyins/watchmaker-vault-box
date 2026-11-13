defmodule Vault.Updates do
  @moduledoc "Authorized audience/session subscriptions; never a second state owner."
  alias Vault.{Controllers, Games}

  def subscribe(principal, game_id, audience), do: subscribe(principal, game_id, audience, 3)

  defp subscribe(_principal, _game_id, _audience, 0), do: Games.error(:stale_session)

  defp subscribe(principal, game_id, audience, remaining) do
    with {:ok, session_id} <- Games.scope(principal, game_id, audience),
         :ok <- Phoenix.PubSub.subscribe(Vault.PubSub, topic(game_id, session_id, audience)) do
      case Games.fetch(principal, game_id, audience) do
        {:ok, %{session_id: ^session_id} = projection} ->
          {:ok, projection}

        {:ok, _new_session} ->
          unsubscribe(game_id, session_id, audience)
          subscribe(principal, game_id, audience, remaining - 1)

        error ->
          unsubscribe(game_id, session_id, audience)
          error
      end
    end
  end

  def subscribe_device(actor, game_id, {session_id, audience, epoch} = scope) do
    with {:ok, ^scope} <- Games.device_scope(actor, game_id) do
      slot = :ets.new(:device_snapshot, [:set, :public])

      result =
        with :ok <-
               Phoenix.PubSub.subscribe(Vault.PubSub, topic(game_id, session_id, audience),
                 sender: {__MODULE__, {slot, game_id, scope}}
               ),
             {:ok, %{session_id: ^session_id, control_epoch: ^epoch} = projection} <-
               Games.device_snapshot(actor, game_id),
             true <- device_audience(projection) == audience,
             {:ok, ^scope} <- Games.device_scope(actor, game_id) do
          {:ok, slot, projection}
        end

      case result do
        {:ok, _, _} ->
          result

        error ->
          unsubscribe_device(game_id, scope, slot)
          if match?({:error, _}, error), do: error, else: Games.error(:scope_changed)
      end
    else
      {:ok, _} -> Games.error(:scope_changed)
      error -> error
    end
  end

  def unsubscribe_device(game_id, {session_id, audience, _epoch}, slot) do
    unsubscribe(game_id, session_id, audience)
    :ets.delete(slot)
    :ok
  end

  def take_device_snapshot(slot) do
    case :ets.take(slot, :latest) do
      [{:latest, _, message}] -> {:ok, message}
      [] -> :empty
    end
  end

  defp device_audience(%{projection: :controller, role: role}), do: {:player, role}
  defp device_audience(%{projection: audience}), do: audience

  @behaviour Phoenix.PubSub.Sender
  @impl true
  def send(
        pid,
        {slot, game_id, {session_id, audience, epoch}},
        {:vault_snapshot, game_id, session_id, audience,
         %{state_revision: revision, session_id: session_id, control_epoch: epoch} = projection} =
          message,
        acc
      ) do
    # The subscriber owns the slot. Publishers replace the state before a single
    # wakeup, so a blocked socket cannot accumulate a mailbox of projections.
    if device_audience(projection) == audience,
      do: offer_snapshot(pid, slot, {:latest, revision, message})

    acc
  rescue
    ArgumentError -> acc
  end

  def send(
        pid,
        {_slot, game_id, {session_id, _, _}},
        {:vault_session, game_id, session_id, _} = message,
        acc
      ) do
    Kernel.send(pid, message)
    acc
  end

  def send(_pid, _slot, _message, acc), do: acc

  defp offer_snapshot(pid, slot, {:latest, revision, _} = entry) do
    if :ets.insert_new(slot, entry) do
      Kernel.send(pid, {:vault_device_snapshot, slot})
    else
      case :ets.lookup(slot, :latest) do
        [{:latest, current, _}] when current >= revision ->
          :ok

        [{:latest, current, _}] ->
          if :ets.select_replace(slot, [{{:latest, current, :_}, [], [{:const, entry}]}]) == 0,
            do: offer_snapshot(pid, slot, entry)

        [] ->
          offer_snapshot(pid, slot, entry)
      end
    end
  end

  def unsubscribe(game_id, session_id, audience),
    do: Phoenix.PubSub.unsubscribe(Vault.PubSub, topic(game_id, session_id, audience))

  def authorized?(principal, game_id, audience),
    do: Controllers.scope?(principal, game_id, audience)

  def publish(game_id, session_id, audience, projection) do
    Phoenix.PubSub.broadcast(
      Vault.PubSub,
      topic(game_id, session_id, audience),
      {:vault_snapshot, game_id, session_id, audience, projection}
    )
  end

  def session_changed(game_id, old, new) do
    for audience <- [:host, :public, :box, {:player, :a}, {:player, :b}] do
      Phoenix.PubSub.broadcast(
        Vault.PubSub,
        topic(game_id, old, audience),
        {:vault_session, game_id, old, new}
      )
    end
  end

  defp topic(game_id, session_id, audience) do
    name =
      case audience do
        {:player, :a} -> "player-a"
        {:player, :b} -> "player-b"
        :host -> "host"
        :public -> "public"
        :box -> "box"
      end

    "vault:#{game_id}:#{session_id}:#{name}"
  end
end
