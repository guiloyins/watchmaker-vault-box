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
