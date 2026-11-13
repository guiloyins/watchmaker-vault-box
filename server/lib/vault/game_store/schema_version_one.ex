defmodule Vault.GameStore.SchemaVersionOne do
  @moduledoc false

  @maximum 9_007_199_254_740_991
  @version 20_261_112_000_000

  def version, do: @version
  def statements, do: Enum.map(objects(), &List.last/1)

  def objects do
    [
      table("vault_metadata", [
        integer("singleton", 1, 1, "PRIMARY KEY"),
        integer("schema_version", 1, 1),
        id("store_id", "UNIQUE"),
        audit("created_at_ms")
      ]),
      table("devices", [
        id("device_id", "PRIMARY KEY"),
        enum("device_class", ~w(controller box)),
        enum("transport", ~w(raw internal)),
        hash("credential_sha256", "UNIQUE", true),
        bool("enabled", "DEFAULT 1"),
        positive("auth_epoch", "DEFAULT 1"),
        integer("allowed_roles_mask", 0, 3, "DEFAULT 0"),
        json("capabilities_json", 2048),
        audit("created_at_ms"),
        audit("updated_at_ms"),
        "CHECK ((transport = 'raw' AND credential_sha256 IS NOT NULL) OR (transport = 'internal' AND device_class = 'box' AND credential_sha256 IS NULL))",
        "CHECK (device_class <> 'box' OR allowed_roles_mask = 0)"
      ]),
      table("games", [
        id("game_id", "PRIMARY KEY"),
        integer("active_slot", 1, 1, "UNIQUE", true),
        enum("box_mode", ~w(simulated physical)),
        id("box_device_id"),
        fk("box_device_id", "devices", "device_id"),
        integer("checkpoint_version", 1, 1),
        nonnegative("checkpoint_revision", "DEFAULT 0"),
        json("checkpoint_json", 8192),
        audit("created_at_ms"),
        audit("updated_at_ms")
      ]),
      table("browser_credentials", [
        id("credential_id", "PRIMARY KEY"),
        enum("kind", ~w(host player)),
        id("game_id", "", true),
        fk("game_id", "games", "game_id"),
        enum("role", ~w(a b), true),
        hash("credential_sha256", "UNIQUE"),
        bool("enabled", "DEFAULT 1"),
        positive("auth_epoch", "DEFAULT 1"),
        audit("created_at_ms"),
        audit("updated_at_ms"),
        "CHECK ((kind = 'host' AND game_id IS NULL AND role IS NULL) OR (kind = 'player' AND game_id IS NOT NULL AND role IS NOT NULL))"
      ]),
      table("assignments", [
        id("game_id"),
        fk("game_id", "games", "game_id"),
        enum("role", ~w(a b)),
        id("device_id", "", true),
        fk("device_id", "devices", "device_id"),
        id("browser_credential_id", "", true),
        fk("browser_credential_id", "browser_credentials", "credential_id"),
        audit("updated_at_ms"),
        "PRIMARY KEY (game_id, role)",
        "CHECK ((device_id IS NULL) <> (browser_credential_id IS NULL))"
      ]),
      table("actuator_commands", [
        id("command_id", "PRIMARY KEY"),
        id("game_id"),
        fk("game_id", "games", "game_id"),
        id("original_session_id"),
        positive("original_round_id"),
        positive("puzzle_revision"),
        id("intended_box_id"),
        fk("intended_box_id", "devices", "device_id"),
        enum("action", ~w(set_latch)),
        enum("target", ~w(released)),
        json("dispatch_binding_json", 1024),
        bool("dispatch_claimed", "DEFAULT 0"),
        bool("dispatch_retired", "DEFAULT 0"),
        audit("retired_at_ms", true),
        nonnegative("history_revision", "DEFAULT 0"),
        audit("created_at_ms"),
        "CHECK ((dispatch_retired = 0) = (retired_at_ms IS NULL))"
      ]),
      table("release_observations", [
        id("observation_id", "PRIMARY KEY"),
        id("command_id"),
        fk("command_id", "actuator_commands", "command_id"),
        id("source_device_id"),
        fk("source_device_id", "devices", "device_id"),
        id("box_boot_id"),
        id("connection_id"),
        id("current_session_id"),
        positive("status_seq"),
        hash("report_sha256"),
        json("report_json", 4096),
        enum("classification", ~w(admitted stale identity_conflict content_conflict)),
        id("query_id", "", true),
        audit("observed_at_ms")
      ]),
      table("recovery_preparations", [
        id("recovery_id", "PRIMARY KEY"),
        id("command_id"),
        fk("command_id", "actuator_commands", "command_id"),
        positive("generation"),
        id("request_id", "UNIQUE"),
        fk("request_id", "game_operations", "request_id", true),
        id("prior_recovery_id", "", true),
        fk("prior_recovery_id", "recovery_preparations", "recovery_id"),
        id("prepared_session_id"),
        id("operator_credential_id"),
        fk("operator_credential_id", "browser_credentials", "credential_id"),
        audit("created_at_ms")
      ]),
      table("release_dispositions", [
        id("disposition_id", "PRIMARY KEY"),
        id("command_id", "UNIQUE"),
        fk("command_id", "actuator_commands", "command_id"),
        id("recovery_id", "UNIQUE"),
        fk("recovery_id", "recovery_preparations", "recovery_id"),
        id("request_id", "UNIQUE"),
        fk("request_id", "game_operations", "request_id", true),
        id("operator_credential_id"),
        fk("operator_credential_id", "browser_credentials", "credential_id"),
        enum("disposition", ~w(closed_no_replay)),
        bounded_text("reason", 1, 512),
        json("evidence_json", 8192),
        id("observation_id"),
        fk("observation_id", "release_observations", "observation_id"),
        audit("created_at_ms")
      ]),
      table("game_operations", [
        id("request_id", "PRIMARY KEY"),
        id("game_id"),
        fk("game_id", "games", "game_id"),
        id("operator_credential_id", "", true),
        fk("operator_credential_id", "browser_credentials", "credential_id"),
        enum(
          "operation",
          ~w(create start pause resume reset arm disarm replace_controller begin_recovery replace_recovery close_recovery checkpoint win restart)
        ),
        hash("request_sha256"),
        json("result_json", 8192),
        nonnegative("checkpoint_revision"),
        audit("created_at_ms"),
        "CHECK ((operator_credential_id IS NULL) = (operation IN ('checkpoint','win','restart')))"
      ])
    ] ++ indexes() ++ triggers()
  end

  defp indexes do
    [
      index("browser_credentials_one_host", "browser_credentials", "kind", "kind = 'host'"),
      index(
        "browser_credentials_player_scope",
        "browser_credentials",
        "game_id,role",
        "kind = 'player'"
      ),
      index(
        "actuator_one_solve",
        "actuator_commands",
        "game_id,original_session_id,original_round_id,action,target",
        true
      ),
      index(
        "recovery_command_generation",
        "recovery_preparations",
        "command_id,generation",
        true
      ),
      index(
        "recovery_one_successor",
        "recovery_preparations",
        "prior_recovery_id",
        "prior_recovery_id IS NOT NULL"
      ),
      index(
        "observation_exact_report",
        "release_observations",
        "command_id,source_device_id,box_boot_id,connection_id,status_seq,report_sha256",
        true
      ),
      index(
        "idx_release_observations_history",
        "release_observations",
        "command_id,observed_at_ms,observation_id"
      ),
      index("idx_game_operations_history", "game_operations", "game_id,created_at_ms")
      | Enum.map(
          [
            {"games", "box_device_id"},
            {"browser_credentials", "game_id"},
            {"assignments", "device_id"},
            {"assignments", "browser_credential_id"},
            {"actuator_commands", "intended_box_id"},
            {"release_observations", "source_device_id"},
            {"recovery_preparations", "operator_credential_id"},
            {"release_dispositions", "operator_credential_id"},
            {"release_dispositions", "observation_id"},
            {"game_operations", "operator_credential_id"}
          ],
          fn {table, column} -> index("idx_#{table}_#{column}", table, column) end
        )
    ]
  end

  defp triggers do
    for table <-
          ~w(release_observations recovery_preparations release_dispositions game_operations),
        action <- ~w(UPDATE DELETE) do
      immutable(table, action)
    end ++
      [
        immutable("actuator_commands", "DELETE"),
        immutable("vault_metadata", "UPDATE"),
        immutable("vault_metadata", "DELETE"),
        immutable("games", "DELETE"),
        update_guard(
          "games",
          ~w(game_id box_mode box_device_id checkpoint_version created_at_ms),
          """
          NEW.checkpoint_revision NOT IN (OLD.checkpoint_revision, OLD.checkpoint_revision + 1)
          OR (NEW.checkpoint_json IS NOT OLD.checkpoint_json AND NEW.checkpoint_revision <> OLD.checkpoint_revision + 1)
          """
        ),
        update_guard(
          "actuator_commands",
          ~w(command_id game_id original_session_id original_round_id puzzle_revision intended_box_id action target dispatch_binding_json created_at_ms),
          """
          NEW.dispatch_claimed < OLD.dispatch_claimed
          OR NEW.dispatch_retired < OLD.dispatch_retired
          OR (OLD.retired_at_ms IS NOT NULL AND NEW.retired_at_ms IS NOT OLD.retired_at_ms)
          OR NEW.history_revision NOT IN (OLD.history_revision, OLD.history_revision + 1)
          """
        )
      ]
  end

  defp table(name, columns) do
    # SQLite requires column definitions before table constraints.
    {checks, fields} =
      Enum.split_with(columns, &String.starts_with?(&1, ["CHECK", "PRIMARY KEY", "FOREIGN KEY"]))

    ["table", name, "CREATE TABLE #{name} (#{Enum.join(fields ++ checks, ", ")})"]
  end

  defp index(name, table, columns, unique_or_predicate \\ false) do
    unique = if unique_or_predicate, do: "UNIQUE ", else: ""
    predicate = if is_binary(unique_or_predicate), do: " WHERE #{unique_or_predicate}", else: ""
    ["index", name, "CREATE #{unique}INDEX #{name} ON #{table}(#{columns})#{predicate}"]
  end

  defp immutable(table, action), do: trigger(table, action, "")

  defp update_guard(table, immutable, checks) do
    immutable_checks = Enum.map(immutable, &"NEW.#{&1} IS NOT OLD.#{&1}")

    trigger(
      table,
      "UPDATE",
      " WHEN " <> Enum.join(immutable_checks ++ [String.trim(checks)], " OR ")
    )
  end

  defp trigger(table, action, predicate) do
    name = "#{table}_guard_#{String.downcase(action)}"

    [
      "trigger",
      name,
      "CREATE TRIGGER #{name} BEFORE #{action} ON #{table}#{predicate} BEGIN SELECT RAISE(ABORT, 'immutable vault record'); END"
    ]
  end

  defp fk(column, parent, key, deferred \\ false) do
    defer = if deferred, do: " DEFERRABLE INITIALLY DEFERRED", else: ""

    "FOREIGN KEY (#{column}) REFERENCES #{parent}(#{key}) ON DELETE RESTRICT ON UPDATE RESTRICT#{defer}"
  end

  defp integer(column, min, max, options \\ "", nullable \\ false),
    do: field(column, "INTEGER", options, nullable, "#{column} BETWEEN #{min} AND #{max}")

  defp nonnegative(column, options \\ ""), do: integer(column, 0, @maximum, options)
  defp positive(column, options \\ ""), do: integer(column, 1, @maximum, options)
  defp bool(column, options), do: field(column, "INTEGER", options, false, "#{column} IN (0,1)")

  defp audit(column, nullable \\ false),
    do: integer(column, 0, 9_223_372_036_854_775_807, "", nullable)

  defp enum(column, options, nullable \\ false) do
    choices = Enum.map_join(options, ",", &"'#{&1}'")
    field(column, "TEXT", "", nullable, "#{column} IN (#{choices})")
  end

  defp id(column, options \\ "", nullable \\ false) do
    field(
      column,
      "TEXT",
      options,
      nullable,
      """
      length(CAST(#{column} AS BLOB)) BETWEEN 1 AND 64 AND instr(#{column},char(0)) = 0 AND #{column} NOT GLOB '*[^A-Za-z0-9_-]*'
      """
      |> String.trim()
    )
  end

  defp hash(column, options \\ "", nullable \\ false),
    do: field(column, "BLOB", options, nullable, "length(#{column}) = 32")

  defp json(column, max), do: bounded_text(column, 1, max)

  defp bounded_text(column, min, max),
    do:
      field(
        column,
        "TEXT",
        "",
        false,
        "length(CAST(#{column} AS BLOB)) BETWEEN #{min} AND #{max}"
      )

  defp field(column, type, options, nullable, check) do
    declaration =
      Enum.join(
        Enum.reject([column, type, if(nullable, do: "", else: "NOT NULL"), options], &(&1 == "")),
        " "
      )

    nullable_check = if nullable, do: "#{column} IS NULL OR ", else: ""

    "#{declaration} CHECK (#{nullable_check}(typeof(#{column}) = '#{String.downcase(type)}' AND #{check}))"
  end
end
