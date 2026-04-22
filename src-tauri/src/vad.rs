use std::ops::Range;

pub const DEFAULT_SILENCE_RMS_THRESHOLD: f32 = 0.01;
pub const DEFAULT_SPEECH_RMS_THRESHOLD: f32 = 0.02;
pub const DEFAULT_SILENCE_DURATION_MS: u64 = 1500;
pub const DEFAULT_VAD_TICK_MS: u64 = 100;
pub const DEFAULT_NO_SPEECH_TIMEOUT_MS: u64 = 10_000;
pub const DEFAULT_CALIBRATION_MS: u64 = 500;
pub const DEFAULT_PRE_ROLL_MS: u64 = 250;
pub const DEFAULT_POST_ROLL_MS: u64 = DEFAULT_SILENCE_DURATION_MS;

/// Why the capture ended on its own (not via the explicit stop channel).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StopReason {
    /// VAD detected sustained silence after speech.
    Silence,
    /// Max recording length reached -- stop regardless of VAD state.
    HardLimit,
    /// Recording started but no speech was ever detected within the configured
    /// timeout. Likely an accidental hotkey press.
    NoSpeech,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VadState {
    Calibrating,
    WaitingForSpeech,
    Speech,
    PostRoll,
    Stopped,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VadDecision {
    Continue,
    Stop(StopReason),
}

#[derive(Debug, Clone)]
pub struct VadConfig {
    pub tick_ms: u64,
    pub silence_rms_threshold: f32,
    pub speech_rms_threshold: f32,
    pub silence_duration_ms: u64,
    pub no_speech_timeout_ms: u64,
    pub calibration_ms: u64,
    pub adaptive_enabled: bool,
    pub silence_noise_multiplier: f32,
    pub speech_noise_multiplier: f32,
    pub max_adaptive_silence_threshold: f32,
    pub max_adaptive_speech_threshold: f32,
    pub pre_roll_ms: u64,
    pub post_roll_ms: u64,
}

impl Default for VadConfig {
    fn default() -> Self {
        Self {
            tick_ms: DEFAULT_VAD_TICK_MS,
            silence_rms_threshold: DEFAULT_SILENCE_RMS_THRESHOLD,
            speech_rms_threshold: DEFAULT_SPEECH_RMS_THRESHOLD,
            silence_duration_ms: DEFAULT_SILENCE_DURATION_MS,
            no_speech_timeout_ms: DEFAULT_NO_SPEECH_TIMEOUT_MS,
            calibration_ms: DEFAULT_CALIBRATION_MS,
            adaptive_enabled: false,
            silence_noise_multiplier: 1.2,
            speech_noise_multiplier: 1.6,
            max_adaptive_silence_threshold: 0.04,
            max_adaptive_speech_threshold: 0.04,
            pre_roll_ms: DEFAULT_PRE_ROLL_MS,
            post_roll_ms: DEFAULT_POST_ROLL_MS,
        }
    }
}

impl VadConfig {
    pub fn frames_per_tick(&self, sample_rate: u32, channels: u16) -> usize {
        let frames = sample_rate as u64 * channels.max(1) as u64 * self.tick_ms.max(1) / 1000;
        frames.max(1) as usize
    }

    pub fn silence_ticks_required(&self) -> u32 {
        ticks_for_duration(self.silence_duration_ms, self.tick_ms)
    }

    pub fn no_speech_ticks_required(&self) -> u32 {
        ticks_for_duration(self.no_speech_timeout_ms, self.tick_ms)
    }

    pub fn calibration_ticks_required(&self) -> u32 {
        ticks_for_duration(self.calibration_ms, self.tick_ms)
    }

    pub fn pre_roll_samples(&self, sample_rate: u32, channels: u16) -> usize {
        samples_for_duration(self.pre_roll_ms, sample_rate, channels)
    }

    pub fn post_roll_samples(&self, sample_rate: u32, channels: u16) -> usize {
        samples_for_duration(self.post_roll_ms, sample_rate, channels)
    }
}

#[allow(dead_code)]
#[derive(Debug, Clone)]
pub struct VadDiagnostics {
    pub state: VadState,
    pub samples_seen: usize,
    pub ticks_seen: u32,
    pub last_rms: f32,
    pub peak_rms: f32,
    pub ambient_rms: Option<f32>,
    pub silence_threshold: f32,
    pub speech_threshold: f32,
    pub speech_detected: bool,
    pub speech_ticks: u32,
    pub silence_ticks: u32,
    pub no_speech_ticks: u32,
    pub calibration_ticks: u32,
    pub speech_start_sample: Option<usize>,
    pub last_speech_sample: Option<usize>,
    pub pre_roll_samples: usize,
    pub post_roll_samples: usize,
    pub stop_reason: Option<StopReason>,
}

pub struct VadEngine {
    config: VadConfig,
    diagnostics: VadDiagnostics,
    calibration_rms_sum: f32,
}

impl VadEngine {
    pub fn new(config: VadConfig, sample_rate: u32, channels: u16) -> Self {
        let state = if config.calibration_ticks_required() > 0 {
            VadState::Calibrating
        } else {
            VadState::WaitingForSpeech
        };
        let diagnostics = VadDiagnostics {
            state,
            samples_seen: 0,
            ticks_seen: 0,
            last_rms: 0.0,
            peak_rms: 0.0,
            ambient_rms: None,
            silence_threshold: config.silence_rms_threshold,
            speech_threshold: config.speech_rms_threshold,
            speech_detected: false,
            speech_ticks: 0,
            silence_ticks: 0,
            no_speech_ticks: 0,
            calibration_ticks: 0,
            speech_start_sample: None,
            last_speech_sample: None,
            pre_roll_samples: config.pre_roll_samples(sample_rate, channels),
            post_roll_samples: config.post_roll_samples(sample_rate, channels),
            stop_reason: None,
        };
        Self {
            config,
            diagnostics,
            calibration_rms_sum: 0.0,
        }
    }

    pub fn frames_per_tick(&self, sample_rate: u32, channels: u16) -> usize {
        self.config.frames_per_tick(sample_rate, channels)
    }

    pub fn diagnostics(&self) -> &VadDiagnostics {
        &self.diagnostics
    }

    pub fn force_stop(&mut self, reason: StopReason) {
        self.diagnostics.stop_reason = Some(reason);
        self.diagnostics.state = VadState::Stopped;
    }

    pub fn observe(&mut self, rms: f32, appended_samples: usize) -> VadDecision {
        if self.diagnostics.stop_reason.is_some() {
            return VadDecision::Continue;
        }

        self.diagnostics.samples_seen = self
            .diagnostics
            .samples_seen
            .saturating_add(appended_samples);
        self.diagnostics.ticks_seen = self.diagnostics.ticks_seen.saturating_add(1);
        self.diagnostics.last_rms = rms;
        self.diagnostics.peak_rms = self.diagnostics.peak_rms.max(rms);

        self.observe_ambient(rms);

        if rms >= self.diagnostics.speech_threshold {
            self.mark_speech(appended_samples);
            return VadDecision::Continue;
        }

        if self.diagnostics.speech_detected && rms < self.diagnostics.silence_threshold {
            self.diagnostics.silence_ticks = self.diagnostics.silence_ticks.saturating_add(1);
            self.diagnostics.state = VadState::PostRoll;
            if self.diagnostics.silence_ticks >= self.config.silence_ticks_required() {
                self.force_stop(StopReason::Silence);
                return VadDecision::Stop(StopReason::Silence);
            }
            return VadDecision::Continue;
        }

        if self.diagnostics.speech_detected {
            self.diagnostics.silence_ticks = self.diagnostics.silence_ticks.saturating_sub(1);
            self.diagnostics.state = VadState::Speech;
            return VadDecision::Continue;
        }

        self.diagnostics.no_speech_ticks = self.diagnostics.no_speech_ticks.saturating_add(1);
        self.diagnostics.state =
            if self.diagnostics.calibration_ticks < self.config.calibration_ticks_required() {
                VadState::Calibrating
            } else {
                VadState::WaitingForSpeech
            };
        if self.diagnostics.no_speech_ticks >= self.config.no_speech_ticks_required() {
            self.force_stop(StopReason::NoSpeech);
            return VadDecision::Stop(StopReason::NoSpeech);
        }

        VadDecision::Continue
    }

    #[allow(dead_code)]
    pub fn trim_range(&self, total_samples: usize) -> Option<Range<usize>> {
        let start = self.diagnostics.speech_start_sample?;
        let end = self.diagnostics.last_speech_sample.unwrap_or(start);
        let start = start.saturating_sub(self.diagnostics.pre_roll_samples);
        let end = end
            .saturating_add(self.diagnostics.post_roll_samples)
            .min(total_samples);
        Some(start..end.max(start))
    }

    fn observe_ambient(&mut self, rms: f32) {
        if self.diagnostics.speech_detected {
            return;
        }
        if self.diagnostics.calibration_ticks >= self.config.calibration_ticks_required() {
            return;
        }
        if rms >= self.config.speech_rms_threshold {
            return;
        }

        self.diagnostics.calibration_ticks = self.diagnostics.calibration_ticks.saturating_add(1);
        self.calibration_rms_sum += rms;
        let ambient = self.calibration_rms_sum / self.diagnostics.calibration_ticks as f32;
        self.diagnostics.ambient_rms = Some(ambient);

        if !self.config.adaptive_enabled {
            return;
        }

        let adaptive_silence = (ambient * self.config.silence_noise_multiplier)
            .min(self.config.max_adaptive_silence_threshold);
        let adaptive_speech = (ambient * self.config.speech_noise_multiplier)
            .min(self.config.max_adaptive_speech_threshold);

        self.diagnostics.silence_threshold =
            self.config.silence_rms_threshold.max(adaptive_silence);
        self.diagnostics.speech_threshold = self.config.speech_rms_threshold.max(adaptive_speech);
        self.diagnostics.silence_threshold = self
            .diagnostics
            .silence_threshold
            .min(self.diagnostics.speech_threshold * 0.8);
    }

    fn mark_speech(&mut self, appended_samples: usize) {
        self.diagnostics.speech_detected = true;
        self.diagnostics.speech_ticks = self.diagnostics.speech_ticks.saturating_add(1);
        self.diagnostics.silence_ticks = 0;
        self.diagnostics.no_speech_ticks = 0;
        self.diagnostics.state = VadState::Speech;
        let chunk_start = self
            .diagnostics
            .samples_seen
            .saturating_sub(appended_samples);
        self.diagnostics
            .speech_start_sample
            .get_or_insert(chunk_start);
        self.diagnostics.last_speech_sample = Some(self.diagnostics.samples_seen);
    }
}

fn ticks_for_duration(duration_ms: u64, tick_ms: u64) -> u32 {
    let tick_ms = tick_ms.max(1);
    let ticks = duration_ms.div_ceil(tick_ms);
    ticks.max(1).min(u32::MAX as u64) as u32
}

fn samples_for_duration(duration_ms: u64, sample_rate: u32, channels: u16) -> usize {
    ((sample_rate as u64 * channels.max(1) as u64 * duration_ms) / 1000) as usize
}

#[cfg(test)]
mod tests {
    use super::*;

    fn engine_with(config: VadConfig) -> VadEngine {
        VadEngine::new(config, 16_000, 1)
    }

    #[test]
    fn default_config_matches_existing_tick_windows() {
        let config = VadConfig::default();
        assert_eq!(config.frames_per_tick(16_000, 1), 1600);
        assert_eq!(config.silence_ticks_required(), 15);
        assert_eq!(config.no_speech_ticks_required(), 100);
    }

    #[test]
    fn reports_no_speech_after_timeout() {
        let config = VadConfig {
            no_speech_timeout_ms: 300,
            ..VadConfig::default()
        };
        let mut vad = engine_with(config);

        assert_eq!(vad.observe(0.0, 1600), VadDecision::Continue);
        assert_eq!(vad.observe(0.0, 1600), VadDecision::Continue);
        assert_eq!(
            vad.observe(0.0, 1600),
            VadDecision::Stop(StopReason::NoSpeech)
        );
        assert_eq!(vad.diagnostics().stop_reason, Some(StopReason::NoSpeech));
        assert_eq!(vad.diagnostics().state, VadState::Stopped);
    }

    #[test]
    fn reports_silence_after_speech_and_post_roll() {
        let config = VadConfig {
            silence_duration_ms: 300,
            ..VadConfig::default()
        };
        let mut vad = engine_with(config);

        assert_eq!(vad.observe(0.03, 1600), VadDecision::Continue);
        assert_eq!(vad.observe(0.0, 1600), VadDecision::Continue);
        assert_eq!(vad.diagnostics().state, VadState::PostRoll);
        assert_eq!(vad.observe(0.0, 1600), VadDecision::Continue);
        assert_eq!(
            vad.observe(0.0, 1600),
            VadDecision::Stop(StopReason::Silence)
        );
    }

    #[test]
    fn adaptive_calibration_raises_thresholds_in_noisy_rooms() {
        let config = VadConfig {
            adaptive_enabled: true,
            calibration_ms: 300,
            ..VadConfig::default()
        };
        let mut vad = engine_with(config);

        for _ in 0..3 {
            assert_eq!(vad.observe(0.015, 1600), VadDecision::Continue);
        }

        assert!(vad.diagnostics().ambient_rms.unwrap() > 0.014);
        assert!(vad.diagnostics().speech_threshold > DEFAULT_SPEECH_RMS_THRESHOLD);
        assert!(vad.diagnostics().silence_threshold > DEFAULT_SILENCE_RMS_THRESHOLD);
    }

    #[test]
    fn trim_range_includes_pre_and_post_roll() {
        let config = VadConfig {
            pre_roll_ms: 100,
            post_roll_ms: 200,
            ..VadConfig::default()
        };
        let mut vad = engine_with(config);

        assert_eq!(vad.observe(0.0, 1600), VadDecision::Continue);
        assert_eq!(vad.observe(0.03, 1600), VadDecision::Continue);
        assert_eq!(vad.observe(0.03, 1600), VadDecision::Continue);

        assert_eq!(vad.trim_range(10_000), Some(0..8000));
    }
}
