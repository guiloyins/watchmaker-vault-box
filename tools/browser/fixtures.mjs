import { test as base, expect } from "@playwright/test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { chmod, mkdtemp, readFile, realpath, rm } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { once } from "node:events";

const here = dirname(fileURLToPath(import.meta.url));
const repository = resolve(here, "../..");
const mix = process.env.VAULT_BROWSER_MIX || "asdf";

function mixProcess(args, env) {
  const argumentsForMix = mix === "asdf" ? ["exec", "mix", ...args] : args;
  return spawn(mix, argumentsForMix, {
    cwd: join(repository, "server"),
    env,
    stdio: ["pipe", "pipe", "pipe"],
    detached: process.platform !== "win32",
  });
}

function stopGroup(child, signal) {
  try {
    if (process.platform === "win32") child.kill(signal);
    else process.kill(-child.pid, signal);
  } catch (error) {
    if (error.code !== "ESRCH") throw error;
  }
}

async function completed(child, label) {
  child.stdout.resume();
  child.stderr.resume();
  const [code] = await once(child, "exit");
  assert.equal(code, 0, `${label} failed`);
}

async function availablePort() {
  const socket = createServer();
  await new Promise((resolve, reject) => {
    socket.once("error", reject);
    socket.listen(0, "127.0.0.1", resolve);
  });
  const { port } = socket.address();
  await new Promise((resolve) => socket.close(resolve));
  return port;
}

async function start(env) {
  const child = mixProcess(["run", join(here, "server_harness.exs")], env);
  const responses = [];
  child.stderr.resume();
  createInterface({ input: child.stdout }).on("line", (line) => {
    const prefix = "VAULT_HARNESS ";
    if (line.startsWith(prefix)) responses.push(JSON.parse(line.slice(prefix.length)));
  });

  async function response(label) {
    await expect.poll(
      () => {
        if (child.exitCode !== null || child.signalCode !== null) return "process exited";
        return responses.length ? "ready" : "waiting";
      },
      { message: label, timeout: 17_000 },
    ).toBe("ready");
    return responses.shift();
  }

  async function stop() {
    if (child.exitCode !== null || child.signalCode !== null) return;
    const exit = once(child, "exit");
    child.stdin.on("error", () => {});
    child.stdin.end("stop\n");
    const timer = setTimeout(() => stopGroup(child, "SIGTERM"), 4_000);
    const killTimer = setTimeout(() => stopGroup(child, "SIGKILL"), 8_000);
    try {
      await exit;
    } finally {
      clearTimeout(timer);
      clearTimeout(killTimer);
    }
  }

  try {
    const ready = await response("isolated server startup");
    assert.equal(ready.ready, true);
    return {
      gameId: ready.game_id,
      async command(command) {
        child.stdin.write(`${command}\n`);
        return response(command);
      },
      stop,
    };
  } catch (error) {
    await stop();
    throw error;
  }
}

export const test = base.extend({
  vault: async ({ browser }, use) => {
    const testRoot = await realpath(await mkdtemp(join(tmpdir(), "vault-browser-")));
    await chmod(testRoot, 0o700);
    let server;
    const contexts = [];

    try {
      const port = await availablePort();
      const origin = `http://127.0.0.1:${port}`;
      const env = {
        ...process.env,
        MIX_HOME: join(repository, ".cache/mix"),
        HEX_HOME: join(repository, ".cache/hex"),
        ELIXIR_MAKE_CACHE_DIR: join(repository, ".cache/elixir_make"),
        MIX_ENV: "test",
        VAULT_BOX_MODE: "simulated",
        VAULT_SIMULATOR_TRANSPORT: "internal",
        VAULT_TRUSTED_LAN_WS: "false",
        VAULT_TLS_CERT_FILE: undefined,
        VAULT_TLS_KEY_FILE: undefined,
        VAULT_TEST_ROOT: testRoot,
        VAULT_DATA_DIR: testRoot,
        VAULT_DATABASE: join(testRoot, "vault.sqlite3"),
        VAULT_SIMULATOR_DATABASE: join(testRoot, "simulated-box.sqlite3"),
        VAULT_HOST_KEY_FILE: join(testRoot, "host.key"),
        VAULT_SECRET_KEY_BASE_FILE: join(testRoot, "secret-key-base.key"),
        VAULT_BIND: "127.0.0.1",
        VAULT_PORT: String(port),
        VAULT_ORIGIN: origin,
        PHX_SERVER: "true",
        ELIXIR_ERL_OPTIONS: "+S 2",
      };

      await completed(mixProcess(["vault.test.prepare"], env), "isolated store preparation");
      server = await start(env);
      const gameId = server.gameId;
      const gamePath = `/games/${gameId}`;

      async function submitCredential(page, role, credential) {
        const host = role === "host";
        await page.goto(host ? "/login" : "/join");
        const secret = (await readFile(join(testRoot, credential), "utf8")).trim();
        await page.getByLabel(host ? "Host access key" : "Join token").fill(secret);
        await page.getByRole("button", { name: host ? "Sign in" : "Join game" }).click();
      }

      async function login(page, role, credential = `${role === "host" ? "host" : `player-${role}`}.key`) {
        const host = role === "host";
        await submitCredential(page, role, credential);
        await expect(page).toHaveURL(`${origin}${host ? `${gamePath}/host` : `${gamePath}/play/${role}`}`);
        await expect(page.locator(".phx-connected")).toBeVisible();
      }

      async function open(role, configure = () => {}) {
        const context = await browser.newContext({ baseURL: origin, serviceWorkers: "block" });
        contexts.push(context);
        const page = await context.newPage();
        await configure(page);
        if (role) await login(page, role);
        return { context, page };
      }

      await use({
        origin,
        gamePath,
        open,
        login,
        submitCredential,
        command: (command) => server.command(command),
        async rotateHostKey() {
          await server.stop();
          await completed(mixProcess(["vault.host.rotate", "--output", join(testRoot, "rotated.key")], env), "isolated host rotation");
          server = await start(env);
        },
      });
    } finally {
      await Promise.allSettled(contexts.map((context) => context.close()));
      await server?.stop();
      await rm(testRoot, { force: true, recursive: true });
    }
  },
});

export { expect };
