type State = "idle" | "listening" | "processing" | "done";

const LABELS: Record<State, string> = {
  idle: "Ready",
  listening: "Listening…",
  processing: "Thinking…",
  done: "Copied",
};

let overlayEl: HTMLElement | null = null;
let labelEl: HTMLSpanElement | null = null;

function setState(state: State) {
  if (!overlayEl || !labelEl) return;
  overlayEl.dataset.state = state;
  labelEl.textContent = LABELS[state];
}

window.addEventListener("DOMContentLoaded", () => {
  overlayEl = document.getElementById("overlay");
  labelEl = document.querySelector<HTMLSpanElement>(".label");
  setState("idle");
});

(window as unknown as { zerm: { setState: typeof setState } }).zerm = {
  setState,
};
