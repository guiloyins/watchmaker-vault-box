defmodule Vault.GameStore.ActuatorCommand do
  @moduledoc false
  use Ecto.Schema

  @primary_key false
  schema "actuator_commands" do
    field :command_id, :string, primary_key: true
    field :game_id, :string
    field :original_session_id, :string
    field :original_round_id, :integer
    field :puzzle_revision, :integer
    field :intended_box_id, :string
    field :action, :string
    field :target, :string
    field :dispatch_binding_json, :string
    field :dispatch_claimed, :boolean, default: false
    field :dispatch_retired, :boolean, default: false
    field :retired_at_ms, :integer
    field :history_revision, :integer, default: 0
    field :created_at_ms, :integer
  end
end
