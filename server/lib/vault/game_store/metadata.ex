defmodule Vault.GameStore.Metadata do
  @moduledoc false
  use Ecto.Schema

  @primary_key false
  schema "vault_metadata" do
    field :singleton, :integer, primary_key: true
    field :schema_version, :integer
    field :store_id, :string
    field :created_at_ms, :integer
  end
end
