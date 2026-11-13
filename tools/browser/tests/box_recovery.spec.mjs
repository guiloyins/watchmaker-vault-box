import { test, expect } from "../fixtures.mjs";
import {
  chooseRunes, followGoldenRoute, neutralThenPointerHold, prepareTwoPlayers, sharedProgress,
} from "../game_helpers.mjs";

test("M1-06 lost simulated release acknowledgement closes without replay through the host", async ({ vault }) => {
  const game = await prepareTwoPlayers(vault);
  const { host, a, b } = game;
  await followGoldenRoute(game);
  await chooseRunes(a, b);
  await host.getByText("Simulated faults", { exact: true }).click();
  await host.getByRole("button", { name: "Drop next acknowledgement" }).click();

  await neutralThenPointerHold(a);
  await expect(b.locator("[data-peer-held]")).toHaveAttribute("data-peer-held", "true");
  await neutralThenPointerHold(b);
  await expect(sharedProgress(a)).toHaveAttribute("data-active", "true");
  await expect(a.getByRole("heading", { name: "Puzzle solved" })).toBeVisible();
  await a.mouse.up();
  await b.mouse.up();

  await expect(host.getByRole("button", { name: "Reset puzzle" })).toBeDisabled();
  const original = (await vault.command("outcomes")).outcomes;
  expect(original).toHaveLength(1);
  await host.getByRole("button", { name: "Begin release recovery" }).click();

  const recovery = host.getByRole("region", { name: "Release recovery" });
  await expect(recovery.getByText(/generation 1/)).toBeVisible();
  await recovery.getByText("Simulated recovery service", { exact: true }).click();
  const boot = await host.locator("[data-box-boot]").textContent();
  const service = async (name) => {
    await test.step(name, async () => {
      await recovery.getByRole("button", { name }).click();
      await expect(host.locator("[data-operator-feedback]")).toHaveText("Operation accepted.");
    });
  };
  await service("Stop simulated mechanism");
  await service("Enter modeled recovery");
  await service("Reboot into recovery");
  await expect(host.locator("[data-box-boot]")).not.toHaveText(boot);
  await expect(host.locator("[data-box-readiness]")).toHaveText("Setup required");
  await service("Seal modeled record");

  const close = recovery.getByRole("button", { name: "Close release without replay" });
  await expect(close).toBeVisible();
  const values = await recovery.locator(".diagnostic-grid dd").allTextContents();
  expect(values).toHaveLength(3);
  await recovery.getByLabel("Sealed local record ID").fill(values[0]);
  await recovery.getByLabel("Local service epoch").fill(values[1]);
  await recovery.getByLabel("Seal operation ID").fill(values[2]);
  await recovery.getByLabel("Reason").fill("Verified the modeled record after simulated restart.");
  await recovery.getByRole("checkbox").check();
  await close.click();
  await expect(recovery.getByText(/Closed without replay/)).toBeVisible();
  const committed = (await vault.command("outcomes")).outcomes;
  expect(committed).toEqual([{ ...original[0], dispatch_retired: true }]);
});
