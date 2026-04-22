import { listen } from "@tauri-apps/api/event";
import { invoke } from "@tauri-apps/api/core";
import { getCurrentWindow } from "@tauri-apps/api/window";

type HudState =
  | "ready"
  | "listening"
  | "processing"
  | "slow-processing"
  | "copied"
  | "pasted"
  | "no-target"
  | "permission-needed"
  | "failed"
  | "retry-available";

type HudPayload =
  | string
  | {
      label?: string;
      message?: string;
      reason?: string;
      state?: HudState;
      pasted?: boolean;
      copied?: boolean;
      retryAvailable?: boolean;
    };

const LABELS: Record<HudState, string> = {
  ready: "Ready",
  listening: "Listening...",
  processing: "Thinking...",
  "slow-processing": "Still working...",
  copied: "Copied",
  pasted: "Pasted",
  "no-target": "No target",
  "permission-needed": "Permission needed",
  failed: "Failed",
  "retry-available": "Retry available",
};

const TRANSIENT_MS: Partial<Record<HudState, number>> = {
  copied: 1400,
  pasted: 1400,
  "no-target": 2400,
  failed: 4000,
  "retry-available": 4000,
};

let overlayEl: HTMLElement | null = null;
let labelEl: HTMLSpanElement | null = null;
let doneTimer: number | null = null;

function clearDoneTimer() {
  if (doneTimer !== null) {
    clearTimeout(doneTimer);
    doneTimer = null;
  }
}

function readablePayload(payload: HudPayload | undefined, fallback: string) {
  const raw =
    typeof payload === "string"
      ? payload
      : payload?.label ?? payload?.message ?? payload?.reason ?? fallback;
  const clean = raw.replace(/\s+/g, " ").trim();
  if (!clean) return fallback;
  return clean.length > 56 ? `${clean.slice(0, 53)}...` : clean;
}

function setState(state: HudState, label?: string) {
  if (!overlayEl || !labelEl) return;
  clearDoneTimer();
  overlayEl.dataset.state = state;
  overlayEl.dataset.busy =
    state === "listening" ||
    state === "processing" ||
    state === "slow-processing"
      ? "true"
      : "false";
  labelEl.textContent = label ?? LABELS[state];
}

function fadeOutAfter(ms: number, hide = true) {
  clearDoneTimer();
  doneTimer = window.setTimeout(() => {
    setState("ready");
    if (hide) {
      void invoke("pill_done");
    }
  }, ms);
}

function setTransientState(
  state: HudState,
  payload?: HudPayload,
  fallback = LABELS[state],
) {
  setState(state, readablePayload(payload, fallback));
  const ms = TRANSIENT_MS[state];
  if (ms !== undefined) {
    fadeOutAfter(ms);
  }
}

function stateFromDonePayload(payload: HudPayload | undefined): HudState {
  if (payload && typeof payload === "object") {
    if (payload.state === "pasted" || payload.pasted) return "pasted";
    if (payload.state === "copied" || payload.copied) return "copied";
  }
  return "copied";
}

async function listenMany<T>(
  eventNames: string[],
  handler: (payload: T) => void,
) {
  await Promise.all(
    eventNames.map((eventName) =>
      listen<T>(eventName, (event) => {
        handler(event.payload);
      }),
    ),
  );
}

async function init() {
  overlayEl = document.getElementById("overlay");
  labelEl = document.querySelector<HTMLSpanElement>(".label");
  setState("ready");

  // Drag is handled by Rust: NSWindow.movableByWindowBackground = true
  // (set in lib.rs setup) makes the entire transparent window draggable.

  // Persist the pill's position whenever the user moves it. Debounced so we
  // don't spam disk during a drag.
  const win = getCurrentWindow();
  let saveTimer: number | null = null;
  void win.onMoved((event) => {
    if (saveTimer !== null) clearTimeout(saveTimer);
    saveTimer = window.setTimeout(() => {
      void invoke("set_pill_position", {
        x: event.payload.x,
        y: event.payload.y,
      });
    }, 350);
  });

  const bars = Array.from(
    document.querySelectorAll<HTMLDivElement>("#spectrum .bar"),
  );

  // Each bar has a different sensitivity profile so the spectrum looks lively
  const sensitivities = bars.map((_, i) => {
    const center = (bars.length - 1) / 2;
    const distFromCenter = Math.abs(i - center) / center;
    return 0.75 + (1 - distFromCenter) * 0.55; // center bars more responsive
  });

  // Smoothing: track recent levels per bar so changes look fluid, not jumpy
  const smoothed = new Array<number>(bars.length).fill(0);
  const SMOOTHING = 0.55; // higher = smoother, lower = snappier

  await listen<number>("zerm://audio-level", (event) => {
    const level = Math.min(1, Math.max(0, event.payload));
    // Soft floor + aggressive scaling: typical speech RMS is 0.02-0.15.
    // Map RMS curve to perceptually responsive bar heights.
    // sqrt() lifts low input so even quiet speech moves the bars visibly.
    const scaled = Math.min(1, Math.sqrt(level) * 2.4);
    bars.forEach((bar, i) => {
      const t = Date.now() / 50;
      const wobble = 0.7 + Math.abs(Math.sin(t * 0.06 + i * 0.85)) * 0.4;
      const target = scaled * sensitivities[i] * wobble;
      smoothed[i] = smoothed[i] * SMOOTHING + target * (1 - SMOOTHING);
      const h = Math.max(3, Math.round(smoothed[i] * 22));
      bar.style.height = `${h}px`;
    });
  });

  await listenMany<void>(["zerm://ready", "zerm://idle"], () => {
    setState("ready");
  });

  await listenMany<void>(
    ["zerm://recording-start", "zerm://listening", "zerm://listen-start"],
    () => {
      setState("listening");
    },
  );

  await listenMany<void>(
    ["zerm://processing-start", "zerm://processing", "zerm://transcribing"],
    () => {
      setState("processing");
    },
  );

  await listenMany<void>(
    [
      "zerm://slow-processing",
      "zerm://processing-slow",
      "zerm://long-processing",
    ],
    () => {
      setState("slow-processing");
    },
  );

  await listenMany<HudPayload>(["zerm://copied", "zerm://copy-done"], (payload) => {
    setTransientState("copied", payload);
  });

  await listenMany<HudPayload>(["zerm://pasted", "zerm://paste-done"], (payload) => {
    setTransientState("pasted", payload);
  });

  await listenMany<HudPayload>(
    ["zerm://no-target", "zerm://paste-no-target"],
    (payload) => {
      setTransientState("no-target", payload);
    },
  );

  await listenMany<HudPayload>(
    [
      "zerm://permission-needed",
      "zerm://accessibility-needed",
      "zerm://paste-permission-needed",
    ],
    (payload) => {
      setState("permission-needed", readablePayload(payload, LABELS["permission-needed"]));
    },
  );

  await listenMany<HudPayload>(
    ["zerm://retry-available", "zerm://paste-retry-available"],
    (payload) => {
      setTransientState("retry-available", payload);
    },
  );

  await listen<HudPayload>("zerm://hud-state", (event) => {
    const payload = event.payload;
    if (payload && typeof payload === "object" && payload.state) {
      const state = payload.state;
      if (state === "permission-needed") {
        setState(state, readablePayload(payload, LABELS[state]));
        return;
      }
      setTransientState(state, payload);
    }
  });

  await listen<void>("zerm://recording-stop", () => {
    setState("processing");
  });

  await listen<void>("zerm://recording-cancelled", () => {
    setState("ready");
    fadeOutAfter(300);
  });

  await listen<string>("zerm://transcript", () => {
    // Payload is dictated text — may contain secrets. Do NOT log.
  });

  await listen<HudPayload>("zerm://done", (event) => {
    // Payload contains cleaned output. Do NOT log.
    const state = stateFromDonePayload(event.payload);
    setTransientState(state, event.payload);
  });

  await listenMany<HudPayload>(["zerm://error", "zerm://failed"], (payload) => {
    if (payload && typeof payload === "object" && payload.retryAvailable) {
      setTransientState("retry-available", payload);
      return;
    }
    setTransientState("failed", payload, LABELS.failed);
  });
}

window.addEventListener("DOMContentLoaded", () => {
  void init();
});
