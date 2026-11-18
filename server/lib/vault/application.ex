defmodule Vault.Application do
  @moduledoc "Guarded application admission; storage is validated before games or HTTP."
  use Application
  alias Vault.{Credentials, MaintenanceGuard, Repo}

  @impl true
  def start(_type, _args) do
    with :ok <- configuration(),
         {:ok, paths} <- MaintenanceGuard.admit(),
         :ok <- transport_configuration(paths),
         :ok <- Credentials.test_admission(paths),
         {:ok, secret} <- Credentials.secret_key_base(paths),
         {:ok, guard} <- MaintenanceGuard.acquire(paths.root) do
      case start_guarded(paths, secret) do
        {:ok, pid} ->
          {:ok, pid, guard}

        {:error, reason} ->
          MaintenanceGuard.release(guard)
          {:error, reason}
      end
    end
  end

  defp transport_configuration(paths) do
    if Map.get(paths, :simulator_transport, :internal) ==
         Application.get_env(:vault, :simulator_transport, :internal),
       do: :ok,
       else: {:error, :simulator_transport_mismatch}
  end

  defp configuration do
    origin = Application.get_env(:vault, :origin)
    uri = if is_binary(origin), do: URI.parse(origin)

    if Application.get_env(:vault, :box_mode) in [:simulated, :physical] and
         is_tuple(Application.get_env(:vault, :bind)) and
         is_integer(Application.get_env(:vault, :port)) and
         uri != nil and uri.scheme in ["http", "https"] and is_binary(uri.host) and
         uri.userinfo == nil and uri.query == nil and uri.fragment == nil and
         uri.path in [nil, "", "/"] and tls_configuration?(uri.scheme),
       do: :ok,
       else: {:error, :invalid_runtime_configuration}
  end

  defp tls_configuration?("http"),
    do:
      is_nil(Application.get_env(:vault, :tls_cert_file)) and
        is_nil(Application.get_env(:vault, :tls_key_file))

  defp tls_configuration?("https") do
    cert = Application.get_env(:vault, :tls_cert_file)
    key = Application.get_env(:vault, :tls_key_file)

    is_binary(cert) and File.regular?(cert) and is_binary(key) and
      MaintenanceGuard.protected_file(key) == :ok
  end

  defp tls_configuration?(_), do: false

  defp start_guarded(paths, secret) do
    endpoint = Application.get_env(:vault, VaultWeb.Endpoint, [])
    uri = URI.parse(Application.fetch_env!(:vault, :origin))

    listener = [
      ip: Application.fetch_env!(:vault, :bind),
      port: Application.fetch_env!(:vault, :port),
      thousand_island_options: [
        silent_terminate_on_error: true,
        transport_options: [send_timeout: 100, send_timeout_close: true]
      ]
    ]

    {http, https} =
      if uri.scheme == "https" do
        {false,
         Keyword.merge(listener,
           certfile: Application.fetch_env!(:vault, :tls_cert_file),
           keyfile: Application.fetch_env!(:vault, :tls_key_file)
         )}
      else
        {listener, false}
      end

    endpoint =
      Keyword.merge(endpoint,
        secret_key_base: secret,
        http: http,
        https: https,
        url: [host: uri.host, port: uri.port, scheme: uri.scheme],
        check_origin: [Application.fetch_env!(:vault, :origin)]
      )

    Application.put_env(:vault, VaultWeb.Endpoint, endpoint)
    Application.put_env(:vault, :deployment, paths)

    case Supervisor.start_link([{Repo, Repo.options(paths.database)}],
           strategy: :one_for_one,
           name: Vault.Supervisor
         ) do
      {:ok, supervisor} ->
        result =
          with :ok <- Credentials.verify_server(paths) do
            children = [
              {Phoenix.PubSub, name: Vault.PubSub},
              {Registry, keys: :unique, name: Vault.Registry},
              {DynamicSupervisor, name: Vault.GameSupervisor, strategy: :one_for_one},
              {DynamicSupervisor, name: Vault.ControllerSupervisor, strategy: :one_for_one},
              if(Map.get(paths, :simulator_transport) == :internal,
                do:
                  {Vault.SimulatedBox,
                   path: paths.simulator_database,
                   instance_id: paths.simulator_instance_id,
                   device_id: paths.simulator_device_id,
                   clock: Application.get_env(:vault, :clock, Vault.Clock.system())}
              ),
              Vault.Auth,
              Vault.Recovery,
              VaultWeb.Endpoint
            ]

            Enum.reduce_while(Enum.reject(children, &is_nil/1), :ok, fn child, :ok ->
              case Supervisor.start_child(supervisor, child) do
                {:ok, _} -> {:cont, :ok}
                {:ok, _, _} -> {:cont, :ok}
                {:error, _} -> {:halt, {:error, :startup_failed}}
              end
            end)
          end

        case result do
          :ok ->
            {:ok, supervisor}

          _ ->
            Supervisor.stop(supervisor, :normal)
            {:error, :invalid_application_store}
        end

      {:error, _} ->
        {:error, :repository_start_failed}
    end
  end

  @impl true
  def stop(guard), do: MaintenanceGuard.release(guard)

  @impl true
  def config_change(changed, _new, removed), do: VaultWeb.Endpoint.config_change(changed, removed)
end
