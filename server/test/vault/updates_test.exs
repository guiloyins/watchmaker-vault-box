defmodule Vault.UpdatesTest do
  use ExUnit.Case, async: false
  alias Vault.{Auth, Controllers, Credentials, Games, Repo, Updates}
  alias Vault.GameStore.Operation

  setup do
    root = Application.fetch_env!(:vault, :data_dir)
    source = {127, 0, 0, :erlang.phash2(make_ref(), 254) + 1}
    {:ok, key} = Credentials.read_key(Path.join(root, "player-a.key"))
    {:ok, player} = Auth.exchange(:player, key, source)
    {:ok, host_key} = Credentials.read_key(Path.join(root, "host.key"))
    {:ok, host} = Auth.exchange(:host, host_key, source)
    {:ok, game} = Games.active_id()

    on_exit(fn ->
      Auth.logout(player)
      Auth.logout(host)
    end)

    %{player: player, host: host, game: game}
  end

  test "authorized subscription returns one role and refuses forged scopes", c do
    assert {:ok, projection} = Updates.subscribe(c.player, c.game, {:player, :a})
    assert projection.role == :a
    assert {:error, %{code: :not_authorized}} = Updates.subscribe(c.player, c.game, {:player, :b})
    assert {:error, %{code: :not_authorized}} = Updates.subscribe(c.player, c.game, :host)

    assert {:error, %{code: :not_authorized}} =
             Updates.subscribe(c.player, c.game, "vault:forged:host")

    assert {:error, %{code: :not_found}} =
             Updates.subscribe(c.player, "unknown_game", {:player, :a})

    Updates.unsubscribe(c.game, projection.session_id, {:player, :a})
  end

  test "host/public/box separation and logout are checked on delivery and fetch", c do
    assert {:ok, host} = Games.fetch(c.host, c.game, :host)
    assert host.panels.a.role == :a
    assert host.panels.b.role == :b
    assert {:ok, public} = Games.fetch(c.host, c.game, :public)

    refute Enum.any?(
             [:maze, :seal, :hold, :board_version, :panels, :actors, :diagnostics],
             &Map.has_key?(public, &1)
           )

    Auth.logout(c.player)
    refute Updates.authorized?(c.player, c.game, {:player, :a})
    assert {:error, %{code: :not_authorized}} = Games.fetch(c.player, c.game, {:player, :a})
  end

  test "logout between topic admission and the bootstrap fetch removes the subscription", c do
    game = Controllers.id("bootstrap")
    session = Controllers.id("session")
    topic = "vault:#{game}:#{session}:player-a"
    player = c.player
    subscriber = self()

    fake_game =
      Task.async(fn ->
        {:ok, _} = Registry.register(Vault.Registry, game, nil)
        send(subscriber, :ready_to_subscribe)

        receive do
          {:"$gen_call", from, {:scope, ^player, {:player, :a}}} ->
            GenServer.reply(from, {:ok, session})
        end

        receive do
          {:"$gen_call", from, {:fetch, ^player, {:player, :a}}} ->
            assert [{^subscriber, _}] = Registry.lookup(Vault.PubSub, topic)
            assert :ok = Auth.logout(player)
            GenServer.reply(from, Games.error(:not_authorized))
        end
      end)

    assert_receive :ready_to_subscribe
    assert {:error, %{code: :not_authorized}} = Updates.subscribe(player, game, {:player, :a})
    Task.await(fake_game)
    assert [] = Registry.lookup(Vault.PubSub, topic)
  end

  test "operation readback returns typed errors and rejects a logged-out host", c do
    %{request_id: request_id} = Repo.get_by!(Operation, game_id: c.game, operation: "create")

    assert {:ok, %{result: %{"request_id" => ^request_id}}} =
             Games.read_operation(c.host, c.game, request_id)

    assert {:error, %Games.Error{code: :not_found}} =
             Games.read_operation(c.host, c.game, "missing_operation")

    assert {:error, %Games.Error{code: :not_authorized}} =
             Games.read_operation(c.player, c.game, request_id)

    assert :ok = Auth.logout(c.host)

    assert {:error, %Games.Error{code: :not_authorized}} =
             Games.read_operation(c.host, c.game, request_id)
  end

  test "host logout during receipt read denies delivery of committed history", c do
    %{request_id: request_id} = Repo.get_by!(Operation, game_id: c.game, operation: "create")
    {:ok, game_session} = Games.ensure(c.game)
    test = self()
    handler_id = {__MODULE__, make_ref()}

    assert :ok =
             :telemetry.attach(
               handler_id,
               [:vault, :repo, :query],
               &__MODULE__.hold_readback/4,
               {game_session, test}
             )

    task = Task.async(fn -> Games.read_operation(c.host, c.game, request_id) end)

    try do
      assert_receive :receipt_query_finished, 1_000
      assert :ok = Auth.logout(c.host)
    after
      send(game_session, :continue_readback)
      :telemetry.detach(handler_id)
    end

    assert {:error, %Games.Error{code: :not_authorized}} = Task.await(task)
  end

  def hold_readback(_event, _measurements, metadata, {game_session, test}) do
    if self() == game_session and metadata.source == "game_operations" do
      send(test, :receipt_query_finished)

      receive do
        :continue_readback -> :ok
      after
        1_000 -> :ok
      end
    end
  end
end
