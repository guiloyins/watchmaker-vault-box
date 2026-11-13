defmodule VaultWeb.BrowserController do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3, put_private: 3]

  alias Vault.Controllers.{Actor, Context, Input}
  alias Vault.Games

  @max_integer 9_007_199_254_740_991
  @directions %{"up" => :up, "down" => :down, "left" => :left, "right" => :right}
  @runes %{"star" => :star, "moon" => :moon, "sun" => :sun, "wave" => :wave}
  @roles %{"a" => :a, "b" => :b}
  @invalidations ~w(paused resumed role_changed session_changed disconnected expired logout)a
  @claim_fields ~w(v type connection_id command_seq session_id action payload)
  @action_context_fields ~w(round_id puzzle_revision role control_epoch)
  @input_fields ~w(session_id round_id puzzle_revision role control_epoch pressed press_id)

  def bind(socket, panels) do
    socket = socket |> put_bindings(%{}) |> present_actors()
    Enum.reduce(panels, socket, &bind_panel(&2, &1))
  end

  def reset(socket, panels) do
    boots =
      Map.new(bindings(socket), fn {_id, binding} ->
        {binding.panel, binding.actor.boot_id}
      end)

    Enum.each(bindings(socket), fn {_id, binding} ->
      Games.disconnect(binding.actor, socket.assigns.game_id, :replaced)
    end)

    socket = socket |> put_bindings(%{}) |> present_actors()

    Enum.reduce(
      panels,
      socket,
      &bind_panel(&2, &1, Map.get_lazy(boots, &1, fn -> identifier() end))
    )
  end

  def actor_for(bindings, panel) do
    bindings[panel]
  end

  def handle_event("vault:input", payload, socket) do
    with {:ok, binding, socket} <- admit(socket, payload),
         {:ok, input} <- decode_input(payload, binding),
         {:ok, result} <- Games.sample(binding.actor, socket.assigns.game_id, input) do
      {:noreply,
       event(socket, "vault:input_result", %{
         actor_id: binding.actor.actor_id,
         binding_generation: binding.actor.binding_generation,
         heartbeat_seq: result.heartbeat_seq,
         input_seq: result.input_seq,
         input_accepted: result.input_accepted,
         code: result.code
       })}
    else
      {:reject, socket} -> {:noreply, socket}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("vault:command", payload, socket) do
    case admit(socket, payload) do
      {:ok, binding, socket} -> {:noreply, handle_command(socket, binding, payload)}
      {:reject, socket} -> {:noreply, socket}
    end
  end

  def handle_info({:vault_challenge, id, connection, generation, seq}, socket) do
    case bindings(socket)[id] do
      %{actor: %{connection_id: ^connection, binding_generation: ^generation}} ->
        event(socket, "vault:challenge", %{
          actor_id: id,
          connection_id: connection,
          binding_generation: generation,
          heartbeat_seq: seq
        })

      _ ->
        socket
    end
  end

  def handle_info({:vault_context, %Actor{} = actor, %Context{} = context, reason}, socket) do
    case bindings(socket)[actor.actor_id] do
      %{actor: previous} = binding
      when previous.binding_generation <= actor.binding_generation ->
        same_connection? = previous.connection_id == actor.connection_id

        socket =
          if reason in @invalidations, do: invalidate(socket, previous, reason), else: socket

        binding = %{binding | actor: actor, context: context}
        binding = if same_connection?, do: binding, else: %{binding | commands: %{}, greatest: 0}

        socket
        |> put_binding(binding)
        |> present_actors()
        |> rebind(binding)

      _ ->
        socket
    end
  end

  def handle_info({:vault_disconnect, id, reason}, socket) do
    case bindings(socket)[id] do
      %{actor: actor} when reason == :session_changed ->
        invalidate(socket, actor, reason)

      %{actor: actor, panel: panel} ->
        reason = if reason in @invalidations, do: reason, else: :disconnected

        socket =
          socket
          |> invalidate(actor, reason)
          |> put_bindings(Map.delete(bindings(socket), id))
          |> present_actors()

        if reason == :disconnected && VaultWeb.Auth.valid?(actor.principal),
          do: bind_panel(socket, panel, actor.boot_id),
          else: socket

      _ ->
        socket
    end
  end

  defp bind_panel(socket, panel, boot_id \\ identifier()) do
    %{principal: principal, game_id: game_id} = socket.assigns

    case Games.bind(principal, game_id, %{
           owner_pid: self(),
           source: :browser,
           boot_id: boot_id,
           panel: panel
         }) do
      {:ok, {%Actor{} = actor, %Context{} = context}} ->
        binding = %{
          actor: actor,
          context: context,
          panel: panel,
          last_ms: now_ms(),
          tokens: 10_000,
          commands: %{},
          greatest: 0
        }

        socket |> put_binding(binding) |> present_actors() |> rebind(binding)

      {:error, _} ->
        socket
    end
  end

  defp admit(socket, %{"actor_id" => id, "binding_generation" => generation} = payload) do
    with %{actor: %{binding_generation: ^generation}} = binding <- bindings(socket)[id],
         true <- id?(id),
         true <- positive?(generation),
         {:ok, bytes} <- Jason.encode(payload),
         true <- byte_size(bytes) <= 2_048,
         {:ok, _} <- Vault.JSON.decode_object(bytes, %{max_bytes: 2_048, max_depth: 8}) do
      now = now_ms()
      tokens = min(10_000, binding.tokens + (now - binding.last_ms) * 30)
      binding = %{binding | last_ms: now, tokens: max(0, tokens - 1_000)}
      socket = put_binding(socket, binding)
      if tokens >= 1_000, do: {:ok, binding, socket}, else: {:reject, socket}
    else
      _ -> {:reject, socket}
    end
  end

  defp admit(socket, _), do: {:reject, socket}

  defp decode_input(
         %{
           "connection_id" => connection,
           "heartbeat_seq" => heartbeat,
           "input_seq" => seq,
           "input" => nested
         } = payload,
         %{actor: %{connection_id: connection}}
       )
       when map_size(payload) == 6 do
    with true <- positive?(heartbeat) and positive?(seq),
         {:ok, context, pressed, press_id} <- input_context(connection, nested) do
      {:ok,
       %Input{
         heartbeat_seq: heartbeat,
         input_seq: seq,
         context: context,
         pressed: pressed,
         press_id: press_id
       }}
    end
  end

  defp decode_input(_, _), do: :error
  defp input_context(_, nil), do: {:ok, nil, false, nil}

  defp input_context(connection, %{"pressed" => pressed, "press_id" => press_id} = nested) do
    with true <- exact?(nested, @input_fields),
         true <-
           (pressed === false and is_nil(press_id)) or (pressed === true and positive?(press_id)),
         {:ok, context} <- full_context(connection, nested) do
      {:ok, context, pressed, press_id}
    end
  end

  defp input_context(_, _), do: :error

  defp handle_command(socket, binding, %{"command" => command} = envelope)
       when map_size(envelope) == 3 do
    with {:ok, seq, context, action} <- decode_command(command, binding.actor.connection_id),
         {:ok, bytes} <- command_comparison(command),
         :ok <- compare_retry(binding, seq, bytes),
         {:ok, result} <-
           Games.command(binding.actor, socket.assigns.game_id, seq, context, action) do
      binding = remember(binding, seq, bytes)

      result =
        result
        |> Map.from_struct()
        |> Map.merge(%{v: 1, type: "command_result", connection_id: binding.actor.connection_id})

      socket =
        if result.code == :snapshot_sent do
          VaultWeb.GameLive.refresh_snapshot(socket)
        else
          socket
        end

      socket
      |> put_binding(binding)
      |> event("vault:command_result", %{
        actor_id: binding.actor.actor_id,
        binding_generation: binding.actor.binding_generation,
        result: result
      })
    else
      :changed_retry ->
        :ok = Games.disconnect(binding.actor, socket.assigns.game_id, :replaced)
        socket

      _ ->
        socket
    end
  end

  defp handle_command(socket, _, _), do: socket

  defp compare_retry(binding, seq, bytes) do
    case Map.fetch(binding.commands, seq) do
      {:ok, other} when other != bytes -> :changed_retry
      _ -> :ok
    end
  end

  defp decode_command(
         %{
           "v" => 1,
           "type" => "command",
           "connection_id" => connection,
           "command_seq" => seq,
           "session_id" => session,
           "action" => action,
           "payload" => payload
         } = command,
         connection
       ) do
    with true <- id?(session) and positive?(seq),
         {:ok, context, action} <- command_action(action, payload, command, connection, session) do
      {:ok, seq, context, action}
    end
  end

  defp decode_command(_, _), do: :error

  defp command_action("claim_role", %{"role" => role} = payload, command, connection, session)
       when map_size(payload) == 1 do
    with true <- wire_fields?(command, @claim_fields),
         {:ok, role} <- Map.fetch(@roles, role) do
      {:ok, limited_context(connection, session, nil, nil), {:claim_role, role}}
    end
  end

  defp command_action("request_snapshot", payload, command, connection, session)
       when payload == %{} do
    if wire_fields?(command, @claim_fields) do
      {:ok, limited_context(connection, session, nil, nil), :request_snapshot}
    end
  end

  defp command_action("release_role", payload, command, connection, session)
       when payload == %{} do
    with true <- wire_fields?(command, @claim_fields ++ ~w(role control_epoch)),
         {:ok, role} <- Map.fetch(@roles, command["role"]),
         true <- nonnegative?(command["control_epoch"]) do
      {:ok, limited_context(connection, session, role, command["control_epoch"]), :release_role}
    end
  end

  defp command_action(
         "move",
         %{"direction" => direction, "expected_board_version" => version} = payload,
         command,
         connection,
         _session
       )
       when map_size(payload) == 2 do
    with true <- wire_fields?(command, @claim_fields ++ @action_context_fields),
         {:ok, direction} <- Map.fetch(@directions, direction),
         true <- nonnegative?(version),
         {:ok, context} <- full_context(connection, command) do
      {:ok, context, {:move, direction, version}}
    end
  end

  defp command_action("select_rune", %{"rune" => rune} = payload, command, connection, _session)
       when map_size(payload) == 1 do
    with true <- wire_fields?(command, @claim_fields ++ @action_context_fields),
         {:ok, rune} <- Map.fetch(@runes, rune),
         {:ok, context} <- full_context(connection, command) do
      {:ok, context, {:select_rune, rune}}
    end
  end

  defp command_action(_, _, _, _, _), do: :error

  defp limited_context(connection, session, role, epoch) do
    %Context{
      connection_id: connection,
      session_id: session,
      round_id: nil,
      puzzle_revision: nil,
      role: role,
      control_epoch: epoch
    }
  end

  defp command_comparison(command) do
    with {:ok, bytes} <- Jason.encode(command),
         {:ok, parsed} <- Vault.JSON.decode_object(bytes, %{max_bytes: 2_048, max_depth: 7}) do
      Vault.JSON.comparison(parsed, 2_048)
    end
  end

  defp full_context(connection, %{
         "session_id" => session,
         "round_id" => round,
         "puzzle_revision" => puzzle,
         "role" => role,
         "control_epoch" => epoch
       }) do
    with true <- id?(session) and positive?(round) and positive?(puzzle) and nonnegative?(epoch),
         {:ok, role} <- Map.fetch(@roles, role) do
      {:ok,
       %Context{
         connection_id: connection,
         session_id: session,
         round_id: round,
         puzzle_revision: puzzle,
         role: role,
         control_epoch: epoch
       }}
    end
  end

  defp full_context(_, _), do: :error

  defp remember(binding, seq, bytes) when seq == binding.greatest + 1 do
    commands = binding.commands |> Map.put(seq, bytes) |> Map.delete(seq - 128)
    %{binding | commands: commands, greatest: seq}
  end

  defp remember(binding, _, _), do: binding

  defp rebind(socket, %{actor: actor, context: context, panel: panel}) do
    event(socket, "vault:rebind", %{
      actor_id: actor.actor_id,
      boot_id: actor.boot_id,
      connection_id: actor.connection_id,
      binding_generation: actor.binding_generation,
      session_id: context.session_id,
      round_id: context.round_id,
      puzzle_revision: context.puzzle_revision,
      role: context.role,
      control_epoch: context.control_epoch,
      required_roles: socket.assigns.projection.required_roles,
      allowed_roles:
        if(actor.principal.kind == :host, do: [panel], else: actor.principal.allowed_roles)
    })
  end

  defp invalidate(socket, actor, reason) do
    event(socket, "vault:invalidate", %{
      actor_id: actor.actor_id,
      connection_id: actor.connection_id,
      binding_generation: actor.binding_generation,
      reason: reason
    })
  end

  defp event(socket, event, payload) do
    if byte_size(Jason.encode!(payload)) <= 8_192,
      do: push_event(socket, event, payload),
      else: socket
  end

  defp put_binding(socket, binding) do
    put_bindings(socket, Map.put(bindings(socket), binding.actor.actor_id, binding))
  end

  defp put_bindings(socket, bindings), do: put_private(socket, :vault_bindings, bindings)
  defp bindings(socket), do: socket.private[:vault_bindings] || %{}

  defp present_actors(socket) do
    actors =
      Map.new(bindings(socket), fn {_id, binding} ->
        actor = Map.take(binding.actor, [:actor_id, :role])
        {binding.panel, actor}
      end)

    assign(socket, :bindings, actors)
  end

  defp wire_fields?(map, fields) do
    Enum.all?(fields, &Map.has_key?(map, &1)) and
      Enum.all?(
        ~w(round_id puzzle_revision role control_epoch) -- fields,
        &(!Map.has_key?(map, &1))
      )
  end

  defp exact?(map, fields), do: map_size(map) == length(fields) and wire_fields?(map, fields)
  defp id?(value), do: is_binary(value) and Regex.match?(~r/\A[A-Za-z0-9_-]{1,64}\z/, value)
  defp nonnegative?(value), do: is_integer(value) and value >= 0 and value <= @max_integer
  defp positive?(value), do: nonnegative?(value) and value > 0
  defp now_ms, do: System.monotonic_time(:millisecond)
  def identifier, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
end
