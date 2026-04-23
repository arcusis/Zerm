use anyhow::{anyhow, Context, Result};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{SampleFormat, SupportedStreamConfig};
use parking_lot::Mutex;
use serde::Serialize;
use std::sync::mpsc::{channel, Sender};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

#[path = "vad.rs"]
mod vad;

pub use vad::{StopReason, VadConfig, VadDecision, VadDiagnostics, VadEngine};

pub const TARGET_SAMPLE_RATE: u32 = 16_000;

/// Absolute cap on raw interleaved samples. 24M f32 samples is about 96 MB
/// before mono/resample processing allocates its working buffers.
pub const MAX_SAMPLES: usize = 24_000_000;

/// Human-friendly duration cap. The effective raw cap is the lower of this
/// duration at the device rate/channel count and MAX_SAMPLES.
pub const MAX_RECORDING_SECS: u64 = 5 * 60;

/// If no speech RMS above threshold is observed for this long, stop.
/// Prevents an accidental hotkey in a quiet room from recording until
/// MAX_SAMPLES is reached.
const NO_SPEECH_TIMEOUT_MS: u64 = 10_000;

#[derive(Clone, Debug, Serialize)]
pub struct AudioInputDevice {
    pub id: String,
    pub name: String,
    pub is_default: bool,
    pub sample_rates: Vec<u32>,
    pub channel_counts: Vec<u16>,
}

pub struct CaptureHandle {
    pub stop: Sender<()>,
    pub sample_rate: u32,
    pub channels: u16,
    pub device_name: String,
    pub sample_format: String,
    pub level: Arc<Mutex<f32>>,
    pub peak_level: Arc<Mutex<f32>>,
    #[allow(dead_code)]
    pub diagnostics: Arc<Mutex<VadDiagnostics>>,
}

pub fn input_devices() -> Result<Vec<AudioInputDevice>> {
    let host = cpal::default_host();
    let default_name = host
        .default_input_device()
        .and_then(|device| device.name().ok());
    let devices = host.input_devices().context("list input devices")?;
    let mut infos = Vec::new();

    for (index, device) in devices.enumerate() {
        let name = device
            .name()
            .unwrap_or_else(|_| format!("<unknown input device {index}>"));
        let mut sample_rates = Vec::new();
        let mut channel_counts = Vec::new();
        if let Ok(configs) = device.supported_input_configs() {
            for config in configs {
                sample_rates.push(config.min_sample_rate().0);
                sample_rates.push(config.max_sample_rate().0);
                channel_counts.push(config.channels());
            }
        }
        sample_rates.sort_unstable();
        sample_rates.dedup();
        channel_counts.sort_unstable();
        channel_counts.dedup();

        infos.push(AudioInputDevice {
            id: name.clone(),
            is_default: default_name.as_deref() == Some(name.as_str()),
            name,
            sample_rates,
            channel_counts,
        });
    }

    Ok(infos)
}

pub fn start_capture<F>(
    buffer: Arc<Mutex<Vec<f32>>>,
    preferred_device_name: Option<String>,
    on_stop: F,
) -> Result<CaptureHandle>
where
    F: Fn(StopReason) + Send + 'static,
{
    let host = cpal::default_host();
    let preferred_device_name = preferred_device_name
        .as_deref()
        .map(str::trim)
        .filter(|name| !name.is_empty())
        .map(str::to_string);
    let device = if let Some(preferred) = preferred_device_name.as_deref() {
        let mut found = None;
        if let Ok(devices) = host.input_devices() {
            for candidate in devices {
                let candidate_name = candidate.name().unwrap_or_default();
                if candidate_name == preferred {
                    found = Some(candidate);
                    break;
                }
            }
        }
        match found {
            Some(device) => device,
            None => {
                log::warn!("selected input device not found: {preferred}; falling back to default");
                host.default_input_device().ok_or_else(|| {
                    anyhow!("selected input device not found and no default input device")
                })?
            }
        }
    } else {
        host.default_input_device()
            .ok_or_else(|| anyhow!("no default input device"))?
    };
    let device_name = device
        .name()
        .unwrap_or_else(|_| "<unknown input device>".to_string());
    let config: SupportedStreamConfig = device
        .default_input_config()
        .context("no default input config")?;
    let sample_rate = config.sample_rate().0;
    let channels = config.channels();
    let sample_format = config.sample_format();
    let sample_format_label = format!("{sample_format:?}");
    let max_samples = max_samples_for_config(sample_rate, channels);

    let (stop_tx, stop_rx) = channel::<()>();
    // Worker signals stream-startup success (or a build/play error) before
    // we return Ok to the caller. Otherwise the UI would flip to
    // "Listening…" even when the mic stream actually failed to open.
    let (ready_tx, ready_rx) = std::sync::mpsc::sync_channel::<std::result::Result<(), String>>(1);
    let buffer_for_thread = buffer.clone();
    let level = Arc::new(Mutex::new(0.0_f32));
    let peak_level = Arc::new(Mutex::new(0.0_f32));
    let level_for_thread = level.clone();
    let peak_level_for_thread = peak_level.clone();
    let vad_config = VadConfig {
        no_speech_timeout_ms: NO_SPEECH_TIMEOUT_MS,
        ..VadConfig::default()
    };
    let diagnostics = Arc::new(Mutex::new(
        VadEngine::new(vad_config.clone(), sample_rate, channels)
            .diagnostics()
            .clone(),
    ));
    let vad_tick_ms = vad_config.tick_ms;
    let diagnostics_for_thread = diagnostics.clone();

    thread::spawn(move || {
        let buffer_for_stream = buffer_for_thread.clone();
        let level_for_stream = level_for_thread.clone();
        let peak_level_for_stream = peak_level_for_thread.clone();
        // Cap each write so a single extend_from_slice can't push the
        // buffer above MAX_SAMPLES even if the OS hands us a huge chunk.
        let buffer_for_len_cap = buffer_for_thread.clone();
        let max_samples_for_stream = max_samples;
        let err_fn = |e| log::error!("audio stream error: {e}");
        let stream_result = match sample_format {
            SampleFormat::F32 => device.build_input_stream(
                &config.into(),
                move |data: &[f32], _| {
                    let mut buf = buffer_for_stream.lock();
                    let available = max_samples_for_stream.saturating_sub(buf.len());
                    let take = data.len().min(available);
                    buf.extend_from_slice(&data[..take]);
                    let rms = compute_rms(&data[..take]);
                    *level_for_stream.lock() = rms;
                    let mut peak = peak_level_for_stream.lock();
                    *peak = peak.max(rms);
                },
                err_fn,
                None,
            ),
            SampleFormat::I16 => device.build_input_stream(
                &config.into(),
                move |data: &[i16], _| {
                    let mut buf = buffer_for_stream.lock();
                    let peak_level_for_stream = peak_level_for_stream.clone();
                    let available = max_samples_for_stream.saturating_sub(buf.len());
                    let take = data.len().min(available);
                    let converted: Vec<f32> = data[..take]
                        .iter()
                        .map(|s| (*s as f32) / (i16::MAX as f32))
                        .collect();
                    let rms = compute_rms(&converted);
                    *level_for_stream.lock() = rms;
                    let mut peak = peak_level_for_stream.lock();
                    *peak = peak.max(rms);
                    buf.extend(converted);
                },
                err_fn,
                None,
            ),
            SampleFormat::U16 => device.build_input_stream(
                &config.into(),
                move |data: &[u16], _| {
                    let mut buf = buffer_for_stream.lock();
                    let peak_level_for_stream = peak_level_for_stream.clone();
                    let available = max_samples_for_stream.saturating_sub(buf.len());
                    let take = data.len().min(available);
                    let converted: Vec<f32> = data[..take]
                        .iter()
                        .map(|s| ((*s as f32) - (u16::MAX as f32 / 2.0)) / (u16::MAX as f32 / 2.0))
                        .collect();
                    let rms = compute_rms(&converted);
                    *level_for_stream.lock() = rms;
                    let mut peak = peak_level_for_stream.lock();
                    *peak = peak.max(rms);
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

        // VAD loop: wake every tick, evaluate recent audio chunk. The
        // engine still preserves the current fixed-threshold behavior, while
        // exposing calibration, pre-roll/post-roll, and stop diagnostics for
        // the richer recorder HUD work.
        let mut vad = VadEngine::new(vad_config, sample_rate, channels);
        *diagnostics_for_thread.lock() = vad.diagnostics().clone();
        let frames_per_tick = vad.frames_per_tick(sample_rate, channels);
        let mut last_pos: usize = 0;

        loop {
            if stop_rx
                .recv_timeout(Duration::from_millis(vad_tick_ms))
                .is_ok()
            {
                break;
            }

            let snapshot_len = {
                let buf = buffer_for_len_cap.lock();
                buf.len()
            };

            // Hard cap: if the buffer reached max_samples, the cpal callback
            // will no longer append anything, so recording is effectively
            // frozen. Stop.
            if snapshot_len >= max_samples {
                log::warn!(
                    "max sample count ({max_samples}) reached (duration cap {MAX_RECORDING_SECS}s, absolute cap {MAX_SAMPLES}); auto-stopping"
                );
                vad.force_stop(StopReason::HardLimit);
                *diagnostics_for_thread.lock() = vad.diagnostics().clone();
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
            let appended_samples = snapshot_len.saturating_sub(last_pos);
            last_pos = snapshot_len;

            match vad.observe(rms, appended_samples) {
                VadDecision::Continue => {
                    *diagnostics_for_thread.lock() = vad.diagnostics().clone();
                }
                VadDecision::Stop(reason) => {
                    *diagnostics_for_thread.lock() = vad.diagnostics().clone();
                    match reason {
                        StopReason::Silence => log::info!("VAD: silence detected, auto-stopping"),
                        StopReason::NoSpeech => {
                            log::info!(
                                "no speech detected in {NO_SPEECH_TIMEOUT_MS}ms; auto-stopping"
                            );
                        }
                        StopReason::HardLimit => {}
                    }
                    drop(stream);
                    on_stop(reason);
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
            device_name,
            sample_format: sample_format_label,
            level,
            peak_level,
            diagnostics,
        }),
        Ok(Err(e)) => Err(anyhow!("audio capture failed to start: {e}")),
        Err(_) => Err(anyhow!("audio capture startup timed out")),
    }
}

pub fn max_samples_for_config(sample_rate: u32, channels: u16) -> usize {
    let by_duration = sample_rate as usize * channels.max(1) as usize * MAX_RECORDING_SECS as usize;
    by_duration.clamp(1, MAX_SAMPLES)
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

    #[test]
    fn max_samples_uses_lower_duration_or_absolute_cap() {
        assert_eq!(max_samples_for_config(16_000, 1), 4_800_000);
        assert_eq!(max_samples_for_config(192_000, 2), MAX_SAMPLES);
    }
}
