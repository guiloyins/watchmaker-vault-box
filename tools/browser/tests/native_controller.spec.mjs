import { spawn } from "node:child_process";
import { once } from "node:events";
import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { setTimeout as sleep } from "node:timers/promises";
import { ws as WebSocket } from "playwright-core/lib/utilsBundle";
import { test, expect } from "../fixtures.mjs";
import { claim, maze, prepareBox, terminal } from "../game_helpers.mjs";

const runner = process.env.VAULT_NATIVE_CONTROLLER_RUNNER;
const captureDir = process.env.VAULT_NATIVE_CONTROLLER_CAPTURE_DIR;
const route = [
  ["a", "Up", 8], ["b", "Right", 9], ["a", "Up", 5], ["b", "Left", 4],
  ["a", "Up", 0], ["b", "Right", 1], ["b", "Right", 2], ["a", "Down", 6],
  ["a", "Down", 10], ["b", "Right", 11], ["a", "Up", 7], ["a", "Up", null],
];
const displacements = { Up: [0, -42], Down: [0, 42], Left: [-42, 0], Right: [42, 0] };

function bridge(vault, role, bearer) {
  const child = spawn(runner, [`native_cyd_${role}`, `boot_native_${role}`, role], {
    stdio: ["pipe", "pipe", "pipe"],
  });
  let socket;
  let state;
  let fault;
  let lastSvg;
  let lastWelcome;
  let closeCode;
  let moves = 0;
  let presses = 0;
  let lastPressId = 0;
  let nativeErrors = false;
  function write(line) {
    if (child.exitCode === null && !child.stdin.destroyed) child.stdin.write(`${line}\n`);
  }
  child.on("error", () => { fault = "native process start failed"; });
  child.stdin.on("error", () => { fault = "native stdin failed"; });
  child.stderr.on("data", () => { nativeErrors = true; });
  createInterface({ input: child.stdout }).on("line", (line) => {
    if (line.startsWith("WIRE ")) {
      const bytes = line.slice(5);
      const envelope = JSON.parse(bytes);
      if (envelope.action === "move") ++moves;
      if (envelope.type === "heartbeat" && envelope.input?.pressed) {
        if (envelope.input.press_id !== lastPressId) ++presses;
        lastPressId = envelope.input.press_id;
      }
      if (socket?.readyState === WebSocket.OPEN) socket.send(bytes);
    } else if (line.startsWith("STATE ")) state = JSON.parse(line.slice(6));
    else if (line.startsWith("SVG ")) lastSvg = line.slice(4);
    else if (line === "CLOSE") socket?.close();
    else fault = "unknown native output";
  });
  const timer = setInterval(() => write("tick"), 20);

  async function wait(predicate, message) {
    await expect.poll(() => {
      if (fault || nativeErrors || child.exitCode !== null) return false;
      return !!state && !!predicate(state);
    }, { message }).toBe(true);
  }

  async function connect() {
    const endpoint = new URL("/device/v1", vault.origin);
    endpoint.protocol = "ws:";
    const ws = new WebSocket(endpoint, { headers: { Authorization: `Bearer ${bearer}` } });
    socket = ws;
    ws.on("error", () => { fault = "device websocket failed"; });
    ws.on("open", () => write("open"));
    ws.on("message", (raw, binary) => {
      if (socket !== ws || binary) return;
      const text = raw.toString("utf8");
      const parsed = JSON.parse(text);
      if (parsed.type === "welcome") lastWelcome = parsed;
      write(`recv ${text}`);
    });
    ws.on("close", (code) => {
      if (socket !== ws) return;
      closeCode = code;
      write("close");
    });
    await wait((s) => s.online && s.role === "-", "native hello/welcome and public snapshot");
  }

  async function sample(x, y) {
    write(`down ${x} ${y}`);
    await sleep(80);
  }
  async function lift() {
    write("released");
    await sleep(105);
  }

  return {
    connect, lift, sample, wait,
    get moves() { return moves; },
    get presses() { return presses; },
    get session() { return lastWelcome?.session_id; },
    get closeCode() { return closeCode; },
    async claim() {
      await wait((s) => s.claimable_roles & (role === "a" ? 1 : 2), "authorized role awaits explicit claim");
      write("claim");
      await wait((s) => s.online && s.role === role, "native role claim and private snapshot");
    },
    async swipe(direction) {
      const [dx, dy] = displacements[direction];
      await sample(120, 170);
      await sample(120 + dx, 170 + dy);
      await lift();
    },
    async capture(name) {
      if (!captureDir) return;
      lastSvg = undefined;
      write("frame");
      await wait(() => lastSvg, "portable panel rendered");
      await mkdir(captureDir, { recursive: true });
      await writeFile(join(captureDir, name + ".svg"), lastSvg);
    },
    async stop() {
      clearInterval(timer);
      socket?.terminate();
      if (child.exitCode !== null || child.signalCode !== null) return;
      const exit = once(child, "exit");
      const kill = setTimeout(() => child.kill("SIGKILL"), 1000);
      child.stdin.end();
      try { await exit; } finally { clearTimeout(kill); }
    },
  };
}

async function native(vault, role, clients) {
  const client = bridge(vault, role, await vault.nativeControllerKey(role));
  clients.set(role, client);
  await client.connect();
  await client.claim();
  return client;
}

for (const scenario of ["a", "b", "both"]) {
  test(`M3 native CYD core over /device/v1: ${scenario}`, async ({ vault }) => {
    test.skip(!runner, "VAULT_NATIVE_CONTROLLER_RUNNER is not set");
    const clients = new Map();
    const browserRole = scenario === "both" ? null : scenario === "a" ? "b" : "a";
    const browser = browserRole ? (await vault.open(browserRole)).page : null;
    const host = (await vault.open("host")).page;
    try {
      if (browser) await claim(browser, browserRole);
      for (const role of ["a", "b"]) {
        if (role === browserRole) continue;
        await native(vault, role, clients);
        await expect(terminal(host, role).locator("[data-mirror-role]")).toHaveAttribute("data-owner-source", "cyd");
      }
      await prepareBox(host);
      await host.getByRole("button", { name: "Start game" }).click();
      for (const [role, client] of clients) {
        await client.wait((s) => s.phase === "maze" && s.position === 12 && s.play_enabled, "first maze projection");
        if (scenario !== "both") await client.capture(`cyd-${role}-maze`);
      }
      const [firstRole, firstClient] = clients.entries().next().value;
      const badAxis = firstRole === "a" ? "Right" : "Up";
      await firstClient.swipe(badAxis);
      expect(firstClient.moves).toBe(0);
      await expect(maze(terminal(host, "a"))).toHaveAttribute("data-position", "12");

      for (const [role, direction, position] of route) {
        const client = clients.get(role);
        if (client) {
          await client.wait((s) => s.play_enabled, "ready for next physical contact");
          const before = client.moves;
          await client.swipe(direction);
          expect(client.moves).toBe(before + 1);
        } else {
          await browser.getByRole("button", { name: direction, exact: true }).click();
        }
        if (position !== null) {
          await expect(maze(terminal(host, "a"))).toHaveAttribute("data-position", String(position));
          for (const [, client] of clients) {
            await client.wait((s) => s.position === position, "native mirrors accepted maze position");
          }
        }
      }

      for (const [role, client] of clients) {
        await client.wait((s) => s.phase === "seal" && s.play_enabled && !s.selected, "role-safe seal projection");
        if (scenario !== "both") await client.capture(`cyd-${role}-seal`);
        await client.sample(role === "a" ? 60 : 170, 120);
        await client.lift();
        await client.wait((s) => s.selected === (role === "a" ? 1 : 2), "native rune tap accepted");
        await client.wait((s) => s.hold_enabled, "fresh neutral sample acknowledged after selecting rune");
      }
      if (browser) {
        const name = browserRole === "a" ? "Star" : "Moon";
        await browser.getByRole("button", { name, exact: true }).click();
        await expect(browser.locator(".terminal")).toHaveAttribute("data-selection", name.toLowerCase());
      }
      if (scenario === "both") {
        await Promise.all([...clients.values()].map((client) => client.sample(110, 267)));
        for (const [, client] of clients) {
          await client.wait((s) => s.local_hold, "dedicated hold detected on native terminal");
        }
        await expect(host.locator("[data-host-phase]")).toHaveAttribute("data-host-phase", "solved");
        for (const [, client] of clients) {
          await client.wait((s) => s.phase === "solved" && s.qualified, "server-authoritative shared hold");
          await client.lift();
        }
        await expect.poll(async () => (await vault.command("outcomes")).outcomes.length).toBe(1);
      } else {
        await firstClient.sample(110, 267);
        await expect(terminal(host, firstRole).locator("[data-mirror-role]")).toHaveAttribute("data-held", "true");
        const oldSession = firstClient.session;
        const oldPresses = firstClient.presses;
        const oldMoves = firstClient.moves;
        await host.getByRole("button", { name: "Reset puzzle" }).click();
        await firstClient.wait((s) => !s.online && !s.local_hold, "reset retires current hold and socket");
        expect(firstClient.closeCode).toBe(4003);
        if (scenario === "a") await firstClient.capture("cyd-a-offline");
        await firstClient.connect();
        expect(firstClient.session).not.toBe(oldSession);
        await firstClient.claim();
        await sleep(300);  // The fake finger remains down across the socket replacement.
        expect(firstClient.presses).toBe(oldPresses);
        expect(firstClient.moves).toBe(oldMoves);
        await firstClient.lift();
        await expect(terminal(host, firstRole).locator("[data-mirror-role]")).toHaveAttribute("data-held", "false");
      }
    } finally {
      await Promise.all([...clients.values()].map((client) => client.stop()));
    }
  });
}
