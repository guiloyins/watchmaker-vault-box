import assert from "node:assert/strict";
import { chromium } from "@playwright/test";

const origin = "https://vault-probe.invalid/";
const markup = `
  <title>Vault browser probe</title>
  <label>Probe value <input id="value"></label>
  <button type="button">Save</button>
  <output role="status"></output>
  <script>
    const input = document.getElementById("value");
    const output = document.querySelector("output");
    output.textContent = localStorage.getItem("probe") ?? "empty";
    document.querySelector("button").addEventListener("click", (event) => {
      localStorage.setItem("probe", input.value);
      output.textContent = input.value;
      document.title = event.isTrusted ? "trusted" : "untrusted";
    });
  </script>`;

const browser = await chromium.launch({ headless: true });

try {
  for (const withDoctype of [false, true]) {
    const context = await browser.newContext({ offline: true, serviceWorkers: "block" });
    try {
      await context.route("**/*", (route) => {
        if (route.request().url() !== origin) return route.abort();
        const body = (withDoctype ? "<!doctype html>" : "") + markup;
        return route.fulfill({ contentType: "text/html", body });
      });
      const page = await context.newPage();
      await page.goto(origin, { timeout: 5_000 });
      await page.getByRole("textbox", { name: "Probe value" }).pressSequentially("amber");
      await page.getByRole("button", { name: "Save" }).click({ timeout: 5_000 });
      assert.equal(await page.title(), "trusted");
      assert.equal(await page.getByRole("status").textContent(), "amber");
      console.log(JSON.stringify({ withDoctype, status: "passed", trusted: true, browser: browser.version() }));
    } finally {
      await context.close();
    }
  }
} finally {
  await browser.close();
}
