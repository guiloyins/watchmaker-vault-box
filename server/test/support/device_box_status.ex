defmodule Vault.Test.DeviceBoxStatus do
  @moduledoc false
  import Ecto.Query
  import ExUnit.Assertions
  import Phoenix.ConnTest

  alias Vault.{
    Auth,
    Controllers,
    Credentials,
    GameStore,
    Games,
    MaintenanceGuard,
    Repo,
    StorageFixture
  }

  alias Vault.GameStore.{ReleaseObservation, Records}
  alias Vault.Test.{DeviceEndpoint, FakeClock}

  @endpoint VaultWeb.Endpoint

  # Runs only in the isolated child VM. Seed an existing durable intent through
  # the store before starting the server, so recovery exercises a prior solve.
  def exercise(root) do
    with_box(root, :simulated, fn fixture, host, key, command, clock ->
      status_recovery(fixture, host, command, clock)
      host_page_recovery(fixture, host, command, clock, root, key)
    end)

    IO.puts("raw box status checks passed")
  end

  def physical_recovery(root) do
    with_box(root, :physical, fn fixture, host, key, command, clock ->
      game = fixture.game_id
      host_route = "/games/#{game}/host"
      host_conn = sign_in("/login", key, host_route)

      assert {:ok, %{session_id: session, release: %{status: :pending}}} =
               Games.fetch(host, game, :host)

      assert {:ok, prep} =
               Games.begin_recovery(host, game, Controllers.id("begin"), %{
                 command_id: command,
                 expected_session_id: session
               })

      pending = host_conn |> recycle() |> get(host_route) |> html_response(200)
      assert pending =~ "Copy local recovery data"
      assert recovery_documents(pending)["Committed preparation"] == prep
      assert pending =~ ~s(phx-submit="attest_sealed_record")
      refute pending =~ ~s(id="simulated-recovery")

      {box, welcome, boot} = connect_box(fixture, command)
      report = confirmed_report(game, welcome, boot, command)
      box = status(box, report, "ok")
      box = heartbeat(box, welcome, clock, 100, 1)

      assert {:ok, %{session_id: recovery_session, release: %{status: :position_confirmed}}} =
               Games.fetch(host, game, :host)

      terminal = host_conn |> recycle() |> get(host_route) |> html_response(200)
      assert terminal =~ "Copy local recovery data"
      assert recovery_documents(terminal)["Committed preparation"] == prep
      assert terminal =~ ~s(phx-submit="attest_sealed_record")
      assert terminal =~ ~r/<button[^>]+phx-value-action="reset"[^>]+disabled[^>]*>/

      assert {:error, %{code: :unresolved_release}} =
               Games.host(host, game, Controllers.id("reset"), recovery_session, :reset)

      assert {:ok, %{query_id: query}} =
               Games.attest_sealed_record(host, game, attestation(prep, welcome, boot))

      assert {%{"command_id" => ^command}, box} = DeviceEndpoint.receive_type(box, "box_query")
      box = status(box, %{report | "status_seq" => 2}, "ok")

      assert {:ok, %{release: %{close_evidence: %{query_id: ^query} = evidence}}} =
               Games.fetch(host, game, :host)

      ready = host_conn |> recycle() |> get(host_route) |> html_response(200)
      assert ready =~ ~s(phx-submit="close_recovery")

      assert {:ok, %{"disposition" => "closed_no_replay"}} =
               Games.close_recovery(host, game, Controllers.id("close"), %{
                 command_id: command,
                 expected_recovery_id: prep["recovery_id"],
                 evidence: evidence,
                 reason: "Verified matching local record"
               })

      closed = host_conn |> recycle() |> get(host_route) |> html_response(200)
      assert closed =~ "Closed without replay"
      refute closed =~ ~s(phx-submit="close_recovery")
      refute closed =~ ~r/<button[^>]+phx-value-action="reset"[^>]+disabled[^>]*>/

      assert {:ok, _} = Games.host(host, game, Controllers.id("reset"), recovery_session, :reset)
      assert {:ok, %{release: nil}} = Games.fetch(host, game, :host)
      DeviceEndpoint.close(box)
    end)

    IO.puts("physical recovery checks passed")
  end

  def physical_reconnect(root) do
    with_box(root, :physical, fn fixture, host, _key, command, _clock ->
      {box, welcome, boot} = connect_box(fixture, command)
      report = confirmed_report(fixture.game_id, welcome, boot, command)
      confirmation = report["command_confirmation"]
      box = status(box, report, "ok")
      DeviceEndpoint.close(box)

      {box, welcome, new_boot, snapshot} = box_snapshot(fixture, command)
      assert new_boot != boot

      assert %{"release_status" => "position_confirmed", "command_confirmation" => ^confirmation} =
               snapshot["box"]

      # A rebooted box may lose access to the original journal entry. The new
      # report creates uncertainty while the prior confirmation stays in history.
      box = status(box, report(welcome, new_boot, command, 1), "ok")

      assert {:ok, %{release: %{status: :uncertain, observations: observations}}} =
               Games.fetch(host, fixture.game_id, :host)

      assert Enum.any?(observations, &(&1.command_confirmation == confirmation))
      DeviceEndpoint.close(box)

      {reconnected, rejoined, _, snapshot} = box_snapshot(fixture, command)
      assert rejoined["connection_id"] != welcome["connection_id"]

      assert %{"release_status" => "uncertain", "command_confirmation" => nil} = snapshot["box"]

      DeviceEndpoint.close(reconnected)
    end)

    IO.puts("physical reconnect checks passed")
  end

  defp with_box(root, box_mode, scenario) do
    Logger.configure(level: :warning)
    external_simulator = box_mode == :simulated
    Application.put_env(:vault, :box_mode, box_mode)

    if box_mode == :physical,
      do: Application.put_env(:vault, :box_device_id, "fixture_physical_box")

    Application.put_env(
      :vault,
      :simulator_transport,
      if(external_simulator, do: :external, else: :internal)
    )

    {:ok, %{box_device_id: device_id}} =
      Credentials.prepare_test(external_simulator: external_simulator)

    repo = StorageFixture.start_repo(root)
    {game, command} = seed_intent(device_id)
    {:ok, %{store_id: store_id}} = MaintenanceGuard.admit()
    assert :ok = GameStore.verify_open(store_id)
    :ok = Supervisor.stop(repo)
    Repo.put_dynamic_repo(Repo)

    {:ok, clock} = FakeClock.start_link(0)
    Application.put_env(:vault, :clock, FakeClock.handle(clock))
    Application.put_env(:vault, :environment, :test)
    Application.put_env(:vault, :origin, "http://127.0.0.1:4000")
    Application.put_env(:vault, :port, 0)
    Application.put_env(:vault, :bind, {127, 0, 0, 1})

    Application.put_env(:vault, VaultWeb.Endpoint,
      adapter: Bandit.PhoenixAdapter,
      server: false,
      render_errors: [
        formats: [html: VaultWeb.ErrorHTML, json: VaultWeb.ErrorJSON],
        layout: false
      ],
      pubsub_server: Vault.PubSub,
      live_view: [signing_salt: "vault-test"]
    )

    {:ok, _} = Application.ensure_all_started(:vault)

    {:ok, listener} =
      Bandit.start_link(plug: VaultWeb.Endpoint, ip: {127, 0, 0, 1}, port: 0, startup_log: false)

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(listener)

    {:ok, <<secret::binary-size(64), "\n">>} =
      MaintenanceGuard.read_protected(Path.join(root, "box.key"), 65)

    {:ok, key} = Credentials.read_key(Path.join(root, "host.key"))
    {:ok, host} = Auth.exchange(:host, key)

    fixture = %{
      port: port,
      device_id: device_id,
      secret: secret,
      game_id: game,
      box_mode: box_mode
    }

    try do
      scenario.(fixture, host, key, command, clock)
    after
      :ok = Supervisor.stop(listener)
      :ok = Application.stop(:vault)
    end
  end

  defp host_page_recovery(fixture, host, command, clock, root, host_key) do
    game = fixture.game_id
    host_route = "/games/#{game}/host"
    player_route = "/games/#{game}/play/a"
    {:ok, player_key} = Credentials.read_key(Path.join(root, "player-a.key"))
    host_conn = sign_in("/login", host_key, host_route)
    player_conn = sign_in("/join", player_key, player_route)
    assert player_conn |> recycle() |> get(host_route) |> response(403) == "Access denied"

    assert {:ok, %{checkpoint: checkpoint, preparation: stored}} = GameStore.load(game)

    assert {:ok, %{result: prep}} =
             GameStore.read_operation(game, stored.request_id, host.subject_id)

    assert checkpoint.session_id == prep["current_session_id"]

    {box, welcome, boot, snapshot} = box_snapshot(fixture, command)
    assert welcome["session_id"] == checkpoint.session_id
    box = status(box, report(welcome, boot, command, 1), "ok")
    box = heartbeat(box, welcome, clock, 3_300, 1)

    context = %{
      "session_id" => checkpoint.session_id,
      "recovery_id" => prep["recovery_id"],
      "recovery_generation" => prep["recovery_generation"],
      "disposition_id" => nil
    }

    binding = %{
      "box_boot_id" => boot,
      "connection_id" => welcome["connection_id"],
      "current_session_id" => checkpoint.session_id
    }

    before_close = host_conn |> recycle() |> get(host_route) |> html_response(200)
    assert before_close =~ "Copy local recovery data"
    assert before_close =~ "Request fresh box observation"

    expected = %{
      "Committed preparation" => prep,
      "Current host context" => context,
      "Current box binding" => binding
    }

    assert ^expected = recovery_documents(before_close)

    assert {:ok, %{query_id: query}} =
             Games.attest_sealed_record(host, game, attestation(prep, welcome, boot))

    assert {%{"command_id" => ^command}, box} = DeviceEndpoint.receive_type(box, "box_query")
    box = status(box, report(welcome, boot, command, 2), "ok")

    assert {:ok, %{release: %{close_evidence: %{query_id: ^query} = evidence}}} =
             Games.fetch(host, game, :host)

    close_request = Controllers.id("operator_close")

    assert {:ok, disposition} =
             Games.close_recovery(host, game, close_request, %{
               command_id: command,
               expected_recovery_id: prep["recovery_id"],
               evidence: evidence,
               reason: "Reviewed matching modeled local record"
             })

    assert {:ok, %{result: ^disposition}} =
             GameStore.read_operation(game, close_request, host.subject_id)

    assert disposition["disposition"] == "closed_no_replay"

    after_close = host_conn |> recycle() |> get(host_route) |> html_response(200)
    assert after_close =~ "Closed without replay. Recorded release status remains"
    assert after_close =~ "Uncertain"

    expected =
      expected
      |> put_in(["Current host context", "disposition_id"], disposition["disposition_id"])
      |> Map.put("Committed closed disposition", disposition)

    assert ^expected = recovery_documents(after_close)

    player_html = player_conn |> recycle() |> get(player_route) |> html_response(200)
    assert player_html =~ "Terminal A"
    refute player_html =~ "Copy local recovery data"
    refute player_html =~ "Committed closed disposition"

    {box_snapshot, box} = DeviceEndpoint.receive_type(box, "snapshot")

    # Request public state on a fresh ordinary controller connection and verify
    # the current host receipt has not become public device data.
    {:ok, <<secret::binary-size(64), "\n">>} =
      MaintenanceGuard.read_protected(Path.join(root, "cyd-a.key"), 65)

    {controller, _, public} =
      DeviceEndpoint.connect(%{fixture | device_id: "sim_cyd_a", secret: secret})

    assert public["projection"] == "public"

    for body <- [
          player_html,
          Jason.encode!(public),
          Jason.encode!(snapshot),
          Jason.encode!(box_snapshot)
        ] do
      for private <- [
            prep["recovery_id"],
            prep["request_id"],
            disposition["disposition_id"],
            disposition["local_record_id"],
            query,
            boot
          ] do
        refute body =~ private
      end
    end

    refute player_html =~ binding["connection_id"]
    assert public["connection_id"] != binding["connection_id"]
    assert snapshot["connection_id"] == binding["connection_id"]
    assert box_snapshot["connection_id"] == binding["connection_id"]

    DeviceEndpoint.close(controller)
    DeviceEndpoint.close(box)
  end

  defp sign_in(path, key, destination) do
    page = get(build_conn(), path)
    [_, csrf] = Regex.run(~r/name="_csrf_token" value="([^"]+)"/, html_response(page, 200))
    signed_in = page |> recycle() |> post(path, %{"access_token" => key, "_csrf_token" => csrf})
    assert redirected_to(signed_in) == destination
    signed_in
  end

  defp recovery_documents(html) do
    [_, details] =
      Regex.run(~r/<details[^>]+id="external-recovery-data"[^>]*>(.*?)<\/details>/s, html)

    Regex.scan(
      ~r/<label>\s*([^<]+?)\s*<textarea[^>]+readonly[^>]*>(.*?)<\/textarea>\s*<\/label>/s,
      details,
      capture: :all_but_first
    )
    |> Map.new(fn [label, value] ->
      value =
        value
        |> String.replace("&quot;", "\"")
        |> String.replace("&#39;", "'")
        |> String.replace("&lt;", "<")
        |> String.replace("&gt;", ">")
        |> String.replace("&amp;", "&")

      {label, Jason.decode!(value)}
    end)
  end

  defp status_recovery(fixture, host, command, clock) do
    {initial, welcome, _boot} = connect_box(fixture, command)
    game = fixture.game_id

    assert {:ok, prep} =
             Games.begin_recovery(host, game, Controllers.id("begin"), %{
               command_id: command,
               expected_session_id: welcome["session_id"]
             })

    assert {{:close, 4003, "session_reset"}, initial} = receive_close(initial)
    DeviceEndpoint.close(initial)

    {client, welcome, boot} = connect_box(fixture, command)
    assert welcome["session_id"] == prep["current_session_id"]
    original = report(welcome, boot, command, 10)
    client = status(client, original, "ok")
    assert [first] = observations(command)
    assert first.classification == "admitted"
    assert Controllers.id?(first.query_id)

    equivalent = Jason.encode!(original) |> String.replace("\"counter\":2", "\"counter\":2e0")
    client = DeviceEndpoint.send_frame(client, {:text, equivalent})
    client = expect_ack(client, 10, "ok")
    assert [^first] = observations(command)

    client = heartbeat(client, welcome, clock, 100, 1)
    attestation = attestation(prep, welcome, boot)

    assert {:ok, %{query_id: query}} =
             Games.attest_sealed_record(host, game, attestation)

    assert query != first.query_id
    assert {:error, %{code: :query_pending}} = Games.attest_sealed_record(host, game, attestation)

    assert {%{"command_id" => ^command}, client} =
             DeviceEndpoint.receive_type(client, "box_query")

    assert {:error, :timeout, client} =
             DeviceEndpoint.receive_until(
               client,
               &match?(%{"type" => "box_query"}, &1),
               DeviceEndpoint.now_ms() + 120
             )

    client = status(client, original, "ok")
    client = status(client, report(welcome, boot, command, 9), "stale_status")
    client = status(client, report(welcome, boot, nil, 11), "ok")
    assert {:ok, %{release: %{close_evidence: nil}}} = Games.fetch(host, game, :host)
    assert [%{query_id: nil, classification: "stale"}, ^first] = observations(command)

    client = status(client, report(welcome, boot, command, 13), "ok")

    assert {:ok, %{release: %{close_evidence: %{query_id: ^query, status_seq: 13}}}} =
             Games.fetch(host, game, :host)

    assert [_, ^first, %{query_id: ^query, classification: "admitted"}] = observations(command)

    client =
      Enum.reduce(20..48//2, client, fn seq, client ->
        started = DeviceEndpoint.now_ms()
        client = status(client, report(welcome, boot, command, seq), "ok")
        Process.sleep(max(0, 35 - (DeviceEndpoint.now_ms() - started)))
        client
      end)

    # Sequence 13 is the oldest cached receipt; 11 and 10 have aged out.
    before = observations(command)
    client = status(client, report(welcome, boot, command, 13), "ok")
    client = status(client, original, "stale_status")
    assert ^before = observations(command)

    changed = report(welcome, boot, command, 13) |> put_in(["extension", "counter"], 3)
    client = DeviceEndpoint.send_json(client, changed)
    assert {{:close, 1002, "sequence_conflict"}, client} = receive_close(client)
    DeviceEndpoint.close(client)

    after_conflict = observations(command)
    assert length(after_conflict) == length(before) + 1
    assert Enum.all?(before, &(&1 in after_conflict))

    assert Enum.any?(
             after_conflict,
             &(&1.status_seq == 13 and &1.classification == "content_conflict")
           )

    assert {:ok, %{release: %{close_evidence: nil}}} = Games.fetch(host, game, :host)

    after_timeout = query_timeout(fixture, host, command, prep, clock, after_conflict)

    {client, welcome, boot} = connect_box(fixture, command)
    client = DeviceEndpoint.send_json(client, confirmed_report(game, welcome, boot, command))
    assert {{:close, 1008, "binding_ended"}, client} = receive_close(client)
    DeviceEndpoint.close(client)
    assert ^after_timeout = observations(command)

    assert {:ok,
            %{command: %{command_id: ^command, dispatch_claimed: false, dispatch_retired: true}}} =
             GameStore.load(game)
  end

  defp query_timeout(fixture, host, command, prep, clock, history) do
    {client, welcome, boot} = connect_box(fixture, command)
    game = fixture.game_id
    client = status(client, report(welcome, boot, command, 1), "ok")
    client = heartbeat(client, welcome, clock, 200, 1)

    assert {:ok, %{query_id: query}} =
             Games.attest_sealed_record(host, game, attestation(prep, welcome, boot))

    assert {%{"command_id" => ^command}, client} =
             DeviceEndpoint.receive_type(client, "box_query")

    # Keep the box live until the 3,000 ms query deadline, independently of
    # the shorter 1,500 ms silence limit and 400 ms input lease.
    client =
      Enum.reduce(Enum.with_index(500..2_900//300, 2), client, fn {time, seq}, client ->
        client = heartbeat(client, welcome, clock, time, seq)
        Process.sleep(35)
        client
      end)

    :ok = FakeClock.advance_to(clock, 3_200)
    assert {{:close, 1008, "binding_ended"}, client} = receive_close(client)
    DeviceEndpoint.close(client)

    late = report(welcome, boot, command, 2)
    {replacement, fresh, _boot} = connect_box(fixture, command)
    assert fresh["connection_id"] != welcome["connection_id"]
    replacement = DeviceEndpoint.send_json(replacement, late)
    assert {{:close, 1002, "invalid_binding"}, replacement} = receive_close(replacement)
    DeviceEndpoint.close(replacement)

    observations = observations(command)
    assert length(observations) == length(history) + 1
    assert Enum.all?(history, &(&1 in observations))
    refute Enum.any?(observations, &(&1.query_id == query))
    assert {:ok, %{release: %{close_evidence: nil}}} = Games.fetch(host, game, :host)
    observations
  end

  defp attestation(prep, welcome, boot) do
    %{
      local_record_id: "inspected_record",
      service_epoch: 1,
      seal_operation_id: "inspected_seal",
      recovery_id: prep["recovery_id"],
      recovery_generation: prep["recovery_generation"],
      box_boot_id: boot,
      connection_id: welcome["connection_id"],
      current_session_id: welcome["session_id"],
      operator_confirmed: true
    }
  end

  defp heartbeat(client, welcome, clock, time, seq) do
    :ok = FakeClock.advance_to(clock, time)
    {challenge, client} = DeviceEndpoint.receive_type(client, "heartbeat_request")

    client =
      DeviceEndpoint.send_json(client, %{
        "v" => 1,
        "type" => "heartbeat",
        "connection_id" => welcome["connection_id"],
        "heartbeat_seq" => challenge["heartbeat_seq"],
        "input_seq" => seq,
        "input" => nil
      })

    assert {%{"input_accepted" => true}, client} =
             DeviceEndpoint.receive_message(client, fn
               %{"type" => "heartbeat_ack"} -> true
               {:close, _, _} -> true
               _ -> false
             end),
           "heartbeat failed at injected time #{time}, sample #{seq}"

    client
  end

  defp seed_intent(device_id) do
    {:ok, record} = GameStore.active()
    game = record.game.game_id
    old = record.checkpoint
    command = Controllers.id("release")

    seal = %{
      old
      | phase: :seal,
        position: 3,
        selected_runes: %{a: :star, b: :moon},
        state_revision: 1
    }

    solved = %{seal | phase: :solved, state_revision: 2, release_command_id: command}

    attrs = %{
      game_id: game,
      expected_session_id: old.session_id,
      request_id: Controllers.id("checkpoint"),
      operation: :checkpoint,
      operator_credential_id: nil,
      expected_revision: record.game.checkpoint_revision,
      request: %{},
      checkpoint: seal,
      result: %{"session_id" => old.session_id}
    }

    assert {:ok, _} = GameStore.commit(attrs)
    {:ok, current} = GameStore.load(game)

    attrs = %{
      attrs
      | request_id: Controllers.id("win"),
        operation: :win,
        expected_revision: current.game.checkpoint_revision,
        checkpoint: solved,
        result: %{"command_id" => command}
    }

    intent = %{
      command_id: command,
      game_id: game,
      intended_box_id: device_id,
      original_session_id: old.session_id,
      original_round_id: old.round_id,
      puzzle_revision: old.puzzle_revision,
      dispatch_binding: %{
        box_boot_id: "prior_boot",
        connection_id: "prior_connection",
        session_id: old.session_id,
        arm_id: "prior_arm",
        heartbeat_seq: 1,
        binding_generation: 1
      }
    }

    assert {:ok, _} = GameStore.commit(attrs, command: intent, qualify: fn -> true end)
    assert {:ok, _} = Records.original_win(Repo.get!(GameStore.ActuatorCommand, command))
    {game, command}
  end

  defp connect_box(fixture, command) do
    {client, welcome, boot, _} = box_snapshot(fixture, command)
    {client, welcome, boot}
  end

  defp box_snapshot(fixture, command) do
    boot = Controllers.id("box_boot")

    hello =
      DeviceEndpoint.hello(fixture, %{
        "boot_id" => boot,
        "device_class" => "box",
        "capabilities" => %{
          "latch" => "stepper",
          "home_sensor" => false,
          "released_sensor" => fixture.box_mode == :physical,
          "led_count" => 8,
          "buzzer" => false,
          "max_message_bytes" => 8192
        }
      })

    {client, welcome, snapshot} = DeviceEndpoint.connect(fixture, hello)
    assert %{"assigned_role" => nil, "allowed_roles" => [], "required_roles" => []} = welcome
    assert %{"projection" => "box", "role" => nil} = snapshot
    assert Map.take(snapshot, ~w(maze seal hold board_version)) == %{}

    assert {%{"command_id" => ^command}, client} =
             DeviceEndpoint.receive_type(client, "box_query")

    {client, welcome, boot, snapshot}
  end

  defp report(welcome, boot, command, seq) do
    %{
      "v" => 1,
      "type" => "box_status",
      "connection_id" => welcome["connection_id"],
      "session_id" => welcome["session_id"],
      "box_boot_id" => boot,
      "status_seq" => seq,
      "command_id" => command,
      "command_session_id" => nil,
      "release_status" => if(command, do: "uncertain", else: "not_requested"),
      "failure_code" => if(command, do: "unknown_command"),
      "motor_active" => false,
      "latch_position" => "unknown",
      "position_basis" => "unverified",
      "command_confirmation" => nil,
      "readiness" => %{
        "arm_id" => nil,
        "armed_session_id" => nil,
        "calibration_valid" => false,
        "start_verified" => false
      },
      "extension" => %{"counter" => 2}
    }
  end

  defp confirmed_report(game, welcome, boot, command) do
    {:ok, %{command: persisted}} = GameStore.load(game)

    Map.merge(report(welcome, boot, command, 1), %{
      "command_session_id" => persisted.original_session_id,
      "release_status" => "position_confirmed",
      "failure_code" => nil,
      "latch_position" => "released",
      "position_basis" => "endstop",
      "command_confirmation" => %{"basis" => "endstop", "box_boot_id" => boot}
    })
  end

  defp status(client, report, code),
    do: client |> DeviceEndpoint.send_json(report) |> expect_ack(report["status_seq"], code)

  defp expect_ack(client, seq, code) do
    accepted = code == "ok"

    assert {%{"status_seq" => ^seq, "code" => ^code, "accepted" => ^accepted}, client} =
             DeviceEndpoint.receive_type(client, "box_status_ack")

    client
  end

  defp observations(command) do
    Repo.all(
      from row in ReleaseObservation,
        where: row.command_id == ^command,
        order_by: [row.status_seq, row.observation_id]
    )
  end

  defp receive_close(client),
    do: DeviceEndpoint.receive_message(client, &match?({:close, _, _}, &1))
end
