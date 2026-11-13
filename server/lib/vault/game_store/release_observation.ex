defmodule Vault.GameStore.ReleaseObservation do
  @moduledoc false
  use Ecto.Schema

  @primary_key false
  schema "release_observations" do
    field :observation_id, :string, primary_key: true
    field :command_id, :string
    field :source_device_id, :string
    field :box_boot_id, :string
    field :connection_id, :string
    field :current_session_id, :string
    field :status_seq, :integer
    field :report_sha256, :binary
    field :report_json, :string
    field :classification, :string
    field :query_id, :string
    field :observed_at_ms, :integer
  end
end
