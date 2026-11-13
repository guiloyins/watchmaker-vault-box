defmodule Vault.Application do
  @moduledoc "Guarded application admission; storage is validated before games or HTTP."
  use Application
  alias Vault.{Credentials, GameStore, MaintenanceGuard, Repo}

  @impl true
  def start(_type, _args) do
    with :ok <- configuration(),
         {:ok, paths} <- MaintenanceGuard.admit(),
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

  defp configuration do
    origin = Application.get_env(:vault, :origin)
    uri = if is_binary(origin), do: URI.parse(origin)

    if Application.get_env(:vault, :box_mode) == :simulated and
         is_tuple(Application.get_env(:vault, :bind)) and
         is_integer(Application.get_env(:vault, :port)) and
         uri != nil and uri.scheme in ["http", "https"] and is_binary(uri.host) and
         uri.userinfo == nil and uri.query == nil and uri.fragment == nil and
         uri.path in [nil, "", "/"],
       do: :ok,
       else: {:error, :invalid_runtime_configuration}
  end

  defp start_guarded(paths, secret) do
    endpoint = Application.get_env(:vault, VaultWeb.Endpoint, [])
    uri = URI.parse(Application.fetch_env!(:vault, :origin))

    endpoint =
      Keyword.merge(endpoint,
        secret_key_base: secret,
        http: [
          ip: Application.fetch_env!(:vault, :bind),
          port: Application.fetch_env!(:vault, :port)
        ],
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
          with :ok <- GameStore.verify_open(paths.store_id),
               {:ok, %{game: game}} <- GameStore.active(),
               true <-
                 game.box_device_id == paths.simulator_device_id and game.box_mode == "simulated" do
            children = [
              {Phoenix.PubSub, name: Vault.PubSub},
              {Registry, keys: :unique, name: Vault.Registry},
              {DynamicSupervisor, name: Vault.GameSupervisor, strategy: :one_for_one},
              {DynamicSupervisor, name: Vault.ControllerSupervisor, strategy: :one_for_one},
              {Vault.SimulatedBox,
               path: paths.simulator_database,
               instance_id: paths.simulator_instance_id,
               device_id: paths.simulator_device_id,
               clock: Application.get_env(:vault, :clock, Vault.Clock.system())},
              Vault.Auth,
              Vault.Recovery,
              VaultWeb.Endpoint
            ]

            Enum.reduce_while(children, :ok, fn child, :ok ->
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
