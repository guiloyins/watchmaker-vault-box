import { test, expect } from "../fixtures.mjs";
import { claim, maze, prepareTwoPlayers, terminal } from "../game_helpers.mjs";

test("M1-01 a GameSession-only crash restores paused progress under a new session", async ({ vault }) => {
  const { host, a, b } = await prepareTwoPlayers(vault);
  await a.getByRole("button", { name: "Up", exact: true }).click();
  await expect(maze(b)).toHaveAttribute("data-position", "8");
  const originalSession = await terminal(a, "a").getAttribute("data-session");

  expect((await vault.command("restart_game_session")).restarted).toBe(true);
  await expect(terminal(a, "a")).not.toHaveAttribute("data-session", originalSession);
  await expect(maze(a)).toHaveAttribute("data-position", "8");
  await expect(maze(b)).toHaveAttribute("data-position", "8");
  await expect(host.locator("[data-host-paused]")).toBeVisible();
  await expect(terminal(a, "a").locator("[data-control-state]")).toHaveText("Observer");
  await expect(a.getByRole("button", { name: "Up", exact: true })).toBeDisabled();
  expect((await vault.command("outcomes")).outcomes).toEqual([]);
});
