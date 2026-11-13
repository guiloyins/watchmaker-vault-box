defmodule Vault.GameStore.ReleaseDisposition do
  @moduledoc false
  use Ecto.Schema

  @primary_key false
  schema "release_dispositions" do
    field :disposition_id, :string, primary_key: true
    field :command_id, :string
    field :recovery_id, :string
    field :request_id, :string
    field :operator_credential_id, :string
    field :disposition, :string
    field :reason, :string
    field :evidence_json, :string
    field :observation_id, :string
    field :created_at_ms, :integer
  end
end
