const participantKeys = {
  a: { ArrowUp: "up", ArrowDown: "down" },
  b: { ArrowLeft: "left", ArrowRight: "right" },
};
const hostKeys = {
  a: { w: "up", s: "down" },
  b: { a: "left", d: "right" },
};
const resultLabels = {
  role_claimed: "Control assigned.",
  role_released: "Control released.",
  moved: "Key moved.",
  rune_selected: "Rune selected.",
  stale_board: "The key moved. Try a fresh direction.",
  stale_round: "The round changed. Try again.",
  stale_puzzle: "The puzzle changed. Try again.",
  paused: "The game is paused.",
  wrong_phase: "That action is unavailable in this stage.",
  wall: "A wall blocks that move.",
  out_of_bounds: "That move leaves the maze.",
  wrong_axis: "That direction belongs to your partner.",
  role_busy: "This terminal already has a controller.",
  stale_controller: "Control changed.",
  not_authorized: "That action is unavailable.",
};

function editable(target) {
  return target instanceof Element &&
    Boolean(target.closest('form, input, textarea, select, [contenteditable]:not([contenteditable="false"])'));
}

function keyFor(event) {
  return event.key.length === 1 ? event.key.toLowerCase() : event.key;
}

export default {
  mounted() {
    this.binding = null;
    this.connectionId = null;
    this.bootId = null;
    this.commandSeq = 0;
    this.inputSeq = 0;
    this.heartbeatSeq = 0;
    this.pressSeq = 0;
    this.contact = null;
    this.pending = null;
    this.afterSnapshot = null;
    this.setNeutral(false);
    this.blockedKeys = new Set();
    this.blockedPointers = new Set();
    this.listeners = new AbortController();

    const on = (target, event, callback) =>
      target.addEventListener(event, callback, { signal: this.listeners.signal });

    this.handleEvent("vault:rebind", (payload) => this.rebind(payload));
    this.handleEvent("vault:challenge", (payload) => this.challenge(payload));
    this.handleEvent("vault:input_result", (payload) => this.inputResult(payload));
    this.handleEvent("vault:command_result", (payload) => this.commandResult(payload));
    this.handleEvent("vault:invalidate", (payload) => {
      if (this.matches(payload)) this.invalidate();
    });

    on(this.el, "click", (event) => this.click(event));
    on(this.el, "pointerdown", (event) => this.pointerDown(event));
    on(this.el, "lostpointercapture", (event) => this.pointerLost(event));
    on(window, "pointerup", (event) => this.pointerEnded(event));
    on(window, "pointercancel", (event) => this.pointerEnded(event));
    on(window, "keydown", (event) => this.keyDown(event));
    on(window, "keyup", (event) => this.keyUp(event));
    on(window, "blur", () => this.clearContact(true));
    on(window, "pagehide", () => this.clearContact(true));
    on(document, "visibilitychange", () => {
      if (document.visibilityState !== "visible") this.clearContact(true);
    });
    on(document, "focusin", (event) => {
      if (editable(event.target)) this.clearContact(true);
    });

    this.lastMirrorEvent = this.el.dataset.mirrorEvent;
    this.syncView();
  },

  updated() {
    this.syncView();
  },

  disconnected() {
    this.invalidate(false);
    this.feedback("Connection lost. Controls are paused.");
  },

  reconnected() {
    this.feedback("Connection restored. Waiting for control context.");
  },

  destroyed() {
    this.invalidate();
    this.listeners.abort();
    cancelAnimationFrame(this.progressFrame);
    clearTimeout(this.mirrorTimer);
  },

  syncView() {
    const view = this.el.dataset;
    if (view.session !== this.viewSession ||
        view.phase !== this.viewPhase ||
        view.paused !== this.viewPaused ||
        view.selection !== this.viewSelection) {
      this.clearContact(true);
      this.setNeutral(false);
    }
    this.viewSession = view.session;
    this.viewPhase = view.phase;
    this.viewPaused = view.paused;
    this.viewSelection = view.selection;
    this.setNeutral(this.neutralSent);
    if (this.contact) this.el.dataset.localHeld = "true";

    this.mirrorAction(view);
    const progress = this.el.querySelector("[data-progress]");
    const progressState = progress &&
      [progress.dataset.active, progress.dataset.elapsed, progress.dataset.qualified].join(":");
    if (this.progressElement !== progress || this.progressState !== progressState) {
      cancelAnimationFrame(this.progressFrame);
      this.progressElement = progress;
      this.progressState = progressState;
      if (progress) this.animate(progress);
    }
  },

  mirrorAction(view) {
    if (!view.mirrorEvent || this.lastMirrorEvent === view.mirrorEvent) return;
    this.lastMirrorEvent = view.mirrorEvent;
    clearTimeout(this.mirrorTimer);
    this.mirrorTarget?.classList.remove("mirror-action");

    const value = view.mirrorDirection || view.mirrorRune;
    const action = view.mirrorDirection ? "move" : "select_rune";
    this.mirrorTarget = [...this.el.querySelectorAll("[data-command]")].find(
      (button) => button.dataset.command === action && button.dataset.value === value,
    );
    if (this.mirrorTarget) {
      this.mirrorTarget.classList.add("mirror-action");
      this.mirrorTimer = setTimeout(() => this.mirrorTarget?.classList.remove("mirror-action"), 150);
    }
    if (!this.ownsPanel() && resultLabels[view.mirrorCode]) this.feedback(resultLabels[view.mirrorCode]);
  },

  animate(progress) {
    const elapsed = Number(progress.dataset.elapsed);
    progress.value = elapsed;
    if (progress.dataset.active !== "true") return;

    const began = performance.now();
    const step = (now) => {
      progress.value = Math.min(progress.max - 1, elapsed + now - began);
      if (progress.value < progress.max - 1) {
        this.progressFrame = requestAnimationFrame(step);
      }
    };
    this.progressFrame = requestAnimationFrame(step);
  },

  matches(payload) {
    return this.binding &&
      payload.actor_id === this.binding.actor_id &&
      payload.binding_generation === this.binding.binding_generation &&
      (!payload.connection_id || payload.connection_id === this.binding.connection_id);
  },

  rebind(payload) {
    if (payload.actor_id !== this.el.dataset.actor) return;
    this.clearContact(true);
    this.clearPending();
    this.afterSnapshot = null;
    this.setNeutral(false);

    if (this.connectionId !== payload.connection_id) {
      this.commandSeq = 0;
      this.inputSeq = 0;
      this.heartbeatSeq = 0;
    }
    if (this.bootId !== payload.boot_id) this.pressSeq = 0;

    this.connectionId = payload.connection_id;
    this.bootId = payload.boot_id;
    this.binding = payload;
    this.feedback("");
    this.sendCommand("request_snapshot", {});
  },

  invalidate(sendSample = true) {
    this.clearContact(true, sendSample);
    this.clearPending();
    this.afterSnapshot = null;
    this.setNeutral(false);
    this.binding = null;
  },

  challenge(payload) {
    if (!this.matches(payload) || payload.heartbeat_seq <= this.heartbeatSeq) return;
    this.heartbeatSeq = payload.heartbeat_seq;
    this.sendSample();
  },

  sendSample() {
    const binding = this.binding;
    if (!binding || this.heartbeatSeq < 1) return;
    const sameSession = binding.session_id === this.el.dataset.session;
    const pressed = Boolean(this.contact && this.canHold());
    const input = binding.role && sameSession ? {
      ...this.fullContext(),
      pressed,
      press_id: pressed ? this.contact.pressId : null,
    } : null;
    this.inputSeq += 1;
    this.pushEvent("vault:input", {
      actor_id: binding.actor_id,
      connection_id: binding.connection_id,
      binding_generation: binding.binding_generation,
      heartbeat_seq: this.heartbeatSeq,
      input_seq: this.inputSeq,
      input,
    });
    if (input && !input.pressed) this.lastNeutral = this.inputSeq;
  },

  inputResult(payload) {
    if (!this.matches(payload)) return;
    if (payload.input_accepted && payload.input_seq === this.lastNeutral) {
      this.setNeutral(true);
      return;
    }
    if (!payload.input_accepted && payload.input_seq === this.inputSeq && this.contact) {
      this.clearContact(true);
      this.setNeutral(false);
    }
  },

  setNeutral(ready) {
    this.neutralSent = ready;
    if (ready) this.el.dataset.neutral = "true";
    else delete this.el.dataset.neutral;
  },

  fullContext() {
    const { session_id, round_id, puzzle_revision, role, control_epoch } = this.binding;
    return { session_id, round_id, puzzle_revision, role, control_epoch };
  },

  ownsPanel() {
    return this.binding?.role === this.el.dataset.panel &&
      this.binding.session_id === this.el.dataset.session;
  },

  canHold() {
    return this.ownsPanel() && this.el.dataset.phase === "seal" &&
      this.el.dataset.paused !== "true" && document.visibilityState === "visible" &&
      !this.el.querySelector("[data-hold]")?.disabled;
  },

  press(contact) {
    if (!this.canHold() || !this.neutralSent || this.contact ||
        this.blockedKeys.size || this.blockedPointers.size) return false;
    this.pressSeq += 1;
    this.contact = { ...contact, pressId: this.pressSeq };
    this.el.dataset.localHeld = "true";
    this.sendSample();
    return true;
  },

  clearContact(requireLift, sendSample = true) {
    const contact = this.contact;
    this.contact = null;
    delete this.el.dataset.localHeld;

    if (!contact) return;
    this.setNeutral(false);
    if (contact.kind === "key" && requireLift) this.blockedKeys.add(contact.key);
    if (contact.kind === "pointer") {
      if (requireLift) this.blockedPointers.add(contact.id);
      if (contact.target.hasPointerCapture(contact.id)) {
        contact.target.releasePointerCapture(contact.id);
      }
    }
    if (sendSample) this.sendSample();
  },

  pointerDown(event) {
    const target = event.target.closest("[data-hold]");
    if (!target || event.button !== 0 || !event.isPrimary || target.disabled) return;

    // A new primary down means the previous primary contact ended, even if
    // its up occurred outside the window while the page was hidden.
    this.blockedPointers.clear();
    if (this.press({ kind: "pointer", id: event.pointerId, target })) {
      target.setPointerCapture(event.pointerId);
    }
  },

  pointerLost(event) {
    if (this.contact?.kind === "pointer" && this.contact.id === event.pointerId) {
      this.clearContact(true);
    }
  },

  pointerEnded(event) {
    this.blockedPointers.delete(event.pointerId);
    if (this.contact?.kind === "pointer" && this.contact.id === event.pointerId) {
      this.clearContact(false);
    }
  },

  keyDown(event) {
    if (event.defaultPrevented || event.repeat || event.metaKey || event.ctrlKey ||
        event.altKey || editable(event.target)) return;
    const key = keyFor(event);
    const role = this.el.dataset.panel;
    const host = this.el.dataset.mode === "host";
    const holdKey = host ? (role === "a" ? "q" : "p") : " ";
    const direction = (host ? hostKeys : participantKeys)[role][key];

    if (key === holdKey && this.canHold()) {
      event.preventDefault();
      this.blockedKeys.delete(key);
      this.press({ kind: "key", key });
    } else if (direction && this.ownsPanel() && this.el.dataset.phase === "maze" &&
        this.el.dataset.paused !== "true") {
      event.preventDefault();
      this.move(direction);
    }
  },

  keyUp(event) {
    const key = keyFor(event);
    this.blockedKeys.delete(key);
    if (this.contact?.kind === "key" && this.contact.key === key) {
      this.clearContact(false);
    }
  },

  click(event) {
    const button = event.target.closest("[data-command]");
    if (!button || button.disabled || !this.binding) return;
    const { command, value } = button.dataset;

    switch (command) {
      case "claim_role":
        this.sendCommand(command, { role: value });
        break;
      case "release_role":
        this.sendCommand(command, {});
        break;
      case "move":
        this.move(value);
        break;
      case "select_rune":
        this.clearContact(true);
        this.setNeutral(false);
        this.sendCommand(command, { rune: value });
        break;
    }
  },

  move(direction) {
    this.sendCommand("move", {
      direction,
      expected_board_version: Number(this.el.dataset.board),
    });
  },

  sendCommand(action, payload) {
    if (!this.binding) return;
    if (this.pending) {
      if (this.pending.envelope.command.action === "request_snapshot" && !this.afterSnapshot) {
        this.afterSnapshot = { action, payload, context: this.decisionContext() };
      }
      return;
    }

    const binding = this.binding;
    const command = {
      v: 1,
      type: "command",
      connection_id: binding.connection_id,
      command_seq: ++this.commandSeq,
      session_id: binding.session_id,
      action,
      payload,
    };

    if (action === "move" || action === "select_rune") {
      Object.assign(command, this.fullContext());
    } else if (action === "release_role") {
      Object.assign(command, { role: binding.role, control_epoch: binding.control_epoch });
    }

    this.pending = {
      attempts: 0,
      envelope: { actor_id: binding.actor_id, binding_generation: binding.binding_generation, command },
    };
    this.transmit();
  },

  transmit() {
    const pending = this.pending;
    this.pushEvent("vault:command", pending.envelope);
    pending.timer = setTimeout(() => {
      if (this.pending !== pending) return;
      if (pending.attempts < 3) {
        pending.attempts += 1;
        this.transmit();
      } else {
        this.invalidate();
        window.location.reload();
      }
    }, 500);
  },

  clearPending() {
    clearTimeout(this.pending?.timer);
    this.pending = null;
  },

  commandResult(payload) {
    if (!this.matches(payload) || !this.pending) return;
    const result = payload.result;
    const command = this.pending.envelope.command;
    if (result.connection_id !== this.binding.connection_id ||
        result.session_id !== this.binding.session_id ||
        result.command_seq !== command.command_seq) return;

    this.clearPending();
    if (result.code === "stale_session" || result.code === "seq_gap") {
      this.invalidate();
      window.location.reload();
      return;
    }
    if (resultLabels[result.code]) this.feedback(resultLabels[result.code]);
    const queued = this.afterSnapshot;
    this.afterSnapshot = null;
    if (queued && queued.context === this.decisionContext()) {
      this.sendCommand(queued.action, queued.payload);
    }
  },

  decisionContext() {
    const { session, phase, paused, board, selection } = this.el.dataset;
    return [session, phase, paused, board, selection, this.binding?.control_epoch].join("/");
  },

  feedback(text) {
    const status = this.el.querySelector("[data-action-status]");
    if (status) status.textContent = text;
  },
};
