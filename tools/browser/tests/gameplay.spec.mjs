import { test, expect } from "../fixtures.mjs";
import {
  chooseRunes, claim, followGoldenRoute, hostPhase, maze, neutralThenPointerHold,
  prepareTwoPlayers, sharedProgress, terminal,
} from "../game_helpers.mjs";

test("M1-01 isolated views reload into one game and the box is simulated", async ({ vault }) => {
  const game = await prepareTwoPlayers(vault);
  const { host, a, b } = game;
  await expect(host.getByText("Simulated box", { exact: true })).toBeVisible();

  await a.getByRole("button", { name: "Up", exact: true }).click();
  for (const page of [a, b]) await expect(maze(page)).toHaveAttribute("data-position", "8");

  const session = await terminal(a, "a").getAttribute("data-session");
  await a.reload();
  await expect(maze(a)).toHaveAttribute("data-position", "8");
  await expect(terminal(a, "a")).toHaveAttribute("data-session", session);
  await expect(terminal(a, "a").locator("[data-control-state]")).toHaveText("Observer");
  await expect(host.locator("[data-host-paused]")).toBeVisible();
  await b.reload();
  await host.reload();
  for (const role of ["a", "b"]) {
    await expect(terminal(host, role).locator(".maze-board")).toHaveAttribute("data-position", "8");
  }
  await claim(a, "a");
  await claim(b, "b");
  await host.getByRole("button", { name: "Arm box" }).click();
  await host.getByRole("button", { name: "Resume game" }).click();
  await expect(host.locator("[data-host-paused]")).toHaveCount(0);
  expect((await vault.command("outcomes")).outcomes).toEqual([]);
});

test("M1-02 movement is accepted once per decision and wall/bounds preserve the board", async ({ vault }) => {
  const game = await prepareTwoPlayers(vault);
  const { a, b, host } = game;
  await a.getByRole("button", { name: "Down", exact: true }).click();
  await expect(a.locator("[data-action-status]")).toHaveText("That move leaves the maze.");
  await b.getByRole("button", { name: "Right", exact: true }).click();
  await expect(b.locator("[data-action-status]")).toHaveText("A wall blocks that move.");
  await expect(maze(a)).toHaveAttribute("data-position", "12");
  await expect(terminal(a, "a")).toHaveAttribute("data-board", "0");

  await a.keyboard.down("ArrowUp");
  await expect(maze(a)).toHaveAttribute("data-position", "8");
  await a.keyboard.down("ArrowUp");
  await a.keyboard.up("ArrowUp");
  await expect(terminal(a, "a")).toHaveAttribute("data-board", "1");

  await a.getByRole("button", { name: "Down", exact: true }).click();
  await expect(maze(a)).toHaveAttribute("data-position", "12");
  const boardStart = Number(await terminal(a, "a").getAttribute("data-board"));
  await followGoldenRoute(game, boardStart);
  await expect(hostPhase(host)).toHaveText("Final seal");
  expect((await vault.command("outcomes")).outcomes).toEqual([]);
});

test("M1-06 correct fresh overlap qualifies once and only the simulated mechanism moves", async ({ vault }) => {
  const game = await prepareTwoPlayers(vault);
  const { host, a, b } = game;
  await followGoldenRoute(game);
  await expect(a.locator("[data-selection]")).toHaveCount(0);
  await expect(b.locator("[data-selection]")).toHaveCount(0);

  await chooseRunes(a, b, "Sun", "Moon");
  await neutralThenPointerHold(a);
  await expect(b.locator("[data-peer-held]")).toHaveAttribute("data-peer-held", "true");
  await neutralThenPointerHold(b);
  await expect(a.locator("[data-peer-held]")).toHaveAttribute("data-peer-held", "true");
  await expect(sharedProgress(a)).toHaveAttribute("data-active", "false");
  await a.mouse.up();
  await b.mouse.up();
  expect((await vault.command("outcomes")).outcomes).toEqual([]);

  await chooseRunes(a, b);
  await host.getByRole("button", { name: "Pause game" }).click();
  await expect(a.getByRole("button", { name: "Star", exact: true })).toHaveAttribute("aria-pressed", "true");
  await expect(a.getByRole("button", { name: "Hold seal" })).toBeDisabled();
  await expect(sharedProgress(a)).toHaveAttribute("data-active", "false");
  await host.getByRole("button", { name: "Arm box" }).click();
  await host.getByRole("button", { name: "Resume game" }).click();

  await neutralThenPointerHold(a);
  await expect(b.locator("[data-peer-held]")).toHaveAttribute("data-peer-held", "true");
  await neutralThenPointerHold(b);
  await expect(sharedProgress(a)).toHaveAttribute("data-active", "true");
  await expect(a.getByRole("heading", { name: "Puzzle solved" })).toBeVisible({ timeout: 5_000 });
  await a.mouse.up();
  await b.mouse.up();

  await expect(host.getByText("Simulated motion complete", { exact: true }).first()).toBeVisible();
  const { outcomes } = await vault.command("outcomes");
  expect(outcomes).toHaveLength(1);
  expect(outcomes[0].dispatch_claimed).toBe(true);
});
