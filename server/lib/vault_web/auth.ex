defmodule VaultWeb.Auth do
  @moduledoc false
  import Plug.Conn, except: [assign: 3]
  import Phoenix.Controller, only: [redirect: 2]
  import Phoenix.Component, only: [assign: 3]
  alias Vault.Auth

  @session_key "vault_principal"

  def init(kind), do: kind

  def call(conn, kind) do
    case admission(get_session(conn, @session_key), kind, conn.path_params) do
      {:ok, principal} -> assign_principal(conn, principal)
      {:error, :not_authorized} -> conn |> redirect(to: sign_in_path(kind)) |> halt()
      {:error, :scope} -> conn |> send_resp(403, "Access denied") |> halt()
    end
  end

  def on_mount(kind, params, session, socket) do
    case admission(session[@session_key], kind, params) do
      {:ok, principal} ->
        {:cont, assign(socket, :principal, principal)}

      {:error, _} ->
        {:halt, Phoenix.LiveView.redirect(socket, to: sign_in_path(kind))}
    end
  end

  def sign_in(conn, principal) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_session(@session_key, Auth.to_session(principal))
    |> put_session("live_socket_id", socket_id(principal))
  end

  def sign_out(conn) do
    kind =
      case Auth.from_session(get_session(conn, @session_key)) do
        {:ok, principal} ->
          :ok = Auth.logout(principal)
          VaultWeb.Endpoint.broadcast(socket_id(principal), "disconnect", %{})
          principal.kind

        _ ->
          :host
      end

    {conn |> configure_session(drop: true) |> clear_session(), kind}
  end

  def valid?(principal), do: Auth.valid?(principal)

  def role("a"), do: {:ok, :a}
  def role("b"), do: {:ok, :b}
  def role(_), do: {:error, :scope}

  def sign_in_path(:host), do: "/login"
  def sign_in_path(:player), do: "/join"

  defp admission(value, kind, params) do
    with {:ok, principal} <- Auth.from_session(value),
         true <- principal.kind == kind || {:error, :scope},
         :ok <- scope(principal, params) do
      {:ok, principal}
    end
  end

  defp scope(%{kind: :host}, _params), do: :ok

  defp scope(%{kind: :player, game_id: game_id, allowed_roles: allowed}, %{
         "id" => game_id,
         "role" => role
       }) do
    with {:ok, role} <- role(role),
         true <- role in allowed do
      :ok
    else
      _ -> {:error, :scope}
    end
  end

  defp scope(_, _), do: {:error, :scope}

  defp assign_principal(conn, principal), do: Plug.Conn.assign(conn, :principal, principal)
  defp socket_id(principal), do: "vault-browser:" <> principal.browser_session_id
end
