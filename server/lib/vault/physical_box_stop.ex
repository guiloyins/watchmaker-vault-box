defmodule Vault.PhysicalBoxStop do
  @moduledoc false

  alias Vault.GameStore.Codec
  alias Vault.MaintenanceGuard

  # These two documents are supplied by the local operator. The host checks
  # they agree and describes the evidence as an attestation, not authentication.
  def attest(device_id, {operation_path, status_path, true}) do
    with {:ok, operation} <- read_file(operation_path),
         {:ok, boot_id, revision, epoch} <- stop_receipt(operation, device_id),
         {:ok, status} <- read_file(status_path),
         true <- stopped_status?(status, device_id, boot_id, revision, epoch) do
      :ok
    else
      _ -> {:error, :local_stop_required}
    end
  end

  def attest(_, _), do: {:error, :local_stop_required}

  defp read_file(path) when is_binary(path) do
    with {:ok, parent} <- MaintenanceGuard.owned_directory(Path.dirname(Path.expand(path))),
         {:ok, bytes} <-
           MaintenanceGuard.read_protected(Path.join(parent, Path.basename(path)), 8193),
         do: Codec.decode(bytes, 8193)
  end

  defp read_file(_), do: {:error, :local_stop_required}

  defp stop_receipt(
         %{
           "file_version" => 1,
           "operation_id" => operation,
           "expected_revision" => before,
           "request_without_secrets" => request,
           "result" => receipt
         } = file,
         device_id
       )
       when map_size(file) == 5 do
    with true <- Codec.n?(before),
         revision = before + 1,
         true <- Codec.p?(revision) and operation?(operation, revision),
         %{
           "sv" => 1,
           "type" => "request",
           "device_id" => ^device_id,
           "box_boot_id" => boot,
           "operation_id" => ^operation,
           "expected_revision" => ^before,
           "command" => "stop",
           "args" => %{"reason" => reason, "operator" => operator} = args
         } <- request,
         true <- map_size(request) == 8 and map_size(args) == 2 and Codec.id?(boot),
         true <- reason in ["maintenance", "lost_host_key"] and operator?(operator),
         %{
           "storage_version" => 1,
           "operation_id" => ^operation,
           "expected_revision" => ^before,
           "resulting_revision" => ^revision,
           "command" => "stop",
           "completion" => nil,
           "decision" => %{"status" => "ok", "code" => "ok", "data" => data} = decision
         } <- receipt,
         %{
           "operation_id" => ^operation,
           "resulting_revision" => ^revision,
           "service_epoch" => epoch
         } <-
           data,
         true <- map_size(receipt) == 7 and map_size(decision) == 3 and map_size(data) == 3,
         true <- Codec.p?(epoch) do
      {:ok, boot, revision, epoch}
    else
      _ -> {:error, :local_stop_required}
    end
  end

  defp stop_receipt(_, _), do: {:error, :local_stop_required}

  defp stopped_status?(
         %{
           "sv" => 1,
           "type" => "result",
           "request_id" => request,
           "device_id" => device,
           "box_boot_id" => boot,
           "operation_id" => nil,
           "service_revision" => revision,
           "status" => "ok",
           "code" => "ok",
           "data" => data
         } = result,
         device,
         boot,
         revision,
         epoch
       )
       when map_size(result) == 10 do
    with true <- Codec.id?(request),
         %{
           "storage_version" => 1,
           "service_revision" => ^revision,
           "service_epoch" => ^epoch,
           "device_id" => ^device,
           "box_boot_id" => ^boot,
           "binding" => nil,
           "service_inhibited" => true,
           "motion_frozen" => frozen,
           "motor_active" => false,
           "outputs_disabled" => true,
           "active_motion_operation_id" => nil,
           "preparation_operation_id" => nil,
           "readiness" => readiness,
           "position" => position,
           "journal_count" => count,
           "active_local_record_id" => record,
           "clear_operation_id" => clear,
           "storage_fault" => nil
         } <- data,
         %{
           "arm_id" => nil,
           "armed_session_id" => nil,
           "calibration_valid" => calibrated,
           "start_verified" => false
         } <- readiness,
         %{"latch_position" => latch, "position_basis" => basis} <- position do
      map_size(data) == 18 and map_size(readiness) == 4 and map_size(position) == 2 and
        is_boolean(calibrated) and is_boolean(frozen) and is_integer(count) and count in 0..32 and
        latch in ["locked", "released", "unknown"] and
        basis in ["unverified", "manual_verified", "endstop"] and
        (record == nil or Codec.id?(record)) and (clear == nil or Codec.id?(clear))
    else
      _ -> false
    end
  end

  defp stopped_status?(_, _, _, _, _), do: false

  defp operation?(operation, revision) when is_binary(operation) do
    case Regex.run(~r/\Asvc_([0-9a-f]{16})_[0-9a-f]{32}\z/, operation) do
      [_, sequence] -> Integer.parse(sequence, 16) == {revision, ""}
      _ -> false
    end
  end

  defp operation?(_, _), do: false

  defp operator?(%{"operator_id" => id, "observation" => observation} = operator)
       when map_size(operator) == 2 and is_binary(observation) and byte_size(observation) <= 256 do
    Codec.id?(id) and not Regex.match?(~r/[\x{0}-\x{1f}\x{7f}-\x{9f}]/u, observation)
  end

  defp operator?(_), do: false
end
