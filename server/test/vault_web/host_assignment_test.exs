defmodule VaultWeb.HostAssignmentTest do
  use ExUnit.Case, async: true

  alias Vault.{Projections, Puzzle}
  alias VaultWeb.{HostLive, PlayerLive}

  @moduletag :m2
  @fixture Path.expand("../../priv/puzzles/maze-v1.private.json", __DIR__)

  test "the host assignment choices filter registered CYD roles and show device identity" do
    {:ok, fixture} = Vault.JSON.decode(File.read!(@fixture), %{max_bytes: 262_144, max_depth: 64})
    {:ok, puzzle} = Puzzle.from_fixture(fixture)

    session = %{
      checkpoint: %{
        session_id: "test_session",
        state_revision: 1,
        phase: :lobby,
        paused: false,
        active_time_ms: 0,
        required_roles: [:a, :b]
      },
      rules: Puzzle.initial_state(puzzle),
      puzzle: puzzle,
      box: %{connected: false, report: nil},
      record: %{game: %{box_device_id: "test_box", box_mode: "simulated"}},
      release: nil,
      owners: %{a: nil, b: nil},
      epochs: %{a: 0, b: 0},
      actors: %{
        "actor_a" => controller_binding("actor_a", "cyd_a", [:a]),
        "actor_b" => controller_binding("actor_b", "cyd_b", [:b]),
        "actor_sim_b" => controller_binding("actor_sim_b", "sim_cyd_b", [:b])
      },
      diagnostics: [],
      service_result: nil
    }

    host = Projections.snapshot(session, :host, 0)

    for {id, roles} <- [{"cyd_a", [:a]}, {"cyd_b", [:b]}, {"sim_cyd_b", [:b]}] do
      assert Enum.find(host.actors, &(&1.subject_id == id)).allowed_roles == roles
    end

    html =
      render(HostLive, %{
        projection: host,
        bindings: %{},
        request_id: "request",
        operator_feedback: nil,
        pending_operation: nil
      })

    assert [_, options_a] =
             Regex.run(~r/<select id="takeover-target-a"[^>]*>(.*?)<\/select>/s, html)

    assert [_, options_b] =
             Regex.run(~r/<select id="takeover-target-b"[^>]*>(.*?)<\/select>/s, html)

    assert options_a =~ "CYD controller · cyd_a"
    refute options_a =~ "actor_b"
    refute options_a =~ "actor_sim_b"
    assert options_b =~ "CYD controller · cyd_b"
    assert options_b =~ "Simulated CYD controller"
    refute options_b =~ "actor_a"

    for audience <- [:public, :box, {:player, :a}, {:player, :b}] do
      projection = Projections.snapshot(session, audience, 0)
      refute Map.has_key?(projection, :actors)
      refute Map.has_key?(projection, :allowed_roles)
      refute inspect(projection) =~ "cyd_a"
      refute inspect(projection) =~ "cyd_b"
    end

    player = render(PlayerLive, %{projection: host.panels.a, bindings: %{}, role: :a})
    refute player =~ "takeover-target"
    refute player =~ "cyd_a"
    refute player =~ "cyd_b"
  end

  defp controller_binding(actor_id, subject_id, allowed_roles) do
    %{
      panel: nil,
      last_seen_ms: 0,
      actor: %{
        actor_id: actor_id,
        role: nil,
        source: :cyd,
        principal: %{subject_id: subject_id, allowed_roles: allowed_roles}
      }
    }
  end

  defp render(module, assigns) do
    assigns
    |> Map.put(:__changed__, %{})
    |> module.render()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end
end
