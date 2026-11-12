defmodule Vault.MixProject do
  use Mix.Project

  def project do
    if String.to_integer(System.otp_release()) < 27 do
      raise "Vault.JSON requires Erlang/OTP 27 or newer; use the tested .tool-versions"
    end

    [
      app: :vault,
      version: "0.1.0",
      elixir: "~> 1.18.0",
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: Mix.compilers(),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # M0 has no supervision tree. M1 introduces the real application callback.
  def application, do: [extra_applications: [:logger, :crypto]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.8.0"},
      {:phoenix_live_view, "~> 1.2.0"},
      {:phoenix_html, "~> 4.3"},
      {:jason, "~> 1.4"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, "~> 0.26.0"},
      {:exqlite, "~> 0.43.0"},
      {:websock_adapter, "~> 0.5"},
      {:bandit, "~> 1.8"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:mint, "~> 1.7", only: [:dev, :test]},
      {:mint_web_socket, "~> 1.0", only: [:dev, :test]}
    ]
  end
end
