defmodule Vault.GameStore.Operation do
  @moduledoc false
  use Ecto.Schema

  @primary_key false
  schema "game_operations" do
    field :request_id, :string, primary_key: true
    field :game_id, :string
    field :operator_credential_id, :string
    field :operation, :string
    field :request_sha256, :binary
    field :result_json, :string
    field :checkpoint_revision, :integer
    field :created_at_ms, :integer
  end
end
