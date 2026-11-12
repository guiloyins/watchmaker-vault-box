defmodule Vault.Clock do
  @moduledoc "Injectable monotonic clock and scheduler. Deadlines are local to this clock."

  @type t :: {module(), term()}
  @callback now_ms(context :: term()) :: integer()
  @callback schedule_at(context :: term(), pid(), term(), due_at_ms :: integer()) :: reference()
  @callback cancel(context :: term(), reference()) :: boolean()

  @spec system() :: t()
  def system, do: {Vault.Clock.System, nil}

  def now_ms({module, context}), do: module.now_ms(context)

  def schedule_at({module, context}, destination, message, due_at_ms) do
    module.schedule_at(context, destination, message, due_at_ms)
  end

  @doc "Cancels a pending timer. A message already in the recipient's mailbox can still arrive."
  def cancel({module, context}, reference), do: module.cancel(context, reference)
end

defmodule Vault.Clock.System do
  @moduledoc false
  @behaviour Vault.Clock

  @impl true
  def now_ms(nil), do: System.monotonic_time(:millisecond)

  @impl true
  def schedule_at(nil, destination, message, due_at_ms) do
    Process.send_after(destination, message, due_at_ms, abs: true)
  end

  @impl true
  def cancel(nil, reference), do: Process.cancel_timer(reference) != false
end
