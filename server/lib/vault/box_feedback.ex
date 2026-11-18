defmodule Vault.BoxFeedback do
  @moduledoc false

  alias Vault.Puzzle

  @interval_ms 100
  @refresh_ms 500
  @ttl_ms 1_000
  @wall_ms 300

  def new(%{"led_count" => leds, "buzzer" => buzzer})
      when (is_integer(leds) and leds > 0) or buzzer == true do
    %{buzzer: buzzer, sequence: 0, sent_at: nil, shown: nil, prior: nil, wall_until: nil}
  end

  def new(_), do: nil

  def wall(nil, _now), do: nil

  def wall(state, now) do
    if state.wall_until == nil or now >= state.wall_until + @wall_ms,
      do: %{state | wall_until: now + @wall_ms},
      else: state
  end

  def tick(nil, _rules, _duration, _ready, _release, _now), do: {nil, nil}

  def tick(state, rules, duration, ready, release, now) do
    if state.sent_at != nil and now - state.sent_at < @interval_ms do
      {state, nil}
    else
      alert = release != nil and (release.status in [:failed, :uncertain] or release.uncertain)

      wall =
        not alert and not rules.paused and rules.phase == :maze and
          state.wall_until != nil and now < state.wall_until

      current = {rules.phase, ready and not rules.paused, alert}
      shown = desired(rules, duration, now, alert, wall)
      sound = if state.buzzer, do: cue(state, current, wall), else: "none"
      next = %{state | prior: current}

      if shown != state.shown or sound != "none" or
           (state.sent_at != nil and now - state.sent_at >= @refresh_ms) do
        {mode, percent} = shown
        seq = state.sequence + 1

        packet = %{
          "feedback_seq" => seq,
          "light_mode" => mode,
          "progress_percent" => percent,
          "sound" => sound,
          "ttl_ms" => if(wall, do: @wall_ms, else: @ttl_ms)
        }

        {%{next | sequence: seq, shown: shown, sent_at: now}, packet}
      else
        {next, nil}
      end
    end
  end

  defp desired(_rules, _duration, _now, true, _wall), do: {"error", 0}
  defp desired(_rules, _duration, _now, _alert, true), do: {"error", 0}
  defp desired(%{paused: true}, _duration, _now, _alert, _wall), do: {"paused", 0}
  defp desired(%{phase: :solved}, _duration, _now, _alert, _wall), do: {"success", 100}

  defp desired(rules, duration, now, _alert, _wall) do
    if Puzzle.attempt_active?(rules, now) do
      elapsed = (now - rules.attempt.started_at_ms) |> max(0) |> min(duration - 1)
      {"progress", div(elapsed * 100, duration)}
    else
      {"idle", 0}
    end
  end

  defp cue(%{prior: nil}, _current, _wall), do: "none"
  defp cue(%{prior: {_, _, false}}, {_, _, true}, _wall), do: "error"
  defp cue(%{shown: previous}, _, true) when previous != {"error", 0}, do: "error"
  defp cue(%{prior: {phase, _, _}}, {:solved, _, false}, _) when phase != :solved, do: "success"
  defp cue(%{prior: {:maze, _, _}}, {:seal, _, false}, _), do: "tick"

  defp cue(%{prior: {_, false, _}}, {phase, true, false}, _) when phase in [:lobby, :maze],
    do: "tick"

  defp cue(_, _, _), do: "none"
end
