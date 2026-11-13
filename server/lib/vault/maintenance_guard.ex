defmodule Vault.MaintenanceGuard do
  @moduledoc "Exclusive local ownership shared by the Vault VM and offline setup tasks."

  alias Vault.GameStore.Codec

  @guard "vault.owner"
  @manifest "deployment.json"

  defstruct [:path, :token, :inode, :device]

  def admit do
    with {:ok, paths} <- paths(),
         :ok <- protected_file(paths.database),
         :ok <- protected_file(paths.simulator_database),
         {:ok, manifest} <- read_protected(Path.join(paths.root, @manifest), 2048),
         {:ok,
          %{
            "schema_version" => 1,
            "store_id" => store_id,
            "simulator_instance_id" => instance_id,
            "simulator_device_id" => device_id,
            "database" => database,
            "simulator_database" => simulator
          } = document} <- Codec.decode(manifest, 2048),
         true <- map_size(document) == 6,
         true <- database == paths.database and simulator == paths.simulator_database,
         true <- Enum.all?([store_id, instance_id, device_id], &Codec.id?/1) do
      {:ok,
       Map.merge(paths, %{
         store_id: store_id,
         simulator_instance_id: instance_id,
         simulator_device_id: device_id
       })}
    else
      _ -> {:error, :invalid_deployment}
    end
  end

  def paths(opts \\ []) do
    root = Application.get_env(:vault, :data_dir)

    with {:ok, root} <- owned_directory(root, opts),
         {:ok, db} <- data_file(root, :database, "vault.sqlite3"),
         {:ok, simulator} <- data_file(root, :simulator_database, "simulated-box.sqlite3"),
         true <-
           db != simulator and Path.basename(db) not in reserved_names() and
             Path.basename(simulator) not in reserved_names(),
         true <- distinct_files?(db, simulator) do
      {:ok, %{root: root, database: db, simulator_database: simulator}}
    else
      _ -> {:error, :invalid_data_directory}
    end
  end

  def write_manifest(paths) do
    document =
      Map.take(paths, [
        :database,
        :simulator_database,
        :store_id,
        :simulator_instance_id,
        :simulator_device_id
      ])

    with {:ok, bytes} <- Codec.encode(Map.put(document, :schema_version, 1), 2048) do
      write_protected(Path.join(paths.root, @manifest), bytes)
    end
  end

  def manifest_path(root), do: Path.join(root, @manifest)

  def acquire(root) do
    with {:ok, root} <- owned_directory(root),
         path = Path.join(root, @guard),
         token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
         :ok <- write_protected(path, token <> "\npid=" <> List.to_string(:os.getpid()) <> "\n"),
         {:ok, stat} <- File.lstat(path) do
      {:ok, %__MODULE__{path: path, token: token, inode: stat.inode, device: stat.major_device}}
    else
      {:error, :output_exists} -> {:error, :guard_owned}
      _ -> {:error, :guard_unavailable}
    end
  end

  def release(%__MODULE__{path: path, token: token, inode: inode, device: device}) do
    with {:ok, %File.Stat{inode: ^inode, major_device: ^device}} <- File.lstat(path),
         {:ok, marker} <- read_protected(path, 256),
         true <- String.starts_with?(marker, token <> "\n"),
         :ok <- File.rm(path),
         :ok <- sync_directory(Path.dirname(path)) do
      :ok
    else
      _ -> {:error, :guard_cleanup_failed}
    end
  end

  def write_protected(path, bytes) when is_binary(path) and is_binary(bytes) do
    with {:ok, canonical_parent} <- owned_directory(Path.dirname(Path.expand(path))),
         target = Path.join(canonical_parent, Path.basename(path)),
         {:ok, file} <- File.open(target, [:write, :exclusive, :binary, :raw]) do
      result =
        with :ok <- File.chmod(target, 0o600),
             :ok <- :file.write(file, bytes),
             :ok <- :file.sync(file) do
          :ok
        end

      closed = File.close(file)

      with :ok <- result,
           :ok <- closed,
           :ok <- sync_directory(canonical_parent),
           {:ok, ^bytes} <- read_protected(target, byte_size(bytes)) do
        :ok
      else
        _ -> {:error, :output_not_durable}
      end
    else
      {:error, :eexist} -> {:error, :output_exists}
      _ -> {:error, :invalid_output_path}
    end
  end

  def write_protected(_, _), do: {:error, :invalid_output_path}

  def read_protected(path, maximum)
      when is_binary(path) and is_integer(maximum) and maximum >= 0 do
    with {:ok, uid} <- owner_uid(),
         {:ok, expected} <- File.lstat(path),
         true <- protected_stat?(expected, uid),
         {:ok, file} <- File.open(path, [:read, :binary, :raw]) do
      try do
        # Compare the open file's identity with the no-follow stat before
        # reading any bytes. A swapped link or hardlink cannot redirect a read.
        with {:ok, actual} <- :file.read_file_info(file),
             true <- protected_handle?(expected, actual, uid) do
          case :file.read(file, maximum + 1) do
            :eof -> {:ok, ""}
            {:ok, bytes} when byte_size(bytes) <= maximum -> {:ok, bytes}
            _ -> {:error, :protected_file_unreadable}
          end
        else
          _ -> {:error, :protected_file_unreadable}
        end
      after
        File.close(file)
      end
    else
      _ -> {:error, :protected_file_unreadable}
    end
  end

  def read_protected(_, _), do: {:error, :protected_file_unreadable}

  def protected_file(path) when is_binary(path) do
    with {:ok, uid} <- owner_uid(),
         {:ok, stat} <- File.lstat(path),
         true <- protected_stat?(stat, uid) do
      :ok
    else
      _ -> {:error, :unprotected_file}
    end
  end

  def protected_file(_), do: {:error, :unprotected_file}

  defp protected_stat?(%File.Stat{type: :regular, uid: owner, links: 1, mode: mode}, uid),
    do: owner == uid and Bitwise.band(mode, 0o777) == 0o600

  defp protected_stat?(_, _), do: false

  defp protected_handle?(
         expected,
         {:file_info, _size, :regular, _access, _atime, _mtime, _ctime, mode, 1, major, minor,
          inode, owner, _group},
         uid
       ) do
    owner == uid and Bitwise.band(mode, 0o777) == 0o600 and
      {major, minor, inode} == {expected.major_device, expected.minor_device, expected.inode}
  end

  defp protected_handle?(_, _, _), do: false

  def owned_directory(path, opts \\ [])

  def owned_directory(path, opts) when is_binary(path) and byte_size(path) > 0 do
    path = Path.expand(path)

    with :ok <- maybe_create_directory(path, opts[:create]),
         {:ok, canonical} <- canonical_path(path, 32),
         {:ok, uid} <- owner_uid(),
         {:ok, %File.Stat{type: :directory, uid: ^uid, mode: mode}} <- File.lstat(canonical),
         true <- Bitwise.band(mode, 0o777) == 0o700 do
      {:ok, canonical}
    else
      _ -> {:error, :unowned_directory}
    end
  end

  def owned_directory(_, _), do: {:error, :unowned_directory}

  defp maybe_create_directory(path, true) do
    case File.lstat(path) do
      {:error, :enoent} ->
        with :ok <- File.mkdir(path),
             :ok <- File.chmod(path, 0o700) do
          sync_directory(Path.dirname(path))
        end

      {:ok, _} ->
        :ok

      _ ->
        {:error, :directory_unavailable}
    end
  end

  defp maybe_create_directory(_path, _), do: :ok

  defp owner_uid do
    case System.cmd("id", ["-u"], stderr_to_stdout: true) do
      {uid, 0} ->
        case Integer.parse(String.trim(uid)) do
          {uid, ""} -> {:ok, uid}
          _ -> {:error, :uid_unavailable}
        end

      _ ->
        {:error, :uid_unavailable}
    end
  end

  defp canonical_path(_path, 0), do: {:error, :symlink_loop}

  defp canonical_path(path, remaining) do
    [root | parts] = Path.split(path)
    resolve_parts(root, parts, remaining)
  end

  defp resolve_parts(path, [], _remaining), do: {:ok, path}

  defp resolve_parts(parent, [name | rest], remaining) do
    path = Path.join(parent, name)

    case File.read_link(path) do
      {:ok, link} ->
        target = Path.expand(link, parent)
        canonical_path(Path.join([target | rest]), remaining - 1)

      {:error, :einval} ->
        resolve_parts(path, rest, remaining)

      {:error, _} = error ->
        error
    end
  end

  defp data_file(root, setting, default) do
    configured = Application.get_env(:vault, setting) || Path.join(root, default)

    with {:ok, ^root} <- canonical_path(Path.dirname(Path.expand(configured)), 32) do
      {:ok, Path.join(root, Path.basename(configured))}
    end
  end

  defp reserved_names, do: [@guard, @manifest, ".vault-test-prepared"]

  defp distinct_files?(left, right) do
    case {File.lstat(left), File.lstat(right)} do
      {{:ok, first}, {:ok, second}} ->
        {first.major_device, first.inode} != {second.major_device, second.inode}

      _ ->
        true
    end
  end

  def sync_directory(path) do
    with {:ok, descriptor} <- :file.open(path, [:read, :raw, :directory]) do
      synced = :file.sync(descriptor)
      closed = :file.close(descriptor)
      if synced == :ok, do: closed, else: synced
    end
  end
end
