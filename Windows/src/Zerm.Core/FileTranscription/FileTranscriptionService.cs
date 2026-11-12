using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using Zerm.Core.Audio;
using Zerm.Core.Data;
using Zerm.Core.Models;
using Zerm.Core.Settings;
using Zerm.Core.Text;
using Zerm.Core.Transcription;

namespace Zerm.Core.FileTranscription;

public enum FileJobStatus { Queued, Converting, Diarizing, Transcribing, Completed, Failed, Cancelled }

public partial class FileTranscriptionJob : ObservableObject
{
    public Guid Id { get; } = Guid.NewGuid();
    public required string SourcePath { get; init; }
    public string FileName => Path.GetFileName(SourcePath);
    public required string ModelName { get; init; }
    public bool IdentifySpeakers { get; init; }
    public int? SpeakerCount { get; init; }
    public string? Language { get; init; }

    [ObservableProperty] private FileJobStatus _status = FileJobStatus.Queued;
    [ObservableProperty] private double _progress;
    [ObservableProperty] private string? _error;
    [ObservableProperty] private string? _warning;
    [ObservableProperty] private Guid? _transcriptionId;
    public FileTranscript? Transcript { get; set; }
    internal CancellationTokenSource Cancellation { get; } = new();

    public bool IsActive => Status is FileJobStatus.Queued or FileJobStatus.Converting or FileJobStatus.Diarizing or FileJobStatus.Transcribing;
}

/// <summary>Port of FileTranscriptionQueue: convert → diarize (optional) → transcribe → save, one job at a time.</summary>
public sealed class FileTranscriptionService(AppSettings settings, Library library, HistoryStore history, TranscriptionService transcription)
{
    public static readonly string[] SupportedExtensions =
        [".wav", ".mp3", ".m4a", ".mp4", ".mov", ".m4v", ".flac", ".aac", ".wma", ".aiff", ".aif", ".3gp", ".ogg", ".opus", ".webm", ".amr", ".caf"];

    public ObservableCollection<FileTranscriptionJob> Jobs { get; } = [];
    private readonly SemaphoreSlim _runner = new(1, 1);
    public Action<Action>? Dispatch { get; set; }

    private void OnUi(Action a)
    {
        if (Dispatch != null) Dispatch(a);
        else a();
    }

    public FileTranscriptionJob Enqueue(string path, string modelName, bool identifySpeakers, int? speakerCount, string? language)
    {
        var job = new FileTranscriptionJob
        {
            SourcePath = path, ModelName = modelName, IdentifySpeakers = identifySpeakers, SpeakerCount = speakerCount, Language = language,
        };
        OnUi(() => Jobs.Insert(0, job));
        _ = RunAsync(job);
        return job;
    }

    public void Cancel(FileTranscriptionJob job)
    {
        job.Cancellation.Cancel();
        OnUi(() => job.Status = FileJobStatus.Cancelled);
    }

    public FileTranscriptionJob Retry(FileTranscriptionJob job) =>
        Enqueue(job.SourcePath, job.ModelName, job.IdentifySpeakers, job.SpeakerCount, job.Language);

    private async Task RunAsync(FileTranscriptionJob job)
    {
        await _runner.WaitAsync();
        try
        {
            if (job.Cancellation.IsCancellationRequested) return;
            await ProcessAsync(job, job.Cancellation.Token);
        }
        catch (OperationCanceledException)
        {
            OnUi(() => job.Status = FileJobStatus.Cancelled);
        }
        catch (Exception ex)
        {
            Log.Error($"File transcription failed for {job.FileName}", ex);
            OnUi(() =>
            {
                job.Error = Dictation.DictationPipeline.Describe(ex);
                job.Status = FileJobStatus.Failed;
            });
        }
        finally
        {
            _runner.Release();
        }
    }

    public async Task ProcessAsync(FileTranscriptionJob job, CancellationToken ct)
    {
        var model = TranscriptionModelRegistry.Find(job.ModelName, library.CustomTranscriptionModels)
                    ?? throw new InvalidOperationException("The selected model is no longer available.");

        void Set(FileJobStatus s, double p) => OnUi(() => { job.Status = s; job.Progress = p; });

        Set(FileJobStatus.Converting, 0.02);
        var samples = await Task.Run(() => AudioUtil.LoadAs16kMono(job.SourcePath), ct);
        var duration = AudioUtil.DurationSeconds(samples.Length);
        if (duration < 0.1) throw new InvalidOperationException("The file contains no audio.");
        var id = Guid.NewGuid();
        var wavPath = Path.Combine(AppPaths.Recordings, $"{id}.wav");
        await Task.Run(() => AudioUtil.WriteWav16k(wavPath, samples), ct);

        List<SpeakerTurn>? turns = null;
        if (job.IdentifySpeakers)
        {
            if (!Diarizer.IsDownloaded)
            {
                OnUi(() => job.Warning = "Speaker identification models are not downloaded — transcribed without speakers.");
            }
            else
            {
                Set(FileJobStatus.Diarizing, 0.05);
                try
                {
                    var progress = new Progress<double>(p => OnUi(() => job.Progress = 0.05 + p * 0.35));
                    turns = await Task.Run(() => Diarizer.Diarize(samples, job.SpeakerCount, progress, ct), ct);
                    if (turns.Count == 0) turns = null;
                }
                catch (OperationCanceledException) { throw; }
                catch (Exception ex)
                {
                    Log.Error("Diarization failed", ex);
                    OnUi(() => job.Warning = "Speaker identification failed — transcribed without speakers.");
                    turns = null;
                }
            }
        }

        Set(FileJobStatus.Transcribing, turns != null ? 0.4 : 0.05);
        var cleanup = new TextCleanupOptions(settings.RemoveFillerWords, settings.FillerWords, false, library.ReplacementRules, PunctuationCleanupMode.Keep, false);
        var vocabulary = VocabularyTerms.TranscriptionTerms(library.Vocabulary.Select(v => v.Word), null);
        var transcript = new FileTranscript
        {
            SourceFileName = job.FileName,
            Duration = duration,
            ModelName = model.DisplayName,
            LanguageCode = job.Language ?? "auto",
        };

        var spans = turns != null
            ? Diarizer.PlanSpans(turns).Select(t => (t.Start, t.End, (int?)t.Speaker)).ToList()
            : Windows(duration, model.IsLocal ? 600 : 30, model.IsLocal ? 0 : 2).Select(w => (w.Start, w.End, (int?)null)).ToList();

        var failuresInARow = 0;
        string? previousTail = null;
        for (var i = 0; i < spans.Count; i++)
        {
            ct.ThrowIfCancellationRequested();
            var (start, end, speaker) = spans[i];
            var pad = turns != null ? 0.2 : 0;
            var s0 = (int)(Math.Max(0, start - pad) * AudioUtil.SampleRate);
            var s1 = (int)(Math.Min(duration, end + pad) * AudioUtil.SampleRate);
            if (s1 - s0 < AudioUtil.SampleRate / 5) continue;
            var chunk = samples[s0..s1];
            var chunkPath = wavPath;
            if (!model.IsLocal)
            {
                chunkPath = Path.Combine(AppPaths.FileTranscription, $"{job.Id}-{i}.wav");
                AudioUtil.WriteWav16k(chunkPath, chunk);
            }
            try
            {
                var result = await transcription.TranscribeAsync(model, chunkPath, chunk, job.Language, vocabulary, library.CustomModels, ct,
                    Timeout.InfiniteTimeSpan, useVad: false);
                failuresInARow = 0;
                var offset = s0 / (double)AudioUtil.SampleRate;
                var segs = model.IsLocal && turns == null
                    ? result.Segments.Select(seg => (Start: offset + seg.Start, End: offset + seg.End, seg.Text))
                    : [(Start: start, End: end, Text: result.Text)];
                foreach (var seg in segs)
                {
                    var text = WordReplacer.Apply(TranscriptionOutputFilter.Filter(seg.Text, cleanup.RemoveFillerWords, cleanup.FillerWords), cleanup.Replacements);
                    if (turns == null && !model.IsLocal) text = Reconcile(previousTail, text);
                    if (text.Length == 0) continue;
                    previousTail = text;
                    transcript.Segments.Add(new FileSegment { Start = seg.Start, End = Math.Min(duration, seg.End), SpeakerIndex = speaker, Text = text });
                }
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch (Exception ex)
            {
                Log.Warn($"Span {i} failed: {ex.Message}");
                if (++failuresInARow >= 5 || spans.Count == 1) throw;
            }
            finally
            {
                if (chunkPath != wavPath) try { File.Delete(chunkPath); } catch { }
            }
            var progressBase = turns != null ? 0.4 : 0.05;
            var fraction = progressBase + (1 - progressBase) * (i + 1) / spans.Count;
            OnUi(() => job.Progress = fraction);
        }

        if (transcript.Segments.Count == 0) throw new InvalidOperationException("No speech was found in this file.");
        transcript.NormalizeSpeakers();

        var record = new TranscriptionRecord
        {
            Id = id,
            Text = transcript.PlainText,
            Duration = duration,
            AudioFilePath = wavPath,
            TranscriptionModelName = model.DisplayName,
            Status = TranscriptionStatus.Completed,
            SegmentsJson = transcript.ToJson(),
            PromptName = "File: " + job.FileName,
        };
        history.Upsert(record);
        OnUi(() =>
        {
            job.Transcript = transcript;
            job.TranscriptionId = id;
            job.Progress = 1;
            job.Status = FileJobStatus.Completed;
        });
    }

    public void SaveTranscript(Guid recordId, FileTranscript transcript)
    {
        var record = history.Get(recordId);
        if (record == null) return;
        record.SegmentsJson = transcript.ToJson();
        record.Text = transcript.PlainText;
        history.Upsert(record);
    }

    public static IEnumerable<(double Start, double End)> Windows(double duration, double size, double overlap)
    {
        for (var s = 0.0; s < duration; s += size - overlap)
        {
            yield return (s, Math.Min(duration, s + size));
            if (s + size >= duration) yield break;
        }
    }

    /// <summary>Drops the next window's prefix that repeats the previous window's suffix (≤ 40 words, ~20% tolerance).</summary>
    public static string Reconcile(string? previous, string next)
    {
        if (string.IsNullOrEmpty(previous) || next.Length == 0) return next;
        static string Norm(string w) => new(w.ToLowerInvariant().Where(char.IsLetterOrDigit).ToArray());
        var prev = previous.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var words = next.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        for (var k = Math.Min(40, Math.Min(prev.Length, words.Length)); k >= 1; k--)
        {
            var tail = prev[^k..].Select(Norm).ToArray();
            var head = words[..k].Select(Norm).ToArray();
            var mismatches = tail.Zip(head).Count(p => p.First != p.Second);
            var allowed = k <= 2 ? 0 : (int)Math.Floor(k * 0.2);
            if (mismatches <= allowed) return string.Join(" ", words[k..]);
        }
        return next;
    }
}
