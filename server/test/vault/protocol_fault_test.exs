defmodule Vault.ProtocolFaultTest do
  use ExUnit.Case, async: true

  alias Vault.Protocol
  alias Vault.Protocol.{Challenges, CommandWindow, StatusWindow}

  @request ~S|{"v":1,"type":"command","connection_id":"conn","command_seq":1,"session_id":"session","action":"request_snapshot","payload":{}}|
  @status ~S|{"v":1,"type":"box_status","connection_id":"conn","box_boot_id":"boot","session_id":"session","status_seq":1,"command_id":null,"command_session_id":null,"release_status":"not_requested","motor_active":false,"latch_position":"unknown","position_basis":"unverified","readiness":{"arm_id":null,"armed_session_id":null,"calibration_valid":false,"start_verified":false},"failure_code":null,"command_confirmation":null}|

  test "command windows replay rejections, hold exactly 128 pairs and leave gaps unconsumed" do
    window = CommandWindow.new()
    assert {:gap, 1} = CommandWindow.check(window, 2, "gap")
    assert :next = CommandWindow.check(window, 1, "first")
    window = CommandWindow.put(window, 1, "first", {:rejected, :paused})
    assert {:replay, {:rejected, :paused}} = CommandWindow.check(window, 1, "first")
    assert :conflict = CommandWindow.check(window, 1, "changed")
    assert {:gap, 2} = CommandWindow.check(window, 3, "gap")

    window =
      Enum.reduce(2..129, window, fn seq, window ->
        comparison = Integer.to_string(seq)
        assert :next = CommandWindow.check(window, seq, comparison)
        CommandWindow.put(window, seq, comparison, :applied)
      end)

    assert map_size(window.entries) == 128
    assert :expired = CommandWindow.check(window, 1, "first")
    assert {:replay, :applied} = CommandWindow.check(window, 2, "2")
    assert {:replay, :applied} = CommandWindow.check(window, 129, "129")
    assert {:gap, 130} = CommandWindow.check(window, 131, "gap")
    assert :next = CommandWindow.check(window, 130, "expected")
    assert :next = CommandWindow.check(CommandWindow.new(), 1, "first")
  end

  test "status windows allow gaps, keep 16 complete pairs and fence older uncached reports" do
    window = StatusWindow.new()
    assert :next = StatusWindow.check(window, 5, "initial")
    window = StatusWindow.put(window, 5, "initial", %{accepted: true})
    assert {:replay, %{accepted: true}} = StatusWindow.check(window, 5, "initial")
    assert :conflict = StatusWindow.check(window, 5, "changed")
    assert :stale = StatusWindow.check(window, 4, "absent")

    window =
      Enum.reduce(1..16, window, fn index, window ->
        seq = 10 * index
        assert :next = StatusWindow.check(window, seq, "status")
        StatusWindow.put(window, seq, "status", {:ack, seq})
      end)

    assert map_size(window.entries) == 16
    assert StatusWindow.high_water(window) == 160
    assert :stale = StatusWindow.check(window, 5, "initial")
    assert :stale = StatusWindow.check(window, 159, "status")
    assert {:replay, {:ack, 10}} = StatusWindow.check(window, 10, "status")
    assert {:replay, {:ack, 160}} = StatusWindow.check(window, 160, "status")
    assert :next = StatusWindow.check(window, 200, "gap")
  end

  test "both windows compare complete decoded values including huge exponent extensions" do
    for {raw, window} <- [{@request, CommandWindow}, {@status, StatusWindow}] do
      original =
        add_extension(raw, ~S|{"numbers":[1,1e999999,1.5],"é":"\u0000","zero":-0e-999999}|)

      equivalent =
        add_extension(raw, ~S|{"zero":0,"\u00e9":"\u0000","numbers":[10e-1,10e999998,150e-2]}|)

      assert {:ok, %{message: known, comparison: comparison}} = Protocol.decode(original)
      assert {:ok, %{message: ^known, comparison: ^comparison}} = Protocol.decode(equivalent)
      assert :next = window.check(window.new(), 1, comparison)
      recorded = window.put(window.new(), 1, comparison, :result)
      assert {:replay, :result} = window.check(recorded, 1, comparison)

      for changed <- [
            String.replace(equivalent, "10e999998", "1e999998"),
            String.replace(equivalent, "150e-2", "15001e-4"),
            String.replace(equivalent, "10e-1,10e999998", "10e999998,10e-1"),
            String.replace(equivalent, "10e-1", ~S|"1"|),
            String.replace(equivalent, ~S|"\u00e9"|, ~S|"e\u0301"|),
            String.replace(equivalent, ~S|"zero"|, ~S|"new_key"|)
          ] do
        assert {:ok, %{message: ^known, comparison: altered}} = Protocol.decode(changed)
        assert :conflict = window.check(recorded, 1, altered)
      end

      assert {:error, :duplicate_key} =
               Protocol.decode(add_extension(raw, ~S|{"key":null,"\u006bey":null}|))
    end
  end

  test "challenge deadlines are issue-anchored and stale or duplicate samples cannot renew" do
    records = %{} |> Challenges.issue(1, 0) |> Challenges.issue(2, 100)

    assert {:ok, 400} = Challenges.check(records, 1, 1, 0, 0, 399)
    assert {:error, :stale_challenge} = Challenges.check(records, 1, 500, 0, 0, 400)
    assert {:ok, 400} = Challenges.check(records, 1, 2, 1, 1, 399)
    assert {:error, :stale_sample} = Challenges.check(records, 1, 1, 1, 1, 399)
    assert {:error, :stale_challenge} = Challenges.check(records, 1, 3, 2, 2, 399)
    assert {:error, :stale_challenge} = Challenges.check(records, 9, 3, 2, 2, 399)
    assert {:ok, 500} = Challenges.check(records, 2, 3, 2, 2, 499)
    assert {:error, :stale_challenge} = Challenges.deadline(records, 2, 99)
    assert {:ok, -100} = Challenges.deadline(Challenges.issue(%{}, 1, -500), 1, -499)

    assert %{2 => 100, 3 => 400} == Challenges.issue(records, 3, 400)
  end

  test "challenge issue records are capped even when many share a timestamp" do
    records = Enum.reduce(1..33, %{}, &Challenges.issue(&2, &1, 0))
    assert map_size(records) == 32
    assert {:error, :stale_challenge} = Challenges.deadline(records, 1, 399)
    assert {:ok, 400} = Challenges.deadline(records, 2, 399)
    assert {:ok, 400} = Challenges.deadline(records, 33, 399)
  end

  defp add_extension(message, extension) do
    binary_part(message, 0, byte_size(message) - 1) <> ~s|,"extension":| <> extension <> "}"
  end
end
