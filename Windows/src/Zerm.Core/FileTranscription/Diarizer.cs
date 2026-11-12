using SherpaOnnx;
using Zerm.Core.Audio;
using Zerm.Core.Models;

namespace Zerm.Core.FileTranscription;

public sealed record SpeakerTurn(double Start, double End, int Speaker);

/// <summary>
/// Speaker diarization with sherpa-onnx: pyannote segmentation 3.0 + 3D-Speaker ERes2Net embeddings
/// (the Windows counterpart of FluidAudio's offline diarizer on macOS).
/// </summary>
public static class Diarizer
{
    public static string SegmentationDir => Path.Combine(AppPaths.DiarizationModels, "pyannote-segmentation-3-0");
    public static string EmbeddingPath => Path.Combine(AppPaths.DiarizationModels, "3dspeaker_eres2net_base_16k.onnx");

    public static bool IsDownloaded =>
        File.Exists(Path.Combine(SegmentationDir, "model.onnx")) && File.Exists(EmbeddingPath);

    public static long DownloadSize => 6_958_444 + 39_593_761;

    public static IReadOnlyList<DownloadSpec> Downloads =>
    [
        new("https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2",
            Path.Combine(AppPaths.DiarizationModels, "pyannote-segmentation-3-0.tar.bz2"),
            "24615ee884c897d9d2ba09bb4d30da6bb1b15e685065962db5b02e76e4996488", 6_958_444, SegmentationDir),
        new("https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx",
            EmbeddingPath, "1a331345f04805badbb495c775a6ddffcdd1a732567d5ec8b3d5749e3c7a5e4b", 39_593_761),
    ];

    /// <param name="speakerCount">Exact number of speakers, or null to detect automatically.</param>
    public static List<SpeakerTurn> Diarize(float[] samples, int? speakerCount, IProgress<double>? progress, CancellationToken ct)
    {
        var config = new OfflineSpeakerDiarizationConfig();
        config.Segmentation.Pyannote.Model = Path.Combine(SegmentationDir, "model.onnx");
        config.Segmentation.NumThreads = Math.Clamp(Environment.ProcessorCount / 2, 1, 8);
        config.Segmentation.Provider = "cpu";
        config.Embedding.Model = EmbeddingPath;
        config.Embedding.NumThreads = Math.Clamp(Environment.ProcessorCount / 2, 1, 8);
        config.Embedding.Provider = "cpu";
        config.Clustering.NumClusters = speakerCount ?? -1;
        config.Clustering.Threshold = 0.5f;
        config.MinDurationOn = 0.3f;
        config.MinDurationOff = 0.5f;

        using var sd = new OfflineSpeakerDiarization(config);
        if (sd.SampleRate != AudioUtil.SampleRate) throw new InvalidOperationException("Unexpected diarization sample rate");
        OfflineSpeakerDiarizationProgressCallback callback = (done, total, _) =>
        {
            progress?.Report(total > 0 ? done / (double)total : 0);
            return ct.IsCancellationRequested ? 1 : 0;
        };
        var segments = sd.ProcessWithCallback(samples, callback, IntPtr.Zero);
        ct.ThrowIfCancellationRequested();
        return segments.Select(s => new SpeakerTurn(s.Start, s.End, s.Speaker)).OrderBy(s => s.Start).ToList();
    }

    /// <summary>
    /// Plans transcription spans (SpeakerTurnPlanner): same-speaker turns separated by ≤ 2 s merge,
    /// turns shorter than 1 s fold into their neighbour, and spans are capped at 30 s.
    /// </summary>
    public static List<SpeakerTurn> PlanSpans(IReadOnlyList<SpeakerTurn> turns, double mergeGap = 2, double minimumTurn = 1, double maximumSpan = 30)
    {
        var merged = new List<SpeakerTurn>();
        foreach (var t in turns.OrderBy(t => t.Start))
        {
            if (merged.Count > 0 && merged[^1].Speaker == t.Speaker && t.Start - merged[^1].End <= mergeGap)
                merged[^1] = merged[^1] with { End = Math.Max(merged[^1].End, t.End) };
            else
                merged.Add(t);
        }

        // Fold very short turns into the previous span (or the next one if they lead).
        var folded = new List<SpeakerTurn>();
        for (var i = 0; i < merged.Count; i++)
        {
            var t = merged[i];
            if (t.End - t.Start < minimumTurn && (folded.Count > 0 || i + 1 < merged.Count))
            {
                if (folded.Count > 0) folded[^1] = folded[^1] with { End = Math.Max(folded[^1].End, t.End) };
                else merged[i + 1] = merged[i + 1] with { Start = t.Start };
                continue;
            }
            if (folded.Count > 0 && folded[^1].Speaker == t.Speaker && t.Start - folded[^1].End <= mergeGap)
                folded[^1] = folded[^1] with { End = t.End };
            else
                folded.Add(t);
        }

        var spans = new List<SpeakerTurn>();
        foreach (var t in folded)
        {
            for (var s = t.Start; s < t.End; s += maximumSpan)
                spans.Add(t with { Start = s, End = Math.Min(t.End, s + maximumSpan) });
        }
        return spans;
    }
}
