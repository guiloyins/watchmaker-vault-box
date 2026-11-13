defmodule Vault.BoxLink do
  @moduledoc "Routes immutable box effects to the currently authenticated adapter."
  alias Vault.{GameSession, SimulatedBox.Adapter}

  def external?(s), do: s.box.transport == :external

  def arm(s, arm) do
    if external?(s),
      do: emit(s, binding(s, "box_arm", arm), nil, 400),
      else: Adapter.arm(s.runtime, s.box.binding_generation, arm)
  end

  def disarm(s, arm) do
    if external?(s),
      do: emit(s, binding(s, "box_disarm", arm), nil, 400),
      else: Adapter.disarm(s.runtime, s.box.binding_generation, arm)
  end

  def release(s, captured, command) do
    if external?(s) do
      issue = s.box.challenges[captured.heartbeat_seq]
      remaining = if is_integer(issue), do: issue + 400 - GameSession.now(s), else: 0

      packet =
        binding(s, "box_command", captured.arm_id)
        |> Map.merge(%{
          "command_id" => command,
          "heartbeat_seq" => captured.heartbeat_seq,
          "action" => "set_latch",
          "target" => "released"
        })

      if captured.connection_id == s.box.connection_id and
           captured.box_boot_id == s.box.boot_id and
           captured.session_id == s.checkpoint.session_id and
           captured.binding_generation == s.box.binding_generation and remaining > 0,
         do: emit(s, packet, nil, remaining),
         else: {:error, :stale_binding}
    else
      Adapter.release(
        s.runtime,
        captured.binding_generation,
        captured.box_boot_id,
        captured.arm_id,
        captured.heartbeat_seq,
        command,
        %{session_id: captured.session_id, action: "set_latch", target: "released"}
      )
    end
  end

  def query(s, command, context) do
    if external?(s),
      do:
        emit(
          s,
          %{
            "v" => 1,
            "type" => "box_query",
            "connection_id" => s.box.connection_id,
            "command_id" => command
          },
          context,
          400
        ),
      else: Adapter.query(s.runtime, s.box.binding_generation, command, context)
  end

  def ack(s, seq) do
    if external?(s), do: :ok, else: Adapter.ack_status(s.runtime, s.box.binding_generation, seq)
  end

  def unbind(s, reason) do
    if external?(s) do
      if s.box.actor_id && s.actors[s.box.actor_id],
        do: send(s.box.runtime_pid, {:vault_disconnect, s.box.actor_id, reason})

      :ok
    else
      Adapter.unbind(s.runtime, s.box.binding_generation, reason)
    end
  end

  defp emit(s, packet, query, remaining) do
    actor = s.actors[s.box.actor_id]

    if actor != nil and s.box.connected and Process.alive?(actor.actor.owner_pid) do
      deadline = System.monotonic_time(:millisecond) + remaining

      message =
        {:vault_box, actor.actor.actor_id, actor.actor.binding_generation, packet, query,
         deadline}

      if actor.delivery,
        do: VaultWeb.DeviceSocket.deliver(actor.delivery, message),
        else:
          (
            send(actor.actor.owner_pid, message)
            :ok
          )
    else
      {:error, :not_connected}
    end
  end

  defp binding(s, type, arm),
    do: %{
      "v" => 1,
      "type" => type,
      "connection_id" => s.box.connection_id,
      "box_boot_id" => s.box.boot_id,
      "session_id" => s.checkpoint.session_id,
      "arm_id" => arm
    }
end
