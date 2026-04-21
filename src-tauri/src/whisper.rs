use anyhow::{Context, Result};
use std::path::Path;
use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters};

pub struct Whisper {
    ctx: WhisperContext,
}

impl Whisper {
    pub fn load(model_path: &Path) -> Result<Self> {
        let path_str = model_path
            .to_str()
            .context("model path is not valid UTF-8")?;
        let ctx = WhisperContext::new_with_params(path_str, WhisperContextParameters::default())
            .with_context(|| format!("failed to load whisper model from {path_str}"))?;
        Ok(Self { ctx })
    }

    pub fn transcribe(&self, samples: &[f32]) -> Result<String> {
        Ok(self.transcribe_with_options(samples, None, None)?.0)
    }

    /// Returns `(transcript, detected_lang_code)`. The language code is
    /// whatever Whisper auto-detected (or the one passed in), as an ISO
    /// 639-1 string like "en", "he", "ru", "ar", "zh". Empty if detection
    /// failed; callers can treat that as "en".
    pub fn transcribe_with_options(
        &self,
        samples: &[f32],
        language: Option<&str>,
        initial_prompt: Option<&str>,
    ) -> Result<(String, String)> {
        let mut state = self.ctx.create_state().context("create whisper state")?;
        let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });
        params.set_n_threads(num_cpus().min(8) as i32);
        params.set_translate(false);
        params.set_language(language.or(Some("auto")));
        params.set_print_special(false);
        params.set_print_progress(false);
        params.set_print_realtime(false);
        params.set_print_timestamps(false);
        params.set_suppress_blank(true);
        params.set_no_context(true);
        if let Some(prompt) = initial_prompt {
            if !prompt.trim().is_empty() {
                params.set_initial_prompt(prompt);
            }
        }

        state.full(params, samples).context("whisper full failed")?;

        let n_segments = state.full_n_segments().context("segment count")?;
        let mut text = String::new();
        for i in 0..n_segments {
            let seg = state.full_get_segment_text(i).context("segment text")?;
            text.push_str(&seg);
        }

        // Whisper produces a detected-language id as part of the
        // transcription pass. Use that to drive downstream prompt/model
        // dispatch — it's essentially free and more accurate on short
        // utterances than any heuristic or separate classifier.
        // whisper-rs 0.13 exposes this via full_lang_id_from_state.
        let lang = state
            .full_lang_id_from_state()
            .ok()
            .and_then(|id| whisper_rs::get_lang_str(id).map(|s| s.to_string()))
            .unwrap_or_default();

        Ok((text.trim().to_string(), lang))
    }
}

fn num_cpus() -> usize {
    std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(4)
}
