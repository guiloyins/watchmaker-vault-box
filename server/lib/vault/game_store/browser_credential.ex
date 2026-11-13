defmodule Vault.GameStore.BrowserCredential do
  @moduledoc false
  use Ecto.Schema

  @primary_key false
  schema "browser_credentials" do
    field :credential_id, :string, primary_key: true
    field :kind, :string
    field :game_id, :string
    field :role, :string
    field :credential_sha256, :binary, redact: true
    field :enabled, :boolean, default: true
    field :auth_epoch, :integer, default: 1
    field :created_at_ms, :integer
    field :updated_at_ms, :integer
  end
end
