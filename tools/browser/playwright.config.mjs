import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./tests",
  workers: 1,
  retries: 0,
  timeout: process.env.VAULT_BROWSER_MANUAL_DIR ? 220_000 : 65_000,
  expect: { timeout: 6_000 },
  reporter: [["./evidence_reporter.mjs"]],
  use: {
    browserName: "chromium",
    headless: !process.env.VAULT_HEADED,
    trace: "off",
    screenshot: "off",
    video: "off",
    actionTimeout: 6_000,
    navigationTimeout: 12_000,
  },
});
