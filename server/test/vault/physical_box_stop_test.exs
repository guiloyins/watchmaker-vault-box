defmodule Vault.PhysicalBoxStopTest do
  use ExUnit.Case, async: false

  alias Vault.{MaintenanceGuard, StorageFixture}
  alias Vault.GameStore.Codec

  @tag timeout: 45_000
  test "physical host rotation requires matching protected stop evidence and preserves device credentials" do
    root = StorageFixture.temp_root()
    operation_path = Path.join(root, "stop-operation.json")
    status_path = Path.join(root, "stop-status.json")
    reboot_status_path = Path.join(root, "other-boot-status.json")
    unsafe_status_path = Path.join(root, "unsafe-status.json")
    symlink_status = Path.join(root, "linked-status.json")
    {operation, status} = stopped_box()
    write(operation_path, operation)
    write(status_path, status)
    write(reboot_status_path, %{status | "box_boot_id" => "boot_after_stop"})
    write(unsafe_status_path, put_in(status["data"]["outputs_disabled"], false))
    File.ln_s!(status_path, symlink_status)

    source = """
    import ExUnit.Assertions
    alias Vault.{Credentials, MaintenanceGuard}
    Application.put_env(:vault, :box_mode, :physical)
    Application.put_env(:vault, :box_device_id, "native_box")
    {:ok, _} = Credentials.prepare_test()
    [operation_path, status_path, reboot_status, unsafe_status, symlink_status] = System.argv()
    original = Path.join(root, "host.key")
    replacement = Path.join(root, "replacement.key")
    box = Path.join(root, "box.key")
    key_hash = :crypto.hash(:sha256, File.read!(box))
    assert {:error, :local_stop_required} = Credentials.rotate_host(replacement)
    for rejected <- [reboot_status, unsafe_status, symlink_status] do
      assert {:error, :local_stop_required} = Credentials.rotate_host(replacement, {operation_path, rejected, true})
    end
    assert {:error, :local_stop_required} = Credentials.rotate_host(replacement, {operation_path, status_path, false})
    refute File.exists?(replacement)
    assert {:ok, %{active?: true, auth_epoch: 1}} = Credentials.host_status(original)
    assert {:ok, guard} = MaintenanceGuard.acquire(root)
    assert {:error, :guard_owned} = Credentials.rotate_host(replacement, {operation_path, status_path, true})
    refute File.exists?(replacement)
    :ok = MaintenanceGuard.release(guard)
    assert :ok = Credentials.rotate_host(replacement, {operation_path, status_path, true})
    assert {:ok, %{active?: false, auth_epoch: 2}} = Credentials.host_status(original)
    assert {:ok, %{active?: true, auth_epoch: 2}} = Credentials.host_status(replacement)
    assert key_hash == :crypto.hash(:sha256, File.read!(box))
    refute File.exists?(Path.join(root, "simulated-box.sqlite3"))
    IO.puts("physical rotation fixture passed")
    """

    assert {"physical rotation fixture passed\n", 0} =
             StorageFixture.vm(root, source, [
               operation_path,
               status_path,
               reboot_status_path,
               unsafe_status_path,
               symlink_status
             ])
  end

  test "physical evidence cannot bypass the simulated maintenance gate" do
    root = StorageFixture.temp_root()

    source = """
    import ExUnit.Assertions
    alias Vault.Credentials
    {:ok, _} = Credentials.prepare_test()
    replacement = Path.join(root, "replacement.key")
    assert {:error, :local_stop_required} = Credentials.rotate_host(replacement, {"private_operation", "private_status", true})
    refute File.exists?(replacement)
    IO.puts("simulation gate preserved")
    """

    assert {"simulation gate preserved\n", 0} = StorageFixture.vm(root, source)
  end

  defp write(path, artifact) do
    {:ok, bytes} = Codec.encode(artifact, 8192)
    :ok = MaintenanceGuard.write_protected(path, bytes <> "\n")
  end

  defp stopped_box do
    operation = "svc_0000000000000007_" <> String.duplicate("a", 32)
    boot = "boot_before_rotation"
    device = "native_box"

    job = %{
      "file_version" => 1,
      "operation_id" => operation,
      "expected_revision" => 6,
      "request_without_secrets" => %{
        "sv" => 1,
        "type" => "request",
        "device_id" => device,
        "box_boot_id" => boot,
        "operation_id" => operation,
        "expected_revision" => 6,
        "command" => "stop",
        "args" => %{
          "reason" => "lost_host_key",
          "operator" => %{
            "operator_id" => "operator",
            "observation" => "Stopped and inspected fixture"
          }
        }
      },
      "result" => %{
        "storage_version" => 1,
        "operation_id" => operation,
        "expected_revision" => 6,
        "resulting_revision" => 7,
        "command" => "stop",
        "completion" => nil,
        "decision" => %{
          "status" => "ok",
          "code" => "ok",
          "data" => %{
            "operation_id" => operation,
            "resulting_revision" => 7,
            "service_epoch" => 2
          }
        }
      }
    }

    current = %{
      "sv" => 1,
      "type" => "result",
      "device_id" => device,
      "box_boot_id" => boot,
      "request_id" => "req_status",
      "operation_id" => nil,
      "service_revision" => 7,
      "status" => "ok",
      "code" => "ok",
      "data" => %{
        "storage_version" => 1,
        "service_revision" => 7,
        "service_epoch" => 2,
        "device_id" => device,
        "box_boot_id" => boot,
        "binding" => nil,
        "service_inhibited" => true,
        "motion_frozen" => true,
        "motor_active" => false,
        "outputs_disabled" => true,
        "active_motion_operation_id" => nil,
        "preparation_operation_id" => nil,
        "readiness" => %{
          "arm_id" => nil,
          "armed_session_id" => nil,
          "calibration_valid" => false,
          "start_verified" => false
        },
        "position" => %{"latch_position" => "unknown", "position_basis" => "unverified"},
        "journal_count" => 1,
        "active_local_record_id" => nil,
        "clear_operation_id" => nil,
        "storage_fault" => nil
      }
    }

    {job, current}
  end
end
