defmodule Vault.DeviceTimingDiagnostics do
  @moduledoc false

  require Logger

  @slow_ms 100
  @repeat_ms 1_000
  @events [:room_tick, :room_tick_work, :device_scope, :device_sample, :room_checkpoint]

  def enabled?, do: System.get_env("VAULT_DEVICE_SOCKET_DIAGNOSTICS") == "true"

  def start(true), do: System.monotonic_time(:millisecond)
  def start(false), do: nil

  def finish(_event, nil), do: :ok
  def finish(event, started), do: report(event, System.monotonic_time(:millisecond) - started)

  defp report(event, elapsed_ms)
       when event in @events and is_integer(elapsed_ms) and elapsed_ms >= @slow_ms do
    now = System.monotonic_time(:millisecond)
    key = {__MODULE__, event}

    if now >= Process.get(key, now - @repeat_ms) + @repeat_ms do
      Process.put(key, now)
      Logger.warning("Device timing event=#{event} elapsed_ms=#{elapsed_ms}")
    end

    :ok
  end

  defp report(_event, _elapsed_ms), do: :ok
end
