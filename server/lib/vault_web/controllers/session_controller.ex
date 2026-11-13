defmodule VaultWeb.SessionController do
  use VaultWeb, :controller
  alias VaultWeb.Auth

  def host(conn, _params), do: render_form(conn, :host)
  def player(conn, _params), do: render_form(conn, :player)
  def exchange_host(conn, _params), do: exchange(conn, :host)
  def exchange_player(conn, _params), do: exchange(conn, :player)

  def logout(conn, _params) do
    {conn, kind} = Auth.sign_out(conn)
    redirect(conn, to: Auth.sign_in_path(kind))
  end

  defp exchange(conn, kind) do
    case Vault.Auth.exchange(kind, conn.body_params["access_token"], conn.remote_ip) do
      {:ok, principal} ->
        conn |> Auth.sign_in(principal) |> redirect(to: destination(principal))

      {:error, _} ->
        conn |> put_status(:unauthorized) |> render_form(kind, true)
    end
  end

  defp destination(%{kind: :host}) do
    case Vault.Games.active_id() do
      {:ok, game_id} -> ~p"/games/#{game_id}/host"
      _ -> ~p"/login"
    end
  end

  defp destination(%{kind: :player, game_id: game_id, allowed_roles: [role | _]}) do
    ~p"/games/#{game_id}/play/#{role}"
  end

  defp render_form(conn, kind, failed? \\ false) do
    conn
    |> put_layout(false)
    |> render(:new, kind: kind, failed?: failed?, page_title: "The Watchmaker’s Vault")
  end
end
