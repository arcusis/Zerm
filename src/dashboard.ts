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
  input_device_name: string | null;
}

interface DashboardData {
  stats: Stats;
  history: HistoryEntry[];
  settings: Settings;
}

interface AudioInputDevice {
  id: string;
  name: string;
  is_default: boolean;
  sample_rates: number[];
  channel_counts: number[];
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
  currentSettings = settings;
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
        ? "Tap to start, tap again to stop. Hold for push-to-talk."
        : "Windows and Linux currently use the fixed Ctrl+Shift+Space shortcut.";
    }
  }

  void renderInputDeviceSelect(settings);

  document.querySelectorAll<HTMLButtonElement>(".mode-btn").forEach((btn) => {
    btn.classList.toggle("active", btn.dataset.mode === settings.prompt_mode);
  });

  renderVocabulary(settings.vocabulary);
  renderSetupDiagnostics(lastSetupStatus);
}

async function renderInputDeviceSelect(settings: Settings) {
  const select = $("input-device-select") as HTMLSelectElement | null;
  const hint = $("input-device-hint");
  if (!select) return;

  select.disabled = true;
  const selected = settings.input_device_name ?? "";
  try {
    const devices = await setupInvoke<AudioInputDevice[]>("list_audio_input_devices");
    select.innerHTML = "";

    const systemDefault = document.createElement("option");
    systemDefault.value = "";
    const defaultDevice = devices.find((device) => device.is_default);
    systemDefault.textContent = defaultDevice
      ? `System default (${defaultDevice.name})`
      : "System default";
    select.appendChild(systemDefault);

    for (const device of devices) {
      const option = document.createElement("option");
      option.value = device.id;
      option.textContent = device.is_default ? `${device.name} (default)` : device.name;
      select.appendChild(option);
    }

    if (selected && !devices.some((device) => device.id === selected)) {
      const unavailable = document.createElement("option");
      unavailable.value = selected;
      unavailable.textContent = `${selected} (not available)`;
      select.appendChild(unavailable);
    }

    select.value = selected;
    select.disabled = false;
    if (hint) {
      hint.textContent = devices.length
        ? selected
          ? `Recording from ${selected}.`
          : "Recording from the current macOS default input."
        : "No microphone input devices were reported by macOS.";
    }
  } catch (err) {
    select.innerHTML = `<option value="">Could not load microphones</option>`;
    select.disabled = true;
    if (hint) hint.textContent = errorMessage(err);
  }
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
  $("record-toggle-btn")?.addEventListener("click", async () => {
    const btn = $("record-toggle-btn") as HTMLButtonElement | null;
    if (btn) btn.disabled = true;
    try {
      await requiredInvoke("toggle_recording_from_dashboard");
      await refreshSetup();
    } catch (err) {
      window.alert(`Could not toggle recording:\n${String(err)}`);
      await refreshSetup();
    } finally {
      if (btn) btn.disabled = false;
    }
  });

  // Hotkey
  $("hotkey-select")?.addEventListener("change", async (e) => {
    if (!IS_MAC) return;
    const select = e.target as HTMLSelectElement;
    const key = select.value;
    select.disabled = true;
    try {
      await requiredInvoke("set_hotkey", { key });
      await refresh();
    } catch (err) {
      window.alert(`Could not update hotkey:\n${String(err)}`);
      await refresh();
    } finally {
      select.disabled = false;
    }
  });

  $("input-device-select")?.addEventListener("change", async (e) => {
    const select = e.target as HTMLSelectElement;
    const deviceId = select.value || null;
    select.disabled = true;
    try {
      await requiredInvoke("set_input_device", { deviceId });
      await refresh();
      await refreshSetup();
    } catch (err) {
      window.alert(`Could not update microphone:\n${String(err)}`);
      await refresh();
    } finally {
      select.disabled = false;
    }
  });

  // VAD
  $("vad-toggle")?.addEventListener("change", async (e) => {
    const toggle = e.target as HTMLInputElement;
    const checked = toggle.checked;
    toggle.disabled = true;
    try {
      await requiredInvoke("set_vad_enabled", { enabled: checked });
      await refresh();
    } catch (err) {
      toggle.checked = !checked;
      window.alert(`Could not update VAD:\n${String(err)}`);
      await refresh();
    } finally {
      toggle.disabled = false;
    }
  });

  $("autopaste-toggle")?.addEventListener("change", async (e) => {
    const toggle = e.target as HTMLInputElement;
    const checked = toggle.checked;
    toggle.disabled = true;
    try {
      await requiredInvoke("set_auto_paste", { enabled: checked });
      await refresh();
      await refreshSetup();
    } catch (err) {
      toggle.checked = !checked;
      window.alert(`Could not enable auto-paste:\n${String(err)}`);
      await refresh();
      await refreshSetup();
    } finally {
      toggle.disabled = false;
    }
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
      try {
        await requiredInvoke("set_prompt_mode", { mode });
        await refresh();
      } catch (err) {
        window.alert(`Could not update prompt mode:\n${String(err)}`);
        await refresh();
      }
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
  input_permission: {
    required: boolean;
    granted: boolean;
    title: string;
    detail: string;
    settings_label: string;
  };
  microphone_permission: {
    required: boolean;
    granted: boolean;
    title: string;
    detail: string;
    settings_label: string;
  };
  app_signing?: SigningSummary | null;
  signing?: SigningSummary | null;
  signing_summary?: SigningSummary | null;
  auto_paste_ready?: boolean | null;
  automation_permission?: SetupPermissionStatus | null;
  last_insertion?: InsertionDiagnostic | null;
  recording_lifecycle?: string | null;
  last_capture?: CaptureDiagnostic | null;
  insertion?: InsertionDiagnostic | null;
  diagnostics?: Record<string, unknown> | null;
}

interface SetupPermissionStatus {
  required?: boolean;
  granted?: boolean;
  title?: string;
  detail?: string;
  settings_label?: string;
}

interface SigningSummary {
  status?: string | null;
  authority?: string | string[] | null;
  team_identifier?: string | null;
  teamIdentifier?: string | null;
  identifier?: string | null;
  path?: string | null;
  detail?: string | null;
  warning?: string | null;
  trusted?: boolean | null;
  stable_tcc_identity?: boolean | null;
  stableTccIdentity?: boolean | null;
  notarized?: boolean | null;
}

interface InsertionDiagnostic {
  strategy?: string | null;
  status?: string | null;
  detail?: string | null;
  target_app?: string | null;
  targetApp?: string | null;
  target_bundle_id?: string | null;
  targetBundleId?: string | null;
  confirmed?: boolean | null;
  error?: string | null;
  timestamp?: number | string | null;
  at?: number | string | null;
}

interface CaptureDiagnostic {
  status?: string | null;
  raw_samples?: number | null;
  sample_rate?: number | null;
  channels?: number | null;
  approx_seconds?: number | null;
  device_name?: string | null;
  sample_format?: string | null;
  peak_rms?: number | null;
  detail?: string | null;
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

let currentSettings: Settings | null = null;
let lastSetupStatus: SetupStatus | null = null;
let lastSetupCheckedAt: Date | null = null;

function boolLabel(value: boolean | null | undefined): string {
  if (value === true) return "Yes";
  if (value === false) return "No";
  return "Unknown";
}

function shortenPath(path: string | null | undefined): string {
  if (!path) return "Not reported";
  const normalized = path.replace(/\\/g, "/");
  const parts = normalized.split("/");
  if (parts.length <= 4) return path;
  return `…/${parts.slice(-3).join("/")}`;
}

function escapeHtml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#039;");
}

function setupRecord(status: SetupStatus): Record<string, unknown> {
  return status as unknown as Record<string, unknown>;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function optionalRecord(value: unknown): Record<string, unknown> | null {
  return isRecord(value) ? value : null;
}

function stringFromUnknown(value: unknown): string | null {
  if (typeof value === "string") return value;
  if (typeof value === "number" || typeof value === "boolean") return String(value);
  return null;
}

function booleanFromUnknown(value: unknown): boolean | null {
  return typeof value === "boolean" ? value : null;
}

function findRecord(status: SetupStatus, keys: string[]): Record<string, unknown> | null {
  const root = setupRecord(status);
  for (const key of keys) {
    const direct = optionalRecord(root[key]);
    if (direct) return direct;
  }
  const diagnostics = optionalRecord(root.diagnostics);
  if (!diagnostics) return null;
  for (const key of keys) {
    const nested = optionalRecord(diagnostics[key]);
    if (nested) return nested;
  }
  return null;
}

function firstString(record: Record<string, unknown> | null, keys: string[]): string | null {
  if (!record) return null;
  for (const key of keys) {
    const value = stringFromUnknown(record[key]);
    if (value) return value;
  }
  return null;
}

function firstBoolean(record: Record<string, unknown> | null, keys: string[]): boolean | null {
  if (!record) return null;
  for (const key of keys) {
    const value = booleanFromUnknown(record[key]);
    if (value !== null) return value;
  }
  return null;
}

function detectSigningSummary(status: SetupStatus): {
  label: string;
  detail: string;
  tone: "ok" | "warn" | "neutral";
} {
  const signing = findRecord(status, ["app_signing", "signing", "signing_summary"]);
  const statusText = firstString(signing, ["status", "summary", "state"]);
  const authority = firstString(signing, ["authority", "certificate", "signer"]);
  const teamId = firstString(signing, ["team_identifier", "teamIdentifier", "team_id"]);
  const warning = firstString(signing, ["warning", "detail", "message"]);
  const stableTcc = firstBoolean(signing, ["stable_tcc_identity", "stableTccIdentity"]);
  const trusted = firstBoolean(signing, ["trusted", "valid"]);
  const detail = status.input_permission.detail;

  if (statusText || authority || teamId || warning || stableTcc !== null || trusted !== null) {
    const label = statusText ?? (trusted === false ? "Needs attention" : "Reported");
    const parts = [
      teamId ? `Team ${teamId}` : null,
      authority ?? null,
      stableTcc === false ? "TCC identity may change between installs" : null,
      warning ?? null,
    ].filter((part): part is string => Boolean(part));
    return {
      label,
      detail: parts.join(" · ") || "Backend reported signing metadata without details.",
      tone: trusted === false || stableTcc === false || warning ? "warn" : "ok",
    };
  }

  if (detail.includes("not Developer ID signed") || detail.includes("stale Accessibility toggle")) {
    return {
      label: "Ad-hoc or unsigned local build",
      detail:
        "macOS can show Zerm enabled while the current rebuilt binary is not trusted. Remove and re-add the installed app, or use a Developer ID signed build.",
      tone: "warn",
    };
  }

  return {
    label: "Not reported",
    detail: "The backend has not exposed signing metadata for this build yet.",
    tone: "neutral",
  };
}

function detectInsertionDiagnostic(status: SetupStatus): {
  label: string;
  detail: string;
  tone: "ok" | "warn" | "neutral";
} {
  const insertion = findRecord(status, ["last_insertion", "insertion", "lastInsertion"]);
  const strategy = firstString(insertion, ["strategy", "method"]);
  const state = firstString(insertion, ["status", "state"]);
  const error = firstString(insertion, ["error", "failure"]);
  const detail = firstString(insertion, ["detail", "message"]);
  const target =
    firstString(insertion, ["target_app", "targetApp", "app"]) ??
    firstString(insertion, ["target_bundle_id", "targetBundleId", "bundle_id"]);
  const confirmed = firstBoolean(insertion, ["confirmed", "pasted", "success"]);

  if (!insertion) {
    return {
      label: "Awaiting backend report",
      detail:
        "No last insertion strategy/status has been reported yet. This panel is ready for TextInjector diagnostics.",
      tone: "neutral",
    };
  }

  const label = state ?? strategy ?? (confirmed === true ? "Inserted" : "Reported");
  const parts = [
    strategy ? `Strategy: ${strategy}` : null,
    target ? `Target: ${target}` : null,
    confirmed !== null ? `Confirmed: ${boolLabel(confirmed)}` : null,
    error ?? detail ?? null,
  ].filter((part): part is string => Boolean(part));
  return {
    label,
    detail: parts.join(" · ") || "Insertion diagnostics were reported without details.",
    tone: error || confirmed === false ? "warn" : confirmed === true ? "ok" : "neutral",
  };
}

function captureStatus(status: SetupStatus): {
  label: string;
  detail: string;
  tone: "ok" | "warn" | "neutral";
} {
  const capture = status.last_capture;
  if (!capture) {
    return {
      label: status.recording_lifecycle ?? "idle",
      detail: "No capture has completed in this app session.",
      tone: status.recording_lifecycle === "idle" ? "neutral" : "warn",
    };
  }
  const seconds =
    typeof capture.approx_seconds === "number"
      ? `${capture.approx_seconds.toFixed(2)}s`
      : "unknown duration";
  const samples =
    typeof capture.raw_samples === "number"
      ? capture.raw_samples.toLocaleString()
      : "unknown";
  const peak =
    typeof capture.peak_rms === "number"
      ? `peak ${capture.peak_rms.toFixed(4)}`
      : "peak unknown";
  const device = capture.device_name ? `${capture.device_name} · ` : "";
  const format = capture.sample_format ? ` · ${capture.sample_format}` : "";
  return {
    label: capture.status ?? "captured",
    detail:
      capture.detail ??
      `${device}${seconds} · ${samples} samples · ${peak} · ${capture.sample_rate ?? "?"} Hz · ${
        capture.channels ?? "?"
      } channel${capture.channels === 1 ? "" : "s"}${format}`,
    tone: capture.status === "too_short" || capture.status === "silent" ? "warn" : "ok",
  };
}

function diagnosticsRow(
  label: string,
  value: string,
  detail: string,
  tone: "ok" | "warn" | "neutral" = "neutral",
): string {
  return `
    <div class="diagnostic-row diagnostic-${tone}">
      <span class="diagnostic-dot" aria-hidden="true"></span>
      <div class="diagnostic-copy">
        <span class="diagnostic-label">${escapeHtml(label)}</span>
        <strong>${escapeHtml(value)}</strong>
        <span>${escapeHtml(detail)}</span>
      </div>
    </div>
  `;
}

function ensureDiagnosticsSurface(): HTMLElement | null {
  let panel = $("diagnostics-panel");
  if (panel) return panel;

  const settings = document.querySelector<HTMLElement>(".settings");
  if (!settings) return null;

  panel = document.createElement("section");
  panel.id = "diagnostics-panel";
  panel.className = "diagnostics-panel";
  panel.innerHTML = `
    <header class="diagnostics-header">
      <div>
        <span class="eyebrow">Diagnostics</span>
        <h3>Setup and insertion</h3>
      </div>
      <button id="diagnostics-refresh" class="ghost-btn" type="button">Recheck</button>
    </header>
    <div id="diagnostics-grid" class="diagnostics-grid"></div>
    <div id="diagnostics-actions" class="diagnostics-actions"></div>
    <p id="diagnostics-note" class="diagnostics-note"></p>
  `;
  settings.appendChild(panel);
  $("diagnostics-refresh")?.addEventListener("click", async () => {
    await refresh();
    await refreshSetup();
  });
  return panel;
}

function setDiagnosticsRefreshing(refreshing: boolean) {
  const btn = $("diagnostics-refresh") as HTMLButtonElement | null;
  if (!btn) return;
  btn.disabled = refreshing;
  btn.textContent = refreshing ? "Checking…" : "Recheck";
}

let lastRecordingLifecycle: string | null = null;

function updateRecordButton() {
  const btn = $("record-toggle-btn") as HTMLButtonElement | null;
  if (!btn) return;
  const active =
    lastRecordingLifecycle === "starting" ||
    lastRecordingLifecycle === "recording" ||
    lastRecordingLifecycle === "stopping";
  btn.textContent = active ? "Stop" : "Start";
  btn.dataset.active = active ? "true" : "false";
}

function renderSetupDiagnostics(status: SetupStatus | null, failure?: string) {
  const panel = ensureDiagnosticsSurface();
  const grid = $("diagnostics-grid");
  const actions = $("diagnostics-actions");
  const note = $("diagnostics-note");
  if (!panel || !grid || !actions || !note) return;

  if (!status) {
    grid.innerHTML = diagnosticsRow(
      "Setup",
      failure ? "Check failed" : "Checking…",
      failure ?? "Waiting for the backend setup status.",
      failure ? "warn" : "neutral",
    );
    actions.innerHTML = "";
    note.textContent = "";
    updateRecordButton();
    return;
  }

  lastRecordingLifecycle = status.recording_lifecycle ?? null;
  updateRecordButton();

  const signing = detectSigningSummary(status);
  const insertion = detectInsertionDiagnostic(status);
  const capture = captureStatus(status);
  const inputGranted = status.input_permission.granted;
  const microphoneGranted = status.microphone_permission.granted;
  const autoPasteEnabled = currentSettings?.auto_paste === true;
  const backendAutoPasteReady = status.auto_paste_ready;
  const automation = status.automation_permission ?? null;
  const automationRequired = automation?.required === true;
  const automationGranted = automation?.granted === true;
  const autoPasteReady =
    backendAutoPasteReady ??
    (autoPasteEnabled && (!status.input_permission.required || inputGranted));

  grid.innerHTML = [
    diagnosticsRow(
      "Accessibility",
      inputGranted ? "Allowed" : status.input_permission.required ? "Needs permission" : "Not required",
      status.input_permission.detail,
      inputGranted || !status.input_permission.required ? "ok" : "warn",
    ),
    diagnosticsRow(
      "Microphone",
      microphoneGranted
        ? "Allowed"
        : status.microphone_permission.required
          ? "Needs permission"
          : "Not required",
      status.microphone_permission.detail,
      microphoneGranted || !status.microphone_permission.required ? "ok" : "warn",
    ),
    diagnosticsRow(
      "Auto-paste",
      autoPasteEnabled ? (autoPasteReady ? "Enabled and ready" : "Enabled, blocked") : "Off",
      backendAutoPasteReady === false
        ? "Backend reports auto-paste is not ready."
        : autoPasteEnabled
          ? "Zerm will insert into the app focused when recording starts."
          : "Enable auto-paste when you want Zerm to insert text automatically.",
      autoPasteEnabled && !autoPasteReady ? "warn" : autoPasteReady ? "ok" : "neutral",
    ),
    diagnosticsRow(
      "Automation",
      automationRequired ? boolLabel(automationGranted) : "Not reported",
      automation?.detail ??
        "Only shown when the backend reports a separate Automation permission requirement.",
      automationRequired && !automationGranted ? "warn" : automationRequired ? "ok" : "neutral",
    ),
    diagnosticsRow("App signing", signing.label, signing.detail, signing.tone),
    diagnosticsRow(
      "Insertion",
      insertion.label,
      insertion.detail,
      insertion.tone,
    ),
    diagnosticsRow(
      "Whisper",
      status.whisper_loaded
        ? "Loaded"
        : status.whisper_model_present
          ? "Installed, loading"
          : "Missing",
      shortenPath(status.whisper_model_path),
      status.whisper_loaded ? "ok" : "warn",
    ),
    diagnosticsRow(
      "Ollama",
      status.ollama_running
        ? status.ollama_model_pulled
          ? "Ready"
          : "Model missing"
        : "Not running",
      status.ollama_identity_warning ??
        `${status.ollama_model_name} · unverified local service ${boolLabel(status.allow_unverified_ollama)}`,
      status.ollama_running && status.ollama_model_pulled && !status.ollama_identity_warning
        ? "ok"
        : "warn",
    ),
    diagnosticsRow(
      "Hotkey",
      status.runtime_hotkey_label,
      status.hotkey_configurable
        ? "This shortcut is configurable on macOS."
        : "This platform uses the fixed runtime shortcut.",
      "neutral",
    ),
    diagnosticsRow(
      "Recorder",
      status.recording_lifecycle ?? "idle",
      capture.detail,
      capture.tone,
    ),
  ].join("");

  actions.innerHTML = "";
  if (status.input_permission.required && !inputGranted) {
    const repairBtn = document.createElement("button");
    repairBtn.className = "solid-btn";
    repairBtn.type = "button";
    repairBtn.textContent = "Repair Accessibility";
    repairBtn.addEventListener("click", async () => {
      repairBtn.disabled = true;
      try {
        await requiredInvoke("repair_macos_input_permissions");
        startPermissionRecheck();
        void refreshSetup();
      } catch (err) {
        window.alert(`Could not repair macOS permissions:\n${String(err)}`);
      } finally {
        repairBtn.disabled = false;
      }
    });

    const openBtn = document.createElement("button");
    openBtn.className = "ghost-btn";
    openBtn.type = "button";
    openBtn.textContent = status.input_permission.settings_label;
    openBtn.addEventListener("click", async () => {
      await safeInvoke("open_input_permission_settings");
      startPermissionRecheck();
      void refreshSetup();
    });

    const retryBtn = document.createElement("button");
    retryBtn.className = "ghost-btn";
    retryBtn.type = "button";
    retryBtn.textContent = "Recheck now";
    retryBtn.addEventListener("click", () => void refreshSetup());
    actions.append(repairBtn, openBtn, retryBtn);
  }
  if (status.microphone_permission.required && !microphoneGranted) {
    const openMicBtn = document.createElement("button");
    openMicBtn.className = "solid-btn";
    openMicBtn.type = "button";
    openMicBtn.textContent = status.microphone_permission.settings_label;
    openMicBtn.addEventListener("click", async () => {
      await safeInvoke("open_microphone_permission_settings");
      startPermissionRecheck();
      void refreshSetup();
    });

    const retryMicBtn = document.createElement("button");
    retryMicBtn.className = "ghost-btn";
    retryMicBtn.type = "button";
    retryMicBtn.textContent = "Recheck microphone";
    retryMicBtn.addEventListener("click", () => void refreshSetup());
    actions.append(openMicBtn, retryMicBtn);
  }

  note.textContent = lastSetupCheckedAt
    ? `Last checked ${lastSetupCheckedAt.toLocaleTimeString([], {
        hour: "2-digit",
        minute: "2-digit",
        second: "2-digit",
      })}.`
    : "";
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
let setupRefreshQueued = false;
let permissionPollTimer: number | null = null;

function startPermissionRecheck() {
  if (permissionPollTimer !== null) return;
  permissionPollTimer = window.setInterval(() => {
    if (!document.hidden) void refreshSetup();
  }, 1000);
}

function stopPermissionRecheck() {
  if (permissionPollTimer === null) return;
  clearInterval(permissionPollTimer);
  permissionPollTimer = null;
}

async function refreshSetup() {
  if (setupRunning) {
    setupRefreshQueued = true;
    return;
  }
  setupRunning = true;
  setDiagnosticsRefreshing(true);
  try {
    await runSetup();
  } catch (err) {
    const message = errorMessage(err);
    renderSetupDiagnostics(lastSetupStatus, message);
    showSetupFailure("Setup check failed", message);
  } finally {
    setupRunning = false;
    setDiagnosticsRefreshing(false);
    if (setupRefreshQueued) {
      setupRefreshQueued = false;
      window.setTimeout(() => void refreshSetup(), 0);
    }
  }
}

async function runSetup() {
  const status = await setupInvoke<SetupStatus>("check_setup");
  lastSetupStatus = status;
  lastSetupCheckedAt = new Date();
  renderSetupDiagnostics(status);

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

  if (status.input_permission.required && !status.input_permission.granted) {
    startPermissionRecheck();
    showSetupBanner(
      status.input_permission.title,
      status.input_permission.detail,
      `<button class="solid-btn" id="btn-repair-input-permissions">Repair Accessibility</button>
       <button class="ghost-btn" id="btn-open-input-permissions">${status.input_permission.settings_label}</button>
       <button class="ghost-btn" id="btn-retry-setup">Recheck now</button>`,
      "error",
    );
    $("btn-repair-input-permissions")?.addEventListener("click", async () => {
      await requiredInvoke("repair_macos_input_permissions");
      startPermissionRecheck();
      void refreshSetup();
    });
    $("btn-open-input-permissions")?.addEventListener("click", async () => {
      await safeInvoke("open_input_permission_settings");
      startPermissionRecheck();
      void refreshSetup();
    });
    $("btn-retry-setup")?.addEventListener("click", () => void refreshSetup());
    return;
  }

  if (status.microphone_permission.required && !status.microphone_permission.granted) {
    startPermissionRecheck();
    showSetupBanner(
      status.microphone_permission.title,
      status.microphone_permission.detail,
      `<button class="solid-btn" id="btn-open-microphone-permissions">${status.microphone_permission.settings_label}</button>
       <button class="ghost-btn" id="btn-retry-setup">Recheck now</button>`,
      "error",
    );
    $("btn-open-microphone-permissions")?.addEventListener("click", async () => {
      await safeInvoke("open_microphone_permission_settings");
      startPermissionRecheck();
      void refreshSetup();
    });
    $("btn-retry-setup")?.addEventListener("click", () => void refreshSetup());
    return;
  }
  stopPermissionRecheck();

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
      "Zerm found a local Ollama service that could not be fully verified. Install the official app, or explicitly keep using the existing local service.",
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
        "Use the Ollama service already running on this computer?",
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
  window.addEventListener("focus", () => {
    void refresh();
    void refreshSetup();
  });
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden) {
      void refresh();
      void refreshSetup();
    }
  });
  await refresh();
  void refreshSetup();
  try {
    await listen<DashboardData>("zerm://dashboard-updated", (event) => {
      renderStats(event.payload.stats);
      renderHistory(event.payload.history);
      renderSettings(event.payload.settings);
      void refreshSetup();
    });
  } catch (err) {
    console.warn("listen failed:", err);
  }
}

window.addEventListener("DOMContentLoaded", () => {
  void init();
});
