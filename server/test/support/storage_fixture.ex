defmodule Vault.StorageFixture do
  @moduledoc false

  alias Vault.{Credentials, Repo}

  def temp_root do
    root = Path.join(System.tmp_dir!(), "vault-test-" <> Credentials.id())
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  def task(root, task, args \\ []) do
    source = """
    {:ok, _} = Application.ensure_all_started(:crypto)
    [task | args] = System.argv()
    case {task, args} do
      {"prepare", []} -> Vault.Credentials.prepare_test()
      {"init", []} -> Vault.Credentials.init()
      {"rotate", [file]} -> Vault.Credentials.rotate_host(file)
      {"status", [file]} -> Vault.Credentials.host_status(file)
      {"stop", []} -> Vault.Credentials.stop_simulator(:lost_host_key, "test_operator", "Observed stopped fixture")
      {"device", [file]} -> Vault.Credentials.provision_device("fixture_cyd", "controller", ["b"], file)
    end
    |> case do
      :ok -> IO.puts("ok")
      {:ok, %{active?: active, auth_epoch: epoch}} -> IO.puts("epoch=\#{epoch} active=\#{active}")
      {:ok, %{"status" => status}} -> IO.puts(status)
      {:ok, _} -> IO.puts("ok")
      {:error, reason} when is_atom(reason) -> IO.puts("error=\#{reason}"); System.halt(1)
      _ -> IO.puts("unexpected_result"); System.halt(2)
    end
    """

    vm(root, source, [task | args])
  end

  def vm(root, source, args \\ []) do
    {executable, arguments, env} = command(root, source, args)
    System.cmd(executable, arguments, env: env, stderr_to_stdout: true)
  end

  def command(root, source, args \\ []) do
    build = Path.dirname(Path.dirname(Application.app_dir(:vault, "ebin")))
    paths = Path.join(build, "*/ebin")

    settings = """
    root = System.fetch_env!("VAULT_FIXTURE_ROOT")
    Application.put_env(:vault, :data_dir, root)
    Application.put_env(:vault, :test_root, root)
    Application.put_env(:vault, :test_mode, true)
    Application.put_env(:vault, :box_mode, :simulated)
    """

    env = [{"VAULT_FIXTURE_ROOT", root}, {"ELIXIR_ERL_OPTIONS", "+S 2"}]
    {System.find_executable("elixir"), ["-pa", paths, "-e", settings <> source, "--" | args], env}
  end

  def start_repo(root) do
    {:ok, _} = Application.ensure_all_started(:ecto_sqlite3)
    {:ok, pid} = Repo.start_link([name: nil] ++ Repo.options(Path.join(root, "vault.sqlite3")))
    Repo.put_dynamic_repo(pid)
    pid
  end
end
