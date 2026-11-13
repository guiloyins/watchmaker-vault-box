defmodule Vault.Repo.Migrations.CreateVaultState do
  use Ecto.Migration

  def up do
    Enum.each(Vault.GameStore.SchemaVersionOne.statements(), &execute/1)
    execute("PRAGMA user_version = 1")
  end

  def down do
    raise "Vault state has no automatic downgrade"
  end
end
