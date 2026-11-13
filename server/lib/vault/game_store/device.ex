defmodule Vault.GameStore.Device do
  @moduledoc false
  use Ecto.Schema

  @primary_key false
  schema "devices" do
    field :device_id, :string, primary_key: true
    field :device_class, :string
    field :transport, :string
    field :credential_sha256, :binary, redact: true
    field :enabled, :boolean, default: true
    field :auth_epoch, :integer, default: 1
    field :allowed_roles_mask, :integer, default: 0
    field :capabilities_json, :string
    field :created_at_ms, :integer
    field :updated_at_ms, :integer
  end
end
