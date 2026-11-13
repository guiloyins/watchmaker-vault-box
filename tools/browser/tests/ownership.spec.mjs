import { test, expect } from "../fixtures.mjs";
import { claim, maze, prepareBox, terminal } from "../game_helpers.mjs";

for (const browserRole of ["a", "b"]) {
  test(`M1-05 browser ${browserRole.toUpperCase()} and opposite simulated CYD mirror real assignments`, async ({ vault }) => {
    const deviceRole = browserRole === "a" ? "b" : "a";
    const deviceTerminal = deviceRole.toUpperCase();
    const { page: host, context: hostContext } = await vault.open("host");
    const { page: player } = await vault.open(browserRole);
    await claim(player, browserRole);

    const devicePanel = terminal(host, deviceRole);
    await devicePanel.getByText(`Simulated CYD ${deviceTerminal}`, { exact: true }).click();
    await devicePanel.getByRole("button", { name: "Connect simulated CYD", exact: true }).click();
    await expect(devicePanel.locator("[data-mirror-role]")).toHaveAttribute("data-owner-source", "cyd");
    await expect(devicePanel.locator("[data-control-state]")).toHaveText("Observer");
    await prepareBox(host);
    await host.getByRole("button", { name: "Start game" }).click();
    await expect(maze(player)).toHaveAttribute("data-position", "12");

    const { page: observer, context: observerContext } = await vault.open("host");
    await expect(terminal(observer, deviceRole).locator("[data-mirror-role]")).toHaveAttribute("data-owner-source", "cyd");
    await observerContext.close();
    await expect(host.locator("[data-host-paused]")).toHaveCount(0);

    await devicePanel.getByRole("button", { name: "Take control on this panel" }).click();
    await expect(host.locator("[data-host-paused]")).toBeVisible();
    await expect(devicePanel.locator("[data-control-state]")).toHaveText("Controller");
    await expect(devicePanel.locator("[data-mirror-role]")).toHaveAttribute("data-owner-source", "browser");
    await expect(devicePanel.locator("[data-mirror-role]")).toHaveAttribute("data-held", "false");

    await expect(host.locator("[data-controllers-ready]")).toHaveAttribute("data-controllers-ready", "true");
    await host.getByRole("button", { name: "Arm box" }).click();
    await expect(host.locator("[data-box-readiness]")).toHaveText("Armed");
    await host.getByRole("button", { name: "Resume game" }).click();
    await expect(host.locator("[data-host-paused]")).toHaveCount(0);
    await hostContext.close();
    await expect(player.locator("[data-paused-status]")).toBeVisible();
  });
}

test("M1-05 host A/B controls use distinct bindings and shortcut focus excludes forms", async ({ vault }) => {
  const { page: host } = await vault.open("host");
  await test.step("Claim two independent host panels", async () => {
    await claim(host, "a");
    await claim(host, "b");
  });
  const idA = await terminal(host, "a").getAttribute("data-actor");
  const idB = await terminal(host, "b").getAttribute("data-actor");
  expect(idA).toBeTruthy();
  expect(idB).toBeTruthy();
  expect(idA === idB).toBe(false);

  await test.step("Prepare the box and start the game", async () => {
    await prepareBox(host);
    await host.getByRole("button", { name: "Start game" }).click();
    await expect(terminal(host, "a").locator(".maze-board")).toBeVisible();
  });
  const form = await host.evaluate(() => {
    const form = document.createElement("form");
    const input = document.createElement("input");
    input.id = "focus-probe";
    form.append(input);
    document.querySelector(".host-overview").append(form);
    return "#focus-probe";
  });
  const field = host.locator(form);
  await test.step("Typing in a form does not move the key", async () => {
    await field.focus();
    await host.keyboard.type("wsadqp");
    await expect(field).toHaveValue("wsadqp");
    await expect(terminal(host, "a").locator(".maze-board")).toHaveAttribute("data-position", "12");
  });

  await test.step("Separate host key mappings move the shared key", async () => {
    await field.evaluate((element) => element.blur());
    await host.keyboard.press("w");
    await expect(terminal(host, "b").locator(".maze-board")).toHaveAttribute("data-position", "8");
    await host.keyboard.press("d");
    await expect(terminal(host, "a").locator(".maze-board")).toHaveAttribute("data-position", "9");
  });
});
