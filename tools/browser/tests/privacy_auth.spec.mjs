import { test, expect } from "../fixtures.mjs";
import {
  chooseRunes, followGoldenRoute, maze, neutralThenPointerHold, prepareTwoPlayers, terminal,
} from "../game_helpers.mjs";

const otherFields = /"expected_by_role"|"solution_cells"|"solution_steps"|"open_edges"|"hidden_expected_rune"/;

function observeFrames(page) {
  const frames = [];
  page.on("websocket", (socket) => {
    socket.on("framereceived", ({ payload }) => {
      if (typeof payload === "string" && frames.length < 512) frames.push(payload);
    });
  });
  return frames;
}

test("M1-03 player HTML, diffs, DOM and assets contain only scoped puzzle data", async ({ vault }) => {
  const game = await prepareTwoPlayers(vault);
  const framesA = observeFrames(game.a);
  const framesB = observeFrames(game.b);
  const initialA = await game.a.request.get(`${vault.gamePath}/play/a`);
  const initialB = await game.b.request.get(`${vault.gamePath}/play/b`);
  expect(initialA.status()).toBe(200);
  expect(initialB.status()).toBe(200);

  for (const [response, own, other] of [
    [initialA, "2,5,6,9,12", "1,4,10,11"],
    [initialB, "1,4,10,11", "2,5,6,9,12"],
  ]) {
    const html = await response.text();
    expect(html.includes(`data-walls="${own}"`)).toBe(true);
    expect(html.includes(`data-walls="${other}"`)).toBe(false);
    expect(otherFields.test(html)).toBe(false);
  }

  for (const [page, walls, kind, controls] of [
    [game.a, "2,5,6,9,12", "right", ["Up", "Down"]],
    [game.b, "1,4,10,11", "bottom", ["Left", "Right"]],
  ]) {
    await expect(maze(page)).toHaveAttribute("data-walls", walls);
    await expect(maze(page)).toHaveAttribute("data-wall-kind", kind);
    const accessible = await page.locator("[data-command=move]").evaluateAll((buttons) =>
      buttons.map((button) => button.getAttribute("aria-label")));
    expect(accessible).toEqual(controls);
  }

  // Fresh WebSocket listeners require a new connection. Opening observers
  // preserves active ownership and supplies a complete allowed initial view.
  const observerA = await vault.open("a", (page) => {
    page.on("websocket", (socket) => socket.on("framereceived", ({ payload }) => {
      if (typeof payload === "string" && framesA.length < 512) framesA.push(payload);
    }));
  });
  const observerB = await vault.open("b", (page) => {
    page.on("websocket", (socket) => socket.on("framereceived", ({ payload }) => {
      if (typeof payload === "string" && framesB.length < 512) framesB.push(payload);
    }));
  });
  await followGoldenRoute(game);
  await expect(observerA.page.locator("[data-clue]")).toHaveText("Tell B: hold MOON");
  await expect(observerB.page.locator("[data-clue]")).toHaveText("Tell A: hold STAR");

  for (const [frames, forbiddenWallSet, forbiddenClue, ownClue] of [
    [framesA, "1,4,10,11", "Tell A: hold STAR", "Tell B: hold MOON"],
    [framesB, "2,5,6,9,12", "Tell B: hold MOON", "Tell A: hold STAR"],
  ]) {
    const wire = frames.join("\n");
    expect(wire.includes("vault:rebind")).toBe(true);
    expect(wire.includes("vault:challenge")).toBe(true);
    expect(wire.includes(forbiddenWallSet)).toBe(false);
    expect(wire.includes(forbiddenClue)).toBe(false);
    expect(otherFields.test(wire)).toBe(false);
    // LiveView can split adjacent static and dynamic text into separate
    // entries, so inspect the authorized clue in its rendered DOM above.
    expect(wire.includes(ownClue.split(" ").at(-1))).toBe(true);
  }

  for (const path of ["/assets/app.js", "/assets/app.css", "/assets/app.js.map", "/assets/app.css.map"]) {
    const response = await game.a.request.get(path);
    if (path.endsWith(".map") && response.status() === 404) continue;
    expect(response.status()).toBe(200);
    const body = await response.text();
    expect(otherFields.test(body)).toBe(false);
    expect(body.includes("maze-v1.private.json")).toBe(false);
    expect(body.includes("2,5,6,9,12")).toBe(false);
    expect(body.includes("1,4,10,11")).toBe(false);
  }

  expect((await game.a.request.get("/assets/meta.json")).status()).toBe(404);
});

test("M1-04 forged role routes and host actions cannot elevate a player or observer", async ({ vault }) => {
  const game = await prepareTwoPlayers(vault);
  const visitor = await vault.open();
  const observer = await vault.open("a");

  await visitor.page.goto(`${vault.gamePath}/host`);
  await expect(visitor.page).toHaveURL(`${vault.origin}/login`);
  for (const path of ["/host", "/play/b", "/play/c"]) {
    const response = await game.a.request.get(`${vault.gamePath}${path}`, { maxRedirects: 0 });
    expect(response.status()).toBe(403);
    expect((await response.text()).includes("data-walls")).toBe(false);
  }
  await observer.page.getByRole("button", { name: "Request control" }).click();
  await expect(observer.page.locator("[data-action-status]")).toHaveText("This terminal already has a controller.");

  await observer.page.evaluate(() => {
    const button = document.createElement("button");
    button.textContent = "Forge a host action";
    button.setAttribute("phx-click", "operate");
    button.setAttribute("phx-value-action", "reset");
    button.setAttribute("phx-value-request", "forged");
    button.setAttribute("phx-value-session", document.querySelector(".terminal").dataset.session);
    document.querySelector(".terminal").append(button);
  });
  await observer.page.getByRole("button", { name: "Forge a host action" }).click();
  await expect(terminal(game.host, "a").locator(".maze-board")).toHaveAttribute("data-position", "12");
  await expect(observer.page.getByRole("button", { name: "Up", exact: true })).toBeDisabled();
  await expect(game.a.getByRole("button", { name: "Up", exact: true })).toBeEnabled();

  const bad = await vault.open();
  await bad.page.goto("/login");
  await bad.page.getByLabel("Host access key").fill("invalid-credential-for-test");
  await bad.page.getByRole("button", { name: "Sign in" }).click();
  await expect(bad.page.getByRole("alert")).toContainText("Access denied.");
  await expect(bad.page.getByLabel("Host access key")).toHaveValue("");
  expect((await bad.page.content()).includes("invalid-credential-for-test")).toBe(false);

  const noCsrf = await bad.page.request.post("/login", {
    form: { access_token: "invalid-credential-for-test" },
  });
  expect(noCsrf.status()).toBe(403);
});

test("M1-04 old cookie and key are rejected after stopped host key replacement", async ({ vault }) => {
  const { page: oldHost } = await vault.open("host");
  await vault.rotateHostKey();

  await oldHost.goto(`${vault.gamePath}/host`);
  await expect(oldHost).toHaveURL(`${vault.origin}/login`);
  await vault.submitCredential(oldHost, "host", "host.key");
  await expect(oldHost.getByRole("alert")).toContainText("Access denied.");
  await expect(oldHost.getByLabel("Host access key")).toHaveValue("");

  const next = await vault.open();
  await vault.login(next.page, "host", "rotated.key");
  await expect(next.page.getByRole("heading", { name: "Host console" })).toBeVisible();
  const player = await vault.open("a");
  await expect(terminal(player.page, "a")).toBeVisible();
});

test("M1-04 sign out removes a held controller without affecting the partner session", async ({ vault }) => {
  const { a, b, contextA, host } = await prepareTwoPlayers(vault);
  await followGoldenRoute({ a, b });
  await chooseRunes(a, b);
  const sameSessionTab = await contextA.newPage();
  await sameSessionTab.goto(`${vault.gamePath}/play/a`);
  await expect(terminal(sameSessionTab, "a").locator("[data-control-state]")).toHaveText("Observer");

  await neutralThenPointerHold(a);
  await expect(b.locator("[data-peer-held]")).toHaveAttribute("data-peer-held", "true");
  await sameSessionTab.getByRole("button", { name: "Sign out" }).click();
  await expect(sameSessionTab).toHaveURL(`${vault.origin}/join`);
  await expect(b.locator("[data-peer-held]")).toHaveAttribute("data-peer-held", "false");
  await expect(host.locator("[data-host-paused]")).toBeVisible();
  await a.mouse.up();
  const denied = await a.request.get(`${vault.gamePath}/play/a`, { maxRedirects: 0 });
  expect(denied.status()).toBe(302);
  expect(denied.headers().location).toBe("/join");
  await expect(b.getByRole("button", { name: "Moon", exact: true })).toHaveAttribute("aria-pressed", "true");
  expect((await vault.command("outcomes")).outcomes).toEqual([]);
});
