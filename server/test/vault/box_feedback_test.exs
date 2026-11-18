defmodule Vault.BoxFeedbackTest do
  use ExUnit.Case, async: true

  alias Vault.BoxFeedback
  alias Vault.Puzzle.{Input, State}
  alias VaultWeb.DeviceSocket

  test "steady feedback refreshes, wall cues are bounded, and cosmetic telemetry stops at 10 Hz" do
    assert BoxFeedback.new(%{"led_count" => 0, "buzzer" => false}) == nil
    feedback = BoxFeedback.new(%{"led_count" => 8, "buzzer" => true})
    rules = %State{phase: :maze, position: 12}
    {feedback, first} = BoxFeedback.tick(feedback, rules, 2000, true, nil, 100)

    assert first == %{
             "feedback_seq" => 1,
             "light_mode" => "idle",
             "progress_percent" => 0,
             "sound" => "none",
             "ttl_ms" => 1000
           }

    feedback = BoxFeedback.wall(feedback, 150)
    assert {^feedback, nil} = BoxFeedback.tick(feedback, rules, 2000, true, nil, 199)
    {feedback, packet} = BoxFeedback.tick(feedback, rules, 2000, true, nil, 200)
    assert %{"light_mode" => "error", "sound" => "error", "ttl_ms" => 300} = packet
    feedback = BoxFeedback.wall(feedback, 300)
    {feedback, nil} = BoxFeedback.tick(feedback, rules, 2000, true, nil, 349)
    {feedback, packet} = BoxFeedback.tick(feedback, rules, 2000, true, nil, 450)
    assert %{"light_mode" => "idle", "sound" => "none", "feedback_seq" => 3} = packet
    {feedback, nil} = BoxFeedback.tick(feedback, rules, 2000, true, nil, 949)
    {_, packet} = BoxFeedback.tick(feedback, rules, 2000, true, nil, 950)
    assert %{"light_mode" => "idle", "sound" => "none", "feedback_seq" => 4} = packet
  end

  test "live shared hold progress is distinct from the solve cue and mechanism uncertainty" do
    caps = %{"led_count" => 8, "buzzer" => true}
    feedback = BoxFeedback.new(caps)
    maze = %State{phase: :maze, position: 7}
    {feedback, _} = BoxFeedback.tick(feedback, maze, 2000, true, nil, 1000)
    input = %Input{press_id: 1, lease_until_ms: 2250}
    seal = %{maze | phase: :seal, attempt: %{started_at_ms: 1100}, inputs: %{a: input, b: input}}
    {feedback, packet} = BoxFeedback.tick(feedback, seal, 2000, true, nil, 2100)
    assert %{"light_mode" => "progress", "progress_percent" => 50, "sound" => "tick"} = packet
    {feedback, packet} = BoxFeedback.tick(feedback, seal, 2000, true, nil, 2250)
    assert %{"light_mode" => "idle", "progress_percent" => 0, "sound" => "none"} = packet
    solved = %{seal | phase: :solved}

    {feedback, packet} =
      BoxFeedback.tick(feedback, solved, 2000, true, %{status: :pending, uncertain: false}, 2350)

    assert %{"light_mode" => "success", "sound" => "success"} = packet

    {feedback, packet} =
      BoxFeedback.tick(feedback, solved, 2000, true, %{status: :uncertain, uncertain: true}, 2450)

    assert %{"light_mode" => "error", "sound" => "error"} = packet

    {_, packet} =
      BoxFeedback.tick(feedback, solved, 2000, true, %{status: :uncertain, uncertain: true}, 2950)

    assert %{"light_mode" => "error", "sound" => "none"} = packet

    {_, packet} =
      BoxFeedback.tick(
        BoxFeedback.new(caps),
        solved,
        2000,
        true,
        %{status: :motion_complete, uncertain: false},
        2950
      )

    assert %{"light_mode" => "success", "sound" => "none", "feedback_seq" => 1} = packet
  end

  test "cosmetic coalescing emits one wakeup for the latest frame without reserving a critical slot" do
    slot = :ets.new(:feedback_test, [:set, :public])
    counter = :atomics.new(2, signed: false)
    delivery = %DeviceSocket.Delivery{pid: self(), counter: counter, feedback: slot}
    for value <- 1..100, do: assert(:ok = DeviceSocket.offer_feedback(delivery, value))
    assert_receive {:vault_device_feedback, ^slot}
    refute_receive {:vault_device_feedback, ^slot}, 0
    assert :ets.take(slot, :latest) == [{:latest, 100}]
    assert :atomics.get(counter, 1) == 0
    assert :atomics.get(counter, 2) == 0
    assert :ok = DeviceSocket.offer_feedback(delivery, 101)
    assert_receive {:vault_device_feedback, ^slot}
  end
end
