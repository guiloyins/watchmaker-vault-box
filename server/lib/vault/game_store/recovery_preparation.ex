defmodule Vault.GameStore.RecoveryPreparation do
  @moduledoc false
  use Ecto.Schema

  @primary_key false
  schema "recovery_preparations" do
    field :recovery_id, :string, primary_key: true
    field :command_id, :string
    field :generation, :integer
    field :request_id, :string
    field :prior_recovery_id, :string
    field :prepared_session_id, :string
    field :operator_credential_id, :string
    field :created_at_ms, :integer
  end
end
