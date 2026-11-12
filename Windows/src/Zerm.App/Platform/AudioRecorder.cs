using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;
using Zerm.Core;
using Zerm.Core.Audio;

namespace Zerm.App.Platform;

public sealed record AudioDevice(string Id, string Name, bool IsDefault);

/// <summary>
/// Microphone capture through WASAPI (shared mode), converted on the fly to 16 kHz mono float —
/// the Windows counterpart of CoreAudioRecorder.swift.
/// </summary>
public sealed class AudioRecorder : IDisposable
{
    private IWaveIn? _capture;
    private BufferedWaveProvider? _buffer;
    private ISampleProvider? _converter;
    private readonly List<float> _samples = new(16000 * 60);
    private readonly object _gate = new();
    private float[] _readBuffer = new float[16000];
    private TaskCompletionSource<bool>? _firstAudio;

    public DateTime LastCallback { get; private set; }
    public bool HasReceivedAudio { get; private set; }
    public string? DeviceName { get; private set; }
    public string? DeviceId { get; private set; }

    /// <summary>Normalized 0–1 level (dB −60…0), smoothed 0.6 old / 0.4 new.</summary>
    public float Level { get; private set; }
    public float PeakLevel { get; private set; }
    public event Action<Exception?>? Stopped;

    public static List<AudioDevice> InputDevices()
    {
        using var enumerator = new MMDeviceEnumerator();
        string? defaultId = null;
        try { defaultId = enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Communications).ID; } catch { }
        return enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active)
            .Select(d => new AudioDevice(d.ID, d.FriendlyName, d.ID == defaultId))
            .ToList();
    }

    public void Start(string? deviceId)
    {
        Stop();
        lock (_gate) _samples.Clear();
        HasReceivedAudio = false;
        Level = PeakLevel = 0;
        _firstAudio = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);

        // Test hook: stream a file in real time instead of the microphone (ZERM_TEST_AUDIO_FILE).
        if (Environment.GetEnvironmentVariable("ZERM_TEST_AUDIO_FILE") is { Length: > 0 } testFile && File.Exists(testFile))
        {
            StartSimulated(testFile);
            return;
        }

        using var enumerator = new MMDeviceEnumerator();
        MMDevice? device = null;
        if (!string.IsNullOrEmpty(deviceId))
        {
            try { device = enumerator.GetDevice(deviceId); }
            catch { device = null; }
            if (device?.State != DeviceState.Active) device = null;
        }
        device ??= enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Communications);
        DeviceName = device.FriendlyName;
        DeviceId = device.ID;

        // Some drivers reject one WASAPI mode but accept another (seen: 0x80070057 on a wireless
        // headset after its format changed). Try event-driven WASAPI, polled WASAPI, then the classic API.
        var name = device.FriendlyName;
        var attempts = new (string Label, Func<IWaveIn> Create)[]
        {
            ("WASAPI", () => new WasapiCapture(device, true, 20)),
            ("WASAPI polled", () => new WasapiCapture(device, false, 100)),
            ("WaveIn", () => new WaveIn { DeviceNumber = WaveInDeviceFor(name), WaveFormat = new WaveFormat(AudioUtil.SampleRate, 16, 1), BufferMilliseconds = 50 }),
        };
        Exception? last = null;
        foreach (var (label, create) in attempts)
        {
            IWaveIn? capture = null;
            try
            {
                capture = create();
                _buffer = new BufferedWaveProvider(capture.WaveFormat, TimeSpan.FromSeconds(5)) { DiscardOnBufferOverflow = true, ReadFully = false };
                ISampleProvider p = _buffer.ToSampleProvider();
                if (p.WaveFormat.Channels == 2) p = new StereoToMonoSampleProvider(p) { LeftVolume = 0.5f, RightVolume = 0.5f };
                else if (p.WaveFormat.Channels > 2) p = new FirstChannelProvider(p);
                if (p.WaveFormat.SampleRate != AudioUtil.SampleRate) p = new WdlResamplingSampleProvider(p, AudioUtil.SampleRate);
                _converter = p;
                capture.DataAvailable += OnData;
                capture.RecordingStopped += (_, e) => Stopped?.Invoke(e.Exception);
                LastCallback = DateTime.Now;
                capture.StartRecording();
                _capture = capture;
                Log.Info($"Recording from {DeviceName} via {label} ({capture.WaveFormat})");
                return;
            }
            catch (Exception ex)
            {
                last = ex;
                Log.Warn($"{label} capture failed on {name}: {ex.Message}");
                if (capture != null)
                {
                    capture.DataAvailable -= OnData;
                    try { capture.Dispose(); } catch { }
                }
            }
        }
        throw last ?? new InvalidOperationException("No microphone could be opened.");
    }

    /// <summary>MME device number for a WASAPI endpoint name (MME names are cut to 31 characters).</summary>
    private static int WaveInDeviceFor(string friendlyName)
    {
        for (var i = 0; i < WaveIn.DeviceCount; i++)
        {
            var product = WaveIn.GetCapabilities(i).ProductName;
            if (friendlyName.StartsWith(product, StringComparison.OrdinalIgnoreCase) || product.StartsWith(friendlyName, StringComparison.OrdinalIgnoreCase))
                return i;
        }
        return -1; // WAVE_MAPPER: the system default
    }

    private CancellationTokenSource? _simulated;

    private void StartSimulated(string file)
    {
        var source = AudioUtil.LoadAs16kMono(file);
        DeviceName = "Test audio: " + Path.GetFileName(file);
        DeviceId = "test";
        LastCallback = DateTime.Now;
        var cts = _simulated = new CancellationTokenSource();
        _ = Task.Run(async () =>
        {
            const int chunk = AudioUtil.SampleRate / 50; // 20 ms
            var silence = new float[chunk];
            var sw = System.Diagnostics.Stopwatch.StartNew();
            for (long i = 0; !cts.IsCancellationRequested; i++)
            {
                var offset = (int)(i * chunk);
                var span = offset + chunk <= source.Length ? source.AsSpan(offset, chunk) : silence;
                // A real microphone never delivers pure digital zero.
                var block = span.ToArray();
                for (var k = 0; k < block.Length; k++) block[k] += (float)((Random.Shared.NextDouble() - 0.5) * 0.002);
                Feed(block);
                var due = (i + 1) * 20;
                var wait = due - sw.ElapsedMilliseconds;
                if (wait > 0) await Task.Delay((int)wait);
            }
        });
    }

    private void Feed(ReadOnlySpan<float> span)
    {
        LastCallback = DateTime.Now;
        lock (_gate) _samples.AddRange(span);
        var level = AudioUtil.MeterLevel(AudioUtil.Rms(span));
        Level = Level * 0.6f + level * 0.4f;
        PeakLevel = AudioUtil.MeterLevel(AudioUtil.Peak(span));
        if (!HasReceivedAudio && AudioUtil.Peak(span) > 0.0005f)
        {
            HasReceivedAudio = true;
            _firstAudio?.TrySetResult(true);
        }
    }

    private void OnData(object? sender, WaveInEventArgs e)
    {
        LastCallback = DateTime.Now;
        if (_buffer == null || _converter == null) return;
        _buffer.AddSamples(e.Buffer, 0, e.BytesRecorded);
        int read;
        while ((read = _converter.Read(_readBuffer.AsSpan())) > 0)
        {
            var span = _readBuffer.AsSpan(0, read);
            lock (_gate) _samples.AddRange(span);
            var rms = AudioUtil.Rms(span);
            var peak = AudioUtil.Peak(span);
            var level = AudioUtil.MeterLevel(rms);
            Level = Level * 0.6f + level * 0.4f;
            PeakLevel = AudioUtil.MeterLevel(peak);
            if (!HasReceivedAudio && peak > 0.0005f)
            {
                HasReceivedAudio = true;
                _firstAudio?.TrySetResult(true);
            }
        }
    }

    /// <summary>Waits for the first non-silent audio (Bluetooth headsets send digital silence while their link comes up).</summary>
    public async Task<bool> WaitForFirstAudio(TimeSpan timeout)
    {
        var tcs = _firstAudio;
        if (tcs == null) return false;
        return await Task.WhenAny(tcs.Task, Task.Delay(timeout)) == tcs.Task;
    }

    public float[] Snapshot()
    {
        lock (_gate) return [.. _samples];
    }

    public double DurationSeconds
    {
        get { lock (_gate) return AudioUtil.DurationSeconds(_samples.Count); }
    }

    public float[] Stop()
    {
        _simulated?.Cancel();
        _simulated = null;
        var capture = _capture;
        _capture = null;
        if (capture != null)
        {
            capture.DataAvailable -= OnData;
            try { capture.StopRecording(); } catch { }
            capture.Dispose();
        }
        _buffer = null;
        _converter = null;
        return Snapshot();
    }

    public void Dispose() => Stop();

    private sealed class FirstChannelProvider(ISampleProvider source) : ISampleProvider
    {
        private float[] _buf = [];
        public WaveFormat WaveFormat { get; } = WaveFormat.CreateIeeeFloatWaveFormat(source.WaveFormat.SampleRate, 1);

        public int Read(Span<float> buffer)
        {
            var ch = source.WaveFormat.Channels;
            if (_buf.Length < buffer.Length * ch) _buf = new float[buffer.Length * ch];
            var read = source.Read(_buf.AsSpan(0, buffer.Length * ch)) / ch;
            for (var i = 0; i < read; i++) buffer[i] = _buf[i * ch];
            return read;
        }
    }
}
