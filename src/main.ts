import { listen } from "@tauri-apps/api/event";
import { invoke } from "@tauri-apps/api/core";

type State = "ready" | "listening" | "processing" | "done" | "error";

const LABELS: Record<State, string> = {
  ready: "Ready",
  listening: "Listening…",
  processing: "Thinking…",
  done: "Copied",
  error: "Error",
};

let overlayEl: HTMLElement | null = null;
let labelEl: HTMLSpanElement | null = null;
let doneTimer: number | null = null;

function setState(state: State, label?: string) {
  if (!overlayEl || !labelEl) return;
  overlayEl.dataset.state = state;
  labelEl.textContent = label ?? LABELS[state];
}

function fadeOutAfter(ms: number) {
  if (doneTimer !== null) clearTimeout(doneTimer);
  doneTimer = window.setTimeout(() => {
    setState("ready");
    void invoke("pill_done");
  }, ms);
}

async function init() {
  overlayEl = document.getElementById("overlay");
  labelEl = document.querySelector<HTMLSpanElement>(".label");
  setState("ready");

  // Drag is handled by Rust: NSWindow.movableByWindowBackground = true
  // (set in lib.rs setup) makes the entire transparent window draggable.

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

  await listen<void>("zerm://ready", () => {
    setState("ready");
  });

  await listen<void>("zerm://recording-start", () => {
    if (doneTimer !== null) {
      clearTimeout(doneTimer);
      doneTimer = null;
    }
    setState("listening");
  });

  await listen<void>("zerm://processing-start", () => {
    setState("processing");
  });

  await listen<string>("zerm://transcript", (event) => {
    console.log("transcript:", event.payload);
  });

  await listen<{ transcript: string; output: string }>("zerm://done", (event) => {
    setState("done");
    console.log("done:", event.payload);
    fadeOutAfter(1500);
  });

  await listen<string>("zerm://error", (event) => {
    setState("error", String(event.payload).slice(0, 80));
    fadeOutAfter(4000);
  });
}

window.addEventListener("DOMContentLoaded", () => {
  void init();
});
