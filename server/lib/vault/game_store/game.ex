defmodule Vault.GameStore.Game do
  @moduledoc false
  use Ecto.Schema

  @primary_key false
  schema "games" do
    field :game_id, :string, primary_key: true
    field :active_slot, :integer
    field :box_mode, :string
    field :box_device_id, :string
    field :checkpoint_version, :integer
    field :checkpoint_revision, :integer, default: 0
    field :checkpoint_json, :string
    field :created_at_ms, :integer
    field :updated_at_ms, :integer
  end
end
