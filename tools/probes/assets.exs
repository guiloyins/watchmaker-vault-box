# Compile throwaway entries with the pinned executable, before M1 assets exist.
root = Path.join(System.tmp_dir!(), "vault-assets-probe-#{System.unique_integer([:positive])}")
File.mkdir_p!(root)

try do
  File.write!(Path.join(root, "probe.js"), "export const answer = 6 * 7;\n")
  File.write!(Path.join(root, "probe.css"), "body { color: #123456; }\n")
  {version, 0} = System.cmd(Esbuild.bin_path(), ["--version"])
  "0.25.12" = String.trim(version)
  {output, 0} = System.cmd(Esbuild.bin_path(), ["probe.js", "probe.css", "--bundle", "--outdir=out", "--metafile=meta.json"], cd: root, stderr_to_stdout: true)
  true = File.regular?(Path.join(root, "out/probe.js"))
  true = File.regular?(Path.join(root, "out/probe.css"))
  true = File.regular?(Path.join(root, "meta.json"))
  IO.puts(Jason.encode!(%{result: "passed", esbuild: String.trim(version), entries: ["JS", "CSS"], metadata: true, output: output, evidence: "throwaway toolchain entries; no game assets or deploy alias"}))
after
  File.rm_rf!(root)
end
