# Zerm Runtime Privacy Model

Zerm is designed around local processing and minimal durable state.

## Runtime Data Flow

1. Microphone audio is captured locally.
2. Whisper transcribes locally from the model stored in app data.
3. Optional rewrite modes send text to the local Ollama service at `127.0.0.1:11434`.
4. The final output is written to the system clipboard.
5. Auto-paste may insert the output into the target app on macOS if enabled and permitted.

## Privacy Defaults

- No accounts.
- No telemetry.
- No hosted transcription service.
- No cloud LLM calls from Zerm itself.
- Dictation history is opt-in.
- Clearing/disabling history also clears the backup state file.

## Hardening Already Landed

- Custom Tauri commands are dashboard-gated where needed.
- History and auto-paste are opt-in.
- Whisper downloads are hash-pinned and bounded.
- Clipboard failure is treated as a job failure for paste/history/done purposes, preventing stale clipboard auto-paste.
- Ollama calls are gated by local identity checks and user opt-in for unverified local service cases.
- Linux Ollama listener identity is treated as unverified unless the user explicitly opts in.

Related: [[Zerm Auto Paste]], [[Zerm Setup And Permissions]]
