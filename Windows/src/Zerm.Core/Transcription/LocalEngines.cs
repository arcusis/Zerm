using SherpaOnnx;
using Whisper.net;
using Zerm.Core.Audio;
using Zerm.Core.Models;

namespace Zerm.Core.Transcription;

public sealed record TranscriptSegment(double Start, double End, string Text);

public sealed record TranscriptionOptions(string? Language, string? Prompt, bool UseVad = true);

/// <summary>Silero VAD (bundled) — finds the speech regions of a recording.</summary>
public static class SileroVad
{
    public static string ModelPath
    {
        get
        {
            var path = Path.Combine(AppContext.BaseDirectory, "Resources", "silero_vad.onnx");
            return File.Exists(path) ? path : Path.Combine(AppContext.BaseDirectory, "silero_vad.onnx");
        }
    }

    /// <summary>Speech regions as (startSample, endSample), merged with the macOS whisper.cpp VAD tuning.</summary>
    public static List<(int Start, int End)> SpeechRegions(float[] samples, float threshold = 0.5f)
    {
        var config = new VadModelConfig
        {
            SampleRate = AudioUtil.SampleRate,
            NumThreads = 1,
            Provider = "cpu",
        };
        config.SileroVad.Model = ModelPath;
        config.SileroVad.Threshold = threshold;
        config.SileroVad.MinSilenceDuration = 0.1f;
        config.SileroVad.MinSpeechDuration = 0.25f;
        config.SileroVad.MaxSpeechDuration = 30f;
        config.SileroVad.WindowSize = 512;

        var regions = new List<(int, int)>();
        using var vad = new VoiceActivityDetector(config, 60);
        const int window = 512;
        for (var i = 0; i + window <= samples.Length; i += window)
        {
            vad.AcceptWaveform(samples[i..(i + window)]);
            Drain(vad, regions);
        }
        vad.Flush();
        Drain(vad, regions);
        return regions;
    }

    private static void Drain(VoiceActivityDetector vad, List<(int, int)> regions)
    {
        while (!vad.IsEmpty())
        {
            var seg = vad.Front();
            regions.Add((seg.Start, seg.Start + seg.Samples.Length));
            vad.Pop();
        }
    }

    /// <summary>Concatenates speech regions with 30 ms padding; returns null when no speech was found.</summary>
    public static float[]? SpeechOnly(float[] samples)
    {
        var regions = SpeechRegions(samples);
        if (regions.Count == 0) return null;
        var pad = (int)(0.03 * AudioUtil.SampleRate);
        var output = new List<float>(samples.Length);
        var lastEnd = 0;
        foreach (var (s, e) in regions)
        {
            var start = Math.Max(lastEnd, s - pad);
            var end = Math.Min(samples.Length, e + pad);
            if (end > start) output.AddRange(samples.AsSpan(start, end - start));
            output.AddRange(new float[(int)(0.1 * AudioUtil.SampleRate)]); // keep a short pause between regions
            lastEnd = end;
        }
        return [.. output];
    }
}

public interface ILocalTranscriber : IDisposable
{
    Task<IReadOnlyList<TranscriptSegment>> TranscribeAsync(float[] samples, TranscriptionOptions options, CancellationToken ct);
}

public sealed class WhisperTranscriber : ILocalTranscriber
{
    private readonly WhisperFactory _factory;
    private readonly SemaphoreSlim _gate = new(1, 1);

    static WhisperTranscriber()
    {
        // GPU through Vulkan (NVIDIA, AMD, Intel) when the driver supports it, otherwise CPU.
        if (Environment.GetEnvironmentVariable("ZERM_WHISPER_CPU") == "1")
            Whisper.net.LibraryLoader.RuntimeOptions.RuntimeLibraryOrder = [Whisper.net.LibraryLoader.RuntimeLibrary.Cpu];
        else
            Whisper.net.LibraryLoader.RuntimeOptions.RuntimeLibraryOrder =
                [Whisper.net.LibraryLoader.RuntimeLibrary.Vulkan, Whisper.net.LibraryLoader.RuntimeLibrary.Cpu];
    }

    public WhisperTranscriber(string modelPath)
    {
        _factory = WhisperFactory.FromPath(modelPath);
        Log.Info($"Whisper runtime: {LoadedRuntime}");
    }

    public static string LoadedRuntime => Whisper.net.LibraryLoader.RuntimeOptions.LoadedLibrary?.ToString() ?? "not loaded";

    public static bool UsesGpu => Whisper.net.LibraryLoader.RuntimeOptions.LoadedLibrary is
        Whisper.net.LibraryLoader.RuntimeLibrary.Vulkan or Whisper.net.LibraryLoader.RuntimeLibrary.Cuda or Whisper.net.LibraryLoader.RuntimeLibrary.Cuda12;

    /// <summary>
    /// Runs one short inference so GPU shaders are compiled (and cached by the driver) before
    /// the first real dictation. On a first-ever run this can take a minute on Vulkan.
    /// </summary>
    public Task WarmUpAsync(CancellationToken ct = default) =>
        TranscribeAsync(new float[AudioUtil.SampleRate * 2], new TranscriptionOptions("en", null, UseVad: false), ct);

    public async Task<IReadOnlyList<TranscriptSegment>> TranscribeAsync(float[] samples, TranscriptionOptions o, CancellationToken ct)
    {
        await _gate.WaitAsync(ct);
        try
        {
            var input = samples;
            if (o.UseVad && samples.Length > AudioUtil.SampleRate / 2)
            {
                var speech = SileroVad.SpeechOnly(samples);
                if (speech == null) return [];
                input = speech;
            }
            // whisper.cpp needs at least ~1 s of audio; pad short clips with silence.
            if (input.Length < AudioUtil.SampleRate + AudioUtil.SampleRate / 4)
            {
                var padded = new float[AudioUtil.SampleRate + AudioUtil.SampleRate / 4];
                input.CopyTo(padded, 0);
                input = padded;
            }

            var builder = _factory.CreateBuilder()
                .WithThreads(PowerThrottling.InferenceThreads)
                .WithTemperature(0f)
                .WithNoContext()
                .WithLanguage(string.IsNullOrEmpty(o.Language) ? "auto" : o.Language);
            if (!string.IsNullOrWhiteSpace(o.Prompt)) builder = builder.WithPrompt(o.Prompt);
            // Hebrew-tuned models (ivrit.ai) drift into Hebrew script even when another language is
            // forced, e.g. writing accented English phonetically in Hebrew letters. Ban those tokens.
            var suppressHebrew = SuppressesHebrew(o.Language);
            if (suppressHebrew) builder = builder.WithSuppressRegex(HebrewTokenRegex);
            // On CPU, encoding a full 30 s window for a short clip dominates latency; size the
            // encoder context to the clip instead (50 frames per second plus headroom).
            if (!UsesGpu && input.Length < 25 * AudioUtil.SampleRate)
                builder = builder.WithAudioContextSize(Math.Clamp((int)(input.Length / (double)AudioUtil.SampleRate * 50) + 128, 384, 1500));

            await using var processor = builder.Build();
            var segments = new List<TranscriptSegment>();
            await foreach (var seg in processor.ProcessAsync(input, ct))
            {
                var text = CleanSegmentText(seg.Text, suppressHebrew);
                if (text.Length > 0) segments.Add(new TranscriptSegment(seg.Start.TotalSeconds, seg.End.TotalSeconds, text));
            }
            return segments;
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>
    /// Matches any vocabulary token containing a UTF-8 lead byte of the Hebrew block (U+0580–U+05FF
    /// starts with 0xD6 or 0xD7). whisper.cpp tests it with std::regex_match against raw token bytes.
    /// </summary>
    public const string HebrewTokenRegex = @"[\s\S]*[\xD6\xD7][\s\S]*";

    /// <summary>True when a specific non-Hebrew-script language is forced (never for auto-detect).</summary>
    public static bool SuppressesHebrew(string? language) =>
        !string.IsNullOrEmpty(language) && language is not ("auto" or "he" or "iw" or "yi");

    /// <summary>
    /// Drops U+FFFD (whisper.cpp can emit half of a multi-byte character). With Hebrew blocked,
    /// Hebrew speech leaves only right-to-left marks and punctuation behind, so drop those too.
    /// </summary>
    public static string CleanSegmentText(string text, bool hebrewBlocked)
    {
        var sb = new System.Text.StringBuilder(text.Length);
        foreach (var c in text)
        {
            if (c == '\uFFFD') continue;
            if (hebrewBlocked && c is '\u200E' or '\u200F' or (>= '\u202A' and <= '\u202E') or (>= '\u2066' and <= '\u2069')) continue;
            sb.Append(c);
        }
        var cleaned = sb.ToString();
        return hebrewBlocked && !cleaned.Any(char.IsLetterOrDigit) ? "" : cleaned;
    }

    public void Dispose() => _factory.Dispose();
}

public sealed class SherpaTranscriber : ILocalTranscriber
{
    private readonly OfflineRecognizer _recognizer;
    private readonly SemaphoreSlim _gate = new(1, 1);

    public SherpaTranscriber(TranscriptionModel model)
    {
        var dir = model.LocalPath;
        var config = new OfflineRecognizerConfig();
        config.FeatConfig.SampleRate = AudioUtil.SampleRate;
        config.FeatConfig.FeatureDim = 80;
        config.DecodingMethod = "greedy_search";
        config.ModelConfig.Tokens = Path.Combine(dir, "tokens.txt");
        config.ModelConfig.NumThreads = PowerThrottling.InferenceThreads;
        config.ModelConfig.Provider = "cpu";
        config.ModelConfig.Debug = 0;

        string F(params string[] names) => names.Select(n => Path.Combine(dir, n)).FirstOrDefault(File.Exists)
                                            ?? throw new FileNotFoundException($"Model file missing in {dir}: {names[0]}");

        switch (model.SherpaFamily)
        {
            case SherpaFamily.NemoTransducer:
                config.ModelConfig.Transducer.Encoder = F("encoder.int8.onnx", "encoder.onnx");
                config.ModelConfig.Transducer.Decoder = F("decoder.int8.onnx", "decoder.onnx");
                config.ModelConfig.Transducer.Joiner = F("joiner.int8.onnx", "joiner.onnx");
                config.ModelConfig.ModelType = "nemo_transducer";
                break;
            case SherpaFamily.Transducer:
                config.ModelConfig.Transducer.Encoder = F("encoder.int8.onnx", "encoder.onnx");
                config.ModelConfig.Transducer.Decoder = F("decoder.onnx", "decoder.int8.onnx");
                config.ModelConfig.Transducer.Joiner = F("joiner.int8.onnx", "joiner.onnx");
                config.ModelConfig.ModelType = "zipformer";
                config.ModelConfig.ModelingUnit = "bpe";
                if (File.Exists(Path.Combine(dir, "bpe.model"))) config.ModelConfig.BpeVocab = Path.Combine(dir, "bpe.model");
                break;
            case SherpaFamily.Moonshine:
                config.ModelConfig.Moonshine.Preprocessor = F("preprocess.onnx");
                config.ModelConfig.Moonshine.Encoder = F("encode.int8.onnx", "encode.onnx");
                config.ModelConfig.Moonshine.UncachedDecoder = F("uncached_decode.int8.onnx", "uncached_decode.onnx");
                config.ModelConfig.Moonshine.CachedDecoder = F("cached_decode.int8.onnx", "cached_decode.onnx");
                break;
        }
        _recognizer = new OfflineRecognizer(config);
    }

    public async Task<IReadOnlyList<TranscriptSegment>> TranscribeAsync(float[] samples, TranscriptionOptions o, CancellationToken ct)
    {
        await _gate.WaitAsync(ct);
        try
        {
            return await Task.Run(() =>
            {
                // Long audio is decoded in VAD-bounded chunks (<= 30 s) to keep memory flat.
                var segments = new List<TranscriptSegment>();
                var regions = samples.Length > 25 * AudioUtil.SampleRate
                    ? SileroVad.SpeechRegions(samples)
                    : [(0, samples.Length)];
                if (AudioUtil.Peak(samples) < 0.003f) return segments; // digital silence
                foreach (var (start, end) in regions)
                {
                    ct.ThrowIfCancellationRequested();
                    using var stream = _recognizer.CreateStream();
                    stream.AcceptWaveform(AudioUtil.SampleRate, samples[start..end]);
                    _recognizer.Decode(stream);
                    var text = stream.Result.Text.Trim();
                    if (text.Length > 0)
                        segments.Add(new TranscriptSegment(start / (double)AudioUtil.SampleRate, end / (double)AudioUtil.SampleRate, text));
                }
                return (IReadOnlyList<TranscriptSegment>)segments;
            }, ct);
        }
        finally
        {
            _gate.Release();
        }
    }

    public void Dispose() => _recognizer.Dispose();
}
