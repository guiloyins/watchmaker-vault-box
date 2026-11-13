defmodule Vault.Test.Actors do
  @moduledoc "Protocol-shaped controller clients for GameSession integration tests."

  import ExUnit.Assertions
  alias Vault.{Controllers, Games}
  alias Vault.Controllers.Input

  @enforce_keys [:actor, :context, :game]
  defstruct @enforce_keys ++ [command_seq: 0, input_seq: 0, heartbeat_seq: nil]

  def bind(principal, game, panel, source \\ :browser, boot_id \\ Controllers.id("boot")) do
    assert {:ok, {actor, context}} =
             Games.bind(principal, game, %{
               source: source,
               panel: panel,
               boot_id: boot_id,
               owner_pid: self()
             })

    %__MODULE__{actor: actor, context: context, game: game}
  end

  def claim(client, role) do
    {client, result} = command(client, {:claim_role, role})
    assert %{status: :applied, code: :role_claimed} = result
    sync_context(client, :role_changed)
  end

  def command(client, action) do
    seq = client.command_seq + 1
    assert {:ok, result} = Games.command(client.actor, client.game, seq, client.context, action)
    {%{client | command_seq: seq}, result}
  end

  def sync_context(client, reason) do
    actor_id = client.actor.actor_id
    assert_receive {:vault_context, %{actor_id: ^actor_id} = actor, context, ^reason}, 1_000
    %{client | actor: actor, context: context}
  end

  def challenge(client) do
    %{actor_id: id, connection_id: connection, binding_generation: generation} = client.actor
    assert_receive {:vault_challenge, ^id, ^connection, ^generation, seq}, 1_000
    %{client | heartbeat_seq: seq}
  end

  def sample(client, press_id) do
    seq = client.input_seq + 1
    claimed? = not is_nil(client.context.role)

    input = %Input{
      heartbeat_seq: client.heartbeat_seq,
      input_seq: seq,
      context: if(claimed?, do: client.context),
      pressed: claimed? and not is_nil(press_id),
      press_id: if(claimed?, do: press_id)
    }

    assert {:ok, result} = Games.sample(client.actor, client.game, input)
    {%{client | input_seq: seq}, result}
  end

  def sample_ok(client, press_id \\ nil) do
    {client, result} = sample(client, press_id)
    assert result.input_accepted
    client
  end
end
