defmodule Vault.Test.BoxConformance do
  @moduledoc "Literal protocol-v1 observations for a simulated release and its recovery."
  import ExUnit.Assertions

  alias Vault.SimulatedBox.Adapter
  alias Vault.Test.FakeClock

  @instance "instance_conformance"
  @device "box_conformance"
  @now -10_000
  @operator %{"operator_id" => "operator", "observation" => "Reviewed simulated evidence"}

  def instance, do: @instance
  def device, do: @device
  def now, do: @now
  def operator, do: @operator

  def binding(generation, session \\ "original") do
    %{connection_id: "conn_#{generation}", session_id: session, binding_generation: generation}
  end

  def fingerprint(session \\ "original"),
    do: %{session_id: session, action: "set_latch", target: "released"}

  def local_binding(boot, binding) do
    %{
      "box_boot_id" => boot,
      "connection_id" => binding.connection_id,
      "current_session_id" => binding.session_id
    }
  end

  def setup_binding(box, generation, session \\ "original") do
    {:ok, boot} = Adapter.boot_id(box)
    welcome = binding(generation, session)
    assert :ok = Adapter.bind(box, boot, welcome)
    assert_status(box, generation, %{release_status: :not_requested, motor_active: false})
    {boot, welcome}
  end

  def prepare(box, boot, welcome, arm \\ "arm_first") do
    generation = welcome.binding_generation

    assert %{
             "status" => "ok",
             "data" => %{
               "receipt" => %{
                 "decision" => %{
                   "data" => %{
                     "position" => "unknown",
                     "modeled_position" => "locked",
                     "basis" => "unverified"
                   }
                 }
               }
             }
           } = Adapter.prepare(box)

    assert_status(box, generation, %{readiness: readiness(nil, nil, true, false)})
    assert_status(box, generation, %{readiness: readiness(nil, nil, true, true)})
    Adapter.arm(box, generation, arm)
    assert_status(box, generation, %{readiness: readiness(nil, nil, true, true)})

    assert %{"status" => "ok"} =
             Adapter.service_operation(box, "service.exit", %{
               "binding" => local_binding(boot, welcome)
             })

    assert_status(box, generation, %{readiness: readiness(nil, nil, true, true)})
    Adapter.arm(box, generation, arm)
    assert_status(box, generation, %{readiness: readiness(arm, welcome.session_id, true, true)})
  end

  def challenge(box, generation, boot, seq, observed, input_seq \\ nil) do
    Adapter.challenge(box, generation, seq, observed)
    assert_receive {:simulated_box, :heartbeat, ^generation, ^boot, ^seq, received}, 1_000
    if input_seq, do: assert(received == input_seq)
  end

  def assert_status(box, generation, expected, context \\ nil) do
    assert_receive {:simulated_box, :status, ^generation, report, ^context}, 1_000
    %{status: status, original_json: encoded, comparison: comparison} = report
    Adapter.ack_status(box, generation, status.status_seq)

    assert status.latch_position == :unknown
    assert status.position_basis == :unverified
    assert status.command_confirmation == nil
    assert Map.take(status, Map.keys(expected)) == expected

    assert {:ok, %{"v" => {:json_number, "1"}, "type" => "box_status"} = parsed} =
             Vault.JSON.decode_object(encoded, %{max_bytes: 4_096, max_depth: 8})

    assert parsed["latch_position"] == "unknown"
    assert parsed["position_basis"] == "unverified"
    assert parsed["command_confirmation"] == nil
    assert parsed["release_status"] == Atom.to_string(status.release_status)
    assert {:ok, ^comparison} = Vault.JSON.comparison(parsed, 4_096)
    status
  end

  def readiness(arm, session, calibration_valid, start_verified) do
    %{
      arm_id: arm,
      armed_session_id: session,
      calibration_valid: calibration_valid,
      start_verified: start_verified
    }
  end

  def query(box, generation, command, expected) do
    context = %{query_id: "query_literal", binding_generation: generation, minimum_status_seq: 1}
    Adapter.query(box, generation, command, context)
    assert_status(box, generation, Map.put(expected, :command_id, command), context)
  end

  def step(clock, due, ordinal) do
    :ok = FakeClock.advance_to(clock, due)
    assert_receive {:box_trace, {:step, _, ^ordinal}}, 1_000
  end

  def assert_no_steps do
    refute_receive {:box_trace, {:step, _, _}}, 10
  end

  def recovery_preparation(command) do
    %{
      "request_id" => "begin",
      "recovery_id" => "recovery",
      "recovery_generation" => 1,
      "current_session_id" => "recovery_session",
      "game_id" => "game",
      "command_id" => command,
      "intended_box_id" => @device,
      "original_session_id" => "original",
      "original_round_id" => 1,
      "fingerprint" => %{
        "session_id" => "original",
        "action" => "set_latch",
        "target" => "released"
      },
      "prior_recovery_id" => nil,
      "committed_at_ms" => 123
    }
  end

  def recovery_current do
    %{
      "session_id" => "recovery_session",
      "recovery_id" => "recovery",
      "recovery_generation" => 1,
      "disposition_id" => nil
    }
  end

  def disposition(preparation, local, seal, service_epoch, boot, welcome, status_seq) do
    Map.merge(
      Map.take(preparation, ~w(game_id command_id intended_box_id original_session_id
      original_round_id fingerprint recovery_id recovery_generation)),
      %{
        "request_id" => "close",
        "disposition_id" => "disposition",
        "disposition" => "closed_no_replay",
        "closed_session_id" => welcome.session_id,
        "local_record_id" => local,
        "service_epoch" => service_epoch,
        "seal_operation_id" => seal,
        "box_boot_id" => boot,
        "connection_id" => welcome.connection_id,
        "status_seq" => status_seq,
        "committed_at_ms" => 321
      }
    )
  end
end
