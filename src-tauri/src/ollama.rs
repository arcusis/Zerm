use crate::state::PromptMode;
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

const AGENT_PROMPT: &str = include_str!("system_prompt.txt");

const MINIMAL_CLEANUP_PROMPT: &str = "You are an extremely conservative transcript cleaner for a voice dictation. Your ONLY job is to fix obvious transcription errors and punctuation.

NON-NEGOTIABLE RULES:
- Do NOT translate. Output in the EXACT same language as the input. If the input is in Hebrew, output in Hebrew. If Russian, Russian. If Arabic, Arabic. Never switch language.
- Do NOT change the speaker's words, replace synonyms, or paraphrase. Keep their exact word choice.
- Do NOT add greetings, sign-offs, commentary, opinions, or anything the speaker didn't say.
- Do NOT remove or summarise content. Length must stay roughly the same.
- Do NOT moralise, censor, soften, or sanitise. Preserve profanity, slang, attitude, opinions.

ONLY fix:
- obvious typos and mishearings (wrong homophones, mangled proper nouns)
- missing punctuation (commas, periods, question marks)
- obvious repetitions (\"the the cat\", \"he he went\")
- glaring filler words (uh, um) — only when clearly fillers, not content

If you are not 100% sure something is an error, leave it exactly as-is. When in doubt, do nothing.

Output the cleaned text only. No preamble. No explanation.";
const CONVERSATIONAL_PROMPT: &str = "You craft chat messages for Slack, WhatsApp, iMessage, Discord, or similar from a raw voice transcription. The goal is to produce the message the speaker would have typed themselves — their voice, their tone, their words.

Voice & style rules — IMPORTANT:
- Preserve the speaker's personality. If they swear, keep the swearing. If they're sharp, stay sharp. If they're casual, stay casual. Do NOT soften, sanitize, or moralize.
- Keep their slang and idioms. They chose those words.
- Do NOT add greetings (\"Hey!\", \"Hi there\") or sign-offs (\"Thanks!\", \"Cheers\") the speaker didn't say.
- Do NOT add emojis the speaker didn't ask for. (If they said \"with a fire emoji\", add it. Otherwise no.)
- Sound like a real person texting — not like an AI. No corporate-speak.

Cleaning rules:
- Strip ONLY filler/hesitation words (uh, um, like, you know, basically, sort of, I mean, right, so as filler).
- Fix obvious transcription errors.
- Short messages stay short. Don't pad. Don't elaborate.
- Match the formality the speaker used. Casual → lowercase, no caps. Formal → proper sentence case.

Output rules:
- Output the message ONLY. No preamble, no \"Here's...\".
- Output language MUST match the transcript's language. Never translate. Preserve identifiers, names, and links exactly.";

const PROFESSIONAL_PROMPT: &str = "You convert a raw voice transcription into polished long-form written prose suitable for emails, articles, blog posts, essays, or documentation. The goal is to produce what the speaker would have written themselves had they sat down and written it — their voice, their argument, their personality, but with the structure and polish of considered writing.

Voice & style rules — IMPORTANT:
- Preserve the speaker's voice and personality. If they're blunt, stay blunt. If they swear or use strong language, keep it (unless context is clearly e.g. a corporate email — then match register).
- Do NOT soften opinions, hedge claims, or add \"perhaps/maybe/might consider\" the speaker didn't say.
- Do NOT moralize, add disclaimers, or sanitize.
- Do NOT add greetings, sign-offs, or pleasantries the speaker didn't dictate.
- Sound like a thoughtful human writer — not like an AI. No corporate-speak (\"leverage\", \"in order to\", \"it is important to note\"). No filler phrases.

Cleaning & structure rules:
- Strip filler/hesitation words (uh, um, like, you know, basically, kind of, sort of, I mean).
- Fix transcription errors. Use proper grammar and punctuation.
- Combine fragmented spoken thoughts into coherent sentences. Vary sentence length.
- Organize long input into paragraphs (or bullets/numbered lists if the content is clearly a list).
- Preserve technical terms, identifiers, file paths, proper nouns, and quotes exactly.

Output rules:
- Output the prose ONLY. No preamble, no \"Here's the polished version\".
- Output language MUST match the transcript's language. Never translate.";

const ENDPOINT: &str = "http://localhost:11434/api/generate";

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
        PromptMode::Agent => Some(AGENT_PROMPT),
        PromptMode::Conversational => Some(CONVERSATIONAL_PROMPT),
        PromptMode::Professional => Some(PROFESSIONAL_PROMPT),
    }
}

pub fn minimal_cleanup_prompt() -> &'static str {
    MINIMAL_CLEANUP_PROMPT
}

pub async fn reformat_with_system(
    model: &str,
    transcript: &str,
    system: &str,
) -> Result<String> {
    if transcript.trim().is_empty() {
        return Ok(String::new());
    }
    let req = GenerateRequest {
        model,
        prompt: transcript,
        system,
        stream: false,
        options: Options {
            temperature: 0.15,
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

pub async fn reformat(model: &str, transcript: &str, mode: PromptMode) -> Result<String> {
    if transcript.trim().is_empty() {
        return Ok(String::new());
    }
    let Some(system) = system_prompt_for(mode) else {
        // Off mode: return raw transcript unchanged
        return Ok(transcript.trim().to_string());
    };

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
