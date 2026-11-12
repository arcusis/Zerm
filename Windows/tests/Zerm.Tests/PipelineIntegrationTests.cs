using System.Diagnostics;
using Xunit.Abstractions;
using Zerm.Core;
using Zerm.Core.Audio;
using Zerm.Core.Data;
using Zerm.Core.Dictation;
using Zerm.Core.Enhancement;
using Zerm.Core.FileTranscription;
using Zerm.Core.LocalLlm;
using Zerm.Core.Models;
using Zerm.Core.Settings;
using Zerm.Core.TextToSpeech;
using Zerm.Core.Transcription;

namespace Zerm.Tests;

public sealed class FakeHost : IDictationHost
{
    public List<RecorderState> States { get; } = [];
    public List<(string Message, ToastKind Kind)> Toasts { get; } = [];
    public void SetState(RecorderState state) => States.Add(state);
    public void Toast(string message, ToastKind kind, TimeSpan? duration = null, ToastAction? action = null) => Toasts.Add((message, kind));
}

/// <summary>
/// End-to-end tests on real models found under ZERM_TEST_MODELS (laid out like %LOCALAPPDATA%\Zerm).
/// Each test is skipped when its model is missing.
/// </summary>
public sealed class PipelineIntegrationTests : IDisposable
{
    private readonly ITestOutputHelper _out;
    private readonly TempDir _dir = new();
    private static string? Models => Environment.GetEnvironmentVariable("ZERM_TEST_MODELS");

    public PipelineIntegrationTests(ITestOutputHelper output)
    {
        _out = output;
        if (Models != null) AppPaths.Root = Models;
    }

    public void Dispose() => _dir.Dispose();

    private static void Need(string relative) =>
        Skip.If(Models == null || !Path.Exists(Path.Combine(Models, relative)), $"{relative} not available under ZERM_TEST_MODELS");

    private (DictationPipeline Pipeline, FakeHost Host, HistoryStore History, Library Library, AppSettings Settings, TranscriptionService Transcription) Build()
    {
        var settings = AppSettings.Load(_dir.File("settings.json"));
        var library = Library.Load(_dir.File("library.json"));
        var history = new HistoryStore(_dir.File("history.db"));
        var secrets = new SecretStore(_dir.File("secrets.dat"));
        var transcription = new TranscriptionService(settings, secrets);
        var enhancement = new EnhancementService(settings, library, secrets, SharedLlm);
        var host = new FakeHost();
        return (new DictationPipeline(settings, library, history, transcription, enhancement, host), host, history, library, settings, transcription);
    }

    private static readonly LocalLlmEngine SharedLlm = new();

    private static float[] Speak(string text, string voice = "Microsoft David Desktop")
    {
        var path = Path.Combine(Path.GetTempPath(), $"zerm-voice-{Guid.NewGuid():N}.wav");
        try
        {
            using (var synth = new System.Speech.Synthesis.SpeechSynthesizer())
            {
                synth.SelectVoice(voice);
                synth.SetOutputToWaveFile(path, new System.Speech.AudioFormat.SpeechAudioFormatInfo(16000,
                    System.Speech.AudioFormat.AudioBitsPerSample.Sixteen, System.Speech.AudioFormat.AudioChannel.Mono));
                synth.Speak(text);
            }
            return AudioUtil.LoadAs16kMono(path);
        }
        finally { File.Delete(path); }
    }

    private DictationSession Session(TranscriptionModel model, AppSettings s, Library lib, DictationOutputMode mode) =>
        new(model, "en", DictationPipeline.CleanupOptions(s, lib, null), mode, new EnhancementOverrides(), null, null, null, AutoSendKey.None);

    [SkippableFact]
    public async Task InstantDictationTranscribesCleansAndSaves()
    {
        Need("WhisperModels/ggml-tiny.en.bin");
        var (pipeline, host, history, library, settings, _) = Build();
        library.AddReplacement("windows version", "Windows edition");
        var samples = Speak("Um, this is a test of the windows version comma and it works period");
        var wav = _dir.File("a.wav");
        AudioUtil.WriteWav16k(wav, samples);
        var result = await pipeline.RunAsync(wav, samples, Session(TranscriptionModelRegistry.Find("ggml-tiny.en")!, settings, library, DictationOutputMode.Instant), CancellationToken.None);
        Assert.NotNull(result);
        _out.WriteLine(result!.TextToPaste);
        Assert.Contains("Windows edition", result.TextToPaste);
        Assert.DoesNotContain("Um", result.TextToPaste);
        Assert.Null(result.RefineRequest);
        Assert.Equal(TranscriptionStatus.Completed, history.Get(result.Record.Id)!.Status);
        Assert.Equal(1, history.UsageDays().Single().Sessions);
        Assert.Contains(RecorderState.Transcribing, host.States);
        Assert.Empty(host.Toasts);
    }

    [SkippableFact]
    public async Task SilenceIsReportedAndNotPasted()
    {
        Need("WhisperModels/ggml-tiny.en.bin");
        var (pipeline, host, history, library, settings, _) = Build();
        var samples = new float[16000 * 2];
        var wav = _dir.File("s.wav");
        AudioUtil.WriteWav16k(wav, samples);
        var result = await pipeline.RunAsync(wav, samples, Session(TranscriptionModelRegistry.Find("ggml-tiny.en")!, settings, library, DictationOutputMode.Instant), CancellationToken.None);
        Assert.Null(result);
        Assert.Contains(host.Toasts, t => t.Message.StartsWith("No speech detected"));
        Assert.Equal(TranscriptionStatus.Failed, history.Query()[0].Status);
    }

    [SkippableFact]
    public async Task EnhancedModeUsesOnDeviceModel()
    {
        Need("WhisperModels/ggml-tiny.en.bin");
        Need("LLMModels/gemma-4-E2B_q4_0-it.gguf");
        var (pipeline, host, history, library, settings, _) = Build();
        settings.SelectedAIProvider = AIProviders.OnDevice;
        var samples = Speak("so the meeting is on tuesday, sorry not that, actually wednesday at five");
        var wav = _dir.File("e.wav");
        AudioUtil.WriteWav16k(wav, samples);
        var sw = Stopwatch.StartNew();
        var result = await pipeline.RunAsync(wav, samples, Session(TranscriptionModelRegistry.Find("ggml-tiny.en")!, settings, library, DictationOutputMode.Enhanced), CancellationToken.None);
        _out.WriteLine($"{sw.ElapsedMilliseconds} ms raw='{result?.Record.Text}' enhanced='{result?.Record.EnhancedText}' toasts={string.Join("|", host.Toasts)}");
        Assert.NotNull(result);
        Assert.Equal("Enhanced", result!.Record.EnhancementOutcome);
        Assert.Contains("Wednesday", result.TextToPaste);
        Assert.DoesNotContain("Tuesday", result.TextToPaste, StringComparison.OrdinalIgnoreCase);
        Assert.Contains(RecorderState.Enhancing, host.States);
        Assert.Contains("<TRANSCRIPT>", history.Get(result.Record.Id)!.AiRequestUserMessage);
    }

    [SkippableFact]
    public async Task InstantRefineReturnsRequestAndRefinePersists()
    {
        Need("WhisperModels/ggml-tiny.en.bin");
        Need("LLMModels/gemma-4-E2B_q4_0-it.gguf");
        var (pipeline, host, history, library, settings, _) = Build();
        settings.SelectedAIProvider = AIProviders.OnDevice;
        settings.EnhancementTimeoutSeconds = 30;
        var samples = Speak("i think we should ship the release on friday because the tests are green");
        var wav = _dir.File("r.wav");
        AudioUtil.WriteWav16k(wav, samples);
        var session = Session(TranscriptionModelRegistry.Find("ggml-tiny.en")!, settings, library, DictationOutputMode.InstantRefine);
        var result = await pipeline.RunAsync(wav, samples, session, CancellationToken.None);
        Assert.NotNull(result?.RefineRequest);
        Assert.Equal(result!.Record.Text, result.TextToPaste);
        await SharedLlm.PrewarmAsync(LocalLlmCatalog.PathFor(LocalLlmCatalog.Find(LocalLlmCatalog.DefaultId)!));
        var refined = await pipeline.RefineAsync(result.Record, result.RefineRequest!, session.Cleanup, CancellationToken.None);
        _out.WriteLine($"raw='{result.Record.Text}' refined='{refined}' outcome={result.Record.EnhancementOutcome}/{result.Record.EnhancementOutcomeReason} toasts={string.Join("|", host.Toasts)}");
        Assert.NotNull(refined);
        Assert.Equal(refined, history.Get(result.Record.Id)!.EnhancedText);
    }

    [SkippableFact]
    public async Task DiarizationSeparatesTwoVoicesAndFileTranscriptionLabelsThem()
    {
        Need("DiarizationModels/pyannote-segmentation-3-0/model.onnx");
        Need("WhisperModels/ggml-tiny.en.bin");
        var gap = new float[16000];
        var audio = Speak("Good morning everyone. Today we are reviewing the quarterly roadmap and the hiring plan for the next two months.")
            .Concat(gap)
            .Concat(Speak("Thanks. I have prepared the budget numbers and a short summary of the customer feedback we collected.", "Microsoft Zira Desktop"))
            .Concat(gap)
            .Concat(Speak("Great, let us start with the budget and then move to feedback before lunch."))
            .ToArray();

        var sw = Stopwatch.StartNew();
        var turns = Diarizer.Diarize(audio, null, null, CancellationToken.None);
        _out.WriteLine($"diarization {sw.ElapsedMilliseconds} ms: {string.Join(", ", turns)}");
        Assert.Equal(2, turns.Select(t => t.Speaker).Distinct().Count());
        Assert.Equal(turns[0].Speaker, turns[^1].Speaker);

        var (_, _, history, library, settings, transcription) = Build();
        var path = _dir.File("meeting.wav");
        AudioUtil.WriteWav16k(path, audio);
        var service = new FileTranscriptionService(settings, library, history, transcription);
        var job = new FileTranscriptionJob { SourcePath = path, ModelName = "ggml-tiny.en", IdentifySpeakers = true, Language = "en" };
        await service.ProcessAsync(job, CancellationToken.None);
        Assert.Equal(FileJobStatus.Completed, job.Status);
        var t = job.Transcript!;
        _out.WriteLine(FileTranscriptExporter.Export(t, ExportFormat.Text));
        Assert.Equal(2, t.Speakers.Count());
        Assert.Equal(0, t.Paragraphs[0].SpeakerIndex);
        Assert.Contains("budget", FileTranscriptExporter.Export(t, ExportFormat.Srt), StringComparison.OrdinalIgnoreCase);
        var saved = history.Get(job.TranscriptionId!.Value)!;
        Assert.NotNull(FileTranscript.FromJson(saved.SegmentsJson));
        Assert.Contains("Speaker 2:", saved.Text);
    }

    [SkippableFact]
    public async Task KokoroSpeaksAndWhisperUnderstandsIt()
    {
        Need("TTSModels/kokoro-en-v0_19/model.onnx");
        Need("WhisperModels/ggml-tiny.en.bin");
        using var kokoro = new KokoroProvider();
        var sw = Stopwatch.StartNew();
        var audio = await kokoro.SynthesizeAsync("The quick brown fox jumps over the lazy dog.", "3", 1.0, CancellationToken.None);
        _out.WriteLine($"kokoro {sw.ElapsedMilliseconds} ms, {audio.Samples.Length} samples @ {audio.SampleRate}");
        Assert.Equal(24000, audio.SampleRate);
        Assert.True(AudioUtil.Peak(audio.Samples) > 0.05f);

        var resampled = AudioUtil.ToMono16k(new NAudio.Wave.SampleProviders.WdlResamplingSampleProvider(
            new FloatArrayProvider(audio.Samples, audio.SampleRate), 16000));
        using var whisper = new WhisperTranscriber(Path.Combine(Models!, "WhisperModels", "ggml-tiny.en.bin"));
        var text = TranscriptionService.Join(await whisper.TranscribeAsync(resampled, new TranscriptionOptions("en", null), CancellationToken.None));
        _out.WriteLine(text);
        Assert.Contains("fox", text, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task WindowsVoicesSynthesize()
    {
        var provider = new WindowsVoicesProvider();
        Assert.NotEmpty(provider.Voices);
        var audio = await provider.SynthesizeAsync("Testing Windows voices.", provider.Voices[0].Id, 1.0, CancellationToken.None);
        Assert.True(audio.Samples.Length > audio.SampleRate / 2);
        Assert.True(AudioUtil.Peak(audio.Samples) > 0.05f);
    }

    [SkippableFact]
    public async Task ReadAloudRetellWithOnDeviceModel()
    {
        Need("LLMModels/gemma-4-E2B_q4_0-it.gguf");
        var path = LocalLlmCatalog.PathFor(LocalLlmCatalog.Find(LocalLlmCatalog.DefaultId)!);
        var naturalizer = new TtsNaturalizer(SharedLlm, () => path);
        var source = "PR #42 merged ✅ — fixed the ENOENT crash in config.json loader. Next: ship v2.1 on Friday.";
        var spoken = await naturalizer.TransformAsync(source, ReadAloudMode.Retell, CancellationToken.None);
        _out.WriteLine(spoken);
        Assert.DoesNotContain("✅", spoken);
        Assert.Contains("Friday", spoken);
    }

    [Fact]
    public async Task DownloaderVerifiesResumesAndExtracts()
    {
        using var dir = new TempDir();
        var spec = new DownloadSpec("https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx",
            dir.File("vad.onnx"), "9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6", 643_854);
        // Simulate an interrupted download: the first 100 KB are already on disk.
        var full = await Zerm.Core.Net.Http.Client.GetByteArrayAsync(spec.Url);
        await File.WriteAllBytesAsync(spec.Destination + ".part", full[..100_000]);
        DownloadProgress? last = null;
        await ModelDownloader.DownloadAsync(spec, new Progress<DownloadProgress>(p => last = p), CancellationToken.None);
        Assert.Equal(full.Length, new FileInfo(spec.Destination).Length);

        var bad = spec with { Destination = dir.File("bad.onnx"), Sha256 = new string('0', 64) };
        await Assert.ThrowsAsync<ChecksumMismatchException>(() => ModelDownloader.DownloadAsync(bad, null, CancellationToken.None));
        Assert.False(File.Exists(bad.Destination));

        var archive = new DownloadSpec("https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2",
            dir.File("seg.tar.bz2"), "24615ee884c897d9d2ba09bb4d30da6bb1b15e685065962db5b02e76e4996488", 6_958_444, dir.File("seg"));
        var sw = Stopwatch.StartNew();
        await ModelDownloader.DownloadAsync(archive, null, CancellationToken.None);
        _out.WriteLine($"download+extract {sw.ElapsedMilliseconds} ms");
        Assert.True(File.Exists(Path.Combine(dir.File("seg"), "model.onnx")));
        Assert.False(File.Exists(archive.Destination + ".part"));
    }

    private sealed class FloatArrayProvider(float[] samples, int rate) : NAudio.Wave.ISampleProvider
    {
        private int _pos;
        public NAudio.Wave.WaveFormat WaveFormat { get; } = NAudio.Wave.WaveFormat.CreateIeeeFloatWaveFormat(rate, 1);

        public int Read(Span<float> buffer)
        {
            var n = Math.Min(buffer.Length, samples.Length - _pos);
            samples.AsSpan(_pos, n).CopyTo(buffer);
            _pos += n;
            return n;
        }
    }
}
