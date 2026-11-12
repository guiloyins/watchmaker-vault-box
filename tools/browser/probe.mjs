import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { chromium, expect } from "@playwright/test";

const require = createRequire(import.meta.url);
const playwright = require("@playwright/test/package.json").version;
const coreDirectory = dirname(require.resolve("playwright-core/package.json"));
const manifest = JSON.parse(
  readFileSync(join(coreDirectory, "browsers.json"), "utf8"),
);
const headlessShell = manifest.browsers.find(
  ({ name }) => name === "chromium-headless-shell",
);
const npm = process.env.npm_config_user_agent?.match(/^npm\/([^ ]+)/)?.[1];

const origin = "https://vault-probe.invalid/";
const pageMarkup = `
  <title>Vault browser probe</title>
  <label>Probe value <input id="value"></label>
  <button type="button">Save</button>
  <output role="status"></output>
  <script>
    const input = document.getElementById("value");
    const output = document.querySelector("output");
    output.textContent = localStorage.getItem("probe") ?? "empty";
    document.querySelector("button").addEventListener("click", () => {
      localStorage.setItem("probe", input.value);
      output.textContent = input.value;
    });
  </script>
`;

async function createProbePage(browser) {
  const context = await browser.newContext({
    offline: true,
    serviceWorkers: "block",
  });

  await context.route("**/*", (route) => {
    if (route.request().url() === origin) {
      return route.fulfill({ status: 200, contentType: "text/html", body: pageMarkup });
    }
    return route.abort();
  });

  const page = await context.newPage();
  page.setDefaultTimeout(5_000);
  await page.goto(origin, { timeout: 5_000 });
  await expect(page).toHaveTitle("Vault browser probe", { timeout: 5_000 });
  return { context, page };
}

const browser = await chromium.launch({ headless: true, timeout: 15_000 });

try {
  const browserVersion = browser.version();
  assert.equal(browserVersion, headlessShell.browserVersion);

  const first = await createProbePage(browser);
  await first.context.addCookies([{ name: "probe", value: "first", url: origin }]);
  await first.page.getByRole("textbox", { name: "Probe value" }).pressSequentially("amber");
  await first.page.getByRole("button", { name: "Save" }).press("Enter");
  await expect(first.page.getByRole("status")).toHaveText("amber");

  const second = await createProbePage(browser);
  await expect(second.page.getByRole("status")).toHaveText("empty");
  assert.deepEqual(await second.context.cookies(origin), []);
  await second.page.getByRole("textbox", { name: "Probe value" }).pressSequentially("brass");
  await second.page.getByRole("button", { name: "Save" }).press("Enter");
  await expect(second.page.getByRole("status")).toHaveText("brass");

  await first.page.reload({ timeout: 5_000 });
  await expect(first.page.getByRole("status")).toHaveText("amber");
  assert.deepEqual(
    (await first.context.cookies(origin)).map(({ name, value }) => ({ name, value })),
    [{ name: "probe", value: "first" }],
  );

  console.log(JSON.stringify({
    status: "passed",
    node: process.versions.node,
    npm: npm ?? null,
    playwright,
    browser: {
      product: headlessShell.title,
      version: browserVersion,
      revision: headlessShell.revision,
      platform: process.platform,
      architecture: process.arch,
    },
    checks: [
      "bundled headless Chromium version matches Playwright manifest",
      "keyboard entry and button activation on a locally fulfilled offline page",
      "cookies and localStorage isolated across two browser contexts",
    ],
  }, null, 2));
} finally {
  await browser.close();
}
