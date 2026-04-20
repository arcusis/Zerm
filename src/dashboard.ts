import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";

interface HistoryEntry {
  timestamp: number;
  transcript: string;
  output: string;
}

interface Stats {
  words_transcribed: number;
  words_generated: number;
  generation_count: number;
}

type PromptMode = "off" | "agent" | "conversational" | "professional";
type HotkeyChoice =
  | "right_option"
  | "left_option"
  | "right_command"
  | "right_shift"
  | "right_control"
  | "caps_lock"
  | "fn";

interface Settings {
  llm_model: string;
  vad_enabled: boolean;
  prompt_mode: PromptMode;
  hotkey: HotkeyChoice;
  vocabulary: string[];
  auto_paste: boolean;
}

interface DashboardData {
  stats: Stats;
  history: HistoryEntry[];
  settings: Settings;
}

const HOTKEY_LABELS: Record<HotkeyChoice, { kbd: string; label: string }> = {
  right_option: { kbd: "⌥", label: "Right Option" },
  left_option: { kbd: "⌥", label: "Left Option" },
  right_command: { kbd: "⌘", label: "Right Command" },
  right_shift: { kbd: "⇧", label: "Right Shift" },
  right_control: { kbd: "⌃", label: "Right Control" },
  caps_lock: { kbd: "⇪", label: "Caps Lock" },
  fn: { kbd: "fn", label: "Fn" },
};

const $ = <T extends HTMLElement>(id: string) =>
  document.getElementById(id) as T | null;

function fmtTimestamp(ts: number): string {
  const d = new Date(ts);
  const today = new Date();
  const sameDay =
    d.getFullYear() === today.getFullYear() &&
    d.getMonth() === today.getMonth() &&
    d.getDate() === today.getDate();
  if (sameDay) {
    return d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  }
  return d.toLocaleString([], {
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

function renderStats(stats: Stats) {
  $("stat-transcribed")!.textContent = stats.words_transcribed.toLocaleString();
  $("stat-generated")!.textContent = stats.words_generated.toLocaleString();
  $("stat-count")!.textContent = stats.generation_count.toLocaleString();
}

function renderHistory(history: HistoryEntry[]) {
  const list = $("history-list")!;
  list.innerHTML = "";
  if (history.length === 0) {
    const li = document.createElement("li");
    li.className = "empty-state";
    li.innerHTML = `<span class="empty-mark">∅</span><span>No dictations yet. Tap your hotkey to start.</span>`;
    list.appendChild(li);
    return;
  }
  for (const entry of history) {
    const li = document.createElement("li");
    li.className = "history-item";
    li.title = "Click to copy";
    li.innerHTML = `
      <span class="meta-time"></span>
      <span class="output"></span>
      <span class="copied">Copied</span>
    `;
    li.querySelector(".meta-time")!.textContent = fmtTimestamp(entry.timestamp);
    li.querySelector(".output")!.textContent = entry.output || entry.transcript;
    li.addEventListener("click", async () => {
      await safeInvoke("copy_history_entry", { timestamp: entry.timestamp });
      li.classList.add("just-copied");
      setTimeout(() => li.classList.remove("just-copied"), 1400);
    });
    list.appendChild(li);
  }
}

function renderSettings(settings: Settings) {
  ($("vad-toggle") as HTMLInputElement | null)!.checked = settings.vad_enabled;
  const autoPasteEl = $("autopaste-toggle") as HTMLInputElement | null;
  if (autoPasteEl) autoPasteEl.checked = settings.auto_paste;
  ($("hotkey-select") as HTMLSelectElement | null)!.value = settings.hotkey;

  const meta = HOTKEY_LABELS[settings.hotkey];
  if (meta) {
    const kbd = document.querySelector<HTMLElement>(".hotkey-pill kbd");
    if (kbd) kbd.textContent = meta.kbd;
    const label = $("hotkey-label");
    if (label) label.textContent = meta.label;
  }

  document.querySelectorAll<HTMLButtonElement>(".mode-btn").forEach((btn) => {
    btn.classList.toggle("active", btn.dataset.mode === settings.prompt_mode);
  });

  renderVocabulary(settings.vocabulary);
}

function renderVocabulary(terms: string[]) {
  const list = $("vocab-list")!;
  const count = $("vocab-count")!;
  count.textContent = `${terms.length} term${terms.length === 1 ? "" : "s"}`;
  list.innerHTML = "";
  if (terms.length === 0) {
    const li = document.createElement("li");
    li.className = "empty-state";
    li.innerHTML = `<span class="empty-mark">∅</span><span>Your vocabulary is empty. Add your first term above.</span>`;
    list.appendChild(li);
    return;
  }
  for (const term of terms) {
    const li = document.createElement("li");
    li.className = "vocab-chip";
    const termSpan = document.createElement("span");
    termSpan.className = "vocab-term";
    termSpan.textContent = term;
    termSpan.title = term;
    const removeBtn = document.createElement("button");
    removeBtn.className = "vocab-remove";
    removeBtn.type = "button";
    removeBtn.title = `Remove "${term}"`;
    removeBtn.textContent = "×";
    removeBtn.addEventListener("click", async () => {
      await safeInvoke("remove_vocabulary_term", { term });
      await refresh();
    });
    li.append(termSpan, removeBtn);
    list.appendChild(li);
  }
}

function flashButton(btn: HTMLElement, text: string, ok = true) {
  const original = btn.textContent;
  const originalBg = btn.style.background;
  const originalColor = btn.style.color;
  btn.textContent = text;
  btn.style.background = ok ? "var(--green)" : "var(--accent)";
  btn.style.color = "white";
  setTimeout(() => {
    btn.textContent = original;
    btn.style.background = originalBg;
    btn.style.color = originalColor;
  }, 1200);
}

async function safeInvoke<T = unknown>(
  cmd: string,
  args?: Record<string, unknown>,
): Promise<T | null> {
  try {
    return (await invoke<T>(cmd, args)) as T;
  } catch (err) {
    console.error(`invoke ${cmd} failed:`, err);
    return null;
  }
}

async function refresh() {
  const data = await safeInvoke<DashboardData>("get_dashboard");
  if (!data) return;
  renderStats(data.stats);
  renderHistory(data.history);
  renderSettings(data.settings);
}

function setupTabs() {
  document.querySelectorAll<HTMLButtonElement>(".nav-item").forEach((btn) => {
    btn.addEventListener("click", () => {
      const tab = btn.dataset.tab;
      if (!tab) return;
      document
        .querySelectorAll(".nav-item")
        .forEach((b) => b.classList.toggle("active", b === btn));
      document.querySelectorAll<HTMLElement>(".tab-panel").forEach((panel) => {
        panel.classList.toggle("active", panel.dataset.tab === tab);
      });
    });
  });
}

function attachListeners() {
  // Hotkey
  $("hotkey-select")?.addEventListener("change", async (e) => {
    const key = (e.target as HTMLSelectElement).value;
    const result = await safeInvoke("set_hotkey", { key });
    if (result !== null) await refresh();
  });

  // VAD
  $("vad-toggle")?.addEventListener("change", async (e) => {
    const checked = (e.target as HTMLInputElement).checked;
    await safeInvoke("set_vad_enabled", { enabled: checked });
  });

  $("autopaste-toggle")?.addEventListener("change", async (e) => {
    const checked = (e.target as HTMLInputElement).checked;
    await safeInvoke("set_auto_paste", { enabled: checked });
  });

  // Prompt mode
  document.querySelectorAll<HTMLButtonElement>(".mode-btn").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const mode = btn.dataset.mode;
      if (!mode) return;
      document.querySelectorAll(".mode-btn").forEach((b) => b.classList.remove("active"));
      btn.classList.add("active");
      const result = await safeInvoke("set_prompt_mode", { mode });
      if (result === null) await refresh();
    });
  });

  // Vocabulary — add via form submit
  const vocabForm = document.getElementById("vocab-form") as HTMLFormElement | null;
  const vocabInput = $("vocab-input") as HTMLInputElement | null;
  vocabForm?.addEventListener("submit", async (e) => {
    e.preventDefault();
    const value = vocabInput?.value.trim();
    if (!value) return;
    const result = await safeInvoke("add_vocabulary_term", { term: value });
    if (result !== null && vocabInput) {
      vocabInput.value = "";
      vocabInput.focus();
    }
    await refresh();
  });

  $("vocab-clear")?.addEventListener("click", async () => {
    await safeInvoke("clear_vocabulary");
    await refresh();
  });

  // Clear history (no confirm dialog — Tauri WebView doesn't always honor it)
  const clearBtn = $("clear-history");
  let clearArmed = false;
  clearBtn?.addEventListener("click", async () => {
    if (!clearArmed) {
      clearArmed = true;
      const original = clearBtn.textContent;
      clearBtn.textContent = "Click again to confirm";
      clearBtn.style.color = "var(--accent)";
      setTimeout(() => {
        clearArmed = false;
        clearBtn.textContent = original;
        clearBtn.style.color = "";
      }, 2500);
      return;
    }
    clearArmed = false;
    await safeInvoke("clear_history");
    await refresh();
    if (clearBtn) flashButton(clearBtn, "Cleared", true);
  });

  $("quit-btn")?.addEventListener("click", async () => {
    await safeInvoke("quit_app");
  });
}

interface SetupStatus {
  whisper_model_present: boolean;
  whisper_model_path: string | null;
  ollama_running: boolean;
  ollama_model_pulled: boolean;
  ollama_model_name: string;
}

function formatBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(0)} KB`;
  if (n < 1024 * 1024 * 1024) return `${(n / 1024 / 1024).toFixed(1)} MB`;
  return `${(n / 1024 / 1024 / 1024).toFixed(2)} GB`;
}

function showSetupBanner(title: string, detail: string, actionsHTML: string) {
  const banner = $("setup-banner")!;
  banner.hidden = false;
  $("setup-title")!.textContent = title;
  $("setup-detail")!.textContent = detail;
  const actions = $("setup-actions")!;
  actions.innerHTML = actionsHTML;
}

function hideSetupBanner() {
  const banner = $("setup-banner")!;
  banner.hidden = true;
  const progress = $("setup-progress")!;
  progress.hidden = true;
}

async function refreshSetup() {
  const status = await safeInvoke<SetupStatus>("check_setup");
  if (!status) return;
  if (!status.whisper_model_present) {
    showSetupBanner(
      "Whisper model not installed",
      "Zerm needs a speech-to-text model (~466 MB) to transcribe your voice.",
      `<button class="solid-btn" id="btn-download-whisper">Download Whisper model</button>`,
    );
    $("btn-download-whisper")?.addEventListener("click", () => {
      void downloadWhisper();
    });
    return;
  }
  if (!status.ollama_running) {
    showSetupBanner(
      "Ollama is not running",
      "Install Ollama and start the service so Zerm can polish your transcripts locally.",
      `<a class="solid-btn" href="https://ollama.com/download" target="_blank" rel="noreferrer">Get Ollama</a>`,
    );
    return;
  }
  if (!status.ollama_model_pulled) {
    showSetupBanner(
      `Pull the language model`,
      `Run "ollama pull ${status.ollama_model_name}" in a terminal — Zerm will pick it up automatically.`,
      `<a class="solid-btn" href="https://ollama.com/library/${encodeURIComponent(status.ollama_model_name.split(":")[0])}" target="_blank" rel="noreferrer">Open library</a>`,
    );
    return;
  }
  hideSetupBanner();
}

async function downloadWhisper() {
  const banner = $("setup-banner")!;
  banner.hidden = false;
  $("setup-title")!.textContent = "Downloading Whisper model";
  $("setup-detail")!.textContent = "This is a one-time ~466 MB download.";
  $("setup-actions")!.innerHTML = "";
  const progress = $("setup-progress")!;
  const fill = $("setup-progress-fill")!;
  const label = $("setup-progress-label")!;
  progress.hidden = false;
  label.textContent = "Starting…";

  let lastUnlisten: (() => void) | null = null;
  try {
    const { listen: listenEvent } = await import("@tauri-apps/api/event");
    const unlisten = await listenEvent<{ downloaded: number; total: number }>(
      "zerm://whisper-download-progress",
      (event) => {
        const { downloaded, total } = event.payload;
        if (total > 0) {
          const pct = Math.min(100, (downloaded / total) * 100);
          (fill as HTMLDivElement).style.width = `${pct.toFixed(1)}%`;
          label.textContent = `${formatBytes(downloaded)} / ${formatBytes(total)}`;
        } else {
          label.textContent = formatBytes(downloaded);
        }
      },
    );
    lastUnlisten = unlisten;

    const path = await safeInvoke<string>("download_whisper_model");
    if (path) {
      $("setup-title")!.textContent = "Whisper model installed";
      $("setup-detail")!.textContent = "Loading the model into memory…";
      label.textContent = "100%";
      setTimeout(() => {
        void refreshSetup();
      }, 1500);
    }
  } finally {
    if (lastUnlisten) lastUnlisten();
  }
}

async function init() {
  setupTabs();
  attachListeners();
  await refresh();
  void refreshSetup();
  try {
    await listen<DashboardData>("zerm://dashboard-updated", (event) => {
      renderStats(event.payload.stats);
      renderHistory(event.payload.history);
      renderSettings(event.payload.settings);
    });
  } catch (err) {
    console.warn("listen failed:", err);
  }
}

window.addEventListener("DOMContentLoaded", () => {
  void init();
});
