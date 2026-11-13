defmodule VaultWeb.SubscriptionTest do
  use ExUnit.Case, async: false

  alias Vault.{Auth, Controllers, Credentials, Games, Updates}
  alias Vault.Test.DeviceEndpoint, as: Client
  alias VaultWeb.GameLive

  @moduletag :m2

  test "browser subscribes before bootstrap and ignores equal, older, cross-role and old-session projections" do
    {:ok, principal} = player()
    on_exit(fn -> Auth.logout(principal) end)
    game = Controllers.id("bootstrap")
    session = Controllers.id("session")
    topic = "vault:#{game}:#{session}:player-a"
    test = self()

    bootstrap = %{session_id: session, state_revision: 1, ui_revision: 1}
    update = %{bootstrap | state_revision: 2, ui_revision: 2}

    authority =
      Task.async(fn ->
        {:ok, _} = Registry.register(Vault.Registry, game, nil)
        send(test, :ready)

        receive do
          {:"$gen_call", from, {:scope, ^principal, {:player, :a}}} ->
            GenServer.reply(from, {:ok, session})
        end

        receive do
          {:"$gen_call", from, {:fetch, ^principal, {:player, :a}}} ->
            assert [{^test, _}] = Registry.lookup(Vault.PubSub, topic)
            Updates.publish(game, session, {:player, :a}, update)
            GenServer.reply(from, {:ok, bootstrap})
        end
      end)

    assert_receive :ready
    assert {:ok, ^bootstrap} = Updates.subscribe(principal, game, {:player, :a})
    assert_receive {:vault_snapshot, ^game, ^session, {:player, :a}, ^update} = message
    Task.await(authority)

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        principal: principal,
        game_id: game,
        audience: {:player, :a},
        projection: bootstrap
      }
    }

    assert {:noreply, socket} = GameLive.handle_info(message, socket)
    assert socket.assigns.projection == update
    newer = %{update | state_revision: 3, ui_revision: 3}
    other = Controllers.id("wrong_session")

    for message <- [
          {:vault_snapshot, game, session, {:player, :a}, update},
          {:vault_snapshot, game, session, {:player, :a}, bootstrap},
          {:vault_snapshot, game, session, {:player, :b}, newer},
          {:vault_snapshot, "other_game", session, {:player, :a}, newer},
          {:vault_snapshot, game, other, {:player, :a}, %{newer | session_id: other}},
          {:vault_snapshot, game, session, {:player, :a}, %{newer | session_id: other}}
        ] do
      assert {:noreply, ^socket} = GameLive.handle_info(message, socket)
    end

    Updates.unsubscribe(game, session, {:player, :a})
  end

  test "device bootstrap observes an update published between admission and its first fetch" do
    fixture = Client.start()
    {:ok, authority} = Games.ensure(fixture.game_id)
    test = self()
    trace = {__MODULE__, make_ref()}
    game = fixture.game_id
    {:ok, host} = host()
    on_exit(fn -> Auth.logout(host) end)
    {:ok, committed} = Games.fetch(host, game, :public)

    :telemetry.attach(
      trace,
      [:vault, :repo, :query],
      &__MODULE__.publish_during_bootstrap/4,
      %{test: test, authority: authority, game: game, projection: committed}
    )

    try do
      {client, _, snapshot} = Client.connect(fixture)
      assert_receive {:bootstrap_published, revision}, 500
      assert snapshot["state_revision"] < revision

      assert {%{"state_revision" => ^revision, "projection" => "public"}, client} =
               Client.receive_type(client, "snapshot")

      Client.close(client)
    after
      :telemetry.detach(trace)
    end
  end

  test "device sends newest scoped revisions, permits explicit equal refresh, and discards a queued private view after release" do
    fixture = Client.start()
    {:ok, host} = host()
    on_exit(fn -> Auth.logout(host) end)
    game = fixture.game_id
    {client, welcome, _} = Client.connect(fixture)
    session = welcome["session_id"]

    client = Client.send_json(client, Client.command(welcome, 1, "claim_role", %{"role" => "a"}))
    assert {%{"code" => "role_claimed"}, client} = Client.receive_type(client, "command_result")

    assert {%{"projection" => "controller", "role" => "a"} = snapshot, client} =
             Client.receive_type(client, "snapshot")

    pid = Client.handler_pid(fixture, welcome)
    assert is_pid(pid)

    client = Client.send_json(client, Client.command(welcome, 2, "request_snapshot"))

    assert {%{"code" => "snapshot_sent", "state_revision" => requested}, client} =
             Client.receive_type(client, "command_result")

    assert {%{"projection" => "controller", "state_revision" => ^requested}, client} =
             Client.receive_type(client, "snapshot")

    assert requested >= snapshot["state_revision"]

    {:ok, current} = Games.fetch(host, game, {:player, :a})
    latest = %{current | state_revision: current.state_revision + 2_000}

    :sys.suspend(pid)

    try do
      for revision <- [
            latest.state_revision - 1,
            latest.state_revision,
            latest.state_revision - 2
          ] do
        Updates.publish(game, session, {:player, :a}, %{latest | state_revision: revision})
      end

      Updates.publish(game, session, {:player, :a}, %{
        latest
        | session_id: "mismatch",
          state_revision: latest.state_revision + 1
      })
    after
      :sys.resume(pid)
    end

    latest_revision = latest.state_revision

    assert {%{"state_revision" => ^latest_revision, "role" => "a"}, client} =
             Client.receive_message(
               client,
               &match?(%{"type" => "snapshot", "state_revision" => ^latest_revision}, &1)
             )

    Updates.publish(game, session, {:player, :a}, latest)
    Updates.publish(game, session, {:player, :a}, %{latest | state_revision: latest_revision - 1})

    Updates.publish(game, session, {:player, :a}, %{
      latest
      | session_id: "mismatch",
        state_revision: latest_revision + 1
    })

    assert {:error, :timeout, client} =
             Client.receive_until(
               client,
               &match?(%{"type" => "snapshot"}, &1),
               Client.now_ms() + 140
             )

    release =
      Client.command(welcome, 3, "release_role")
      |> Map.merge(Map.take(snapshot, ~w(role control_epoch)))

    # A snapshot sent now establishes the next 100 ms presentation window.
    fence_revision = latest_revision + 2
    Updates.publish(game, session, {:player, :a}, %{latest | state_revision: fence_revision})

    assert {%{"state_revision" => ^fence_revision}, client} =
             Client.receive_type(client, "snapshot")

    Updates.publish(game, session, {:player, :a}, %{latest | state_revision: fence_revision + 1})
    client = Client.send_json(client, release)

    {result, client} =
      Client.receive_message(client, &(&1["type"] in ["command_result", "snapshot"]))

    assert result["code"] == "role_released"

    assert {%{"projection" => "public", "role" => nil} = public, client} =
             Client.receive_type(client, "snapshot")

    assert Map.take(public, ~w(maze seal hold board_version)) == %{}

    refute Enum.any?(
             Registry.lookup(Vault.PubSub, "vault:#{game}:#{session}:player-a"),
             fn {owner, _} -> owner == pid end
           )

    Client.close(client)
  end

  def publish_during_bootstrap(_event, _measurements, %{source: "devices"}, context) do
    %{test: test, authority: authority, game: game, projection: projection} = context
    topic = "vault:#{game}:#{projection.session_id}:public"

    if self() == authority and Registry.lookup(Vault.PubSub, topic) != [] and
         Process.get({__MODULE__, test}) == nil do
      Process.put({__MODULE__, test}, true)
      revision = projection.state_revision + 1_000

      Updates.publish(game, projection.session_id, :public, %{
        projection
        | state_revision: revision
      })

      send(test, {:bootstrap_published, revision})
    end
  end

  def publish_during_bootstrap(_, _, _, _), do: :ok

  defp host, do: login(:host, "host.key")
  defp player, do: login(:player, "player-a.key")

  defp login(kind, file) do
    root = Application.fetch_env!(:vault, :data_dir)
    {:ok, key} = Credentials.read_key(Path.join(root, file))
    Auth.exchange(kind, key, {127, 0, 0, :erlang.phash2(make_ref(), 254) + 1})
  end
end
