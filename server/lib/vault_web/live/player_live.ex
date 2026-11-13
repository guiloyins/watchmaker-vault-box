defmodule VaultWeb.PlayerLive do
  use VaultWeb, :live_view

  import VaultWeb.Layouts, only: [brand: 1, sign_out: 1]
  import VaultWeb.TerminalComponents
  alias VaultWeb.{Auth, BrowserController, GameLive}

  @impl true
  def mount(%{"id" => game_id, "role" => role}, _session, socket) do
    {:ok, role} = Auth.role(role)
    socket = assign(socket, :role, role)
    GameLive.mount(socket, game_id, {:player, role}, [role])
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="player-shell">
      <header class="site-header">
        <.brand caption="Cooperative clockwork puzzle" />
        <.sign_out />
      </header>
      <.terminal
        role={@role}
        view={@projection}
        actor={BrowserController.actor_for(@bindings, @role)}
        mode={:player}
      />
      <footer :if={@projection.phase != :solved} class="player-footer">
        <.box_status box={@projection.box} phase={@projection.phase} />
      </footer>
    </main>
    """
  end

  @impl true
  def handle_event(event, payload, socket) when event in ["vault:input", "vault:command"] do
    GameLive.handle_event(event, payload, socket)
  end

  def handle_event(_, _, socket), do: GameLive.authenticated(socket, fn -> {:noreply, socket} end)

  @impl true
  def handle_info(message, socket), do: GameLive.handle_info(message, socket)
end
