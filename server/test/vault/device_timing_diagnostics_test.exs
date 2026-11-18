defmodule Vault.DeviceTimingDiagnosticsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Vault.DeviceTimingDiagnostics

  @moduletag :m2
  @flag "VAULT_DEVICE_SOCKET_DIAGNOSTICS"

  setup do
    previous = System.get_env(@flag)

    on_exit(fn ->
      if previous, do: System.put_env(@flag, previous), else: System.delete_env(@flag)
    end)
  end

  test "is off unless explicitly enabled" do
    for value <- [nil, "false", "1"] do
      if value, do: System.put_env(@flag, value), else: System.delete_env(@flag)
      refute DeviceTimingDiagnostics.enabled?()
      assert DeviceTimingDiagnostics.start(DeviceTimingDiagnostics.enabled?()) == nil

      log = capture_log(fn -> DeviceTimingDiagnostics.finish(:device_sample, nil) end)
      assert log == ""
    end

    System.put_env(@flag, "true")
    assert DeviceTimingDiagnostics.enabled?()
    assert is_integer(DeviceTimingDiagnostics.start(DeviceTimingDiagnostics.enabled?()))
  end

  test "only fixed slow events log and repeats are bounded per process and event" do
    now = System.monotonic_time(:millisecond)

    log =
      capture_log(fn ->
        DeviceTimingDiagnostics.finish(:room_tick, now + 10_000)
        DeviceTimingDiagnostics.finish("private arbitrary input", now - 250)
        DeviceTimingDiagnostics.finish(:room_tick, now - 110)
        DeviceTimingDiagnostics.finish(:room_tick, now - 250)
        DeviceTimingDiagnostics.finish(:room_tick_work, now - 110)
        DeviceTimingDiagnostics.finish(:room_checkpoint, now - 110)
      end)

    assert length(Regex.scan(~r/Device timing event=room_tick elapsed_ms=\d+/, log)) == 1
    assert length(Regex.scan(~r/Device timing event=room_tick_work elapsed_ms=\d+/, log)) == 1
    assert length(Regex.scan(~r/Device timing event=room_checkpoint elapsed_ms=\d+/, log)) == 1
    refute log =~ "private arbitrary input"
  end
end
