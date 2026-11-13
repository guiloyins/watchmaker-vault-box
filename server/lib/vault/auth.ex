defmodule Vault.Auth do
  @moduledoc "Browser exchange, server-owned session scopes, and current credential checks."

  use GenServer
  import Bitwise
  import Ecto.Query

  alias Vault.{Credentials, GameStore, Repo}
  alias Vault.Controllers.Principal
  alias Vault.GameStore.{BrowserCredential, Codec, Device, Game}

  @session_ms 8 * 60 * 60 * 1000
  @attempt_ms 30_000
  @attempt_limit 8
  @source_limit 1_024
  @session_limit 4_096

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    :ets.new(__MODULE__, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, %{attempts: %{}, next_sweep: System.monotonic_time(:millisecond)}}
  end

  def exchange(kind, token, source \\ :local)

  def exchange(kind, token, source) when kind in [:host, :player] do
    auth_call({:exchange, kind, token, source})
  end

  def exchange(_, _, _), do: {:error, :not_authorized}

  def to_session(%Principal{browser_session_id: id} = principal) when is_binary(id) do
    %{
      "session_id" => id,
      "credential_id" => principal.subject_id,
      "auth_epoch" => principal.auth_epoch,
      "expires_at_ms" => principal.expires_at_ms
    }
  end

  def from_session(%{"session_id" => id} = cookie) when map_size(cookie) == 4 do
    with %Principal{} = principal <- session(id),
         true <- to_session(principal) == cookie and valid?(principal) do
      {:ok, principal}
    else
      _ -> {:error, :not_authorized}
    end
  end

  def from_session(_), do: {:error, :not_authorized}

  def logout(%Principal{browser_session_id: id}), do: logout(id)
  def logout(id) when is_binary(id), do: auth_call({:logout, id})
  def logout(_), do: :ok

  def valid?(%Principal{kind: kind} = principal) when kind in [:host, :player] do
    with true <- principal.expires_at_ms > Credentials.audit_ms(),
         ^principal <- session(principal.browser_session_id),
         %BrowserCredential{enabled: true} = record <- credential(principal.subject_id) do
      matches_browser?(record, principal)
    else
      _ -> false
    end
  end

  def valid?(
        %Principal{
          kind: :internal_box,
          auth_epoch: 1,
          expires_at_ms: nil,
          browser_session_id: nil,
          allowed_roles: []
        } = principal
      ) do
    GameStore.guarded(fn ->
      case {Repo.get(Device, principal.subject_id), Repo.get(Game, principal.game_id)} do
        {%Device{device_class: "box", transport: "internal", enabled: true, auth_epoch: 1},
         %Game{active_slot: 1, box_mode: "simulated", box_device_id: id}} ->
          id == principal.subject_id

        _ ->
          false
      end
    end) == true
  end

  def valid?(%Principal{kind: :device, expires_at_ms: nil, browser_session_id: nil} = principal) do
    GameStore.guarded(fn ->
      case {Repo.get(Device, principal.subject_id), Repo.get(Game, principal.game_id)} do
        {%Device{transport: "raw", enabled: true} = device, %Game{active_slot: 1} = game} ->
          device.auth_epoch == principal.auth_epoch and device_scope?(device, game, principal)

        _ ->
          false
      end
    end) == true
  end

  def valid?(_), do: false

  def simulated_principal(%Principal{kind: :host} = host, game_id, role) when role in [:a, :b] do
    GameStore.guarded(fn ->
      with true <- valid?(host),
           %Game{active_slot: 1, box_mode: "simulated"} <- Repo.get(Game, game_id),
           id = "sim_cyd_" <> Atom.to_string(role),
           %Device{device_class: "controller", enabled: true} = device <- Repo.get(Device, id),
           principal = device_principal(device, game_id),
           true <- principal.allowed_roles == [role] and valid?(principal) do
        {:ok, principal}
      else
        _ -> {:error, :not_authorized}
      end
    end)
  end

  def simulated_principal(_, _, _), do: {:error, :not_authorized}

  def authenticate_device(id, token, game_id) do
    GameStore.guarded(fn ->
      with true <- Codec.id?(id),
           true <- Credentials.device_key?(token),
           %Device{transport: "raw", enabled: true} = device <- Repo.get(Device, id),
           true <-
             Plug.Crypto.secure_compare(Credentials.digest(token), device.credential_sha256),
           principal = device_principal(device, game_id),
           true <- valid?(principal) do
        {:ok, principal}
      else
        _ -> {:error, :not_authorized}
      end
    end)
  end

  defp device_principal(device, game_id) do
    %Principal{
      kind: :device,
      subject_id: device.device_id,
      auth_epoch: device.auth_epoch,
      game_id: game_id,
      allowed_roles: roles(device.allowed_roles_mask),
      expires_at_ms: nil,
      browser_session_id: nil
    }
  end

  defp device_scope?(%Device{device_class: "controller"} = device, game, principal) do
    (device.device_id not in ["sim_cyd_a", "sim_cyd_b"] or game.box_mode == "simulated") and
      principal.allowed_roles == roles(device.allowed_roles_mask)
  end

  defp device_scope?(%Device{device_class: "box", device_id: id}, game, principal),
    do: id == game.box_device_id and principal.allowed_roles == []

  defp roles(mask), do: for({role, bit} <- [a: 1, b: 2], (mask &&& bit) != 0, do: role)

  defp auth_call(message) do
    GenServer.call(__MODULE__, message, 1_000)
  catch
    :exit, _ -> {:error, :not_authorized}
  end

  defp session(id) when is_binary(id) do
    case :ets.lookup(__MODULE__, id) do
      [{^id, principal}] -> principal
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp session(_), do: nil

  defp credential(id), do: GameStore.guarded(fn -> Repo.get(BrowserCredential, id) end)

  defp matches_browser?(record, principal) do
    browser_scope(record) == {principal.kind, principal.game_id, principal.allowed_roles} and
      record.auth_epoch == principal.auth_epoch
  end

  defp browser_scope(%BrowserCredential{kind: "host", game_id: nil, role: nil}),
    do: {:host, nil, [:a, :b]}

  defp browser_scope(%BrowserCredential{kind: "player", game_id: game, role: "a"}),
    do: {:player, game, [:a]}

  defp browser_scope(%BrowserCredential{kind: "player", game_id: game, role: "b"}),
    do: {:player, game, [:b]}

  @impl true
  def handle_call({:exchange, kind, token, source}, _from, state) do
    now = System.monotonic_time(:millisecond)
    state = sweep(state, now)

    case admit_attempt(state, now, source) do
      {:ok, state} -> {:reply, exchange_token(kind, token), state}
      {:error, state} -> {:reply, {:error, :not_authorized}, state}
    end
  end

  def handle_call({:logout, id}, _from, state) do
    :ets.delete(__MODULE__, id)
    {:reply, :ok, state}
  end

  @impl true
  def format_status(status) do
    # A rejected login token never enters diagnostic output, including an OTP crash report.
    Map.drop(status, [:message, :log, :queue, :reason])
  end

  defp sweep(%{next_sweep: next} = state, now) when now >= next do
    wall = Credentials.audit_ms()

    Enum.each(:ets.tab2list(__MODULE__), fn {id, principal} ->
      if principal.expires_at_ms <= wall, do: :ets.delete(__MODULE__, id)
    end)

    %{
      state
      | attempts: Map.reject(state.attempts, fn {_, {until, _}} -> until <= now end),
        next_sweep: now + @attempt_ms
    }
  end

  defp sweep(state, _now), do: state

  defp admit_attempt(state, now, source) do
    source = if is_tuple(source) and tuple_size(source) in [4, 8], do: source, else: :local

    case Map.fetch(state.attempts, source) do
      {:ok, {until, attempts}} when until > now and attempts >= @attempt_limit ->
        {:error, state}

      {:ok, {until, attempts}} when until > now ->
        {:ok, put_in(state.attempts[source], {until, attempts + 1})}

      :error when map_size(state.attempts) >= @source_limit ->
        {:error, state}

      _ ->
        {:ok, put_in(state.attempts[source], {now + @attempt_ms, 1})}
    end
  end

  defp exchange_token(kind, token) do
    if Credentials.key?(token) and :ets.info(__MODULE__, :size) < @session_limit do
      GameStore.guarded(fn -> login(kind, Credentials.digest(token)) end)
      |> case do
        {:ok, _} = authenticated -> authenticated
        _ -> {:error, :not_authorized}
      end
    else
      {:error, :not_authorized}
    end
  end

  defp login(kind, digest) do
    # Compare even on an absent digest row and avoid returning any identity information.
    candidates = Repo.all(from c in BrowserCredential, where: c.kind == ^Atom.to_string(kind))
    record = Enum.find(candidates, &Plug.Crypto.secure_compare(digest, &1.credential_sha256))

    case record do
      %BrowserCredential{enabled: true} ->
        {^kind, game_id, allowed_roles} = browser_scope(record)
        id = Credentials.id("browser_")

        principal = %Principal{
          kind: kind,
          subject_id: record.credential_id,
          auth_epoch: record.auth_epoch,
          game_id: game_id,
          allowed_roles: allowed_roles,
          expires_at_ms: Credentials.audit_ms() + @session_ms,
          browser_session_id: id
        }

        true = :ets.insert_new(__MODULE__, {id, principal})
        {:ok, principal}

      _ ->
        {:error, :not_authorized}
    end
  end
end
