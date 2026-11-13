defmodule Vault.GameStore.Assignment do
  @moduledoc false
  use Ecto.Schema

  @primary_key false
  schema "assignments" do
    field :game_id, :string, primary_key: true
    field :role, :string, primary_key: true
    field :device_id, :string
    field :browser_credential_id, :string
    field :updated_at_ms, :integer
  end
end
