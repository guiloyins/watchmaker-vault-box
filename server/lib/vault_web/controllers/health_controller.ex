defmodule VaultWeb.HealthController do
  use VaultWeb, :controller
  def show(conn, _params), do: json(conn, %{status: "ok"})
end
