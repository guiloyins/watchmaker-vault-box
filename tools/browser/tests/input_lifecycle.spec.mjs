import { writeFile } from "node:fs/promises";
import { join } from "node:path";
import { test, expect } from "../fixtures.mjs";
import {
  chooseRunes, claim, followGoldenRoute, neutralThenPointerHold, prepareTwoPlayers,
  sharedProgress, terminal,
} from "../game_helpers.mjs";

async function enterSeal(vault) {
  const game = await prepareTwoPlayers(vault);
  await followGoldenRoute(game);
  await chooseRunes(game.a, game.b);
  return game;
}

async function watchLifecycle(page) {
  await page.evaluate(() => {
    window.vaultLifecycleProbe = [];
    for (const type of ["pointercancel", "lostpointercapture", "blur", "pagehide", "visibilitychange"]) {
      const target = type === "visibilitychange" ? document : window;
      target.addEventListener(type, (event) => {
        window.vaultLifecycleProbe.push({
          type,
          trusted: event.isTrusted,
          visibility: document.visibilityState,
        });
      }, { capture: true });
    }
  });
}

async function nativeEvent(page, type, visibility) {
  await expect.poll(() => page.evaluate(({ type, visibility }) =>
    window.vaultLifecycleProbe.some((event) =>
      event.type === type && event.trusted && (!visibility || event.visibility === visibility)),
  { type, visibility }), { message: `native ${type} observed` }).toBe(true);
}

async function assertCleared(page, partner) {
  await expect(page.locator(".terminal")).not.toHaveAttribute("data-local-held", "true");
  await expect(partner.locator("[data-peer-held]")).toHaveAttribute("data-peer-held", "false");
  await expect(sharedProgress(partner)).toHaveAttribute("data-active", "false");
}

test("M1-07 native pointer release and lost capture stop the shared hold", async ({ vault }) => {
  const { a, b } = await enterSeal(vault);
  await watchLifecycle(a);
  await neutralThenPointerHold(a);
  await expect(b.locator("[data-peer-held]")).toHaveAttribute("data-peer-held", "true");
  await neutralThenPointerHold(b);
  await expect(sharedProgress(b)).toHaveAttribute("data-active", "true");
  await a.mouse.up();
  await nativeEvent(a, "lostpointercapture");
  await assertCleared(a, b);
  await b.mouse.up();

  await neutralThenPointerHold(a);
  await expect(b.locator("[data-peer-held]")).toHaveAttribute("data-peer-held", "true");
  await a.mouse.move(0, 0);
  await a.mouse.up();
  await assertCleared(a, b);
  expect((await vault.command("outcomes")).outcomes).toEqual([]);
});

test("M1-07 trusted touch cancel clears capture and requires a new contact", async ({ vault }) => {
  const { a, b, contextA } = await enterSeal(vault);
  await watchLifecycle(a);
  await expect(a.locator(".terminal")).toHaveAttribute("data-neutral", "true");
  const devtools = await contextA.newCDPSession(a);
  await devtools.send("Emulation.setTouchEmulationEnabled", { enabled: true, maxTouchPoints: 1 });
  const hold = a.getByRole("button", { name: "Hold seal" });
  await hold.scrollIntoViewIfNeeded();
  const box = await hold.boundingBox();
  const point = { x: box.x + box.width / 2, y: box.y + box.height / 2 };
  await devtools.send("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: [point] });
  await expect(a.locator(".terminal")).toHaveAttribute("data-local-held", "true");
  await expect(b.locator("[data-peer-held]")).toHaveAttribute("data-peer-held", "true");
  await devtools.send("Input.dispatchTouchEvent", { type: "touchCancel", touchPoints: [] });
  await nativeEvent(a, "pointercancel");
  await assertCleared(a, b);

  await expect(a.locator(".terminal")).toHaveAttribute("data-neutral", "true");
  await devtools.send("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: [point] });
  await expect(b.locator("[data-peer-held]")).toHaveAttribute("data-peer-held", "true");
  await devtools.send("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: [] });
  await assertCleared(a, b);
  expect((await vault.command("outcomes")).outcomes).toEqual([]);
});

test("M1-07 native navigation and socket loss clear control; reload needs a fresh press", async ({ vault }) => {
  const { host, a, b, contextA } = await enterSeal(vault);
  await neutralThenPointerHold(a);
  await expect(b.locator("[data-peer-held]")).toHaveAttribute("data-peer-held", "true");
  await a.goto("/join");
  await expect(b.locator("[data-paused-status]")).toBeVisible();
  await expect(b.locator("[data-peer-held]")).toHaveAttribute("data-peer-held", "false");
  await a.mouse.up();

  await a.goto(`${vault.gamePath}/play/a`);
  await claim(a, "a");
  await expect(a.getByRole("button", { name: "Star", exact: true })).toHaveAttribute("aria-pressed", "true");
  await host.getByRole("button", { name: "Arm box" }).click();
  await host.getByRole("button", { name: "Resume game" }).click();
  await expect(a.getByRole("button", { name: "Hold seal" })).toBeEnabled();
  await expect(b.locator("[data-peer-held]")).toHaveAttribute("data-peer-held", "false");

  await neutralThenPointerHold(a);
  await expect(b.locator("[data-peer-held]")).toHaveAttribute("data-peer-held", "true");
  await contextA.setOffline(true);
  await expect(b.locator("[data-paused-status]")).toBeVisible({ timeout: 4_000 });
  await expect(b.locator("[data-peer-held]")).toHaveAttribute("data-peer-held", "false");
  await contextA.setOffline(false);
  await a.mouse.up();
  await a.reload();
  await expect(terminal(a, "a").locator("[data-control-state]")).toHaveText("Observer");
  await expect(a.locator(".terminal")).not.toHaveAttribute("data-local-held", "true");
  expect((await vault.command("outcomes")).outcomes).toEqual([]);
});

test("M1-07 trusted headed tab blur clears active input", async ({ vault }) => {
  test.skip(!process.env.VAULT_HEADED, "Requires a headed Chromium window.");
  const { a, b, contextA } = await enterSeal(vault);
  const adjacentTab = await contextA.newPage();
  await adjacentTab.goto("/join");
  await a.bringToFront();
  await watchLifecycle(a);
  await neutralThenPointerHold(a);
  await expect(b.locator("[data-peer-held]")).toHaveAttribute("data-peer-held", "true");
  const probe = await contextA.newCDPSession(a);
  await probe.send("Emulation.setFocusEmulationEnabled", { enabled: false });
  await adjacentTab.bringToFront();
  await nativeEvent(a, "blur");
  await assertCleared(a, b);
  await a.bringToFront();
  await a.mouse.up();
  await expect(a.locator(".terminal")).not.toHaveAttribute("data-local-held", "true");
  expect((await vault.command("outcomes")).outcomes).toEqual([]);
});

test("M1-07 trusted hidden tab clears active input", async ({ vault }, testInfo) => {
  test.skip(!process.env.VAULT_HEADED, "Requires a headed Chromium window.");
  const { a, b, contextA } = await enterSeal(vault);
  const adjacentTab = await contextA.newPage();
  await adjacentTab.goto("/join");
  await a.bringToFront();
  await watchLifecycle(a);

  const cdp = await contextA.newCDPSession(a);
  await cdp.send("Emulation.setFocusEmulationEnabled", { enabled: false });
  const { windowId } = await cdp.send("Browser.getWindowForTarget");

  const manualDirectory = process.env.VAULT_BROWSER_MANUAL_DIR;
  if (manualDirectory) {
    const hold = a.getByRole("button", { name: "Hold seal" });
    await expect(a.locator(".terminal")).toHaveAttribute("data-neutral", "true");
    await hold.scrollIntoViewIfNeeded();
    const position = await hold.boundingBox();
    await a.mouse.move(position.x + position.width / 2, position.y + position.height / 2);
    await a.mouse.down();
    await expect(b.locator("[data-peer-held]")).toHaveAttribute("data-peer-held", "true");
    await writeFile(join(manualDirectory, "ready"), a.url() + "\n", { flag: "wx", mode: 0o600 });
    await expect.poll(() => a.evaluate(() => window.vaultLifecycleProbe.some((event) =>
      event.type === "visibilitychange" && event.trusted && event.visibility === "hidden")),
    { timeout: 180_000, message: "Observe a trusted hidden tab after a manual window/tab change" }).toBe(true);
    await assertCleared(a, b);
    await a.mouse.up();
    return;
  }

  await neutralThenPointerHold(a);
  await expect(b.locator("[data-peer-held]")).toHaveAttribute("data-peer-held", "true");
  await adjacentTab.bringToFront();

  const hidden = () => a.evaluate(() => window.vaultLifecycleProbe.some((event) =>
    event.type === "visibilitychange" && event.trusted && event.visibility === "hidden"));
  let observed = await hidden();
  if (!observed) {
    await a.bringToFront();
    await a.mouse.up();
    await neutralThenPointerHold(a);
    await expect(b.locator("[data-peer-held]")).toHaveAttribute("data-peer-held", "true");
    await cdp.send("Browser.setWindowBounds", { windowId, bounds: { windowState: "minimized" } });
    try {
      await expect.poll(hidden, { timeout: 1_000 }).toBe(true);
      observed = true;
    } catch {
      observed = false;
    } finally {
      await cdp.send("Browser.setWindowBounds", { windowId, bounds: { windowState: "normal" } });
    }
  }

  if (!observed) {
    testInfo.annotations.push({ type: "native_blocked", description: "Chromium did not expose a hidden document after tab activation or window minimization." });
    test.skip(true, "The runner exposed blur but kept document visibility visible.");
  }
  await assertCleared(a, b);
  await a.mouse.up();
});
