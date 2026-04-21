use anyhow::{anyhow, Context, Result};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{SampleFormat, SupportedStreamConfig};
use parking_lot::Mutex;
use std::sync::mpsc::{channel, Sender};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

pub const TARGET_SAMPLE_RATE: u32 = 16_000;
const SILENCE_RMS_THRESHOLD: f32 = 0.01;
const SPEECH_RMS_THRESHOLD: f32 = 0.02;
const SILENCE_DURATION_MS: u64 = 1500;
const VAD_TICK_MS: u64 = 100;

/// Absolute cap on recorded samples, regardless of device sample rate
/// or channel count. Chosen so the buffer stays under ~500 MB even if
/// the user's mic exposes a 48 kHz stereo (≈ 115M f32 samples) config.
/// Previously we capped by seconds, which scaled with rate/channels —
/// at 192 kHz the 20-min cap would allocate >1.5 GB.
pub const MAX_SAMPLES: usize = 120_000_000;

/// Documented human-friendly cap (for log messages). Derived from
/// MAX_SAMPLES assuming 48 kHz stereo.
pub const MAX_RECORDING_SECS: u64 = 20 * 60;

/// If no speech RMS above threshold is observed for this long, stop.
/// Prevents an accidental hotkey in a quiet room from recording until
/// MAX_SAMPLES is reached.
const NO_SPEECH_TIMEOUT_MS: u64 = 10_000;

pub struct CaptureHandle {
    pub stop: Sender<()>,
    pub sample_rate: u32,
    pub channels: u16,
    pub level: Arc<Mutex<f32>>,
}

/// Why the capture ended on its own (not via the explicit stop channel).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StopReason {
    /// VAD detected sustained silence after speech.
    Silence,
    /// Max recording length reached — stop regardless of VAD state.
    HardLimit,
    /// Recording started but no speech was ever detected within
    /// NO_SPEECH_TIMEOUT_MS. Likely an accidental hotkey press.
    NoSpeech,
}

pub fn start_capture<F>(buffer: Arc<Mutex<Vec<f32>>>, on_stop: F) -> Result<CaptureHandle>
where
    F: Fn(StopReason) + Send + 'static,
{
    let host = cpal::default_host();
    let device = host
        .default_input_device()
        .ok_or_else(|| anyhow!("no default input device"))?;
    let config: SupportedStreamConfig = device
        .default_input_config()
        .context("no default input config")?;
    let sample_rate = config.sample_rate().0;
    let channels = config.channels();
    let sample_format = config.sample_format();

    let (stop_tx, stop_rx) = channel::<()>();
    // Worker signals stream-startup success (or a build/play error) before
    // we return Ok to the caller. Otherwise the UI would flip to
    // "Listening…" even when the mic stream actually failed to open.
    let (ready_tx, ready_rx) = std::sync::mpsc::sync_channel::<std::result::Result<(), String>>(1);
    let buffer_for_thread = buffer.clone();
    let level = Arc::new(Mutex::new(0.0_f32));
    let level_for_thread = level.clone();

    thread::spawn(move || {
        let buffer_for_stream = buffer_for_thread.clone();
        let level_for_stream = level_for_thread.clone();
        // Cap each write so a single extend_from_slice can't push the
        // buffer above MAX_SAMPLES even if the OS hands us a huge chunk.
        let buffer_for_len_cap = buffer_for_thread.clone();
        let err_fn = |e| log::error!("audio stream error: {e}");
        let stream_result = match sample_format {
            SampleFormat::F32 => device.build_input_stream(
                &config.into(),
                move |data: &[f32], _| {
                    let mut buf = buffer_for_stream.lock();
                    let available = MAX_SAMPLES.saturating_sub(buf.len());
                    let take = data.len().min(available);
                    buf.extend_from_slice(&data[..take]);
                    *level_for_stream.lock() = compute_rms(&data[..take]);
                },
                err_fn,
                None,
            ),
            SampleFormat::I16 => device.build_input_stream(
                &config.into(),
                move |data: &[i16], _| {
                    let mut buf = buffer_for_stream.lock();
                    let available = MAX_SAMPLES.saturating_sub(buf.len());
                    let take = data.len().min(available);
                    let converted: Vec<f32> = data[..take]
                        .iter()
                        .map(|s| (*s as f32) / (i16::MAX as f32))
                        .collect();
                    *level_for_stream.lock() = compute_rms(&converted);
                    buf.extend(converted);
                },
                err_fn,
                None,
            ),
            SampleFormat::U16 => device.build_input_stream(
                &config.into(),
                move |data: &[u16], _| {
                    let mut buf = buffer_for_stream.lock();
                    let available = MAX_SAMPLES.saturating_sub(buf.len());
                    let take = data.len().min(available);
                    let converted: Vec<f32> = data[..take]
                        .iter()
                        .map(|s| ((*s as f32) - (u16::MAX as f32 / 2.0)) / (u16::MAX as f32 / 2.0))
                        .collect();
                    *level_for_stream.lock() = compute_rms(&converted);
                    buf.extend(converted);
                },
                err_fn,
                None,
            ),
            other => {
                let _ = ready_tx.send(Err(format!("unsupported sample format: {other:?}")));
                return;
            }
        };

        let stream = match stream_result {
            Ok(s) => s,
            Err(e) => {
                let _ = ready_tx.send(Err(format!("build_input_stream: {e}")));
                return;
            }
        };

        if let Err(e) = stream.play() {
            let _ = ready_tx.send(Err(format!("stream.play: {e}")));
            return;
        }
        // Stream is actually playing — tell the caller it's safe to emit
        // RECORDING_EVENT.
        let _ = ready_tx.send(Ok(()));

        // VAD loop: wake every VAD_TICK_MS, evaluate recent audio chunk
        let frames_per_tick = (sample_rate as u64 * channels as u64 * VAD_TICK_MS / 1000) as usize;
        let silence_ticks_required = (SILENCE_DURATION_MS / VAD_TICK_MS) as u32;
        let no_speech_ticks_required = (NO_SPEECH_TIMEOUT_MS / VAD_TICK_MS) as u32;
        let mut speech_detected = false;
        let mut silence_ticks: u32 = 0;
        let mut no_speech_ticks: u32 = 0;
        let mut last_pos: usize = 0;

        loop {
            if stop_rx
                .recv_timeout(Duration::from_millis(VAD_TICK_MS))
                .is_ok()
            {
                break;
            }

            let snapshot_len = {
                let buf = buffer_for_len_cap.lock();
                buf.len()
            };

            // Hard cap: if the buffer reached MAX_SAMPLES, the cpal callback
            // will no longer append anything, so recording is effectively
            // frozen. Stop.
            if snapshot_len >= MAX_SAMPLES {
                log::warn!(
                    "max sample count ({MAX_SAMPLES}) reached (~{MAX_RECORDING_SECS}s @48k stereo); auto-stopping"
                );
                drop(stream);
                on_stop(StopReason::HardLimit);
                return;
            }

            if snapshot_len <= last_pos {
                continue;
            }

            let chunk_start = snapshot_len.saturating_sub(frames_per_tick.max(1));
            let rms = {
                let buf = buffer_for_len_cap.lock();
                compute_rms(&buf[chunk_start..snapshot_len])
            };
            last_pos = snapshot_len;

            if rms >= SPEECH_RMS_THRESHOLD {
                speech_detected = true;
                silence_ticks = 0;
                no_speech_ticks = 0;
            } else if speech_detected && rms < SILENCE_RMS_THRESHOLD {
                silence_ticks += 1;
                if silence_ticks >= silence_ticks_required {
                    log::info!("VAD: silence detected, auto-stopping");
                    drop(stream);
                    on_stop(StopReason::Silence);
                    return;
                }
            } else if speech_detected {
                silence_ticks = silence_ticks.saturating_sub(1);
            } else {
                // Still waiting for the first syllable.
                no_speech_ticks += 1;
                if no_speech_ticks >= no_speech_ticks_required {
                    log::info!("no speech detected in {NO_SPEECH_TIMEOUT_MS}ms; auto-stopping");
                    drop(stream);
                    on_stop(StopReason::NoSpeech);
                    return;
                }
            }
        }

        drop(stream);
    });

    // Wait up to 3 seconds for the stream thread to signal that
    // build+play succeeded. If it didn't, surface the error so
    // handle_press can skip emitting RECORDING_EVENT and show the user
    // a real error instead of a fake "Listening…" state.
    match ready_rx.recv_timeout(Duration::from_secs(3)) {
        Ok(Ok(())) => Ok(CaptureHandle {
            stop: stop_tx,
            sample_rate,
            channels,
            level,
        }),
        Ok(Err(e)) => Err(anyhow!("audio capture failed to start: {e}")),
        Err(_) => Err(anyhow!("audio capture startup timed out")),
    }
}

pub fn compute_rms(samples: &[f32]) -> f32 {
    if samples.is_empty() {
        return 0.0;
    }
    let sum_sq: f32 = samples.iter().map(|s| s * s).sum();
    (sum_sq / samples.len() as f32).sqrt()
}

pub fn to_mono(samples: &[f32], channels: u16) -> Vec<f32> {
    if channels <= 1 {
        return samples.to_vec();
    }
    let ch = channels as usize;
    samples
        .chunks_exact(ch)
        .map(|frame| frame.iter().sum::<f32>() / ch as f32)
        .collect()
}

pub fn resample_linear(samples: &[f32], from_hz: u32, to_hz: u32) -> Vec<f32> {
    if from_hz == to_hz || samples.is_empty() {
        return samples.to_vec();
    }
    let ratio = from_hz as f64 / to_hz as f64;
    let out_len = ((samples.len() as f64) / ratio).round() as usize;
    let mut out = Vec::with_capacity(out_len);
    for i in 0..out_len {
        let src = (i as f64) * ratio;
        let idx = src as usize;
        let frac = (src - idx as f64) as f32;
        let s0 = samples.get(idx).copied().unwrap_or(0.0);
        let s1 = samples.get(idx + 1).copied().unwrap_or(s0);
        out.push(s0 + (s1 - s0) * frac);
    }
    out
}

pub fn prepare_for_whisper(samples: &[f32], sample_rate: u32, channels: u16) -> Vec<f32> {
    let mono = to_mono(samples, channels);
    resample_linear(&mono, sample_rate, TARGET_SAMPLE_RATE)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn to_mono_averages_stereo() {
        let stereo = vec![1.0, -1.0, 0.5, 0.5];
        let mono = to_mono(&stereo, 2);
        assert_eq!(mono, vec![0.0, 0.5]);
    }

    #[test]
    fn resample_passthrough_when_rates_equal() {
        let s = vec![0.1, 0.2, 0.3];
        assert_eq!(resample_linear(&s, 16000, 16000), s);
    }

    #[test]
    fn resample_halves_length_at_2x_rate() {
        let s: Vec<f32> = (0..100).map(|i| i as f32).collect();
        let out = resample_linear(&s, 32000, 16000);
        assert!(out.len() >= 49 && out.len() <= 51, "got {}", out.len());
    }

    #[test]
    fn rms_zero_for_empty() {
        assert_eq!(compute_rms(&[]), 0.0);
    }

    #[test]
    fn rms_known_value() {
        let samples = vec![0.5, -0.5, 0.5, -0.5];
        assert!((compute_rms(&samples) - 0.5).abs() < 1e-6);
    }
}
