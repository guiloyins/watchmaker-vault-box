defmodule VaultWeb do
  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]
      import Plug.Conn
      unquote(routes())
    end
  end

  def router do
    quote do
      use Phoenix.Router
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView
      unquote(components())
    end
  end

  def html do
    quote do
      use Phoenix.Component
      unquote(components())
    end
  end

  defp components do
    quote do
      import Phoenix.HTML
      unquote(routes())
    end
  end

  defp routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: VaultWeb.Endpoint,
        router: VaultWeb.Router,
        statics: ~w(assets)
    end
  end

  defmacro __using__(which) when is_atom(which), do: apply(__MODULE__, which, [])
end
