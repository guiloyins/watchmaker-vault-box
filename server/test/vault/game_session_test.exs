defmodule Vault.GameSessionTest do
  use ExUnit.Case, async: true

  alias Vault.{Clock, Recovery, StorageFixture}
  alias Vault.Test.FakeClock

  @moduletag :m1
  @moduletag timeout: 30_000

  test "guarded application startup commits session recovery before starting the endpoint" do
    root = StorageFixture.temp_root()
    assert {"ok\n", 0} = StorageFixture.task(root, "prepare")

    checks = """
    import ExUnit.Assertions
    alias Vault.{GameStore, Games}

    Application.put_env(:vault, :origin, "http://127.0.0.1:4000")
    Application.put_env(:vault, :port, 4000)
    Application.put_env(:vault, :bind, {127, 0, 0, 1})
    Application.put_env(:vault, VaultWeb.Endpoint, server: false, adapter: Bandit.PhoenixAdapter,
      render_errors: [formats: [html: VaultWeb.ErrorHTML, json: VaultWeb.ErrorJSON], layout: false],
      pubsub_server: Vault.PubSub, live_view: [signing_salt: "vault-test"])
    Logger.configure(level: :warning)

    assert {:ok, _} = Application.ensure_all_started(:vault)
    assert {:ok, game} = Games.active_id()
    assert [{first_authority, _}] = Registry.lookup(Vault.Registry, game)
    assert Process.alive?(first_authority)
    assert {:ok, %{checkpoint: %{session_id: first_session}}} = GameStore.load(game)
    assert :ok = Application.stop(:vault)

    assert {:ok, _} = Application.ensure_all_started(:vault)
    assert is_pid(Process.whereis(VaultWeb.Endpoint))
    assert [{restarted, _}] = Registry.lookup(Vault.Registry, game)
    assert Process.alive?(restarted) and restarted != first_authority
    assert {:ok, %{checkpoint: %{session_id: second_session, paused: true, pause_reasons: [:recovery]}}} =
      GameStore.load(game)
    assert second_session != first_session
    assert :ok = Application.stop(:vault)
    IO.puts("startup fence passed")
    """

    assert {"startup fence passed\n", 0} = StorageFixture.vm(root, checks)
  end

  test "a stale seal reply or timeout preserves the current check and equality expires its evidence" do
    clock_pid = start_supervised!({FakeClock, 0})
    clock = FakeClock.handle(clock_pid)
    stale = {:seal_readback, make_ref()}
    current = {:seal_readback, make_ref()}
    timer = Clock.schedule_at(clock, self(), {:seal_readback_timeout, current}, 3_000)

    state = %{
      clock: clock,
      seal_check: %{tag: current, timer: timer, deadline: 3_000},
      close_evidence: nil,
      seal_attestation: nil,
      query: nil
    }

    successful = %{"status" => "ok", "data" => %{"record" => %{"local_record_id" => "older"}}}

    assert ^state = Recovery.seal_readback(state, stale, %{"status" => "rejected"})
    assert ^state = Recovery.seal_readback(state, stale, successful)
    assert ^state = Recovery.seal_readback_timeout(state, stale)
    :ok = FakeClock.advance_to(clock_pid, 2_999)
    assert ^state = Recovery.seal_readback_timeout(state, current)
    :ok = FakeClock.advance_to(clock_pid, 3_000)

    expired = %{state | seal_check: nil}
    assert ^expired = Recovery.seal_readback_timeout(state, current)
    assert ^expired = Recovery.seal_readback(state, current, successful)
    assert ^expired = Recovery.seal_readback(expired, current, %{"status" => "rejected"})

    established = %{expired | close_evidence: %{query_id: "current_query"}}
    assert ^established = Recovery.seal_readback(established, stale, successful)
    assert ^established = Recovery.seal_readback_timeout(established, current)
  end

  test "public actors solve the golden route at exactly 2,000ms and a GameSession restart preserves box history" do
    root = StorageFixture.temp_root()
    assert {"ok\n", 0} = StorageFixture.task(root, "prepare")

    checks = """
    import ExUnit.Assertions
    import Ecto.Query
    alias Vault.{Auth, Credentials, Games, GameStore, Repo, SimulatedBox, Updates}
    alias Vault.GameStore.{ActuatorCommand, ReleaseObservation}
    alias Vault.SimulatedBox.{Adapter, Store}
    alias Vault.Test.{Actors, FakeClock}

    Process.flag(:trap_exit, true)
    {:ok, clock} = FakeClock.start_link(0)
    Process.unlink(clock)
    Application.put_env(:vault, :clock, FakeClock.handle(clock))
    Application.put_env(:vault, :origin, "http://127.0.0.1:4000")
    Application.put_env(:vault, :port, 4000)
    Application.put_env(:vault, :bind, {127, 0, 0, 1})
    Application.put_env(:vault, VaultWeb.Endpoint, server: false, adapter: Bandit.PhoenixAdapter,
      render_errors: [formats: [html: VaultWeb.ErrorHTML, json: VaultWeb.ErrorJSON], layout: false],
      pubsub_server: Vault.PubSub, live_view: [signing_salt: "vault-test"])
    Logger.configure(level: :warning)
    {:ok, _} = Application.ensure_all_started(:vault)

    try do
      read = fn file ->
        {:ok, token} = Credentials.read_key(Path.join(root, file))
        token
      end
      {:ok, host} = Auth.exchange(:host, read.("host.key"))
      {:ok, player_a} = Auth.exchange(:player, read.("player-a.key"))
      {:ok, player_b} = Auth.exchange(:player, read.("player-b.key"))
      {:ok, game} = Games.active_id()

      wait = fn predicate ->
        assert Enum.reduce_while(1..250, false, fn _, _ ->
          if predicate.(), do: {:halt, true}, else: (Process.sleep(4); {:cont, false})
        end)
      end
      fetch = fn ->
        {:ok, snapshot} = Games.fetch(host, game, :host)
        snapshot
      end
      wait.(fn -> fetch.().box.connected end)
      first = fetch.()
      assert first.phase == :lobby
      assert first.box.simulated
      assert first.box.latch_position == :unknown
      assert first.box.position_basis == :unverified
      assert first.box.command_confirmation == nil
      initial_session = first.session_id

      {:ok, authority} = Games.ensure(game)
      assert Enum.all?(1..4 |> Task.async_stream(fn _ -> Games.ensure(game) end),
        &(&1 == {:ok, {:ok, authority}}))
      assert [{^authority, _}] = Registry.lookup(Vault.Registry, game)
      assert {:error, %{code: :not_found}} = Games.fetch(host, "unknown_game", :host)
      assert {:error, %{code: :not_authorized}} = Games.fetch(player_a, game, {:player, :b})
      assert {:error, %{code: :not_authorized}} = Games.fetch(player_b, game, :host)
      assert {:error, %{code: :not_authorized}} = Games.host(player_a, game, "forbidden", initial_session, :start)
      assert {:error, %{code: :not_ready}} = Games.host(host, game, "too_early", initial_session, :start)

      a = player_a |> Actors.bind(game, :a) |> Actors.claim(:a)
      {:ok, simulated_b} = Auth.simulated_principal(host, game, :b)
      b = simulated_b |> Actors.bind(game, :b, :cyd) |> Actors.claim(:b)
      assert {:error, %{code: :not_authorized}} = Task.async(fn ->
        Games.command(a.actor, game, 2, a.context, {:move, :up, 0})
      end) |> Task.await()

      :ok = FakeClock.advance_to(clock, 100)
      a = a |> Actors.challenge() |> Actors.sample_ok()
      b = b |> Actors.challenge() |> Actors.sample_ok()
      assert {:ok, %{simulated: true, receipt: %{"status" => "ok"}}} = Games.prepare_simulated(host, game)
      assert {:ok, %{simulated: true, receipt: %{"status" => "ok"}}} = Games.exit_simulated(host, game)
      wait.(fn -> fetch.().box.readiness.start_verified end)
      assert {:ok, %{data: %{arm_id: arm}}} = Games.host(host, game, "arm_initial", initial_session, :arm)
      wait.(fn -> fetch.().box.readiness.arm_id == arm end)

      assert {:ok, start_receipt} = Games.host(host, game, "start_game", initial_session, :start)
      assert {:ok, repeated_start} = Games.host(host, game, "start_game", initial_session, :start)
      assert start_receipt.state_revision == repeated_start.state_revision
      assert {:error, %{code: :request_conflict}} = Games.host(host, game, "start_game", initial_session, :pause)

      assert {:ok, a_view} = Updates.subscribe(player_a, game, {:player, :a})
      assert {:ok, b_view} = Games.fetch(player_b, game, {:player, :b})
      assert a_view.maze == %{
        rows: 4, cols: 4, position: 12, goal: 3, wall_kind: "right",
        walls: [2, 5, 6, 9, 12], allowed_moves: ["up", "down"]
      }
      assert b_view.maze == %{
        rows: 4, cols: 4, position: 12, goal: 3, wall_kind: "bottom",
        walls: [1, 4, 10, 11], allowed_moves: ["left", "right"]
      }
      assert Map.take(fetch.().panels.a, [:board_version, :maze]) ==
        Map.take(a_view, [:board_version, :maze])
      refute Map.has_key?(a_view, :panels)
      refute Map.has_key?(b_view, :actors)
      {a, %{status: :rejected, code: :wrong_axis}} = Actors.command(a, {:move, :right, 0})
      {a, %{status: :rejected, code: :out_of_bounds}} = Actors.command(a, {:move, :down, 0})
      {b, %{status: :rejected, code: :wall}} = Actors.command(b, {:move, :right, 0})
      assert fetch.().panels.a.maze.position == 12

      {a, first_move} = Actors.command(a, {:move, :up, 0})
      assert %{status: :applied, code: :moved, data: %{position: 8, board_version: 1}} = first_move
      assert {:ok, ^first_move} = Games.command(a.actor, game, a.command_seq, a.context, {:move, :up, 0})
      {b, %{status: :rejected, code: :stale_board, data: %{position: 8, board_version: 1}}} =
        Actors.command(b, {:move, :right, 0})

      observer = Actors.bind(host, game, :a)
      {observer, %{status: :rejected, code: :role_busy}} = Actors.command(observer, {:claim_role, :a})
      assert :ok = Games.disconnect(observer.actor, game, :closed)
      refute fetch.().paused
      assert Enum.map(fetch.().peers, &{&1.role, &1.source}) == [a: :browser, b: :cyd]

      wrong_panel = Actors.bind(host, game, :b)
      before_assignment = GameStore.load(game) |> elem(1) |> Map.fetch!(:assignments)
      owner_a = a.actor.actor_id
      assert {:error, %{code: :not_ready}} =
        Games.host(host, game, "wrong_panel", initial_session,
          {:replace_controller, :a, wrong_panel.actor.actor_id})
      assert fetch.().assignments.a == owner_a
      assert fetch.().panels.a.maze.position == 8
      refute fetch.().paused
      assert {:ok, %{assignments: ^before_assignment}} = GameStore.load(game)
      assert {:error, :not_found} = GameStore.read_operation(game, "wrong_panel", host.subject_id)
      assert :ok = Games.disconnect(wrong_panel.actor, game, :closed)

      replacement = Actors.bind(player_a, game, :a)
      replacement_id = replacement.actor.actor_id
      assert {:ok, %{data: %{actor_id: ^replacement_id}}} =
        Games.host(host, game, "replace_a", initial_session, {:replace_controller, :a, replacement_id})
      assert fetch.().paused
      assert fetch.().assignments.a == replacement_id
      assert fetch.().panels.a.maze.position == 8
      {a, %{status: :rejected, code: :stale_controller}} = Actors.command(a, {:move, :up, 1})
      a_old = a
      a = replacement |> Actors.sync_context(:role_changed) |> Actors.sync_context(:paused)
      b = Actors.sync_context(b, :paused)
      :ok = FakeClock.advance_to(clock, 200)
      a = a |> Actors.challenge() |> Actors.sample_ok()
      b = b |> Actors.challenge() |> Actors.sample_ok()
      wait.(fn -> fetch.().box.readiness.arm_id == nil end)
      assert {:ok, %{data: %{arm_id: next_arm}}} = Games.host(host, game, "arm_again", initial_session, :arm)
      wait.(fn -> fetch.().box.readiness.arm_id == next_arm end)
      assert {:ok, _} = Games.host(host, game, "resume_game", initial_session, :resume)
      a = Actors.sync_context(a, :resumed)
      b = Actors.sync_context(b, :resumed)
      assert a.actor.actor_id != a_old.actor.actor_id

      route = [{:b, :right, 9}, {:a, :up, 5}, {:b, :left, 4}, {:a, :up, 0},
        {:b, :right, 1}, {:b, :right, 2}, {:a, :down, 6}, {:a, :down, 10},
        {:b, :right, 11}, {:a, :up, 7}, {:a, :up, 3}]
      {clients, board} = Enum.reduce(route, {%{a: a, b: b}, 1},
        fn {role, direction, position}, {clients, board} ->
          next_board = board + 1
          {client, result} = Actors.command(clients[role], {:move, direction, board})
          assert %{status: :applied, code: :moved,
            data: %{position: ^position, board_version: ^next_board}} = result
          {Map.put(clients, role, client), next_board}
        end)
      assert board == 12
      assert fetch.().phase == :seal
      assert Repo.aggregate(ActuatorCommand, :count) == 0

      {:ok, a_seal} = Games.fetch(player_a, game, {:player, :a})
      {:ok, b_seal} = Games.fetch(player_b, game, {:player, :b})
      assert a_seal.maze == nil
      assert b_seal.maze == nil
      assert a_seal.seal == %{clue_for_role: "b", clue_rune: "moon", selected_rune: nil, partner_held: false}
      assert b_seal.seal == %{clue_for_role: "a", clue_rune: "star", selected_rune: nil, partner_held: false}
      {a, %{status: :applied}} =
        clients.a |> Actors.sync_context(:role_changed) |> Actors.command({:select_rune, :sun})
      {b, %{status: :applied}} =
        clients.b |> Actors.sync_context(:role_changed) |> Actors.command({:select_rune, :moon})
      a = a |> Actors.sample_ok() |> Actors.sample_ok(1)
      b = b |> Actors.sample_ok() |> Actors.sample_ok(1)
      assert Enum.all?(fetch.().peers, & &1.held)
      refute fetch.().panels.a.hold.active
      refute fetch.().panels.b.hold.active

      {a, %{status: :applied, code: :role_released}} = Actors.command(a, :release_role)
      a = Actors.sync_context(a, :role_changed)
      b = Actors.sync_context(b, :disconnected)
      assert fetch.().paused
      assert fetch.().assignments.a == nil
      refute Enum.any?(fetch.().peers, & &1.held)
      a = Actors.claim(a, :a)
      a = Actors.sample_ok(a)
      b = Actors.sample_ok(b)
      wait.(fn -> fetch.().box.readiness.arm_id == nil end)
      assert {:ok, %{data: %{arm_id: reclaim_arm}}} =
        Games.host(host, game, "arm_after_reclaim", initial_session, :arm)
      wait.(fn -> fetch.().box.readiness.arm_id == reclaim_arm end)
      assert {:ok, _} = Games.host(host, game, "resume_after_reclaim", initial_session, :resume)
      a = a |> Actors.sync_context(:resumed) |> Actors.sample_ok()
      b = b |> Actors.sync_context(:resumed) |> Actors.sample_ok()
      {a, %{input_accepted: false, code: :must_release}} = Actors.sample(a, 1)
      refute Enum.any?(fetch.().peers, & &1.held)
      {a, %{status: :applied}} = Actors.command(a, {:select_rune, :star})
      a = a |> Actors.sample_ok() |> Actors.sample_ok(2)
      b = b |> Actors.sample_ok() |> Actors.sample_ok(2)
      assert fetch.().panels.a.hold.active

      {_a, _b} = Enum.reduce(300..2_100//100, {a, b}, fn time, {a, b} ->
        :ok = FakeClock.advance_to(clock, time)
        {a |> Actors.challenge() |> Actors.sample_ok(2),
         b |> Actors.challenge() |> Actors.sample_ok(2)}
      end)
      :ok = FakeClock.advance_to(clock, 2_199)
      assert fetch.().phase == :seal
      assert fetch.().panels.a.hold.elapsed_ms == 1_999
      assert Repo.aggregate(ActuatorCommand, :count) == 0

      assert {:ok, %{session_id: next_session}} =
        Games.host(host, game, "reset_while_held", initial_session, :reset)
      assert next_session != initial_session
      assert fetch.().phase == :lobby
      refute Enum.any?(fetch.().peers, & &1.held)
      assert {:error, %{code: :not_authorized}} =
        Games.command(a.actor, game, a.command_seq + 1, a.context, :request_snapshot)

      a = Actors.bind(player_a, game, :a, :browser, a.actor.boot_id) |> Actors.claim(:a)
      b = Actors.bind(simulated_b, game, :b, :cyd, b.actor.boot_id) |> Actors.claim(:b)
      assert a.actor.session_id == next_session
      wait.(fn -> fetch.().box.connected end)
      :ok = FakeClock.advance_to(clock, 2_200)
      a = a |> Actors.challenge() |> Actors.sample_ok()
      b = b |> Actors.challenge() |> Actors.sample_ok()
      assert Repo.aggregate(ActuatorCommand, :count) == 0
      assert {:ok, %{receipt: %{"status" => "ok"}}} = Games.prepare_simulated(host, game)
      assert {:ok, %{receipt: %{"status" => "ok"}}} = Games.exit_simulated(host, game)
      wait.(fn -> fetch.().box.readiness.start_verified end)
      assert {:ok, %{data: %{arm_id: final_arm}}} =
        Games.host(host, game, "arm_after_session_fence", next_session, :arm)
      wait.(fn -> fetch.().box.readiness.arm_id == final_arm end)
      assert {:ok, _} = Games.host(host, game, "start_after_session_fence", next_session, :start)

      clients = Enum.reduce([{:a, :up, 8} | route] |> Enum.with_index(), %{a: a, b: b},
        fn {{role, direction, position}, board}, clients ->
          {client, result} = Actors.command(clients[role], {:move, direction, board})
          assert %{status: :applied, code: :moved, data: %{position: ^position}} = result
          Map.put(clients, role, client)
        end)
      {a, %{status: :applied}} =
        clients.a |> Actors.sync_context(:role_changed) |> Actors.command({:select_rune, :star})
      {b, %{status: :applied}} =
        clients.b |> Actors.sync_context(:role_changed) |> Actors.command({:select_rune, :moon})
      a = Actors.sample_ok(a)
      b = Actors.sample_ok(b)
      {a, %{input_accepted: false, code: :must_release}} = Actors.sample(a, 2)
      {b, %{input_accepted: false, code: :must_release}} = Actors.sample(b, 2)
      refute Enum.any?(fetch.().peers, & &1.held)
      a = Actors.sample_ok(a, 3)
      b = Actors.sample_ok(b, 3)
      assert fetch.().panels.a.hold.active

      {_a, _b} = Enum.reduce(2_300..4_100//100, {a, b}, fn time, {a, b} ->
        :ok = FakeClock.advance_to(clock, time)
        {a |> Actors.challenge() |> Actors.sample_ok(3),
         b |> Actors.challenge() |> Actors.sample_ok(3)}
      end)
      :ok = FakeClock.advance_to(clock, 4_199)
      assert fetch.().phase == :seal
      assert fetch.().panels.a.hold.elapsed_ms == 1_999
      assert Repo.aggregate(ActuatorCommand, :count) == 0
      :ok = FakeClock.advance_to(clock, 4_200)
      wait.(fn -> fetch.().box.release_status == :accepted end)
      solved = fetch.()
      assert solved.phase == :solved
      assert solved.box.motor_active
      assert solved.box.readiness.arm_id == nil
      command_id = solved.box.command_id
      assert [%ActuatorCommand{command_id: ^command_id, dispatch_claimed: true,
        dispatch_retired: false, original_session_id: ^next_session}] =
        Repo.all(from c in ActuatorCommand, where: c.game_id == ^game)
      assert Repo.aggregate(ReleaseObservation, :count) >= 1

      runtime = Process.whereis(SimulatedBox)
      {:ok, box_boot} = Adapter.boot_id(runtime)
      deployment = Application.fetch_env!(:vault, :deployment)
      {:ok, box_db} = Store.open_existing(deployment.simulator_database, deployment.simulator_instance_id, deployment.simulator_device_id)
      {:ok, before} = Store.load(box_db)
      :ok = Store.close(box_db)
      assert [%{"command_id" => ^command_id, "outcomes" => [%{"kind" => "accepted"}]}] = before["journal"]

      ref = Process.monitor(authority)
      Process.exit(authority, :kill)
      assert_receive {:DOWN, ^ref, :process, ^authority, :killed}, 1_000
      wait.(fn ->
        case Registry.lookup(Vault.Registry, game) do
          [{pid, _}] -> pid != authority and Process.alive?(pid)
          _ -> false
        end
      end)
      wait.(fn -> fetch.().box.release_status == :uncertain end)
      recovered = fetch.()
      assert recovered.session_id != next_session
      assert recovered.phase == :solved and recovered.paused
      assert recovered.assignments == %{a: nil, b: nil}
      assert recovered.box.command_id == command_id
      refute recovered.box.motor_active
      assert recovered.box.failure_code == "connection_lost"
      assert Process.whereis(SimulatedBox) == runtime
      assert {:ok, ^box_boot} = Adapter.boot_id(runtime)
      assert Repo.aggregate(ActuatorCommand, :count) == 1
      assert {:ok, %{checkpoint: %{board_version: 12}}} = GameStore.load(game)
      {:ok, box_db} = Store.open_existing(deployment.simulator_database, deployment.simulator_instance_id, deployment.simulator_device_id)
      {:ok, after_restart} = Store.load(box_db)
      :ok = Store.close(box_db)
      assert [%{"command_id" => ^command_id, "outcomes" => [
        %{"kind" => "accepted"}, %{"kind" => "uncertain", "failure_code" => "connection_lost"}
      ]}] = after_restart["journal"]
      assert {:error, %{code: :not_authorized}} =
        Games.command(a.actor, game, a.command_seq + 1, a.context, :request_snapshot)

      begin_args = %{command_id: command_id, expected_session_id: recovered.session_id}
      assert {:ok, preparation} = Games.begin_recovery(host, game, "begin", begin_args)
      assert {:ok, ^preparation} = Games.begin_recovery(host, game, "begin", begin_args)
      recovery_id = preparation["recovery_id"]
      recovery_session = preparation["current_session_id"]
      assert recovery_session != recovered.session_id
      wait.(fn -> fetch.().box.connected and fetch.().session_id == recovery_session end)
      assert {:error, %{code: :unresolved_release}} =
        Games.host(host, game, "blocked_reset", recovery_session, :reset)

      assert {:ok, %{simulated: true, receipt: %{"status" => "ok"}}} =
        Games.recovery_step(host, game, :enter)
      :ok = FakeClock.advance_to(clock, 4_300)
      wait.(fn -> fetch.().box.connected end)
      assert {:ok, %{simulated: true, receipt: %{"status" => "ok"}}} =
        Games.recovery_step(host, game, :reboot)
      wait.(fn ->
        view = fetch.()
        view.box.connected and view.box_binding.boot_id != box_boot
      end)
      :ok = FakeClock.advance_to(clock, 4_400)
      assert {:ok, %{simulated: true, receipt: %{"status" => "ok"}}} =
        Games.recovery_step(host, game, :seal)
      wait.(fn -> get_in(fetch.(), [:release, :close_evidence]) != nil end)
      closing = fetch.()
      evidence = closing.release.close_evidence
      assert evidence.recovery_id == recovery_id
      assert evidence.current_session_id == recovery_session
      assert evidence.box_boot_id == closing.box_binding.boot_id
      assert evidence.connection_id == closing.box_binding.connection_id
      assert evidence.operator_confirmed
      assert %ReleaseObservation{command_id: ^command_id, classification: "admitted",
        query_id: query_id, status_seq: status_seq} = Repo.get!(ReleaseObservation, evidence.observation_id)
      assert query_id == evidence.query_id and status_seq == evidence.status_seq
      close_args = %{command_id: command_id, expected_recovery_id: recovery_id,
        evidence: evidence, reason: "Reviewed simulated interrupted release"}
      assert {:ok, %{"disposition" => "closed_no_replay"} = close} =
        Games.close_recovery(host, game, "close", close_args)
      assert {:ok, ^close} = Games.close_recovery(host, game, "close", close_args)
      assert fetch.().box.release_status == :uncertain
      assert {:ok, %{simulated: true, receipt: %{"status" => "ok"}}} =
        Games.recovery_step(host, game, :acknowledge)
      assert {:ok, %{session_id: new_round}} =
        Games.host(host, game, "reset_after_close", recovery_session, :reset)
      assert new_round != recovery_session
      assert fetch.().phase == :lobby
      assert [%ActuatorCommand{command_id: ^command_id, dispatch_claimed: true,
        dispatch_retired: true}] = Repo.all(from c in ActuatorCommand, where: c.game_id == ^game)

      wait.(fn -> fetch.().box.connected end)
      assert :ok = :sys.suspend(runtime)
      try do
        pending = Task.async(fn ->
          Games.service_operation(host, game, "inspect", %{"section" => "calibration"})
        end)
        {:ok, current_game} = Games.ensure(game)
        wait.(fn -> map_size(:sys.get_state(current_game).service_pending) == 1 end)
        started_at = FakeClock.now_ms(clock)
        :ok = FakeClock.advance_to(clock, started_at + 2_999)
        assert Task.yield(pending, 0) == nil
        :ok = FakeClock.advance_to(clock, started_at + 3_000)
        assert {:error, %{code: :readback_required}} = Task.await(pending, 1_000)
      after
        :ok = :sys.resume(runtime)
      end

      assert {:ok, %{receipt: %{"status" => "ok"}}} =
        Games.service_operation(host, game, "inspect", %{"section" => "status"})
    after
      :ok = Application.stop(:vault)
    end
    IO.puts("game session conformance passed")
    """

    assert {"game session conformance passed\n", 0} = StorageFixture.vm(root, checks)
  end
end
