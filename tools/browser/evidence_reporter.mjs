import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { readFileSync } from "node:fs";

const require = createRequire(import.meta.url);
const playwright = require("@playwright/test/package.json").version;
const core = dirname(require.resolve("playwright-core/package.json"));
const manifest = JSON.parse(readFileSync(join(core, "browsers.json"), "utf8"));
const product = process.env.VAULT_HEADED ? "chromium" : "chromium-headless-shell";
const browser = manifest.browsers.find(({ name }) => name === product);

export default class EvidenceReporter {
  onBegin() {
    console.log(JSON.stringify({
      type: "environment",
      node: process.versions.node,
      npm: process.env.npm_config_user_agent?.match(/^npm\/([^ ]+)/)?.[1],
      playwright,
      browser: browser.title,
      browserVersion: browser.browserVersion,
      browserRevision: browser.revision,
      platform: process.platform,
      architecture: process.arch,
      headed: Boolean(process.env.VAULT_HEADED),
    }));
  }

  onTestEnd(test, result) {
    // Titles are static. Error messages, request metadata, console output and
    // attachments may contain credentials or private snapshots and stay local.
    const location = result.errors[0]?.location;
    const first = result.errors[0]?.stack?.match(/(?:^|[(/])([\w.-]+\.mjs):(\d+):\d+/m);
    const step = result.steps.find(({ category, error }) => category === "test.step" && error)?.title;
    const source = location && location.file.match(/([^/]+\.mjs)$/)?.[1];
    const armResult = result.errors[0]?.message?.match(/^vault_arm:(accepted_without_armed_status|not_ready|stale_session|unresolved_release|storage_error|unclassified)$/)?.[1];
    const failureCategory = result.errors[0]?.message?.includes("strict mode violation")
      ? "Ambiguous locator"
      : "Check failed";
    console.log(JSON.stringify({
      type: "scenario",
      id: test.title.match(/M1-\d{2}/)?.[0],
      title: test.title,
      status: result.status,
      durationMs: result.duration,
      nativeBlocked: result.annotations.some((annotation) => annotation.type === "native_blocked") || undefined,
      failure: result.status === "failed" ? failureCategory : undefined,
      source: source ? `${source}:${location.line}` : (first ? `${first[1]}:${first[2]}` : undefined),
      step,
      armResult,
    }));
  }

  onError() {
    console.log(JSON.stringify({ type: "runner_error", error: "Playwright could not run the suite" }));
  }

  onEnd(result) {
    console.log(JSON.stringify({ type: "summary", status: result.status }));
  }
}
