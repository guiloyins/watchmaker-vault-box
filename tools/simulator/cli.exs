Code.require_file("load.exs", __DIR__)

defmodule Vault.Simulator.CLI do
  @moduledoc false
  alias Vault.{Credentials, JSON, MaintenanceGuard}
  alias Vault.GameStore.Codec
  alias Vault.SimulatedBox.{Model.Durable, Store}
  alias Vault.Simulator.{BoxRuntime, Scenarios}

  @usage """
  device-simulator --endpoint URL --device-id ID --credentials-file FILE --scenario NAME [options]

  Scenarios:
    controller-smoke --role a|b
    controller-script --role a|b --steps up,down,left,right,star,moon,sun,wave,hold
    box | box-inspect | box-console --isolated-simulation --box-db FILE --instance-id ID
    box-service --service-file FILE --isolated-simulation --box-db FILE --instance-id ID
    fault-fragments --isolated-simulation --allow-ws (loopback only)

  Options:
    --allow-ws              Permit trusted development WS explicitly.
    --ca-file FILE          Add a PEM trust anchor for verified WSS.
    --duration-ms MS        Observe the connection for up to 60,000 ms (default 1,000).
    --init-box-store        Explicitly create a new box DB; fails if the file exists.
  """

  def main(["--help"]),
    do:
      (
        IO.puts(@usage)
        :ok
      )

  def main(["--" | rest]), do: main(rest)

  def main(argv) do
    with {:ok, opts} <- options(argv),
         :ok <- start_apps(opts),
         :ok <- with_box(opts, &Scenarios.run(opts[:scenario], &1)) do
      :ok
    else
      {:error, reason} when is_atom(reason) ->
        IO.puts(:stderr, "Simulator refused or stopped: #{reason}.")
        {:error, reason}

      _ ->
        IO.puts(:stderr, "Simulator could not run.")
        {:error, :simulator_failed}
    end
  end

  defp options(args) do
    switches = [
      endpoint: :string,
      device_id: :string,
      credentials_file: :string,
      scenario: :string,
      role: :string,
      steps: :string,
      allow_ws: :boolean,
      isolated_simulation: :boolean,
      box_db: :string,
      instance_id: :string,
      init_box_store: :boolean,
      ca_file: :string,
      duration_ms: :integer,
      service_file: :string
    ]

    with true <- length(args) <= 28 and Enum.all?(args, &(byte_size(&1) <= 1_024)),
         {opts, [], []} <- OptionParser.parse(args, strict: switches),
         true <- Keyword.keys(opts) == Enum.uniq(Keyword.keys(opts)),
         true <- Durable.id?(opts[:device_id]),
         true <- protected_credentials?(opts[:credentials_file]),
         {:ok, uri} <- endpoint(opts),
         {:ok, certs} <- ca(opts[:ca_file], uri.scheme),
         duration when duration in 0..60_000 <- Keyword.get(opts, :duration_ms, 1_000),
         {:ok, steps} <- scenario_options(opts, uri),
         {:ok, request} <- service_request(opts) do
      {:ok,
       Keyword.merge(opts,
         uri: uri,
         cacerts: certs,
         steps: steps,
         duration_ms: duration,
         service_request: request
       )}
    else
      _ -> {:error, :invalid_arguments}
    end
  end

  defp endpoint(opts) do
    with endpoint when is_binary(endpoint) <- opts[:endpoint],
         {:ok, %URI{} = uri} <- URI.new(endpoint),
         true <- uri.scheme in ~w(ws wss) and uri.path == "/device/v1",
         true <-
           is_binary(uri.host) and uri.host != "" and
             is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment),
         true <- uri.scheme == "wss" or opts[:allow_ws] == true,
         port when port in 1..65_535 <- uri.port || if(uri.scheme == "wss", do: 443, else: 80) do
      {:ok, %{uri | port: port}}
    else
      _ -> {:error, :invalid_endpoint}
    end
  end

  defp protected_credentials?(file) when is_binary(file) do
    case MaintenanceGuard.read_protected(file, 65) do
      {:ok, <<value::binary-size(64), "\n">>} -> Credentials.device_key?(value)
      _ -> false
    end
  end

  defp protected_credentials?(_), do: false

  defp ca(nil, _), do: {:ok, nil}

  defp ca(path, "wss") do
    with {:ok, %{type: :regular, size: size}} when size in 1..65_536 <- File.stat(path),
         {:ok, pem} when byte_size(pem) <= 65_536 <- File.read(path),
         entries when entries != [] <- :public_key.pem_decode(pem),
         true <- Enum.all?(entries, &match?({:Certificate, _, :not_encrypted}, &1)) do
      {:ok, Enum.map(entries, &elem(&1, 1))}
    else
      _ -> {:error, :invalid_ca}
    end
  rescue
    _ -> {:error, :invalid_ca}
  end

  defp ca(_, _), do: {:error, :unexpected_ca}

  defp scenario_options(opts, uri) do
    case opts[:scenario] do
      "controller-smoke" ->
        if opts[:role] in ~w(a b) and is_nil(opts[:steps]) and is_nil(opts[:box_db]),
          do: {:ok, []}

      "controller-script" ->
        with true <- opts[:role] in ~w(a b) and is_nil(opts[:box_db]),
             steps when is_binary(steps) <- opts[:steps],
             parsed <- String.split(steps, ","),
             true <-
               length(parsed) <= 64 and
                 Enum.all?(parsed, &(&1 in ~w(up down left right star moon sun wave hold))) do
          {:ok, parsed}
        end

      scenario when scenario in ~w(box box-inspect box-service box-console) ->
        with true <- opts[:isolated_simulation] == true,
             true <- uri.scheme == "wss" or uri.host in ["127.0.0.1", "localhost", "::1"],
             path when is_binary(path) <- opts[:box_db],
             true <- Durable.id?(opts[:instance_id]),
             true <- opts[:role] == nil and opts[:steps] == nil do
          {:ok, []}
        end

      "fault-fragments" ->
        if opts[:isolated_simulation] == true and uri.scheme == "ws" and
             uri.host in ["127.0.0.1", "localhost", "::1"] and is_nil(opts[:box_db]),
           do: {:ok, []}

      _ ->
        {:error, :unknown_scenario}
    end
  end

  defp service_request(opts) do
    case {opts[:scenario], opts[:service_file]} do
      {"box-service", path} when is_binary(path) ->
        with {:ok, bytes} <- MaintenanceGuard.read_protected(path, 4_096) do
          decode_service(bytes)
        end

      {"box-service", _} ->
        {:error, :missing_service_request}

      {_, nil} ->
        {:ok, nil}

      _ ->
        {:error, :unexpected_service_request}
    end
  end

  def decode_service(bytes) when byte_size(bytes) <= 4_096 do
    with {:ok, parsed} <- JSON.decode_object(bytes, %{max_bytes: 4_096, max_depth: 8}),
         {:ok, value} <- local_numbers(parsed),
         %{"command" => command, "args" => args} <- value,
         true <- is_binary(command) and is_map(args),
         true <- map_size(value) == 2 or Vault.SimulatedBox.Adapter.valid_service?(value) do
      {:ok, value}
    else
      _ -> {:error, :invalid_service_request}
    end
  end

  def decode_service(_), do: {:error, :invalid_service_request}

  defp local_numbers({:json_number, _} = token),
    do: Vault.JSON.Number.integer(token, 0, 9_007_199_254_740_991)

  defp local_numbers(value) when is_list(value), do: map_numbers(value)

  defp local_numbers(value) when is_map(value) do
    value
    |> Enum.reduce_while({:ok, %{}}, fn {key, entry}, {:ok, acc} ->
      case local_numbers(entry) do
        {:ok, native} -> {:cont, {:ok, Map.put(acc, key, native)}}
        error -> {:halt, error}
      end
    end)
  end

  defp local_numbers(value), do: {:ok, value}

  defp map_numbers(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case local_numbers(entry) do
        {:ok, native} -> {:cont, {:ok, [native | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp start_apps(opts) do
    apps = [:mint, :mint_web_socket] ++ if(opts[:box_db], do: [:exqlite], else: [])

    with true <- absent_apps?(),
         :ok <-
           Enum.reduce_while(apps, :ok, fn app, _ ->
             case Application.ensure_all_started(app) do
               {:ok, _} -> {:cont, :ok}
               _ -> {:halt, {:error, :dependency_start_failed}}
             end
           end),
         true <- absent_apps?() do
      :ok
    else
      _ -> {:error, :unexpected_application}
    end
  end

  defp absent_apps? do
    started = Application.started_applications() |> Enum.map(&elem(&1, 0))

    :vault not in started and :phoenix not in started and
      Process.whereis(Vault.Repo) == nil and Process.whereis(VaultWeb.Endpoint) == nil
  end

  defp with_box(opts, run) do
    if opts[:box_db] do
      path = Path.expand(opts[:box_db])

      with {:ok, guard} <- MaintenanceGuard.acquire(Path.dirname(path), "box-runtime.owner") do
        # The guard uses the canonical parent, including when the caller used
        # a symlinked directory spelling.
        path = Path.join(Path.dirname(guard.path), Path.basename(path))

        case guarded_box(path, opts, run) do
          {:stopped, outcome} ->
            case MaintenanceGuard.release(guard) do
              :ok -> outcome
              _ -> {:error, :box_guard_cleanup_failed}
            end

          {:uncertain, _} ->
            {:error, :box_stop_uncertain}
        end
      end
    else
      run.(opts)
    end
  end

  defp guarded_box(path, opts, run) do
    with :ok <- protect_independent(path, opts),
         :ok <- check_box_deployment(path, opts),
         :ok <- maybe_create(path, opts),
         :ok <- MaintenanceGuard.protected_file(path),
         {:ok, box} <-
           BoxRuntime.start_link(
             path: path,
             instance_id: opts[:instance_id],
             device_id: opts[:device_id]
           ) do
      # Unexpected owner death leaves the guard for explicit offline recovery.
      outcome = run.(Keyword.put(opts, :box, box))
      stop = BoxRuntime.shutdown(box)
      if stop == :ok, do: {:stopped, outcome}, else: {:uncertain, stop}
    else
      {:error, _} = error -> {:stopped, error}
    end
  end

  defp protect_independent(path, opts) do
    if path == Path.expand(opts[:credentials_file]) or
         Path.basename(path) in [
           "vault.sqlite3",
           "box-runtime.owner",
           "vault.owner",
           "deployment.json"
         ],
       do: {:error, :invalid_box_path},
       else: :ok
  end

  defp check_box_deployment(path, opts) do
    root = Path.dirname(path)
    manifest = MaintenanceGuard.manifest_path(root)

    case File.lstat(manifest) do
      {:error, :enoent} -> :ok
      {:ok, _} -> match_external_manifest(manifest, root, path, opts)
      {:error, _} -> {:error, :invalid_box_deployment}
    end
  end

  defp match_external_manifest(manifest, root, path, opts) do
    instance = opts[:instance_id]
    device = opts[:device_id]

    with {:ok, bytes} <- MaintenanceGuard.read_protected(manifest, 2_048),
         {:ok,
          %{
            "schema_version" => 2,
            "simulator_transport" => "external",
            "store_id" => store_id,
            "database" => database,
            "simulator_database" => ^path,
            "simulator_instance_id" => ^instance,
            "simulator_device_id" => ^device
          } = document} <- Codec.decode(bytes, 2_048),
         true <- map_size(document) == 7 and Codec.id?(store_id),
         true <- valid_server_db?(database, root, path),
         :ok <- MaintenanceGuard.protected_file(database),
         :ok <- MaintenanceGuard.protected_file(path) do
      :ok
    else
      _ -> {:error, :invalid_box_deployment}
    end
  end

  defp valid_server_db?(database, root, box_path) when is_binary(database) do
    Path.dirname(database) == root and Path.expand(database) == database and database != box_path and
      Path.basename(database) not in ~w(vault.owner box-runtime.owner deployment.json .vault-test-prepared)
  end

  defp valid_server_db?(_, _, _), do: false

  defp maybe_create(path, opts) do
    if opts[:init_box_store] do
      Store.init_new(path, opts[:instance_id], opts[:device_id])
    else
      :ok
    end
  end
end

case Vault.Simulator.CLI.main(System.argv()) do
  :ok -> System.halt(0)
  {:error, _} -> System.halt(1)
end
