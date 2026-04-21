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

type PromptMode = "off" | "developer" | "conversational" | "professional";
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
  allow_unverified_ollama: boolean;
  save_history: boolean;
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

const IS_MAC = navigator.platform.toLowerCase().includes("mac");
const FIXED_HOTKEY_LABEL = "Ctrl+Shift+Space";

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
  const unverifiedOllamaEl = $("unverified-ollama-toggle") as HTMLInputElement | null;
  if (unverifiedOllamaEl) unverifiedOllamaEl.checked = settings.allow_unverified_ollama;
  const saveHistoryEl = $("savehistory-toggle") as HTMLInputElement | null;
  if (saveHistoryEl) saveHistoryEl.checked = settings.save_history;
  const hotkeySelect = $("hotkey-select") as HTMLSelectElement | null;
  if (hotkeySelect) {
    if (IS_MAC) {
      hotkeySelect.disabled = false;
      hotkeySelect.value = settings.hotkey;
    } else {
      let fixed = hotkeySelect.querySelector<HTMLOptionElement>('option[value="fixed_combo"]');
      if (!fixed) {
        fixed = document.createElement("option");
        fixed.value = "fixed_combo";
        fixed.textContent = FIXED_HOTKEY_LABEL;
        hotkeySelect.prepend(fixed);
      }
      hotkeySelect.value = "fixed_combo";
      hotkeySelect.disabled = true;
    }
  }

  const meta = IS_MAC
    ? HOTKEY_LABELS[settings.hotkey]
    : { kbd: "Ctrl ⇧ Space", label: FIXED_HOTKEY_LABEL };
  if (meta) {
    const kbd = document.querySelector<HTMLElement>(".hotkey-pill kbd");
    if (kbd) kbd.textContent = meta.kbd;
    const label = $("hotkey-label");
    if (label) label.textContent = meta.label;
    const hint = $("hotkey-hint");
    if (hint) {
      hint.textContent = IS_MAC
        ? "Tap once to start. Tap again or stay silent to stop."
        : "Windows and Linux currently use the fixed Ctrl+Shift+Space shortcut.";
    }
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

async function requiredInvoke<T = unknown>(
  cmd: string,
  args?: Record<string, unknown>,
): Promise<T> {
  try {
    return await invoke<T>(cmd, args);
  } catch (err) {
    console.error(`invoke ${cmd} failed:`, err);
    const message = err instanceof Error ? err.message : String(err);
    throw new Error(message);
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
  const applyBodyTabClass = (tab: string) => {
    document.body.classList.toggle("on-history", tab === "history");
  };

  // Initial state
  const activeNav = document.querySelector<HTMLButtonElement>(".nav-item.active");
  applyBodyTabClass(activeNav?.dataset.tab ?? "history");

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
      applyBodyTabClass(tab);
    });
  });
}

function attachListeners() {
  // Hotkey
  $("hotkey-select")?.addEventListener("change", async (e) => {
    if (!IS_MAC) return;
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

  $("unverified-ollama-toggle")?.addEventListener("change", async (e) => {
    const toggle = e.target as HTMLInputElement;
    const checked = toggle.checked;
    toggle.disabled = true;
    try {
      await requiredInvoke("set_allow_unverified_ollama", { enabled: checked });
      await refresh();
      await refreshSetup();
    } catch (err) {
      toggle.checked = !checked;
      window.alert(`Could not update Ollama trust setting:\n${String(err)}`);
      await refresh();
    } finally {
      toggle.disabled = false;
    }
  });

  $("savehistory-toggle")?.addEventListener("change", async (e) => {
    const toggle = e.target as HTMLInputElement;
    const checked = toggle.checked;
    toggle.disabled = true;
    try {
      await requiredInvoke("set_save_history", { enabled: checked });
      await refresh();
    } catch (err) {
      toggle.checked = !checked;
      window.alert(`Could not update history privacy setting:\n${String(err)}`);
      await refresh();
    } finally {
      toggle.disabled = false;
    }
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
    try {
      await requiredInvoke("clear_history");
      await refresh();
      if (clearBtn) flashButton(clearBtn, "Cleared", true);
    } catch (err) {
      await refresh();
      if (clearBtn) flashButton(clearBtn, "Failed", false);
      window.alert(`Could not erase history from disk:\n${String(err)}`);
    }
  });

  $("quit-btn")?.addEventListener("click", async () => {
    await safeInvoke("quit_app");
  });
}

interface SetupStatus {
  whisper_model_present: boolean;
  whisper_loaded: boolean;
  whisper_model_path: string | null;
  ollama_running: boolean;
  ollama_model_pulled: boolean;
  ollama_model_name: string;
  ollama_identity_warning: string | null;
  allow_unverified_ollama: boolean;
  hotkey_configurable: boolean;
  runtime_hotkey_label: string;
}

function formatBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(0)} KB`;
  if (n < 1024 * 1024 * 1024) return `${(n / 1024 / 1024).toFixed(1)} MB`;
  return `${(n / 1024 / 1024 / 1024).toFixed(2)} GB`;
}

function errorMessage(err: unknown): string {
  if (err instanceof Error) return err.message;
  if (typeof err === "string") return err;
  try {
    return JSON.stringify(err);
  } catch {
    return "Unknown error";
  }
}

async function setupInvoke<T = unknown>(
  cmd: string,
  args?: Record<string, unknown>,
): Promise<T> {
  try {
    return await invoke<T>(cmd, args);
  } catch (err) {
    throw new Error(errorMessage(err));
  }
}

function showSetupBanner(
  title: string,
  detail: string,
  actionsHTML: string,
  tone: "info" | "error" = "info",
) {
  resetSetupProgress();
  const banner = $("setup-banner")!;
  banner.hidden = false;
  banner.classList.toggle("setup-error", tone === "error");
  $("setup-title")!.textContent = title;
  $("setup-detail")!.textContent = detail;
  const actions = $("setup-actions")!;
  actions.innerHTML = actionsHTML;
}

function resetSetupProgress() {
  const progress = $("setup-progress");
  const fill = $("setup-progress-fill") as HTMLDivElement | null;
  const label = $("setup-progress-label");
  if (progress) progress.hidden = true;
  if (fill) fill.style.width = "0%";
  if (label) label.textContent = "";
}

function showSetupFailure(title: string, detail: string, manualUrl?: string) {
  resetSetupProgress();
  const manual = manualUrl
    ? `<a class="ghost-btn" href="${manualUrl}" target="_blank" rel="noreferrer">Manual install</a>`
    : "";
  showSetupBanner(
    title,
    detail,
    `<button class="solid-btn" id="btn-retry-setup">Retry</button>${manual}`,
    "error",
  );
  $("btn-retry-setup")?.addEventListener("click", () => void refreshSetup());
}

function hideSetupBanner() {
  const banner = $("setup-banner")!;
  banner.hidden = true;
  banner.classList.remove("setup-error");
  resetSetupProgress();
}

let setupRunning = false;

async function refreshSetup() {
  if (setupRunning) return;
  setupRunning = true;
  try {
    await runSetup();
  } catch (err) {
    showSetupFailure("Setup check failed", errorMessage(err));
  } finally {
    setupRunning = false;
  }
}

async function runSetup() {
  const status = await setupInvoke<SetupStatus>("check_setup");

  // 1. Whisper — auto-download, no click needed
  if (!status.whisper_model_present) {
    const downloaded = await downloadWhisper();
    if (!downloaded) return;
    const loaded = await poll(() => checkWhisperReady(), 1500, 60);
    if (!loaded) {
      showSetupFailure(
        "Whisper did not finish loading",
        "The model downloaded, but Zerm could not confirm it is ready in memory.",
        "https://huggingface.co/ggerganov/whisper.cpp/tree/main",
      );
      return;
    }
    await runSetup();
    return;
  }

  if (!status.whisper_loaded) {
    showSetupBanner(
      "Loading Whisper model",
      "Zerm found the model file and is loading it into memory.",
      `<button class="ghost-btn" id="btn-retry-setup">Retry</button>`,
    );
    $("btn-retry-setup")?.addEventListener("click", () => void refreshSetup());
    const loaded = await poll(() => checkWhisperReady(), 1500, 40);
    if (loaded) {
      await runSetup();
    } else {
      showSetupFailure(
        "Whisper is still not ready",
        "The model file exists, but the backend has not reported a loaded Whisper pipeline.",
        "https://huggingface.co/ggerganov/whisper.cpp/tree/main",
      );
    }
    return;
  }

  // 2. Ollama — require explicit user click before downloading and
  //    executing a third-party installer. Never silent.
  if (!status.ollama_running) {
    showSetupBanner(
      "Set up Ollama",
      "Zerm can install the local AI helper it uses to polish transcripts. Nothing is sent to a cloud service.",
      `<button class="solid-btn" id="btn-install-ollama">Install Ollama</button>
       <a class="ghost-btn" href="https://ollama.com" target="_blank" rel="noreferrer">What is this?</a>`,
    );
    $("btn-install-ollama")?.addEventListener("click", async () => {
      const url = {
        darwin: "https://github.com/ollama/ollama/releases/latest",
        win32: "https://github.com/ollama/ollama/releases/latest",
        linux: "https://ollama.com/install.sh",
      };
      const platformKey = IS_MAC
        ? "darwin"
        : navigator.platform.toLowerCase().includes("win")
          ? "win32"
          : "linux";
      const ok = window.confirm(
        "This will download the official Ollama release asset and launch it after verification. " +
          "Continue?\n\n" +
          `Source: ${url[platformKey]}\n` +
          "Zerm verifies the GitHub release hash and the Ollama publisher signature where your OS supports it.",
      );
      if (ok) await autoInstallOllama();
    });
    return;
  }

  if (status.ollama_identity_warning && !status.allow_unverified_ollama) {
    showSetupBanner(
      "Set up Ollama",
      "Zerm found a local Ollama service. Install the official app, or keep using the local one already on this Mac.",
      `<button class="solid-btn" id="btn-install-ollama">Install official app</button>
       <button class="ghost-btn" id="btn-allow-unverified-ollama">Use existing Ollama</button>
       <button class="ghost-btn" id="btn-retry-setup">Retry</button>`,
    );
    $("btn-install-ollama")?.addEventListener("click", async () => {
      const ok = window.confirm(
        "Zerm will download the official Ollama app, verify it, and open it. Continue?",
      );
      if (ok) await autoInstallOllama();
    });
    $("btn-retry-setup")?.addEventListener("click", () => void refreshSetup());
    $("btn-allow-unverified-ollama")?.addEventListener("click", async () => {
      const ok = window.confirm(
        "Use the Ollama service already running on this Mac?",
      );
      if (!ok) return;
      await requiredInvoke("set_allow_unverified_ollama", { enabled: true });
      await refresh();
      await refreshSetup();
    });
    return;
  }

  // 3. Gemma model — pull from the user's own local Ollama. This is a
  //    LOCAL-only network call (ollama's /api/pull, which Ollama itself
  //    fetches from its library). Safe to kick automatically.
  if (!status.ollama_model_pulled) {
    const pulled = await autoPullModel(status.ollama_model_name);
    if (pulled) await runSetup();
    return;
  }

  hideSetupBanner();
}

async function checkWhisperReady(): Promise<boolean> {
  const s = await setupInvoke<SetupStatus>("check_setup");
  return s.whisper_model_present && s.whisper_loaded;
}

async function poll<T>(
  fn: () => Promise<T>,
  intervalMs: number,
  maxTries: number,
): Promise<T | null> {
  for (let i = 0; i < maxTries; i++) {
    const r = await fn();
    if (r) return r;
    await new Promise((r) => setTimeout(r, intervalMs));
  }
  return null;
}

async function autoInstallOllama(): Promise<boolean> {
  showSetupBanner(
    "Installing Ollama",
    "Zerm is downloading the Ollama installer. You may see a system prompt — approve it.",
    "",
  );
  const progress = $("setup-progress")!;
  const fill = $("setup-progress-fill") as HTMLDivElement;
  const label = $("setup-progress-label")!;
  progress.hidden = false;
  fill.style.width = "0%";
  label.textContent = "Downloading…";

  let unlisten: (() => void) | null = null;
  try {
    const { listen: listenEvent } = await import("@tauri-apps/api/event");
    type InstallProgress =
      | string
      | { status?: string; downloaded?: number; total?: number };
    unlisten = await listenEvent<InstallProgress>(
      "zerm://ollama-install-progress",
      (event) => {
        const p = event.payload;
        if (typeof p !== "string" && p.total && p.downloaded != null) {
          const pct = Math.min(100, (p.downloaded / p.total) * 100);
          fill.style.width = `${pct.toFixed(1)}%`;
          label.textContent = `${formatBytes(p.downloaded)} / ${formatBytes(p.total)}`;
          return;
        }
        const phase = typeof p === "string" ? p : p.status;
        if (phase === "resolving") label.textContent = "Resolving latest release…";
        if (phase === "downloading") label.textContent = "Downloading installer…";
        if (phase === "verifying") label.textContent = "Verifying publisher…";
        if (phase === "installing") label.textContent = "Installing…";
        if (phase === "launching") label.textContent = "Launching installer…";
        if (phase === "done") label.textContent = "Waiting for Ollama to start…";
      },
    );
    await setupInvoke("install_ollama");

    // Wait up to ~2 minutes for Ollama to be running
    showSetupBanner(
      "Finishing Ollama install",
      "Zerm is waiting for the Ollama service to come online.",
      "",
    );
    const ok = await poll(async () => {
      const s = await setupInvoke<SetupStatus>("check_setup");
      return s.ollama_running;
    }, 3000, 40);
    if (ok) {
      await runSetup();
      return true;
    }
    showSetupFailure(
      "Ollama did not start automatically",
      "Open the Ollama app manually, then retry setup.",
      "https://ollama.com/download",
    );
    return false;
  } catch (err) {
    showSetupFailure("Ollama install failed", errorMessage(err), "https://ollama.com/download");
    return false;
  } finally {
    if (unlisten) unlisten();
  }
}

async function autoPullModel(modelName: string): Promise<boolean> {
  showSetupBanner(
    `Pulling ${modelName}`,
    "Zerm is pulling the language model into your local Ollama (one-time).",
    "",
  );
  const progress = $("setup-progress")!;
  const fill = $("setup-progress-fill") as HTMLDivElement;
  const label = $("setup-progress-label")!;
  progress.hidden = false;
  fill.style.width = "0%";
  label.textContent = "Starting…";

  let unlisten: (() => void) | null = null;
  try {
    const { listen: listenEvent } = await import("@tauri-apps/api/event");
    unlisten = await listenEvent<{
      status?: string;
      completed?: number;
      total?: number;
    }>("zerm://ollama-pull-progress", (event) => {
      const p = event.payload;
      if (p.total && p.completed != null) {
        const pct = Math.min(100, (p.completed / p.total) * 100);
        fill.style.width = `${pct.toFixed(1)}%`;
        label.textContent = `${formatBytes(p.completed)} / ${formatBytes(p.total)}`;
      } else if (p.status) {
        label.textContent = p.status;
      }
    });
    await setupInvoke("pull_ollama_model", { model: modelName });
    return true;
  } catch (err) {
    showSetupFailure(
      `Could not pull ${modelName}`,
      errorMessage(err),
      `https://ollama.com/library/${encodeURIComponent(modelName.split(":")[0])}`,
    );
    return false;
  } finally {
    if (unlisten) unlisten();
  }
}

async function downloadWhisper(): Promise<boolean> {
  const banner = $("setup-banner")!;
  banner.hidden = false;
  banner.classList.remove("setup-error");
  $("setup-title")!.textContent = "Downloading Whisper model";
  $("setup-detail")!.textContent = "This is a one-time ~466 MB download.";
  $("setup-actions")!.innerHTML = "";
  const progress = $("setup-progress")!;
  const fill = $("setup-progress-fill")!;
  const label = $("setup-progress-label")!;
  progress.hidden = false;
  (fill as HTMLDivElement).style.width = "0%";
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

    const path = await setupInvoke<string>("download_whisper_model");
    if (path) {
      $("setup-title")!.textContent = "Whisper model installed";
      $("setup-detail")!.textContent = "Loading the model into memory…";
      label.textContent = "100%";
      setTimeout(() => {
        void refreshSetup();
      }, 1500);
      return true;
    }
    return false;
  } catch (err) {
    showSetupFailure(
      "Whisper download failed",
      errorMessage(err),
      "https://huggingface.co/ggerganov/whisper.cpp/tree/main",
    );
    return false;
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
