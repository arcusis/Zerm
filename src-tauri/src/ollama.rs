use crate::state::PromptMode;
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

const DEVELOPER_PROMPT: &str = include_str!("system_prompt.txt");
const HEBREW_PROMPT: &str = include_str!("prompt_he.txt");
const RUSSIAN_PROMPT: &str = include_str!("prompt_ru.txt");
const NONLATIN_PROMPT: &str = include_str!("prompt_nonlatin.txt");

const CONVERSATIONAL_PROMPT: &str = "You are a light-touch editor for voice dictation. The speaker is dictating a casual chat message (Slack, WhatsApp, iMessage, Discord, Teams). Produce text the speaker could send as-is.

PRESERVE their wording. Do NOT paraphrase, shorten, or rephrase unless the raw transcript is genuinely unreadable. Their voice is the point. Keep their hedges, their typos-of-phrasing, their slang, their rambling, their tone. Length of the output should match the length of the input.

ONLY clean up:
- Hesitation and filler words used as filler (uh, um, like as filler, you know, I mean as filler, basically as filler, right as tag, so as opening filler, kind of / sort of as filler).
- Punctuation and capitalisation. Match their formality — if they talk casually, leave lowercase if natural; if they're formal, use proper sentence case.
- Obvious transcription mistakes — wrong homophones, mangled names.
- Stutters and doubled words: \"the the\" → \"the\".

KEEP:
- Their personality, attitude, profanity, opinions.
- Their greetings or sign-offs IF they said them. Do NOT invent greetings.
- Their emojis IF they said \"emoji\". Do NOT sprinkle emojis.
- Their hedges, qualifiers, and conversational markers.

DO NOT:
- Add meta-commentary, AI-flavoured hedging, or corporate-speak.
- Make them sound more formal or more professional than they are.
- Translate. Output language MUST exactly match the input language.

Output the message ONLY. No preamble, no \"Here is your message\".";

const PROFESSIONAL_PROMPT: &str = "You are a light-touch editor for voice dictation. The speaker is dictating something they intend to write down — an email, note, blog post, doc, or other longer prose. Produce polished but faithful text.

PRESERVE their argument, content, voice, and length. Do NOT summarise, paraphrase, introduce ideas they did not express, or omit points they made. If they rambled, they wanted those words in there. Your job is to make it readable, not to rewrite it. Length of the output should be roughly the same as the input.

Clean up:
- Hesitation and filler words used as filler.
- Punctuation, capitalisation, paragraph breaks where the thought clearly shifts.
- Obvious transcription mistakes.
- Sentence-level grammar — verb agreement, tense, fragments that are clearly unintentional.
- Stutters, false starts, and doubled words.

KEEP:
- Their exact word choice. Do NOT swap synonyms.
- Their hedges, qualifiers, opinions, personality, and emphasis.
- Profanity or strong language, unless the surrounding context is clearly a formal setting the speaker themselves signalled.
- Their structure. Only split into paragraphs if the transcript is clearly multi-paragraph in intent. Only use bullets or numbered lists if they explicitly dictated a list.
- Their technical terminology, identifiers, file paths, URLs, and proper nouns exactly as spoken.

DO NOT:
- Add meta-commentary, disclaimers, AI-flavoured hedging, or corporate-speak (\"leverage\", \"in order to\", \"it is important to note\", \"moreover\", etc.).
- Add greetings, sign-offs, or pleasantries they didn't dictate.
- Translate. Output language MUST exactly match the input language.

Output the prose ONLY. No preamble.";

const ENDPOINT: &str = "http://127.0.0.1:11434/api/generate";
const VERSION_ENDPOINT: &str = "http://127.0.0.1:11434/api/version";

#[cfg(any(target_os = "macos", target_os = "linux"))]
fn verify_listener_process() -> Result<()> {
    let out = std::process::Command::new("lsof")
        .args(["-nP", "-iTCP:11434", "-sTCP:LISTEN", "-Fpc"])
        .output()
        .context("run lsof")?;
    if !out.status.success() {
        anyhow::bail!("lsof exited {}", out.status);
    }

    let stdout = String::from_utf8_lossy(&out.stdout);
    let mut pid: Option<String> = None;
    let mut command: Option<String> = None;
    for line in stdout.lines() {
        if let Some(rest) = line.strip_prefix('p') {
            pid = Some(rest.to_string());
        } else if let Some(rest) = line.strip_prefix('c') {
            command = Some(rest.to_string());
            break;
        }
    }

    let command = command.ok_or_else(|| anyhow::anyhow!("no listener command found"))?;
    if command.eq_ignore_ascii_case("ollama") {
        return Ok(());
    }

    anyhow::bail!(
        "port 11434 is owned by '{}' (pid {:?}), not Ollama",
        command,
        pid
    )
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn verify_listener_process() -> Result<()> {
    anyhow::bail!("listener process verification is not implemented on this platform")
}

/// Verify that the process listening on localhost:11434 is actually
/// Ollama and not some random service that bound the port first. We
/// hit /api/version (which Ollama responds to with `{ "version": "X" }`)
/// and accept only a parseable response with a non-empty `version`
/// string. Anything else and we refuse to POST transcripts to it.
pub async fn verify_identity() -> Result<String> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(2))
        .build()
        .context("build http client")?;
    let resp = client
        .get(VERSION_ENDPOINT)
        .send()
        .await
        .context("GET /api/version")?;
    if !resp.status().is_success() {
        anyhow::bail!("ollama /api/version returned {}", resp.status());
    }
    let body: serde_json::Value = resp.json().await.context("parse /api/version")?;
    let version = body
        .get("version")
        .and_then(|v| v.as_str())
        .ok_or_else(|| {
            anyhow::anyhow!(
                "service on 11434 did not return an Ollama-shaped /api/version response"
            )
        })?;
    if version.trim().is_empty() {
        anyhow::bail!("ollama /api/version returned an empty version string");
    }
    if let Err(e) = verify_listener_process() {
        let msg = e.to_string();
        if msg.contains("not Ollama") {
            return Err(e).context("Ollama process identity check failed");
        }
        log::warn!("Ollama process identity could not be fully verified: {e:#}");
    }
    Ok(version.to_string())
}

#[derive(Serialize)]
struct GenerateRequest<'a> {
    model: &'a str,
    prompt: &'a str,
    system: &'a str,
    stream: bool,
    options: Options,
}

#[derive(Serialize)]
struct Options {
    temperature: f32,
    num_predict: i32,
}

#[derive(Deserialize)]
struct GenerateResponse {
    response: String,
}

pub fn system_prompt_for(mode: PromptMode) -> Option<&'static str> {
    match mode {
        PromptMode::Off => None,
        PromptMode::Developer => Some(DEVELOPER_PROMPT),
        PromptMode::Conversational => Some(CONVERSATIONAL_PROMPT),
        PromptMode::Professional => Some(PROFESSIONAL_PROMPT),
    }
}

/// Language-aware prompt selection.
/// - For Hebrew / Russian / non-Latin scripts we override regardless of
///   PromptMode because the code-switching behaviour (preserve inline
///   English technical terms verbatim) is orthogonal to the formality
///   tier and matters more than which tone the user picked.
/// - For Latin-script languages (en, es, fr, de, ...) we use the
///   existing mode-specific prompts.
pub fn system_prompt_for_lang(mode: PromptMode, lang: &str) -> Option<&'static str> {
    match lang {
        "he" => Some(HEBREW_PROMPT),
        "ru" => Some(RUSSIAN_PROMPT),
        // Non-Latin scripts that don't have a bespoke prompt yet.
        "ar" | "fa" | "ur" | "zh" | "ja" | "ko" | "th" | "hi" | "bn" | "el" | "ka" | "hy"
        | "am" | "ti" => Some(NONLATIN_PROMPT),
        _ => system_prompt_for(mode),
    }
}

pub async fn reformat(model: &str, transcript: &str, mode: PromptMode) -> Result<String> {
    reformat_lang(model, transcript, mode, "").await
}

pub async fn reformat_lang(
    model: &str,
    transcript: &str,
    mode: PromptMode,
    lang: &str,
) -> Result<String> {
    if transcript.trim().is_empty() {
        return Ok(String::new());
    }
    let Some(system) = system_prompt_for_lang(mode, lang) else {
        // Off mode on a Latin-script language: return raw transcript unchanged
        return Ok(transcript.trim().to_string());
    };

    // Identity check before we POST the transcript. If something other
    // than Ollama is listening on 11434, treat as no LLM available.
    verify_identity()
        .await
        .context("Ollama identity check failed — refusing to POST transcript")?;

    let req = GenerateRequest {
        model,
        prompt: transcript,
        system,
        stream: false,
        options: Options {
            temperature: 0.2,
            num_predict: 4096,
        },
    };

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(120))
        .build()
        .context("build http client")?;

    let resp = client
        .post(ENDPOINT)
        .json(&req)
        .send()
        .await
        .with_context(|| format!("post {ENDPOINT}"))?;

    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        anyhow::bail!("ollama returned {status}: {body}");
    }

    let parsed: GenerateResponse = resp.json().await.context("parse ollama response")?;
    Ok(parsed.response.trim().to_string())
}
