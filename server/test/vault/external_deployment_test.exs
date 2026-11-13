defmodule Vault.ExternalDeploymentTest do
  use ExUnit.Case, async: true
  alias Vault.StorageFixture
  @moduletag :m2
  @moduletag timeout: 30_000

  test "guarded HTTPS listener accepts a verified WSS upgrade with no plaintext listener" do
    root = StorageFixture.temp_root()
    tls = Vault.Test.SimulatorFixture.tls(root)
    File.chmod!(tls.key, 0o600)

    source = """
    import ExUnit.Assertions
    alias Mint.{HTTP, WebSocket}
    {:ok, _} = Application.ensure_all_started(:crypto)
    assert {:ok, _} = Vault.Credentials.prepare_test(external_simulator: true)
    Application.put_env(:vault, :simulator_transport, :external)
    Application.put_env(:vault, :origin, "https://localhost:443")
    Application.put_env(:vault, :port, 0)
    Application.put_env(:vault, :bind, {127, 0, 0, 1})
    Application.put_env(:vault, :tls_cert_file, Path.join(root, "test-server.pem"))
    Application.put_env(:vault, :tls_key_file, Path.join(root, "test-server.key"))
    Application.put_env(:vault, VaultWeb.Endpoint, server: true, adapter: Bandit.PhoenixAdapter,
      render_errors: [formats: [html: VaultWeb.ErrorHTML, json: VaultWeb.ErrorJSON], layout: false],
      pubsub_server: Vault.PubSub, live_view: [signing_salt: "vault-test"])
    Logger.configure(level: :critical)
    assert {:ok, _} = Application.ensure_all_started(:vault)
    assert VaultWeb.Endpoint.config(:http) == false
    assert {:ok, {{127, 0, 0, 1}, port}} = VaultWeb.Endpoint.server_info(:https)
    [{:Certificate, ca, :not_encrypted}] = :public_key.pem_decode(File.read!(Path.join(root, "test-ca.pem")))
    assert {:ok, conn} = HTTP.connect(:https, "localhost", port, mode: :passive,
      protocols: [:http1], transport_opts: [cacerts: [ca], verify: :verify_peer, send_timeout: 100])
    {:ok, <<key::binary-size(64), "\\n">>} = Vault.MaintenanceGuard.read_protected(Path.join(root, "cyd-a.key"), 65)
    assert {:ok, conn, ref} = WebSocket.upgrade(:wss, conn, "/device/v1", [{"authorization", "Bearer " <> key}])
    {conn, messages} = Enum.reduce_while(1..4, {conn, []}, fn _, {conn, messages} ->
      assert {:ok, conn, received} = HTTP.recv(conn, 0, 1_000)
      messages = messages ++ received
      if Enum.member?(messages, {:done, ref}), do: {:halt, {conn, messages}}, else: {:cont, {conn, messages}}
    end)
    assert {:status, ref, 101} in messages
    assert {:ok, _} = HTTP.close(conn)
    assert :ok = Application.stop(:vault)
    IO.puts("verified WSS endpoint passed")
    """

    assert {"verified WSS endpoint passed\n", 0} = StorageFixture.vm(root, source)
  end

  test "external setup preserves mode, protects device keys and excludes concurrent box maintenance" do
    root = StorageFixture.temp_root()

    checks = """
    import ExUnit.Assertions
    alias Vault.{Auth, Credentials, Games, MaintenanceGuard}
    {:ok, _} = Application.ensure_all_started(:crypto)
    assert {:ok, paths} = Credentials.prepare_test(external_simulator: true)
    assert paths.simulator_transport == :external
    assert {:ok, _} = Credentials.init(external_simulator: true)
    assert {:error, :simulator_transport_mismatch} = Credentials.init()
    for name <- ~w(box.key cyd-a.key cyd-b.key) do
      assert :ok = MaintenanceGuard.protected_file(Path.join(root, name))
      assert {:ok, <<key::binary-size(64), "\\n">>} = MaintenanceGuard.read_protected(Path.join(root, name), 65)
      assert Credentials.device_key?(key)
    end
    assert {:ok, guard} = MaintenanceGuard.acquire(root, "box-runtime.owner")
    assert {:error, :guard_owned} = Credentials.init(external_simulator: true)
    refute File.exists?(Path.join(root, "vault.owner"))
    assert :ok = MaintenanceGuard.release(guard)

    Application.put_env(:vault, :simulator_transport, :external)
    Application.put_env(:vault, :origin, "http://127.0.0.1:4000")
    Application.put_env(:vault, :port, 4000)
    Application.put_env(:vault, :bind, {127, 0, 0, 1})
    Application.put_env(:vault, VaultWeb.Endpoint, server: false, adapter: Bandit.PhoenixAdapter,
      render_errors: [formats: [html: VaultWeb.ErrorHTML, json: VaultWeb.ErrorJSON], layout: false],
      pubsub_server: Vault.PubSub, live_view: [signing_salt: "vault-test"])
    Logger.configure(level: :warning)
    assert {:ok, _} = Application.ensure_all_started(:vault)
    assert Process.whereis(Vault.SimulatedBox) == nil
    assert {:ok, game} = Games.active_id()
    for {file, expected, roles} <- [{"box.key", :box, []}, {"cyd-a.key", :controller, [:a]}, {"cyd-b.key", :controller, [:b]}] do
      {:ok, <<key::binary-size(64), "\\n">>} = MaintenanceGuard.read_protected(Path.join(root, file), 65)
      assert {:ok, %{principal: principal, device_class: ^expected, game_id: ^game}} = Auth.authenticate_device(key)
      assert principal.allowed_roles == roles
    end
    assert {:ok, guard} = MaintenanceGuard.acquire(root, "box-runtime.owner")
    assert {:error, :guard_owned} = MaintenanceGuard.acquire(root, "box-runtime.owner")
    assert :ok = MaintenanceGuard.release(guard)
    assert :ok = Application.stop(:vault)
    refute File.exists?(Path.join(root, "vault.owner"))
    IO.puts("external deployment passed")
    """

    assert {"external deployment passed\n", 0} = StorageFixture.vm(root, checks)
  end
end
