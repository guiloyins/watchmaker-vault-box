files =
  for file <-
        ~w(admission frame_limits mint_transport client box_runtime runner fault_transport scenarios) do
    Path.join(__DIR__, file <> ".exs")
  end

case Kernel.ParallelCompiler.compile(files) do
  {:ok, _modules, []} -> :ok
  {:ok, _modules, _warnings} -> :ok
  {:error, _, _} -> raise "simulator modules did not compile"
end
