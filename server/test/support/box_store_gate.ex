defmodule Vault.Test.BoxStoreGate do
  @moduledoc false

  alias Vault.SimulatedBox.Store

  def open_existing(path, instance, device) do
    with {:ok, handle} <- Store.open_existing(path, instance, device) do
      {:ok, {handle, path}}
    end
  end

  def close({handle, _path}), do: Store.close(handle)
  def load({handle, _path}), do: Store.load(handle)
  def readback({handle, _path}, expectation), do: Store.readback(handle, expectation)

  def commit({handle, path}, %{patch: %{"receipt" => %{"command" => command}}} = persist) do
    case :global.whereis_name({__MODULE__, Path.dirname(path), command}) do
      controller when is_pid(controller) -> gate_service_commit(handle, persist, controller)
      :undefined -> Store.commit(handle, persist)
    end
  end

  def commit({handle, path}, %{purpose: :accept} = persist) do
    controller = Path.dirname(path) |> gate_name() |> :global.whereis_name()

    if is_pid(controller) do
      send(controller, {:box_write_gate, self(), :before_commit})

      case wait(controller) do
        :commit ->
          result = Store.commit(handle, persist)
          send(controller, {:box_write_gate, self(), :after_commit, result})
          :deliver = wait(controller)
          result

        :lose_before_commit ->
          {:error, :unknown}
      end
    else
      Store.commit(handle, persist)
    end
  end

  def commit({handle, _path}, persist), do: Store.commit(handle, persist)

  def register_service(path, command),
    do: :global.register_name({__MODULE__, Path.dirname(path), command}, self())

  defp gate_service_commit(handle, persist, controller) do
    send(
      controller,
      {:service_write_gate, self(), :before_commit, persist.operation_id,
       persist.patch["receipt"]["operation_id"]}
    )

    case wait(controller) do
      :rollback ->
        {:error, :rolled_back}

      :lose_before_commit ->
        {:error, :unknown}

      :commit ->
        result = Store.commit(handle, persist)
        send(controller, {:service_write_gate, self(), :after_commit, result})

        case wait(controller) do
          :lose_reply -> {:error, :unknown}
          :deliver -> result
        end
    end
  end

  def register(path), do: path |> Path.dirname() |> gate_name() |> :global.register_name(self())

  defp wait(controller) do
    monitor = Process.monitor(controller)

    try do
      receive do
        {:box_write_gate, ^controller, decision} -> decision
        {:DOWN, ^monitor, :process, ^controller, _reason} -> exit(:test_gate_owner_down)
      end
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  defp gate_name(directory), do: {__MODULE__, directory}
end
