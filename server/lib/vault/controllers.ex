defmodule Vault.Controllers do
  @moduledoc "Server-created identities; all live grants are owned by GameSession."

  defmodule Principal do
    @enforce_keys [
      :kind,
      :subject_id,
      :auth_epoch,
      :game_id,
      :allowed_roles,
      :expires_at_ms,
      :browser_session_id
    ]
    defstruct @enforce_keys
  end

  defmodule Actor do
    @enforce_keys [
      :actor_id,
      :principal,
      :source,
      :owner_pid,
      :boot_id,
      :connection_id,
      :binding_generation,
      :session_id,
      :role,
      :control_epoch
    ]
    defstruct @enforce_keys
  end

  defmodule Context do
    @enforce_keys [
      :connection_id,
      :session_id,
      :round_id,
      :puzzle_revision,
      :role,
      :control_epoch
    ]
    defstruct @enforce_keys
  end

  defmodule Input do
    @enforce_keys [:heartbeat_seq, :input_seq, :context, :pressed, :press_id]
    defstruct @enforce_keys
  end

  @max 9_007_199_254_740_991
  def id(prefix \\ "id"),
    do: prefix <> "_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

  def id?(value),
    do:
      is_binary(value) and byte_size(value) in 1..64 and
        Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, value)

  def number?(n, minimum \\ 0), do: is_integer(n) and n >= minimum and n <= @max

  def valid?(%Principal{} = principal), do: Vault.Auth.valid?(principal)
  def valid?(_), do: false

  def scope?(%Principal{kind: :host} = principal, _game, audience),
    do: valid?(principal) and audience in [:host, :public, {:player, :a}, {:player, :b}]

  def scope?(
        %Principal{kind: :player, game_id: game, allowed_roles: roles} = principal,
        game,
        {:player, role}
      ),
      do: valid?(principal) and role in roles

  def scope?(%Principal{game_id: game} = principal, game, :public), do: valid?(principal)

  def scope?(%Principal{kind: :device, game_id: game} = principal, game, {:player, role}),
    do:
      valid?(principal) and role in principal.allowed_roles and
        Vault.Auth.device_class(principal) == :controller

  def scope?(%Principal{kind: :device, game_id: game} = principal, game, :box),
    do: valid?(principal) and Vault.Auth.device_class(principal) == :box

  def scope?(%Principal{kind: :internal_box} = principal, _game, :box), do: valid?(principal)
  def scope?(_, _, _), do: false

  def context(actor, checkpoint) do
    %Context{
      connection_id: actor.connection_id,
      session_id: checkpoint.session_id,
      round_id: checkpoint.round_id,
      puzzle_revision: checkpoint.puzzle_revision,
      role: actor.role,
      control_epoch: actor.control_epoch
    }
  end

  def same_context?(%Context{} = a, %Context{} = b), do: a == b
  def same_context?(_, _), do: false
end
