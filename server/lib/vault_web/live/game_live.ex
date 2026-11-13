defmodule VaultWeb.GameLive do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1, put_flash: 3, redirect: 2]

  alias Vault.{Games, Updates}
  alias VaultWeb.{Auth, BrowserController}

  def mount(socket, game_id, audience, panels) do
    principal = socket.assigns.principal

    with {:ok, projection} <- bootstrap(socket, principal, game_id, audience) do
      socket =
        socket
        |> assign(:game_id, game_id)
        |> assign(:audience, audience)
        |> assign(:projection, projection)
        |> assign(:bindings, %{})
        |> assign(:panels, panels)

      if connected?(socket) do
        schedule_authorization_check(principal)
        {:ok, BrowserController.bind(socket, panels)}
      else
        {:ok, socket}
      end
    else
      {:error, _} ->
        {:ok,
         socket
         |> put_flash(:error, "The game is unavailable.")
         |> redirect(to: Auth.sign_in_path(principal.kind))}
    end
  end

  def handle_event(event, params, socket) do
    authenticated(socket, fn ->
      BrowserController.handle_event(event, params, socket)
    end)
  end

  def handle_info({:vault_snapshot, game_id, session_id, audience, projection}, socket) do
    authenticated(socket, fn ->
      current = socket.assigns.projection

      if game_id == socket.assigns.game_id and audience == socket.assigns.audience and
           session_id == current.session_id and projection.session_id == session_id and
           revision(projection) > revision(current) do
        {:noreply, assign(socket, :projection, projection)}
      else
        {:noreply, socket}
      end
    end)
  end

  def handle_info({:vault_session, game_id, old_session, _new_session}, socket) do
    authenticated(socket, fn ->
      %{principal: principal, projection: current, audience: audience} = socket.assigns

      if game_id == socket.assigns.game_id and old_session == current.session_id do
        Updates.unsubscribe(game_id, old_session, audience)

        case Updates.subscribe(principal, game_id, audience) do
          {:ok, projection} ->
            socket = assign(socket, :projection, projection)
            {:noreply, BrowserController.reset(socket, socket.assigns.panels)}

          _ ->
            {:noreply, socket}
        end
      else
        {:noreply, socket}
      end
    end)
  end

  def handle_info(:vault_check_auth, socket) do
    authenticated(socket, fn ->
      schedule_authorization_check(socket.assigns.principal)
      {:noreply, socket}
    end)
  end

  def handle_info({:vault_context, _, _, _} = message, socket) do
    authenticated(socket, fn -> {:noreply, BrowserController.handle_info(message, socket)} end)
  end

  def handle_info({:vault_disconnect, _, _} = message, socket) do
    authenticated(socket, fn -> {:noreply, BrowserController.handle_info(message, socket)} end)
  end

  def handle_info({:vault_challenge, _, _, _, _} = message, socket) do
    {:noreply, BrowserController.handle_info(message, socket)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  def refresh_snapshot(socket) do
    %{principal: principal, game_id: game_id, audience: audience, projection: current} =
      socket.assigns

    case Games.fetch(principal, game_id, audience) do
      {:ok, %{session_id: session_id} = fresh} when session_id == current.session_id ->
        if revision(fresh) >= revision(current),
          do: assign(socket, :projection, fresh),
          else: socket

      _ ->
        socket
    end
  end

  def authenticated(socket, callback) do
    if Auth.valid?(socket.assigns.principal),
      do: callback.(),
      else: {:noreply, redirect(socket, to: Auth.sign_in_path(socket.assigns.principal.kind))}
  end

  defp bootstrap(socket, principal, game_id, audience) do
    if connected?(socket),
      do: Updates.subscribe(principal, game_id, audience),
      else: Games.fetch(principal, game_id, audience)
  end

  defp revision(projection), do: {projection.state_revision, projection.ui_revision}

  defp schedule_authorization_check(principal) do
    expiry = principal.expires_at_ms - System.system_time(:millisecond)
    Process.send_after(self(), :vault_check_auth, expiry |> max(1) |> min(1_000))
  end
end
