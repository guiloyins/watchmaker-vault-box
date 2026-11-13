defmodule Vault.Test.TimingCases do
  @moduledoc false

  import ExUnit.Assertions
  alias Vault.{Auth, Credentials, Games, GameStore, Protocol, Repo, Updates}
  alias Vault.Controllers.Input
  alias Vault.GameStore.ActuatorCommand
  alias Vault.Test.{Actors, FakeClock}

  @route [
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

  @fixture_cases ~w(hold_exact_boundary staggered_overlap release_just_before_completion
                    lease_expiry_wins_tie late_challenge_does_not_extend_lease
                    expired_challenge_rejected expired_press_requires_real_release
                    pause_keeps_choices_clears_attempt observer_disconnect_does_not_pause
                    recovery_does_not_resume_old_hold)

  def fixture_cases, do: @fixture_cases

  def run(root, name) do
    source = if name == :observer_disconnect_does_not_pause, do: :cyd, else: :browser
    with_game(root, fn game -> apply(__MODULE__, name, [game]) end, source)
  end

  def with_game(root, fun, source \\ :browser) do
    Process.flag(:trap_exit, true)
    {:ok, clock} = FakeClock.start_link(0)
    Process.unlink(clock)
    Application.put_env(:vault, :clock, FakeClock.handle(clock))
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

    Logger.configure(level: :warning)
    assert {:ok, _} = Application.ensure_all_started(:vault)

    try do
      setup(root, clock, source) |> fun.()
    after
      assert :ok = Application.stop(:vault)
      Agent.stop(clock)
    end
  end

  defp setup(root, clock, source) do
    host = login(root, "host.key", :host)
    player_a = login(root, "player-a.key", :player)
    player_b = login(root, "player-b.key", :player)
    assert {:ok, game} = Games.active_id()
    assert {:ok, authority} = Games.ensure(game)
    fixture = %{game: game, host: host, clock: clock, authority: authority}
    wait(fn -> fetch(fixture).box.connected end)

    {principal_a, principal_b} =
      if source == :cyd do
        {:ok, cyd_a} = Auth.simulated_principal(host, game, :a)
        {:ok, cyd_b} = Auth.simulated_principal(host, game, :b)
        {cyd_a, cyd_b}
      else
        {player_a, player_b}
      end

    a = principal_a |> Actors.bind(game, :a, source) |> Actors.claim(:a)
    b = principal_b |> Actors.bind(game, :b, source) |> Actors.claim(:b)

    fixture =
      Map.merge(fixture, %{
        a: a,
        b: b,
        principals: %{a: principal_a, b: principal_b},
        source: source
      })

    fixture = heartbeat(fixture, 100, %{a: nil, b: nil})
    assert {:ok, %{receipt: %{"status" => "ok"}}} = Games.prepare_simulated(host, game)
    assert {:ok, %{receipt: %{"status" => "ok"}}} = Games.exit_simulated(host, game)
    wait(fn -> fetch(fixture).box.readiness.start_verified end)
    session_id = fetch(fixture).session_id
    assert {:ok, %{data: %{arm_id: arm}}} = Games.host(host, game, "test_arm", session_id, :arm)
    wait(fn -> fetch(fixture).box.readiness.arm_id == arm end)
    assert {:ok, _} = Games.host(host, game, "test_start", session_id, :start)
    Map.put(fixture, :session_id, session_id)
  end

  def start_next_round(fixture, at) do
    wait(fn -> fetch(fixture).box.connected end)

    a = fixture.principals.a |> Actors.bind(fixture.game, :a, fixture.source) |> Actors.claim(:a)
    b = fixture.principals.b |> Actors.bind(fixture.game, :b, fixture.source) |> Actors.claim(:b)
    fixture = %{fixture | a: a, b: b, session_id: fetch(fixture).session_id}
    fixture = heartbeat(fixture, at, %{a: nil, b: nil})

    assert {:ok, %{receipt: %{"status" => "ok"}}} =
             Games.prepare_simulated(fixture.host, fixture.game)

    assert {:ok, %{receipt: %{"status" => "ok"}}} =
             Games.exit_simulated(fixture.host, fixture.game)

    wait(fn -> fetch(fixture).box.readiness.start_verified end)

    assert {:ok, %{data: %{arm_id: arm}}} =
             Games.host(fixture.host, fixture.game, "new_round_arm", fixture.session_id, :arm)

    wait(fn -> fetch(fixture).box.readiness.arm_id == arm end)

    assert {:ok, _} =
             Games.host(fixture.host, fixture.game, "new_round_start", fixture.session_id, :start)

    fixture
  end

  def to_seal(fixture) do
    fixture =
      @route
      |> Enum.with_index()
      |> Enum.reduce(fixture, fn {{role, direction, position}, board}, fixture ->
        {client, result} = Actors.command(fixture[role], {:move, direction, board})
        assert %{status: :applied, code: :moved, data: %{position: ^position}} = result
        Map.put(fixture, role, client)
      end)

    {a, %{status: :applied}} =
      fixture.a |> Actors.sync_context(:role_changed) |> Actors.command({:select_rune, :star})

    {b, %{status: :applied}} =
      fixture.b |> Actors.sync_context(:role_changed) |> Actors.command({:select_rune, :moon})

    fixture = %{fixture | a: a, b: b}
    fixture |> accept(:a, nil) |> accept(:b, nil)
  end

  def fetch(%{host: host, game: game}) do
    assert {:ok, projection} = Games.fetch(host, game, :host)
    projection
  end

  def count_intents, do: Repo.aggregate(ActuatorCommand, :count)

  def wait(predicate) do
    assert Enum.reduce_while(1..200, false, fn _, _ ->
             if predicate.() do
               {:halt, true}
             else
               Process.sleep(5)
               {:cont, false}
             end
           end)
  end

  defp login(root, file, kind) do
    assert {:ok, token} = Credentials.read_key(Path.join(root, file))
    assert {:ok, principal} = Auth.exchange(kind, token)
    principal
  end

  def advance(fixture, at) do
    assert :ok = FakeClock.advance_to(fixture.clock, at)
    :sys.get_state(fixture.authority)
    fixture
  end

  def heartbeat(fixture, at, presses) do
    fixture = advance(fixture, at)

    Enum.reduce([:a, :b], fixture, fn role, fixture ->
      client = Actors.challenge(fixture[role])
      fixture = Map.put(fixture, role, client)

      if Map.has_key?(presses, role) do
        accept(fixture, role, presses[role])
      else
        fixture
      end
    end)
  end

  def accept(fixture, role, press_id) do
    {fixture, result} = sample(fixture, role, press_id)
    assert %{input_accepted: true} = result
    fixture
  end

  defp sample(fixture, role, press_id, overrides \\ []) do
    client = fixture[role]
    input_seq = Keyword.get(overrides, :input_seq, client.input_seq + 1)
    heartbeat = Keyword.get(overrides, :heartbeat_seq, client.heartbeat_seq)
    context = Keyword.get(overrides, :context, client.context)
    result = validated_sample(client, context, input_seq, heartbeat, press_id)
    {put_in(fixture[role].input_seq, max(input_seq, client.input_seq)), result}
  end

  defp validated_sample(client, context, seq, heartbeat, press_id) do
    bytes =
      Jason.encode!(%{
        v: 1,
        type: "heartbeat",
        connection_id: client.actor.connection_id,
        heartbeat_seq: heartbeat,
        input_seq: seq,
        input: %{
          session_id: context.session_id,
          round_id: context.round_id,
          puzzle_revision: context.puzzle_revision,
          control_epoch: context.control_epoch,
          role: context.role,
          pressed: press_id != nil,
          press_id: press_id
        }
      })

    assert {:ok, %{message: sample}} = Protocol.decode(bytes)

    input = %Input{
      heartbeat_seq: sample["heartbeat_seq"],
      input_seq: sample["input_seq"],
      context: context,
      pressed: sample["input"]["pressed"],
      press_id: sample["input"]["press_id"]
    }

    assert {:ok, result} = Games.sample(client.actor, client.game, input)
    result
  end

  def presses(fixture, last), do: presses(fixture, 200, last, 1, 1)

  def presses(fixture, first, last, a, b) do
    Enum.reduce(first..last//100, fixture, fn at, fixture ->
      heartbeat(fixture, at, %{a: a, b: b})
    end)
  end

  defp capture_completion(fixture) do
    expected_authority = fixture.authority

    assert [completion] =
             Agent.get(fixture.clock, fn clock ->
               for {_ref, {_at, _order, ^expected_authority, {:qualify, _, _} = message}} <-
                     clock.timers,
                   do: message
             end)

    completion
  end

  defp inject_twice(fixture, completion) do
    send(fixture.authority, completion)
    send(fixture.authority, completion)
    :sys.get_state(fixture.authority)
    fixture
  end

  defp hold(fixture), do: fetch(fixture).panels.a.hold
  defp role_held?(fixture, role), do: Enum.find(fetch(fixture).peers, &(&1.role == role)).held

  def hold_exact_boundary(fixture) do
    fixture = fixture |> to_seal() |> presses(2100)
    completion = capture_completion(fixture)
    advance(fixture, 2199)
    assert %{phase: :seal} = fetch(fixture)
    assert %{active: true, elapsed_ms: 1999, qualified: false} = hold(fixture)
    assert count_intents() == 0

    advance(fixture, 2200)
    assert %{phase: :solved} = fetch(fixture)
    assert %{active: false, elapsed_ms: 2000, qualified: true} = hold(fixture)
    assert [%ActuatorCommand{command_id: command_id}] = Repo.all(ActuatorCommand)

    fixture |> advance(2300) |> inject_twice(completion)
    assert [%ActuatorCommand{command_id: ^command_id}] = Repo.all(ActuatorCommand)
  end

  def staggered_overlap(fixture) do
    fixture = fixture |> to_seal() |> presses(200, 500, 1, nil) |> advance(550) |> accept(:b, 1)
    fixture = presses(fixture, 600, 2500, 1, 1)
    advance(fixture, 2549)
    assert %{phase: :seal} = fetch(fixture)
    assert %{active: true, elapsed_ms: 1999} = hold(fixture)
    assert count_intents() == 0
    advance(fixture, 2550)
    assert %{phase: :solved} = fetch(fixture)
    assert count_intents() == 1
  end

  def release_just_before_completion(fixture) do
    fixture = fixture |> to_seal() |> presses(2100)
    completion = capture_completion(fixture)
    fixture = fixture |> advance(2199) |> accept(:b, nil)
    assert %{active: false, elapsed_ms: 0} = hold(fixture)
    fixture |> advance(2200) |> inject_twice(completion)
    assert %{phase: :seal} = fetch(fixture)
    assert %{active: false, elapsed_ms: 0} = hold(fixture)
    assert count_intents() == 0
  end

  def lease_expiry_wins_tie(fixture) do
    fixture = fixture |> to_seal() |> presses(1800)
    completion = capture_completion(fixture)
    fixture = Enum.reduce(1900..2100//100, fixture, &heartbeat(&2, &1, %{a: 1}))
    advance(fixture, 2199)
    assert %{phase: :seal} = fetch(fixture)
    assert %{active: true, elapsed_ms: 1999} = hold(fixture)
    fixture = heartbeat(fixture, 2200, %{a: 1})
    assert %{phase: :seal} = fetch(fixture)
    assert %{active: false, elapsed_ms: 0} = hold(fixture)
    refute role_held?(fixture, :b)
    refute fetch(fixture).paused
    assert count_intents() == 0
    inject_twice(fixture, completion)
    fixture = Enum.reduce(2300..3200//100, fixture, &heartbeat(&2, &1, %{a: 1}))
    advance(fixture, 3299)
    refute fetch(fixture).paused
    advance(fixture, 3300)
    assert %{paused: true, pause_reasons: reasons} = fetch(fixture)
    assert Enum.sort(reasons) == [:controller_offline, :recovery]
    assert count_intents() == 0
  end

  def late_challenge_does_not_extend_lease(fixture) do
    fixture = fixture |> to_seal() |> presses(200)
    challenge = fixture.a.heartbeat_seq
    fixture = fixture |> advance(599) |> accept(:a, 1)
    assert fixture.a.heartbeat_seq == challenge
    assert %{active: true, elapsed_ms: 399} = hold(fixture)
    advance(fixture, 600)

    {_ignored, %{input_accepted: false, code: :stale_challenge}} =
      sample(fixture, :a, 1, input_seq: 100)

    assert %{active: false, elapsed_ms: 0, fresh_press_required: true} = hold(fixture)
    refute role_held?(fixture, :a)
    refute fetch(fixture).paused
  end

  def expired_challenge_rejected(fixture) do
    fixture = fixture |> to_seal() |> presses(200)
    expired = fixture.a.heartbeat_seq
    previous_input = fixture.a.input_seq
    fixture = heartbeat(fixture, 300, %{a: 1, b: 1})

    {_ignored, %{input_accepted: false, code: :stale_sample}} =
      sample(fixture, :a, nil, input_seq: fixture.a.input_seq)

    {_ignored, %{input_accepted: false, code: :stale_sample}} =
      sample(fixture, :a, nil, input_seq: previous_input)

    {_ignored, %{input_accepted: false, code: :stale_challenge}} =
      sample(fixture, :a, nil, heartbeat_seq: expired)

    assert role_held?(fixture, :a)
    fixture = advance(fixture, 600)

    {_ignored, %{input_accepted: false, code: :stale_challenge}} =
      sample(fixture, :a, 1, heartbeat_seq: expired, input_seq: 100)

    fixture = heartbeat(fixture, 700, %{b: nil})
    {_ignored, %{input_accepted: true}} = sample(fixture, :a, nil)
    refute role_held?(fixture, :a)
    refute hold(fixture).active
  end

  def expired_press_requires_real_release(fixture) do
    fixture = fixture |> to_seal() |> presses(200, 200, 7, nil)
    fixture = Enum.reduce(300..600//100, fixture, &heartbeat(&2, &1, %{b: nil}))
    refute role_held?(fixture, :a)

    {fixture, %{input_accepted: false, code: :must_release}} =
      fixture |> advance(610) |> sample(:a, 7, input_seq: 100)

    binding_fields = [:last_seen_ms, :lease_until_ms, :input_seq, :last_challenge, :press_high]
    id = fixture.a.actor.actor_id
    before = :sys.get_state(fixture.authority).actors[id] |> Map.take(binding_fields)

    {_ignored, %{input_accepted: false, code: :must_release}} =
      fixture |> advance(615) |> sample(:a, 8, input_seq: 101)

    after_rejection = :sys.get_state(fixture.authority).actors[id] |> Map.take(binding_fields)
    assert before == after_rejection
    refute role_held?(fixture, :a)

    # The rejected press cannot consume the sample sequence or a later real
    # press ID. A neutral sample using that sequence must still be accepted.
    fixture = fixture |> advance(620) |> accept(:a, nil)
    assert fixture.a.input_seq == 101
    refute hold(fixture).fresh_press_required
    fixture = fixture |> advance(630) |> accept(:a, 8)
    assert role_held?(fixture, :a)
  end

  def pause_keeps_choices_clears_attempt(fixture) do
    fixture = fixture |> to_seal() |> presses(1700)
    completion = capture_completion(fixture)

    assert {:ok, _} =
             Games.host(fixture.host, fixture.game, "test_pause", fixture.session_id, :pause)

    assert %{phase: :seal, paused: true, panels: panels} = fetch(fixture)
    assert panels.a.seal.selected_rune == "star"
    assert panels.b.seal.selected_rune == "moon"
    refute panels.a.hold.active
    previous = fixture.a.context

    advance(fixture, 1800)
    a = fixture.a |> Actors.sync_context(:paused) |> Actors.challenge()
    b = fixture.b |> Actors.sync_context(:paused)
    fixture = %{fixture | a: a, b: b}

    {_ignored, %{input_accepted: false, code: :stale_context}} =
      sample(fixture, :a, 1, context: previous)

    fixture |> advance(2200) |> inject_twice(completion)
    assert count_intents() == 0
    assert %{phase: :seal, paused: true} = fetch(fixture)
  end

  def observer_disconnect_does_not_pause(fixture) do
    observer = Actors.bind(fixture.host, fixture.game, :a)
    initial = fetch(fixture).assignments
    fixture = heartbeat(fixture, 200, %{a: nil, b: nil})
    assert :ok = Games.disconnect(observer.actor, fixture.game, :closed)
    advance(fixture, 201)
    assert %{paused: false, assignments: ^initial, peers: peers} = fetch(fixture)
    assert Enum.map(peers, & &1.source) == [:cyd, :cyd]

    assert :ok = Games.disconnect(fixture.a.actor, fixture.game, :closed)
    assert %{paused: true, pause_reasons: reasons} = fetch(fixture)
    assert :controller_offline in reasons
    assert :recovery in reasons
  end

  def recovery_does_not_resume_old_hold(fixture) do
    fixture = fixture |> to_seal() |> presses(200)
    completion = capture_completion(fixture)
    assert %{active: true} = hold(fixture)
    ref = Process.monitor(fixture.authority)
    Process.exit(fixture.authority, :kill)
    assert_receive {:DOWN, ^ref, :process, _, :killed}, 1_000

    wait(fn ->
      match?(
        [{pid, _}] when pid != fixture.authority,
        Registry.lookup(Vault.Registry, fixture.game)
      )
    end)

    assert {:ok, authority} = Games.ensure(fixture.game)
    fixture = %{fixture | authority: authority}
    assert %{paused: true, session_id: session, assignments: %{a: nil, b: nil}} = fetch(fixture)
    refute session == fixture.session_id
    refute Enum.any?(fetch(fixture).peers, & &1.held)

    assert {:ok, %{checkpoint: %{session_id: ^session, phase: :seal, paused: true}}} =
             GameStore.load(fixture.game)

    advance(fixture, 210)
    old = fixture.a

    assert {:error, %{code: :not_authorized}} =
             Games.sample(old.actor, old.game, %Input{
               context: old.context,
               input_seq: old.input_seq + 1,
               heartbeat_seq: old.heartbeat_seq,
               pressed: true,
               press_id: 1
             })

    advance(fixture, 220)

    a =
      fixture.principals.a
      |> Actors.bind(fixture.game, :a, fixture.source, old.actor.boot_id)
      |> Actors.claim(:a)

    assert a.actor.session_id == session
    fixture |> advance(230) |> inject_twice(completion)
    assert %{phase: :seal, paused: true} = fetch(fixture)
    assert count_intents() == 0
  end

  def heartbeat_presentation(fixture) do
    fixture = to_seal(fixture)
    assert %{active: false, elapsed_ms: 0} = hold(fixture)
    assert {:ok, _} = Updates.subscribe(fixture.host, fixture.game, :host)
    fixture = heartbeat(fixture, 200, %{a: nil, b: nil})
    {:messages, messages} = Process.info(self(), :messages)
    assert Enum.any?(messages, &match?({:vault_snapshot, _, _, :host, _}, &1))
    drain_snapshots()

    before = fetch(fixture)
    fixture = Enum.reduce(300..700//100, fixture, &heartbeat(&2, &1, %{a: nil, b: nil}))
    after_heartbeats = fetch(fixture)

    for key <- [:puzzle_revision, :state_revision, :ui_revision] do
      assert before[key] == after_heartbeats[key]
    end

    assert before.panels.a.board_version == after_heartbeats.panels.a.board_version
    refute_received {:vault_snapshot, _, _, :host, _}

    fixture = fixture |> accept(:a, 1) |> accept(:b, 1)
    assert %{active: true, elapsed_ms: 0, qualified: false} = hold(fixture)
    fixture = heartbeat(fixture, 800, %{a: 1, b: 1})
    assert %{active: true, elapsed_ms: 100} = hold(fixture)
    fixture = accept(fixture, :a, nil)
    assert %{active: false, elapsed_ms: 0, qualified: false} = hold(fixture)
  end

  defp drain_snapshots do
    receive do
      {:vault_snapshot, _, _, :host, _} -> drain_snapshots()
    after
      0 -> :ok
    end
  end
end
