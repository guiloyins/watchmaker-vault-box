defmodule Vault.Credentials do
  @moduledoc "Protected credential provisioning and stopped-maintenance replacement."

  import Ecto.Query

  alias Vault.{GameStore, MaintenanceGuard, PhysicalBoxStop, Repo, SimulatedBox}
  alias Vault.GameStore.{BrowserCredential, Codec, Device, Metadata}
  alias Vault.SimulatedBox.{Adapter, Store}

  @test_marker ".vault-test-prepared"
  @files %{
    host: "host.key",
    player_a: "player-a.key",
    player_b: "player-b.key",
    secret_key_base: "secret-key-base.key",
    box: "box.key",
    cyd_a: "cyd-a.key",
    cyd_b: "cyd-b.key"
  }
  @simulator_device_id "simulated_box"

  def id(prefix \\ ""), do: prefix <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  def key, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  def digest(token), do: :crypto.hash(:sha256, token)
  def audit_ms, do: System.system_time(:millisecond)

  def key?(token) when is_binary(token) and byte_size(token) == 43 do
    case Base.url_decode64(token, padding: false) do
      {:ok, bytes} when byte_size(bytes) == 32 ->
        Base.url_encode64(bytes, padding: false) == token

      _ ->
        false
    end
  end

  def key?(_), do: false

  def device_key?(token) when is_binary(token) and byte_size(token) == 64,
    do: Regex.match?(~r/\A[0-9a-f]{64}\z/, token)

  def device_key?(_), do: false

  defp device_key, do: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

  def read_key(path) do
    with {:ok, <<token::binary-size(43), "\n">>} <- MaintenanceGuard.read_protected(path, 44),
         true <- key?(token) do
      {:ok, token}
    else
      _ -> {:error, :invalid_key_file}
    end
  end

  def secret_key_base(paths) do
    path = Application.get_env(:vault, :secret_key_base_file) || file(paths, :secret_key_base)

    with {:ok, <<secret::binary-size(86), "\n">>} <- MaintenanceGuard.read_protected(path, 87),
         {:ok, bytes} <- Base.url_decode64(secret, padding: false),
         true <- byte_size(bytes) == 64 do
      {:ok, secret}
    else
      _ -> {:error, :invalid_secret_key_base}
    end
  end

  def secret_key_base do
    with {:ok, paths} <- MaintenanceGuard.paths(), do: secret_key_base(paths)
  end

  def init(opts \\ []) do
    with {:ok, paths} <- MaintenanceGuard.paths(create: opts[:test] != true and not test_mode?()),
         :ok <- prepare_test_root(paths, opts[:test] == true or test_mode?()) do
      with_guard(paths, fn ->
        case File.lstat(MaintenanceGuard.manifest_path(paths.root)) do
          {:ok, _} ->
            verify_existing_transport(paths, opts)

          {:error, :enoent} ->
            with {:ok, deployment} <- new_deployment(paths, opts),
                 do: initialize(deployment, opts)

          _ ->
            {:error, :invalid_deployment}
        end
      end)
    end
  end

  def prepare_test(opts \\ []) do
    with {:ok, paths} <- init(Keyword.put(opts, :test, true)),
         :ok <- write_test_marker(paths) do
      {:ok, paths}
    end
  end

  def test_admission(paths) do
    if test_mode?() do
      with :ok <- prepare_test_root(paths, true),
           {:ok, raw} <-
             MaintenanceGuard.read_protected(Path.join(paths.root, @test_marker), 2048),
           {:ok, document} <- Codec.decode(raw, 2048),
           true <- document == test_marker(paths) do
        :ok
      else
        _ -> {:error, :test_preparation_required}
      end
    else
      :ok
    end
  end

  defp test_mode? do
    Application.get_env(:vault, :test_mode, false) or
      Application.get_env(:vault, :environment) == :test or System.get_env("MIX_ENV") == "test"
  end

  defp prepare_test_root(_paths, test) when test in [nil, false], do: :ok

  defp prepare_test_root(paths, true) do
    with {:ok, root} <- MaintenanceGuard.owned_directory(Application.get_env(:vault, :test_root)),
         true <-
           root == paths.root and
             Application.get_env(:vault, :box_mode) in [:simulated, :physical],
         true <-
           Path.dirname(paths.database) == root and Path.dirname(paths.simulator_database) == root,
         true <-
           is_nil(Application.get_env(:vault, :host_key_file)) or
             Path.expand(Application.get_env(:vault, :host_key_file)) == file(paths, :host),
         true <-
           is_nil(Application.get_env(:vault, :secret_key_base_file)) or
             Path.expand(Application.get_env(:vault, :secret_key_base_file)) ==
               file(paths, :secret_key_base) do
      :ok
    else
      _ -> {:error, :invalid_test_root}
    end
  end

  defp test_marker(%{box_mode: :physical} = paths),
    do: %{
      "schema_version" => 2,
      "root" => paths.root,
      "store_id" => paths.store_id,
      "box_device_id" => paths.box_device_id
    }

  defp test_marker(paths),
    do: %{
      "schema_version" => 1,
      "root" => paths.root,
      "store_id" => paths.store_id,
      "simulator_instance_id" => paths.simulator_instance_id
    }

  defp write_test_marker(paths) do
    marker = Path.join(paths.root, @test_marker)

    with {:ok, bytes} <- Codec.encode(test_marker(paths), 2048) do
      case MaintenanceGuard.write_protected(marker, bytes) do
        :ok ->
          :ok

        {:error, :output_exists} ->
          with {:ok, ^bytes} <- MaintenanceGuard.read_protected(marker, 2048) do
            :ok
          else
            _ -> {:error, :invalid_test_marker}
          end

        error ->
          error
      end
    end
  end

  defp setup_mode do
    case Application.get_env(:vault, :box_mode) do
      :simulated -> :ok
      _ -> {:error, :simulated_mode_required}
    end
  end

  defp new_deployment(paths, opts) do
    mode = Application.get_env(:vault, :box_mode)
    external = opts[:external_simulator] == true
    device_id = Application.get_env(:vault, :box_device_id)
    paths = Map.merge(paths, %{store_id: id("store_"), box_mode: mode})

    case mode do
      :simulated ->
        {:ok,
         Map.merge(paths, %{
           simulator_device_id: @simulator_device_id,
           box_device_id: @simulator_device_id,
           simulator_instance_id: id("sim_"),
           simulator_transport: if(external, do: :external, else: :internal)
         })}

      :physical ->
        if Codec.id?(device_id) and
             device_id not in [@simulator_device_id, "sim_cyd_a", "sim_cyd_b"] and
             not external and
             Application.get_env(:vault, :simulator_transport, :internal) == :internal do
          {:ok, Map.put(paths, :box_device_id, device_id)}
        else
          {:error, :invalid_physical_box_configuration}
        end

      _ ->
        {:error, :invalid_box_mode}
    end
  end

  defp initialize(paths, opts) do
    host_output =
      opts[:output] || Application.get_env(:vault, :host_key_file) || file(paths, :host)

    secret_output =
      Application.get_env(:vault, :secret_key_base_file) || file(paths, :secret_key_base)

    targets = %{
      host: Path.expand(host_output),
      player_a: file(paths, :player_a),
      player_b: file(paths, :player_b),
      secret_key_base: Path.expand(secret_output)
    }

    device_keys =
      case paths do
        %{box_mode: :physical} -> [:box]
        %{simulator_transport: :external} -> [:box, :cyd_a, :cyd_b]
        _ -> []
      end

    targets = Enum.reduce(device_keys, targets, &Map.put(&2, &1, file(paths, &1)))

    with :ok <- ensure_fresh(paths, targets),
         tokens = %{
           host: key(),
           player_a: key(),
           player_b: key(),
           secret_key_base: Base.url_encode64(:crypto.strong_rand_bytes(64), padding: false)
         },
         tokens = Enum.reduce(device_keys, tokens, &Map.put(&2, &1, device_key())),
         :ok <- write_setup_keys(targets, tokens),
         :ok <- MaintenanceGuard.write_protected(paths.database, ""),
         :ok <- with_repo(paths.database, fn -> initialize_server(paths, tokens) end),
         :ok <- initialize_simulator(paths),
         :ok <- MaintenanceGuard.sync_directory(paths.root),
         :ok <- MaintenanceGuard.write_manifest(paths) do
      {:ok, Map.put(paths, :credential_paths, targets)}
    end
  end

  defp initialize_simulator(%{box_mode: :physical}), do: :ok

  defp initialize_simulator(paths) do
    with :ok <-
           Store.init_new(
             paths.simulator_database,
             paths.simulator_instance_id,
             paths.simulator_device_id
           ),
         do: MaintenanceGuard.protected_file(paths.simulator_database)
  end

  defp ensure_fresh(paths, targets) do
    names = [paths.database, paths.simulator_database | Map.values(targets)]

    if length(Enum.uniq(names)) == length(names) and
         Enum.all?(names, &(File.lstat(&1) == {:error, :enoent})) do
      :ok
    else
      {:error, :partial_or_existing_setup}
    end
  end

  defp write_setup_keys(targets, tokens) do
    Enum.reduce_while(Enum.sort(Map.keys(targets)), :ok, fn field, :ok ->
      case MaintenanceGuard.write_protected(
             Map.fetch!(targets, field),
             Map.fetch!(tokens, field) <> "\n"
           ) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp initialize_server(paths, tokens) do
    migrator =
      Ecto.Migrator.run(Repo, :up,
        all: true,
        log: false,
        log_migrations_sql: false,
        migration_lock: false
      )

    now = audit_ms()
    host_id = id("credential_")
    game_id = id("game_")

    with [_] <- migrator,
         {:ok, :ok} <-
           GameStore.transaction(fn ->
             GameStore.insert!(Metadata, %{
               singleton: 1,
               schema_version: 1,
               store_id: paths.store_id,
               created_at_ms: now
             })

             insert_browser(host_id, "host", nil, nil, tokens.host, now)

             insert_device(paths.box_device_id, "box", box_transport(paths), tokens[:box], 0, now)

             if paths.box_mode == :simulated do
               insert_device(
                 "sim_cyd_a",
                 "controller",
                 "raw",
                 Map.get_lazy(tokens, :cyd_a, &device_key/0),
                 1,
                 now
               )

               insert_device(
                 "sim_cyd_b",
                 "controller",
                 "raw",
                 Map.get_lazy(tokens, :cyd_b, &device_key/0),
                 2,
                 now
               )
             end

             case GameStore.create(
                    game_id,
                    paths.box_mode,
                    paths.box_device_id,
                    host_id,
                    id("request_"),
                    Map.take(paths, [:box_mode, :box_device_id])
                  ) do
               {:ok, _} -> :ok
               {:error, code} -> GameStore.rollback(code)
             end

             insert_browser(id("credential_"), "player", game_id, "a", tokens.player_a, now)
             insert_browser(id("credential_"), "player", game_id, "b", tokens.player_b, now)
             :ok
           end),
         :ok <- verify_server(paths) do
      :ok
    else
      _ -> {:error, :setup_failed}
    end
  end

  def verify_server(paths) do
    with :ok <- GameStore.verify_open(paths.store_id),
         {:ok, %{game: game}} <- GameStore.active(),
         true <-
           game.box_mode == to_string(paths.box_mode) and
             game.box_device_id == paths.box_device_id,
         %Device{device_class: "box", transport: transport, allowed_roles_mask: 0} <-
           Repo.get(Device, game.box_device_id),
         true <- transport == box_transport(paths) do
      :ok
    else
      _ -> {:error, :invalid_deployment}
    end
  end

  defp box_transport(%{simulator_transport: :internal}), do: "internal"
  defp box_transport(_), do: "raw"

  defp verify_simulator(%{box_mode: :physical}), do: :ok

  defp verify_simulator(paths) do
    with {:ok, handle} <-
           Store.open_existing(
             paths.simulator_database,
             paths.simulator_instance_id,
             paths.simulator_device_id
           ),
         do: Store.close(handle)
  end

  defp verify_existing_transport(paths, opts) do
    requested = if opts[:external_simulator] == true, do: :external, else: :internal

    with {:ok, deployment} <- MaintenanceGuard.admit(),
         true <- Map.get(deployment, :simulator_transport, :internal) == requested,
         true <- deployment.root == paths.root,
         :ok <- with_repo(deployment.database, fn -> verify_server(deployment) end),
         :ok <- verify_simulator(deployment),
         {:ok, _} <- secret_key_base(deployment) do
      {:ok, deployment}
    else
      false -> {:error, :simulator_transport_mismatch}
      error -> error
    end
  end

  def rotate_host(output, physical_stop \\ nil) do
    with {:ok, paths} <- MaintenanceGuard.paths() do
      with_guard(paths, fn ->
        with {:ok, deployment} <- admitted_maintenance(),
             :ok <- verify_stopped_box(deployment, physical_stop),
             :ok <- with_repo(deployment.database, fn -> activate_host(deployment, output) end) do
          :ok
        end
      end)
    end
  end

  defp verify_stopped_box(%{box_mode: :physical, box_device_id: id}, evidence),
    do: PhysicalBoxStop.attest(id, evidence)

  defp verify_stopped_box(%{box_mode: :simulated} = deployment, nil),
    do: verify_stopped_simulator(deployment)

  defp verify_stopped_box(_, _), do: {:error, :local_stop_required}

  defp activate_host(paths, output) do
    with :ok <- verify_server(paths),
         %BrowserCredential{} = previous <- host_record(),
         true <- previous.auth_epoch < Codec.max_integer(),
         replacement = key(),
         :ok <- MaintenanceGuard.write_protected(output, replacement <> "\n") do
      digest = digest(replacement)
      credential_id = previous.credential_id
      epoch = previous.auth_epoch

      query =
        from c in BrowserCredential,
          where:
            c.credential_id == ^credential_id and
              c.auth_epoch == ^epoch and c.credential_sha256 == ^previous.credential_sha256

      case GameStore.transaction(fn ->
             case Repo.update_all(query,
                    set: [
                      credential_sha256: digest,
                      auth_epoch: epoch + 1,
                      enabled: true,
                      updated_at_ms: audit_ms()
                    ]
                  ) do
               {1, _} -> :ok
               _ -> GameStore.rollback(:activation_conflict)
             end
           end) do
        {:ok, :ok} -> :ok
        {:error, :activation_conflict} -> {:error, :activation_conflict}
        {:error, _} -> {:error, :readback_required}
      end
    else
      false -> {:error, :epoch_exhausted}
      nil -> {:error, :host_credential_unavailable}
      {:error, _} = error -> error
    end
  end

  def host_status(path) do
    with {:ok, token} <- read_key(path),
         {:ok, paths} <- MaintenanceGuard.paths() do
      with_guard(paths, fn ->
        with {:ok, deployment} <- admitted_maintenance() do
          with_readonly_repo(deployment.database, fn ->
            with :ok <- GameStore.verify_open(deployment.store_id),
                 %BrowserCredential{} = record <- host_record() do
              active? =
                record.enabled and
                  Plug.Crypto.secure_compare(digest(token), record.credential_sha256)

              {:ok, %{active?: active?, auth_epoch: record.auth_epoch}}
            else
              _ -> {:error, :host_credential_unavailable}
            end
          end)
        end
      end)
    end
  end

  def stop_simulator(reason, operator_id, observation)
      when reason in [:maintenance, :lost_host_key] do
    with :ok <- setup_mode(),
         {:ok, paths} <- MaintenanceGuard.paths() do
      with_guard(paths, fn ->
        with {:ok, deployment} <- admitted_maintenance(),
             {:ok, runtime} <-
               SimulatedBox.start_link(
                 path: deployment.simulator_database,
                 instance_id: deployment.simulator_instance_id,
                 device_id: deployment.simulator_device_id,
                 name: nil,
                 maintenance_owner: self()
               ) do
          try do
            case Adapter.service_operation(runtime, "stop", %{
                   "reason" => Atom.to_string(reason),
                   "operator" => %{"operator_id" => operator_id, "observation" => observation}
                 }) do
              %{"status" => "ok"} = result -> {:ok, result}
              %{"status" => "uncertain"} -> {:error, :readback_required}
              _ -> {:error, :local_stop_rejected}
            end
          after
            GenServer.stop(runtime)
          end
        end
      end)
    end
  end

  defp verify_stopped_simulator(paths) do
    with {:ok, handle} <-
           Store.open_existing(
             paths.simulator_database,
             paths.simulator_instance_id,
             paths.simulator_device_id
           ) do
      try do
        case Store.load(handle) do
          {:ok, %{"service" => %{"service_inhibited" => true, "inflight_motion" => nil}}} -> :ok
          _ -> {:error, :local_stop_required}
        end
      after
        Store.close(handle)
      end
    end
  end

  def provision_device(id, class, roles, output, opts \\ []) do
    with true <- Codec.id?(id),
         true <-
           class in ["controller", "box"] and is_list(roles) and
             Enum.uniq(roles) == roles and Enum.all?(roles, &(&1 in ["a", "b"])) and
             ((class == "box" and roles == []) or (class == "controller" and roles != [])),
         true <- id not in [@simulator_device_id, "sim_cyd_a", "sim_cyd_b"],
         {:ok, paths} <- MaintenanceGuard.paths() do
      role_mask =
        Enum.reduce(roles, 0, fn role, mask -> mask + if(role == "a", do: 1, else: 2) end)

      with_guard(paths, fn ->
        with {:ok, deployment} <- admitted_maintenance() do
          with_repo(deployment.database, fn ->
            provision(deployment, id, class, role_mask, output, opts[:rotate])
          end)
        end
      end)
    else
      false -> {:error, :invalid_device_registration}
      error -> error
    end
  end

  defp provision(paths, id, class, mask, output, rotate) do
    with :ok <- GameStore.verify_open(paths.store_id),
         existing = Repo.get(Device, id),
         :ok <- device_provisionable(existing, class, mask, rotate),
         token = device_key(),
         :ok <- MaintenanceGuard.write_protected(output, token <> "\n") do
      case GameStore.transaction(fn ->
             case existing do
               nil ->
                 insert_device(id, class, "raw", token, mask, audit_ms())

               device ->
                 query =
                   from d in Device,
                     where: d.device_id == ^id and d.auth_epoch == ^device.auth_epoch

                 {1, _} =
                   Repo.update_all(query,
                     set: [
                       credential_sha256: digest(token),
                       auth_epoch: device.auth_epoch + 1,
                       enabled: true,
                       updated_at_ms: audit_ms()
                     ]
                   )
             end

             :ok
           end) do
        {:ok, :ok} -> :ok
        _ -> {:error, :readback_required}
      end
    end
  end

  defp device_provisionable(nil, _, _, rotate) when rotate in [nil, false], do: :ok

  defp device_provisionable(
         %Device{
           transport: "raw",
           device_class: class,
           allowed_roles_mask: mask,
           auth_epoch: epoch
         },
         class,
         mask,
         true
       )
       when epoch < 9_007_199_254_740_991,
       do: :ok

  defp device_provisionable(_, _, _, _), do: {:error, :device_registration_conflict}

  defp insert_browser(id, kind, game, role, token, now) do
    GameStore.insert!(BrowserCredential, %{
      credential_id: id,
      kind: kind,
      game_id: game,
      role: role,
      credential_sha256: digest(token),
      created_at_ms: now,
      updated_at_ms: now
    })
  end

  defp insert_device(id, class, transport, token, roles, now) do
    GameStore.insert!(Device, %{
      device_id: id,
      device_class: class,
      transport: transport,
      credential_sha256: token && digest(token),
      allowed_roles_mask: roles,
      capabilities_json: "{}",
      created_at_ms: now,
      updated_at_ms: now
    })
  end

  defp admitted_maintenance do
    with {:ok, paths} <- MaintenanceGuard.admit(),
         :ok <- test_admission(paths) do
      {:ok, paths}
    end
  end

  defp host_record, do: Repo.get_by(BrowserCredential, kind: "host")
  defp file(paths, kind), do: Path.join(paths.root, Map.fetch!(@files, kind))

  defp with_guard(paths, fun) do
    with {:ok, guard} <- MaintenanceGuard.acquire(paths.root) do
      # A nonlocal exit intentionally leaves the marker. Resources must be closed before release.
      result =
        case MaintenanceGuard.acquire(paths.root, "box-runtime.owner") do
          {:ok, box_guard} ->
            result = fun.()

            case MaintenanceGuard.release(box_guard) do
              :ok -> result
              error -> error
            end

          error ->
            error
        end

      case MaintenanceGuard.release(guard) do
        :ok -> result
        error -> error
      end
    end
  end

  defp with_repo(database, fun), do: with_repo_options(Repo.options(database), fun)

  defp with_readonly_repo(database, fun) do
    options =
      Repo.options(database) |> Keyword.put(:mode, :readonly) |> Keyword.delete(:journal_mode)

    with_repo_options(options, fun)
  end

  defp with_repo_options(opts, fun) do
    with {:ok, _} <- Application.ensure_all_started(:ecto_sqlite3),
         {:ok, pid} <- Repo.start_link(opts) do
      try do
        GameStore.guarded(fun)
      after
        Supervisor.stop(pid)
      end
    else
      _ -> {:error, :storage_error}
    end
  end
end
