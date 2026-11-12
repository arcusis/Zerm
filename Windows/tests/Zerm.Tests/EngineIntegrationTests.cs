using System.Diagnostics;
using Xunit.Abstractions;
using Zerm.Core.Audio;
using Zerm.Core.Models;
using Zerm.Core.Transcription;

namespace Zerm.Tests;

/// <summary>
/// Runs the real native engines. Models are taken from ZERM_TEST_MODELS (a folder containing
/// ggml-tiny.en.bin and/or an extracted sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8 folder); tests
/// without their model are skipped rather than failed.
/// </summary>
public class EngineIntegrationTests(ITestOutputHelper output)
{
    private static string? ModelsDir => Environment.GetEnvironmentVariable("ZERM_TEST_MODELS");

    internal static float[] SpeechSample(string text = "Hello world, this is a dictation test for the Windows version.")
    {
        var path = Path.Combine(Path.GetTempPath(), $"zerm-test-{Guid.NewGuid():N}.wav");
        try
        {
            using (var synth = new System.Speech.Synthesis.SpeechSynthesizer())
            {
                synth.SetOutputToWaveFile(path, new System.Speech.AudioFormat.SpeechAudioFormatInfo(16000,
                    System.Speech.AudioFormat.AudioBitsPerSample.Sixteen, System.Speech.AudioFormat.AudioChannel.Mono));
                synth.Speak(text);
            }
            return AudioUtil.LoadAs16kMono(path);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void VadFindsSpeechAndIgnoresSilence()
    {
        var speech = SpeechSample();
        var padded = new float[16000 * 2].Concat(speech).Concat(new float[16000 * 2]).ToArray();
        var regions = SileroVad.SpeechRegions(padded);
        Assert.NotEmpty(regions);
        Assert.True(regions[0].Start >= 16000 * 1.5, $"speech region starts at {regions[0].Start}");
        Assert.Empty(SileroVad.SpeechRegions(new float[16000 * 3]));
        Assert.Null(SileroVad.SpeechOnly(new float[16000 * 3]));
    }

    [SkippableFact]
    public async Task WhisperTranscribesSynthesizedSpeech()
    {
        var model = ModelsDir == null ? null : Path.Combine(ModelsDir, "ggml-tiny.en.bin");
        Skip.If(model == null || !File.Exists(model), "ZERM_TEST_MODELS/ggml-tiny.en.bin not available");
        using var t = new WhisperTranscriber(model!);
        var sw = Stopwatch.StartNew();
        var segs = await t.TranscribeAsync(SpeechSample(), new TranscriptionOptions("en", "Hello, how are you doing?"), CancellationToken.None);
        var text = string.Join(" ", segs.Select(s => s.Text)).ToLowerInvariant();
        output.WriteLine($"{sw.ElapsedMilliseconds} ms: {text}");
        Assert.Contains("dictation test", text);
        Assert.Contains("windows", text);

        var silent = await t.TranscribeAsync(new float[16000 * 3], new TranscriptionOptions("en", null), CancellationToken.None);
        Assert.Empty(silent);
    }

    [SkippableFact]
    public async Task ParakeetTranscribesSynthesizedSpeech()
    {
        Skip.If(ModelsDir == null || !Directory.Exists(Path.Combine(ModelsDir, "SherpaOnnxModels", "parakeet-tdt-0.6b-v3")),
            "ZERM_TEST_MODELS/SherpaOnnxModels/parakeet-tdt-0.6b-v3 not available");
        Zerm.Core.AppPaths.Root = ModelsDir!;
        var model = TranscriptionModelRegistry.Find("parakeet-tdt-0.6b-v3")!;
        Assert.True(model.IsDownloaded);
        using var t = new SherpaTranscriber(model);
        var sw = Stopwatch.StartNew();
        var segs = await t.TranscribeAsync(SpeechSample(), new TranscriptionOptions(null, null), CancellationToken.None);
        var text = string.Join(" ", segs.Select(s => s.Text)).ToLowerInvariant();
        output.WriteLine($"{sw.ElapsedMilliseconds} ms: {text}");
        Assert.Contains("dictation test", text);

        sw.Restart();
        await t.TranscribeAsync(SpeechSample("Second call to measure warm latency."), new TranscriptionOptions(null, null), CancellationToken.None);
        output.WriteLine($"warm: {sw.ElapsedMilliseconds} ms");
    }
}
