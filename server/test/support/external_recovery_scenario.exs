defmodule Vault.Test.ExternalRecoveryScenario do
  @moduledoc false
  import ExUnit.Assertions

  alias Vault.{Auth, Credentials, GameStore, Games, MaintenanceGuard, Repo}
  alias Vault.GameStore.ActuatorCommand
  alias Vault.SimulatedBox.Store
  alias Vault.Simulator.{BoxRuntime, Runner}
  alias Vault.Test.{Actors, FakeClock}

  @operator %{"operator_id" => "operator", "observation" => "Reviewed modeled recovery evidence"}

  def cli(root) do
    configure(nil)
    Logger.configure(level: :warning)
    {:ok, _} = Application.ensure_all_started(:vault)
    {:ok, paths} = MaintenanceGuard.admit()

    {:ok, listener} =
      Bandit.start_link(
        plug: VaultWeb.Endpoint,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false,
        http_2_options: [enabled: false]
      )

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(listener)

    common = [
      "--endpoint",
      "ws://127.0.0.1:#{port}/device/v1",
      "--allow-ws",
      "--duration-ms",
      "0"
    ]

    cli = Path.expand("../../../tools/device-simulator", __DIR__)
    env = [{"MIX_ENV", "test"}, {"ELIXIR_ERL_OPTIONS", "+S 2"}]

    try do
      assert {output, 0} =
               System.cmd(
                 cli,
                 common ++
                   [
                     "--device-id",
                     "sim_cyd_a",
                     "--credentials-file",
                     Path.join(root, "cyd-a.key"),
                     "--scenario",
                     "controller-smoke",
                     "--role",
                     "a"
                   ],
                 env: env,
                 stderr_to_stdout: true
               )

      assert output =~ "Controller role a connected"

      assert {output, 0} =
               System.cmd(
                 cli,
                 common ++
                   [
                     "--device-id",
                     "sim_cyd_a",
                     "--credentials-file",
                     Path.join(root, "cyd-a.key"),
                     "--scenario",
                     "fault-fragments",
                     "--isolated-simulation"
                   ],
                 env: env,
                 stderr_to_stdout: true
               )

      assert output =~ "Split fragmented hello accepted"

      endpoint = "ws://127.0.0.1:#{port}/device/v1"
      credential = Path.join(root, "box.key")
      assert {output, 0} = box_cli(paths, credential, endpoint)
      assert output =~ "latch position remains unknown and unverified"

      assert {output, 1} =
               box_cli(
                 %{paths | simulator_instance_id: "different_instance"},
                 credential,
                 endpoint
               )

      assert output =~ "Simulator refused or stopped: invalid_box_deployment."
      refute File.exists?(Path.join(root, "box-runtime.owner"))
    after
      Application.stop(:vault)
    end
  end

  def refuse_internal_cli(root) do
    {:ok, _} = Application.ensure_all_started(:exqlite)
    {:ok, paths} = MaintenanceGuard.admit()
    assert paths.simulator_transport == :internal
    credential = Path.join(root, "external-attempt.key")
    :ok = MaintenanceGuard.write_protected(credential, String.duplicate("0", 64) <> "\n")
    {:ok, server_guard} = MaintenanceGuard.acquire(root)

    try do
      before_revision = box_store_revision(paths)
      before_bytes = File.read!(paths.simulator_database)

      assert {output, 1} =
               box_cli(paths, credential, "ws://127.0.0.1:1/device/v1")

      assert output =~ "Simulator refused or stopped: invalid_box_deployment."
      assert File.read!(paths.simulator_database) == before_bytes
      assert box_store_revision(paths) == before_revision
      refute File.exists?(Path.join(root, "box-runtime.owner"))
    after
      :ok = MaintenanceGuard.release(server_guard)
    end
  end

  defp box_store_revision(paths) do
    {:ok, store} =
      Store.open_existing(
        paths.simulator_database,
        paths.simulator_instance_id,
        paths.simulator_device_id
      )

    try do
      {:ok, document} = Store.load(store)
      document["store_revision"]
    after
      :ok = Store.close(store)
    end
  end

  defp box_cli(paths, credential, endpoint) do
    cli = Path.expand("../../../tools/device-simulator", __DIR__)
    env = [{"MIX_ENV", "test"}, {"ELIXIR_ERL_OPTIONS", "+S 2"}]

    System.cmd(
      cli,
      [
        "--endpoint",
        endpoint,
        "--allow-ws",
        "--duration-ms",
        "0",
        "--device-id",
        paths.simulator_device_id,
        "--credentials-file",
        credential,
        "--scenario",
        "box-inspect",
        "--box-db",
        paths.simulator_database,
        "--instance-id",
        paths.simulator_instance_id,
        "--isolated-simulation"
      ],
      env: env,
      stderr_to_stdout: true
    )
  end

  def run(root, outcome) do
    {:ok, clock} = FakeClock.start_link(0)
    configure(clock)
    Logger.configure(level: :warning)
    {:ok, _} = Application.ensure_all_started(:vault)
    {:ok, _} = Application.ensure_all_started(:mint_web_socket)
    {:ok, paths} = MaintenanceGuard.admit()
    assert paths.simulator_transport == :external
    refute Process.whereis(Vault.SimulatedBox)
    {:ok, guard} = MaintenanceGuard.acquire(root, "box-runtime.owner")

    {:ok, listener} =
      Bandit.start_link(
        plug: VaultWeb.Endpoint,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false,
        http_2_options: [enabled: false]
      )

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(listener)

    {:ok, box} =
      BoxRuntime.start_link(
        path: paths.simulator_database,
        device_id: paths.simulator_device_id,
        instance_id: paths.simulator_instance_id,
        clock: FakeClock.handle(clock),
        trace: self()
      )

    {:ok, runner} =
      Runner.start_link(
        uri: URI.parse("ws://127.0.0.1:#{port}/device/v1"),
        credentials_file: Path.join(root, "box.key"),
        device_id: paths.simulator_device_id,
        box: box,
        box_clock: FakeClock.handle(clock),
        client_trace: self(),
        trace: self()
      )

    try do
      host = authenticate(root, :host, "host.key")
      a_principal = authenticate(root, :player, "player-a.key")
      b_principal = authenticate(root, :player, "player-b.key")
      {:ok, game} = Games.active_id()
      {:ok, authority} = Games.ensure(game)
      session = fetch(host, game).session_id
      a = Actors.bind(a_principal, game, :a) |> Actors.claim(:a)
      b = Actors.bind(b_principal, game, :b) |> Actors.claim(:b)

      assert_receive {:simulator_client, generation,
                      {:welcome, gate, %{"session_id" => ^session}}},
                     5_000

      assert gate.generation == generation
      wait(fn -> fetch(host, game).box.connected end)
      assert :ok = FakeClock.advance_to(clock, 100)
      a = a |> Actors.challenge() |> Actors.sample_ok()
      b = b |> Actors.challenge() |> Actors.sample_ok()
      wait(fn -> :sys.get_state(authority).box.lease_until_ms == 500 end)
      prepare(box)
      wait(fn -> fetch(host, game).box.readiness.start_verified end)
      {:ok, %{data: %{arm_id: arm}}} = Games.host(host, game, "initial_arm", session, :arm)
      wait(fn -> fetch(host, game).box.readiness.arm_id == arm end)
      assert {:ok, _} = Games.host(host, game, "initial_start", session, :start)

      sustain_hold(clock, authority, a, b)

      if outcome == :absent, do: :sys.suspend(gate.pid)
      :ok = FakeClock.advance_to(clock, 2_100)
      wait(fn -> fetch(host, game).phase == :solved end)
      assert {:ok, %{command: %{command_id: command}}} = GameStore.load(game)

      if outcome == :interrupted do
        wait(fn -> fetch(host, game).box.release_status == :accepted end)
        :ok = FakeClock.advance_to(clock, 2_110)
        assert_receive {:box_trace, {:step, _, 1}}, 1_000
      end

      Process.exit(gate.pid, :kill)
      assert_receive {:simulator_runner, {:owner_down, ^generation}}, 1_000
      original_boot = :sys.get_state(box).boot || elem(BoxRuntime.boot_id(box), 1)
      wait(fn -> not fetch(host, game).box.connected end)

      if outcome == :interrupted do
        assert_receive {:box_trace, {:deactivate, :connection_lost}}, 1_000

        assert_receive {:box_trace, {:storage_started, {:commit, interrupted_id, :outcome}}},
                       1_000

        assert_receive {:box_trace, {:storage_finished, ^interrupted_id, {:ok, _, _}}}, 1_000
      end

      # Kill the GameSession independently while leaving the box runtime/store.
      # Its new welcome fences the original session, and it can only query.
      monitor = Process.monitor(authority)
      Process.exit(authority, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^authority, :killed}, 1_000

      wait(fn ->
        case Games.fetch(host, game, :host) do
          {:ok, %{session_id: fresh}} -> fresh != session
          {:error, %{code: :readback_required}} -> false
        end
      end)

      restart_session = fetch(host, game).session_id
      wait(fn -> fetch(host, game).box.connected end)
      wait(fn -> fetch(host, game).box.release_status == :uncertain end)

      assert fetch(host, game).box.failure_code ==
               if(outcome == :interrupted, do: "connection_lost", else: "unknown_command")

      assert {:error, _} = Games.host(host, game, "early_reset", restart_session, :reset)

      {:ok, preparation} =
        Games.begin_recovery(host, game, "begin_recovery", %{
          expected_session_id: restart_session,
          command_id: command
        })

      recovery_session = preparation["current_session_id"]
      wait(fn -> current_binding(box, recovery_session) end)

      current = %{
        "session_id" => recovery_session,
        "recovery_id" => preparation["recovery_id"],
        "recovery_generation" => preparation["recovery_generation"],
        "disposition_id" => nil
      }

      old_connection = BoxRuntime.binding(box)["connection_id"]

      assert %{
               "status" => "ok",
               "data" => %{
                 "receipt" => %{
                   "decision" => %{
                     "data" => %{"local_record_id" => local, "service_epoch" => epoch}
                   }
                 }
               }
             } =
               BoxRuntime.service(box, "recovery.enter", %{
                 "preparation" => preparation,
                 "host_current" => current,
                 "operator" => @operator
               })

      wait(fn -> current_binding(box, recovery_session) end)
      # Wait for the recovery-enter transport fence; the next owner can
      # perform a deliberate modeled reboot while the local inhibit persists.
      wait(fn -> binding_changed?(box, old_connection) end)

      assert %{"status" => "ok"} =
               BoxRuntime.service(box, "reboot", %{"reason" => "recovery"})

      binding =
        wait(fn ->
          case BoxRuntime.binding(box) do
            %{"current_session_id" => ^recovery_session, "box_boot_id" => boot} = current
            when is_binary(boot) and boot != original_boot ->
              current

            _ ->
              nil
          end
        end)

      assert %{"status" => "ok", "data" => %{"receipt" => %{"operation_id" => seal}}} =
               BoxRuntime.service(box, "recovery.seal", %{
                 "local_record_id" => local,
                 "recovery_id" => preparation["recovery_id"],
                 "recovery_generation" => preparation["recovery_generation"],
                 "binding" => binding,
                 "host_current" => current,
                 "operator" => @operator
               })

      assert %{
               "status" => "ok",
               "data" => %{"record" => %{"seal" => %{}, "journal_observation" => observation}}
             } =
               BoxRuntime.service(box, "inspect", %{
                 "section" => "recovery",
                 "local_record_id" => local
               })

      if outcome == :absent, do: assert(observation == "not_present_current_journal")

      {:ok, authority} = Games.ensure(game)
      {:ok, time} = tick(clock)
      wait(fn -> :sys.get_state(authority).box.lease_until_ms == time + 400 end)

      assert {:ok, %{query_id: _}} =
               Games.attest_sealed_record(host, game, %{
                 current_session_id: recovery_session,
                 box_boot_id: binding["box_boot_id"],
                 connection_id: binding["connection_id"],
                 recovery_id: preparation["recovery_id"],
                 recovery_generation: preparation["recovery_generation"],
                 local_record_id: local,
                 service_epoch: epoch,
                 seal_operation_id: seal,
                 operator_confirmed: true
               })

      wait(fn -> fetch(host, game).release.close_evidence end)
      evidence = fetch(host, game).release.close_evidence

      assert {:ok, disposition} =
               Games.close_recovery(host, game, "close_recovery", %{
                 command_id: command,
                 expected_recovery_id: preparation["recovery_id"],
                 evidence: evidence,
                 reason: "Reviewed simulation journal; original command retired"
               })

      assert disposition["disposition"] == "closed_no_replay"
      assert fetch(host, game).box.release_status == :uncertain

      assert %{"status" => "ok"} =
               BoxRuntime.service(box, "recovery.attest_disposition", %{
                 "local_record_id" => local,
                 "disposition" => disposition,
                 "operator" => @operator
               })

      assert {:ok, _} = Games.host(host, game, "new_round", recovery_session, :reset)
      fresh_session = fetch(host, game).session_id
      refute fresh_session == recovery_session
      assert fetch(host, game).phase == :lobby
      wait(fn -> current_binding(box, fresh_session) end)
      verify_disposition_preparation(box, disposition["disposition_id"])

      a = Actors.bind(a_principal, game, :a) |> Actors.claim(:a)
      b = Actors.bind(b_principal, game, :b) |> Actors.claim(:b)
      {:ok, time} = tick(clock)
      a = a |> Actors.challenge() |> Actors.sample_ok()
      b = b |> Actors.challenge() |> Actors.sample_ok()
      wait(fn -> :sys.get_state(authority).box.lease_until_ms == time + 400 end)
      wait(fn -> fetch(host, game).box.readiness.start_verified end)

      {:ok, %{data: %{arm_id: new_arm}}} =
        Games.host(host, game, "fresh_arm", fresh_session, :arm)

      refute new_arm == arm
      wait(fn -> fetch(host, game).box.readiness.arm_id == new_arm end)
      assert {:ok, _} = Games.host(host, game, "fresh_start", fresh_session, :start)
      assert fetch(host, game).phase == :maze
      assert fetch(host, game).box.latch_position == :unknown
      assert fetch(host, game).box.position_basis == :unverified
      assert fetch(host, game).box.command_confirmation == nil
      assert Repo.aggregate(ActuatorCommand, :count) == 1
      assert Repo.get!(ActuatorCommand, command).dispatch_retired
      verify_journal(paths, outcome, command)
      refute_receive {:box_trace, {:step, _, _}}, 20

      sustain_hold(clock, authority, a, b)
      {:ok, _} = tick(clock)
      wait(fn -> fetch(host, game).phase == :solved end)
      assert {:ok, %{command: %{command_id: new_command}}} = GameStore.load(game)
      refute new_command == command
      assert Repo.aggregate(ActuatorCommand, :count) == 2
      wait(fn -> fetch(host, game).box.release_status == :accepted end)
      assert Repo.get!(ActuatorCommand, command).dispatch_retired
      assert Repo.get!(ActuatorCommand, command).original_session_id == session
    after
      :ok = Runner.shutdown(runner)
      :ok = BoxRuntime.shutdown(box)
      :ok = MaintenanceGuard.release(guard)
      Application.stop(:vault)
    end
  end

  defp configure(clock) do
    Application.put_env(:vault, :simulator_transport, :external)
    Application.put_env(:vault, :environment, :test)

    Application.put_env(
      :vault,
      :clock,
      if(clock, do: FakeClock.handle(clock), else: Vault.Clock.system())
    )

    Application.put_env(:vault, :origin, "http://127.0.0.1:4000")
    Application.put_env(:vault, :port, 4000)
    Application.put_env(:vault, :bind, {127, 0, 0, 1})

    Application.put_env(:vault, VaultWeb.Endpoint,
      server: false,
      adapter: Bandit.PhoenixAdapter,
      render_errors: [
        formats: [html: VaultWeb.ErrorHTML, json: VaultWeb.ErrorJSON],
        layout: false
      ],
      pubsub_server: Vault.PubSub,
      live_view: [signing_salt: "vault-test"]
    )
  end

  defp authenticate(root, kind, file) do
    {:ok, value} = Credentials.read_key(Path.join(root, file))
    {:ok, principal} = Auth.exchange(kind, value)
    principal
  end

  defp prepare(box) do
    assert %{"status" => "ok"} = BoxRuntime.prepare(box)

    assert %{"status" => "ok"} =
             BoxRuntime.service(box, "service.exit", %{"binding" => BoxRuntime.binding(box)})
  end

  defp verify_disposition_preparation(box, disposition) do
    assert %{"status" => "ok"} =
             BoxRuntime.service(box, "service.prepare", %{
               "authorization" => "disposition",
               "authorization_id" => disposition,
               "operator" => @operator
             })

    assert %{"status" => "ok"} =
             BoxRuntime.service(box, "reference.set", %{
               "calibration_revision" => 1,
               "reference" => "locked_zero",
               "method" => "manual_verified",
               "operator" => @operator
             })

    assert %{"status" => "ok"} =
             BoxRuntime.service(box, "position.confirm", %{
               "position" => "locked",
               "basis" => "manual_verified",
               "command_id" => nil,
               "operator" => @operator
             })

    assert %{"status" => "ok"} =
             BoxRuntime.service(box, "service.exit", %{"binding" => BoxRuntime.binding(box)})
  end

  defp sustain_hold(clock, authority, a, b) do
    {a, b} = maze(a, b)

    {a, %{status: :applied}} =
      a |> Actors.sync_context(:role_changed) |> Actors.command({:select_rune, :star})

    {b, %{status: :applied}} =
      b |> Actors.sync_context(:role_changed) |> Actors.command({:select_rune, :moon})

    a = a |> Actors.sample_ok() |> Actors.sample_ok(1)
    b = b |> Actors.sample_ok() |> Actors.sample_ok(1)

    Enum.reduce(1..19, {a, b}, fn _, {a, b} ->
      # The production socket rate uses real elapsed time, independently
      # of the injected domain and box watchdog clock.
      Process.sleep(45)
      {:ok, time} = tick(clock)
      a = a |> Actors.challenge() |> Actors.sample_ok(1)
      b = b |> Actors.challenge() |> Actors.sample_ok(1)
      wait(fn -> :sys.get_state(authority).box.lease_until_ms == time + 400 end)
      {a, b}
    end)
  end

  defp maze(a, b) do
    route = [
      {:a, :up, 8},
      {:b, :right, 9},
      {:a, :up, 5},
      {:b, :left, 4},
      {:a, :up, 0},
      {:b, :right, 1},
      {:b, :right, 2},
      {:a, :down, 6},
      {:a, :down, 10},
      {:b, :right, 11},
      {:a, :up, 7},
      {:a, :up, 3}
    ]

    clients =
      Enum.reduce(Enum.with_index(route), %{a: a, b: b}, fn {{role, direction, position}, board},
                                                            clients ->
        {client, result} = Actors.command(clients[role], {:move, direction, board})
        assert %{status: :applied, data: %{position: ^position}} = result
        Map.put(clients, role, client)
      end)

    {clients.a, clients.b}
  end

  defp verify_journal(paths, outcome, command) do
    {:ok, store} =
      Store.open_existing(
        paths.simulator_database,
        paths.simulator_instance_id,
        paths.simulator_device_id
      )

    try do
      assert {:ok, durable} = Store.load(store)

      case outcome do
        :absent ->
          assert durable["journal"] == []

        :interrupted ->
          assert [
                   %{
                     "command_id" => ^command,
                     "outcomes" => [
                       %{"kind" => "accepted"},
                       %{"kind" => "uncertain", "failure_code" => "connection_lost"}
                     ]
                   }
                 ] = durable["journal"]
      end
    after
      Store.close(store)
    end
  end

  defp fetch(host, game) do
    {:ok, snapshot} = Games.fetch(host, game, :host)
    snapshot
  end

  defp tick(clock) do
    current = FakeClock.now_ms(clock)
    next = current + 100
    :ok = FakeClock.advance_to(clock, next)
    {:ok, next}
  end

  defp current_binding(box, session) do
    case BoxRuntime.binding(box) do
      %{"current_session_id" => ^session} -> true
      _ -> false
    end
  end

  defp binding_changed?(box, connection) do
    case BoxRuntime.binding(box) do
      %{"connection_id" => id} when id != connection -> true
      _ -> false
    end
  end

  defp wait(predicate, remaining \\ 1_000)
  defp wait(_, 0), do: flunk("bounded condition did not become true")

  defp wait(predicate, remaining) do
    case predicate.() do
      value when value in [false, nil] ->
        Process.sleep(3)
        wait(predicate, (remaining - 3) |> max(0))

      value ->
        value
    end
  end
end
