import { expect } from "./fixtures.mjs";

export const terminal = (page, role) => page.locator(`#terminal-${role}`);
export const maze = (page) => page.locator(".maze-board");
export const hostPhase = (page) => page.locator("[data-host-phase]");
export const sharedProgress = (page) => page.locator("[data-progress]");

export async function claim(page, role) {
  const panel = terminal(page, role);
  await panel.getByRole("button", { name: "Request control" }).click();
  await expect(panel.locator("[data-control-state]")).toHaveText("Controller");
}

export async function prepareBox(page) {
  await page.getByRole("button", { name: "Prepare simulated reference" }).click();
  await expect(page.locator("[data-box-readiness]")).toHaveText("Exit service required");
  await expect(page.getByRole("button", { name: "Arm box" })).toBeDisabled();
  await page.getByRole("button", { name: "Exit simulated service" }).click();
  await expect(page.locator("[data-box-readiness]")).toHaveText("Ready to arm");
  await expect(page.locator("[data-controllers-ready]")).toHaveAttribute("data-controllers-ready", "true");
  await page.getByRole("button", { name: "Arm box" }).click();
  try {
    await expect(page.locator("[data-box-readiness]")).toHaveText("Armed");
  } catch (error) {
    const feedback = await page.locator("[data-operator-feedback]").textContent({ timeout: 1_000 }).catch(() => null);
    const classifications = new Map([
      ["Operation accepted.", "accepted_without_armed_status"],
      ["Operation declined. Not ready.", "not_ready"],
      ["Operation declined. Stale session.", "stale_session"],
      ["Operation declined. Unresolved release.", "unresolved_release"],
      ["Operation declined. Storage error.", "storage_error"],
    ]);
    throw new Error(`vault_arm:${classifications.get(feedback?.trim()) || "unclassified"}`, { cause: error });
  }
}

export async function prepareTwoPlayers(vault) {
  const host = (await vault.open("host")).page;
  const a = await vault.open("a");
  const b = await vault.open("b");
  await expect(host.getByRole("button", { name: "Start game" })).toBeDisabled();
  await claim(a.page, "a");
  await claim(b.page, "b");
  await prepareBox(host);
  await host.getByRole("button", { name: "Start game" }).click();
  await expect(maze(a.page)).toHaveAttribute("data-position", "12");
  await expect(maze(b.page)).toHaveAttribute("data-position", "12");
  return { host, a: a.page, b: b.page, contextA: a.context, contextB: b.context };
}

export async function followGoldenRoute({ a, b, controls = { a, b } }, initialBoard = 0) {
  const route = [
    ["a", "Up", 8], ["b", "Right", 9], ["a", "Up", 5], ["b", "Left", 4],
    ["a", "Up", 0], ["b", "Right", 1], ["b", "Right", 2], ["a", "Down", 6],
    ["a", "Down", 10], ["b", "Right", 11], ["a", "Up", 7], ["a", "Up", null],
  ];

  for (const [index, [role, direction, target]] of route.entries()) {
    await controls[role].getByRole("button", { name: direction, exact: true }).click();
    if (target !== null) {
      for (const observer of [a, b]) {
        await expect(maze(observer)).toHaveAttribute("data-position", String(target));
        await expect(observer.locator(".terminal")).toHaveAttribute("data-board", String(initialBoard + index + 1));
      }
    } else {
      await expect(a.locator("[data-clue]")).toHaveText("Tell B: hold MOON");
      await expect(b.locator("[data-clue]")).toHaveText("Tell A: hold STAR");
    }
  }
}

export async function chooseRunes(a, b, runeA = "Star", runeB = "Moon") {
  await a.getByRole("button", { name: runeA, exact: true }).click();
  await b.getByRole("button", { name: runeB, exact: true }).click();
  await expect(a.locator(".terminal")).toHaveAttribute("data-selection", runeA.toLowerCase());
  await expect(b.locator(".terminal")).toHaveAttribute("data-selection", runeB.toLowerCase());
}

export async function neutralThenPointerHold(page) {
  await expect(page.getByRole("button", { name: "Hold seal" })).toBeEnabled();
  await expect(page.locator(".terminal")).toHaveAttribute("data-neutral", "true");
  const hold = page.getByRole("button", { name: "Hold seal" });
  await hold.scrollIntoViewIfNeeded();
  const position = await hold.boundingBox();
  await page.mouse.move(position.x + position.width / 2, position.y + position.height / 2);
  await page.mouse.down();
  await expect(page.locator(".terminal")).toHaveAttribute("data-local-held", "true");
}
