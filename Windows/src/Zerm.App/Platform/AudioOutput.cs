using System.Windows.Media.Imaging;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;
using Zerm.Core;
using Zerm.Core.Settings;
using Zerm.Core.TextToSpeech;

namespace Zerm.App.Platform;

/// <summary>Start/stop/escape feedback sounds (SoundManager.swift).</summary>
public sealed class SoundPlayer(AppSettings settings)
{
    private static string Bundled(string name) => Path.Combine(AppContext.BaseDirectory, "Assets", "Sounds", name);

    public void PlayStart(Action? completed = null) =>
        Play(settings.CustomStartSound ?? Bundled("recstart.mp3"), 0.4f, completed);

    public void PlayStop() => Play(settings.CustomStopSound ?? Bundled("recstop.mp3"), 0.4f);
    public void PlayEscape() => Play(Bundled("esc.wav"), 0.3f);

    private void Play(string path, float volume, Action? completed = null)
    {
        if (!settings.SoundFeedbackEnabled || !File.Exists(path))
        {
            completed?.Invoke();
            return;
        }
        try
        {
            var reader = new AudioFileReader(path) { Volume = volume };
            var output = new WaveOut();
            output.Init(reader);
            output.PlaybackStopped += (_, _) =>
            {
                output.Dispose();
                reader.Dispose();
                completed?.Invoke();
            };
            output.Play();
        }
        catch (Exception ex)
        {
            Log.Warn($"Sound failed: {ex.Message}");
            completed?.Invoke();
        }
    }

    /// <summary>Validates a custom sound: decodable and at most 3 seconds long.</summary>
    public static string? ValidateCustomSound(string path)
    {
        try
        {
            using var reader = new AudioFileReader(path);
            return reader.TotalTime.TotalSeconds > 3.0 ? "The sound must be 3 seconds or shorter." : null;
        }
        catch
        {
            return "This file could not be played.";
        }
    }
}

/// <summary>Mutes the default output while recording (MediaController.swift), skipping headphones if asked.</summary>
public sealed class SystemMute(AppSettings settings)
{
    private string? _mutedDeviceId;
    private int _generation;

    public static bool IsHeadphones(MMDevice device)
    {
        try
        {
            if (device.ID.Contains("BTHENUM", StringComparison.OrdinalIgnoreCase)) return true;
            var formFactor = device.Properties.Contains(PropertyKeys.PKEY_AudioEndpoint_FormFactor) ? device.Properties[PropertyKeys.PKEY_AudioEndpoint_FormFactor].Value : null;
            if (formFactor is uint ff && ff is 3 or 5) return true; // Headphones, Headset
            var name = device.FriendlyName.ToLowerInvariant();
            return name.Contains("headphone") || name.Contains("headset") || name.Contains("earbuds") || name.Contains("airpods");
        }
        catch
        {
            return false;
        }
    }

    public void Mute()
    {
        var generation = ++_generation;
        if (!settings.SystemMuteEnabled) return;
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            var device = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
            if (settings.SkipMuteWithHeadphones && IsHeadphones(device)) return;
            if (device.AudioEndpointVolume.Mute) return; // already muted by the user: leave alone
            if (generation != _generation) return;
            device.AudioEndpointVolume.Mute = true;
            _mutedDeviceId = device.ID;
        }
        catch (Exception ex)
        {
            Log.Warn($"Mute failed: {ex.Message}");
        }
    }

    public async Task UnmuteAsync()
    {
        _generation++;
        var id = _mutedDeviceId;
        _mutedDeviceId = null;
        if (id == null) return;
        if (settings.AudioResumptionDelay > 0) await Task.Delay(TimeSpan.FromSeconds(settings.AudioResumptionDelay));
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            enumerator.GetDevice(id).AudioEndpointVolume.Mute = false;
        }
        catch (Exception ex)
        {
            Log.Warn($"Unmute failed: {ex.Message}");
        }
    }
}

/// <summary>Streaming speech playback queue with an output level meter (TTSPlayer.swift).</summary>
public sealed class SpeechPlayer : IDisposable
{
    private const int Rate = 24000;
    private WaveOut? _output;
    private BufferedWaveProvider? _buffer;
    private bool _finishedQueueing;
    private TaskCompletionSource? _done;

    public float Level { get; private set; }
    public bool IsPlaying => _output?.PlaybackState == PlaybackState.Playing;

    public void Begin()
    {
        Stop();
        _finishedQueueing = false;
        _done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        _buffer = new BufferedWaveProvider(WaveFormat.CreateIeeeFloatWaveFormat(Rate, 1), TimeSpan.FromMinutes(10))
        {
            DiscardOnBufferOverflow = false,
            ReadFully = true,
        };
        var meter = new MeteringSampleProvider(_buffer.ToSampleProvider(), Rate / 30);
        meter.StreamVolume += (_, e) => Level = Math.Clamp(e.MaxSampleValues.Max() * 1.6f, 0, 1);
        _output = new WaveOut { BufferMilliseconds = 60, NumberOfBuffers = 2 };
        _output.Init(meter);
        _output.Play();
        _ = Task.Run(WatchForEnd);
    }

    public void Enqueue(PcmAudio audio)
    {
        if (_buffer == null) return;
        var samples = audio.SampleRate == Rate ? audio.Samples : Resample(audio);
        var bytes = new byte[samples.Length * 4];
        Buffer.BlockCopy(samples, 0, bytes, 0, bytes.Length);
        _buffer.AddSamples(bytes, 0, bytes.Length);
    }

    private static float[] Resample(PcmAudio audio)
    {
        var src = new RawProvider(audio);
        var resampler = new WdlResamplingSampleProvider(src, Rate);
        var list = new List<float>((int)(audio.Samples.Length * (double)Rate / audio.SampleRate) + 1024);
        var buf = new float[8192];
        int n;
        while ((n = resampler.Read(buf.AsSpan())) > 0) list.AddRange(buf.AsSpan(0, n));
        return [.. list];
    }

    public void FinishQueueing() => _finishedQueueing = true;

    public Task Completion => _done?.Task ?? Task.CompletedTask;

    private async Task WatchForEnd()
    {
        while (_output != null)
        {
            await Task.Delay(50);
            if (_finishedQueueing && _buffer != null && _buffer.BufferedBytes == 0)
            {
                await Task.Delay(180);
                break;
            }
        }
        Level = 0;
        _done?.TrySetResult();
    }

    public void Stop()
    {
        _output?.Stop();
        _output?.Dispose();
        _output = null;
        _buffer = null;
        Level = 0;
        _done?.TrySetResult();
    }

    public void Dispose() => Stop();

    private sealed class RawProvider(PcmAudio audio) : ISampleProvider
    {
        private int _pos;
        public WaveFormat WaveFormat { get; } = WaveFormat.CreateIeeeFloatWaveFormat(audio.SampleRate, 1);

        public int Read(Span<float> buffer)
        {
            var n = Math.Min(buffer.Length, audio.Samples.Length - _pos);
            audio.Samples.AsSpan(_pos, n).CopyTo(buffer);
            _pos += n;
            return n;
        }
    }
}

/// <summary>Screen context for Enhanced mode: OCR of the foreground window with Windows.Media.Ocr.</summary>
public static class ScreenContext
{
    public static async Task<string?> CaptureForegroundTextAsync(IntPtr window)
    {
        try
        {
            if (!Native.GetWindowRect(window, out var r) || r.Right - r.Left < 50 || r.Bottom - r.Top < 50) return null;
            var width = Math.Min(r.Right - r.Left, 3840);
            var height = Math.Min(r.Bottom - r.Top, 2160);
            using var bmp = new System.Drawing.Bitmap(width, height);
            using (var g = System.Drawing.Graphics.FromImage(bmp))
                g.CopyFromScreen(r.Left, r.Top, 0, 0, new System.Drawing.Size(width, height));
            using var ms = new MemoryStream();
            bmp.Save(ms, System.Drawing.Imaging.ImageFormat.Png);
            ms.Position = 0;
            var stream = ms.AsRandomAccessStream();
            var decoder = await Windows.Graphics.Imaging.BitmapDecoder.CreateAsync(stream);
            using var software = await decoder.GetSoftwareBitmapAsync();
            var engine = Windows.Media.Ocr.OcrEngine.TryCreateFromUserProfileLanguages();
            if (engine == null) return null;
            var result = await engine.RecognizeAsync(software);
            var text = string.Join("\n", result.Lines.Select(l => l.Text));
            return text.Length > 4000 ? text[..4000] : text;
        }
        catch (Exception ex)
        {
            Log.Warn($"Screen OCR failed: {ex.Message}");
            return null;
        }
    }
}
