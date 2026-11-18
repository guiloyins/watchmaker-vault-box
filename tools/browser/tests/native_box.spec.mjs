import { spawn } from "node:child_process";
import { once } from "node:events";
import { createInterface } from "node:readline";
import { ws as WebSocket } from "playwright-core/lib/utilsBundle";
import { test, expect } from "../fixtures.mjs";
import { claim, chooseRunes, followGoldenRoute, neutralThenPointerHold } from "../game_helpers.mjs";

const runner = process.env.VAULT_NATIVE_BOX_RUNNER;
test.use({ vaultBoxMode: "physical" });
test.skip(!runner, "VAULT_NATIVE_BOX_RUNNER is not set");

async function bridge(vault) {
  const bearer = await vault.nativeBoxKey();
  const child = spawn(runner, ["native_box", "boot_native_box"], { stdio: ["pipe", "pipe", "pipe"] });
  let socket;
  let fault = false;
  let state;
  let reopened = false;
  let lostAck = false;
  let lostSeq;
  const terminalReports = [];
  const queries = [];
  const commands = [];
  const feedback = [];

  function write(line) {
    if (child.exitCode === null && !child.stdin.destroyed) child.stdin.write(`${line}\n`);
  }

  child.on("error", () => { fault = true; });
  child.stdin.on("error", () => { fault = true; });
  child.stderr.on("data", () => { fault = true; });
  createInterface({ input: child.stdout }).on("line", (line) => {
    if (line.startsWith("WIRE ")) {
      const raw = line.slice(5);
      const message = JSON.parse(raw);
      if (message.release_status === "motion_complete") {
        terminalReports.push(raw);
        if (!reopened && lostSeq === undefined) lostSeq = message.status_seq;
      }
      if (socket?.readyState === WebSocket.OPEN) socket.send(raw);
    } else if (line.startsWith("STATE ")) {
      state = JSON.parse(line.slice(6));
    } else if (line === "CLOSE") {
      socket?.close();
    } else {
      fault = true;
    }
  });
  const timer = setInterval(() => write("tick"), 10);

  async function waitState(predicate, message) {
    await expect.poll(() => {
      if (fault || child.exitCode !== null) return false;
      write("state");
      return Boolean(state && predicate(state));
    }, { message }).toBe(true);
  }

  async function connect() {
    const endpoint = new URL("/device/v1", vault.origin);
    endpoint.protocol = "ws:";
    const peer = new WebSocket(endpoint, { headers: { Authorization: `Bearer ${bearer}` } });
    socket = peer;
    peer.on("error", () => { fault = true; });
    peer.on("open", () => write("open"));
    peer.on("message", (bytes, binary) => {
      if (binary || socket !== peer) return;
      const text = bytes.toString("utf8");
      const message = JSON.parse(text);
      if (message.type === "box_command") commands.push(message);
      if (message.type === "box_query") queries.push(message);
      if (message.type === "box_feedback") feedback.push(message);
      if (!lostAck && message.type === "box_status_ack" && message.status_seq === lostSeq) {
        lostAck = true;
        return;
      }
      write(`recv ${text}`);
    });
    peer.on("close", () => {
      if (socket === peer) write("close");
    });
    await waitState((view) => view.connected, "Native hello and server welcome established a binding");
  }

  return {
    connect, terminalReports, queries, commands, feedback, waitState,
    prepare() { write("prepare"); },
    async reconnect() {
      const closed = once(socket, "close");
      socket.close();
      await closed;
      await waitState((view) => !view.connected && !view.energized, "Closed generation stopped the native box");
      reopened = true;
      await connect();
    },
    async stop() {
      clearInterval(timer);
      socket?.terminate();
      if (child.exitCode !== null || child.signalCode !== null) return;
      const exited = once(child, "exit");
      const kill = setTimeout(() => child.kill("SIGKILL"), 1000);
      child.stdin.end();
      try { await exited; } finally { clearTimeout(kill); }
    },
  };
}

test("M4 native box over raw WebSocket releases once and answers reconnect history", async ({ vault }) => {
  const host = (await vault.open("host")).page;
  const a = (await vault.open("a")).page;
  const b = (await vault.open("b")).page;
  const box = await bridge(vault);
  const readiness = host.locator("[data-box-readiness]");
  const outcome = host.locator('[aria-labelledby="vault-status-title"] [data-release-status]');
  try {
    await claim(a, "a");
    await claim(b, "b");
    await box.connect();
    await expect(readiness).toHaveText("Setup required");
    await expect(host.getByRole("button", { name: "Arm box" })).toBeDisabled();
    box.prepare();
    await expect(readiness).toHaveText("Ready to arm");
    await expect(host.getByText("Manual verified", { exact: true })).toBeVisible();
    await expect(host.getByText("Simulated box", { exact: true })).toHaveCount(0);
    await expect(host.locator("[data-controllers-ready]")).toHaveAttribute("data-controllers-ready", "true");
    await host.getByRole("button", { name: "Arm box" }).click();
    await expect(readiness).toHaveText("Armed");
    await box.waitState((view) => view.steps === 0 && view.entries === 0, "Arming alone never takes a step");
    await host.getByRole("button", { name: "Start game" }).click();
    await followGoldenRoute({ a, b });
    await chooseRunes(a, b);
    await neutralThenPointerHold(a);
    await neutralThenPointerHold(b);
    await expect(outcome).toHaveAttribute("data-release-status", "motion_complete");
    await Promise.all([a.mouse.up(), b.mouse.up()]);
    await box.waitState((view) => view.steps === 8 && view.entries === 1 && !view.energized,
      "One bounded fake stroke committed one native journal entry");
    await expect.poll(() => box.terminalReports.length).toBe(2);
    expect(box.terminalReports[1]).toBe(box.terminalReports[0]);
    expect(box.commands).toHaveLength(1);
    const commandId = box.commands[0].command_id;
    const first = JSON.parse(box.terminalReports[0]);
    expect(first.command_confirmation).toBeNull();
    expect(first.latch_position).toBe("unknown");
    expect(box.feedback.some((packet) => packet.light_mode === "progress" && packet.progress_percent > 0)).toBe(true);
    const cues = box.feedback.filter((packet) => packet.sound === "success");
    expect(cues).toHaveLength(1);
    expect(cues[0].light_mode).toBe("success");
    expect(cues[0]).not.toHaveProperty("action");
    const persisted = (await vault.command("outcomes")).outcomes;
    expect(persisted).toHaveLength(1);
    expect(persisted[0].command_id).toBe(commandId);
    expect(persisted[0].dispatch_claimed).toBe(true);

    await box.reconnect();
    await expect.poll(() => box.queries.some((query) => query.command_id === commandId &&
      query.connection_id !== first.connection_id)).toBe(true);
    await expect.poll(() => box.terminalReports.length).toBe(3);
    const replay = JSON.parse(box.terminalReports[2]);
    expect(replay.connection_id).not.toBe(first.connection_id);
    expect(replay.command_session_id).toBe(first.command_session_id);
    expect(replay.readiness.arm_id).toBeNull();
    await expect.poll(() => box.feedback.some((packet) => packet.connection_id === replay.connection_id)).toBe(true);
    const reboundFeedback = box.feedback.find((packet) => packet.connection_id === replay.connection_id);
    expect(reboundFeedback).toMatchObject({ light_mode: "success", sound: "none", feedback_seq: 1 });
    expect(box.commands).toHaveLength(1);
    await box.waitState((view) => view.entries === 1 && view.steps === 8 && !view.energized,
      "Reconnection queries the original command without another stroke");
  } finally {
    await box.stop();
  }
});
