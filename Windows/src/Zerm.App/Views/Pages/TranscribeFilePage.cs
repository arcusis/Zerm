using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;
using Microsoft.Win32;
using Zerm.App.Localization;
using Zerm.Core.Dictation;
using Zerm.Core.FileTranscription;
using Zerm.Core.Models;

namespace Zerm.App.Views.Pages;

/// <summary>Port of the Transcribe File page: drop zone, speaker options and the job queue.</summary>
public sealed class TranscribeFilePage : ContentControl
{
    private readonly AppHost _host = AppHost.Current;
    private bool _identifySpeakers = true;
    private int _speakerCount;
    private string _modelName;
    private string _language;
    private StackPanel _queue = new();

    public TranscribeFilePage()
    {
        _modelName = _host.CurrentModel?.Name ?? "";
        _language = _host.Settings.SelectedLanguage;
        Render();
        _host.FileTranscription.Jobs.CollectionChanged += OnJobs;
        _host.Downloads.Changed += Rerender;
        Unloaded += (_, _) =>
        {
            _host.FileTranscription.Jobs.CollectionChanged -= OnJobs;
            _host.Downloads.Changed -= Rerender;
        };
    }

    private void OnJobs(object? s, System.Collections.Specialized.NotifyCollectionChangedEventArgs e) => Dispatcher.BeginInvoke(RenderQueue);
    private void Rerender() => Dispatcher.BeginInvoke(Render);

    private void Render()
    {
        _queue = new StackPanel(); // a WPF element can only have one parent
        var drop = new Border
        {
            AllowDrop = true, MinHeight = 170, CornerRadius = new CornerRadius(14), BorderThickness = new Thickness(2), Margin = new Thickness(0, 0, 0, 14),
            BorderBrush = (Brush)Application.Current.FindResource("CardStrokeColorDefaultBrush"),
            Background = (Brush)Application.Current.FindResource("SubtleFillColorSecondaryBrush"),
        };
        var dropContent = UiKit.VStack(
            UiKit.Glyph(Icons.File, 34).Center(),
            UiKit.Text(Loc.T("Drop audio or video files here"), 16, FontWeights.SemiBold).Center().Margin(0, 10, 0, 4),
            UiKit.Caption("MP3, M4A, WAV, FLAC, AAC, WMA, MP4, MOV").Center(),
            UiKit.Button(Loc.T("Choose Files…"), ChooseFiles, Icons.Folder, accent: true).Center().Margin(0, 12, 0, 0));
        dropContent.VerticalAlignment = VerticalAlignment.Center;
        drop.Child = dropContent;
        drop.DragOver += (_, e) =>
        {
            e.Effects = e.Data.GetDataPresent(DataFormats.FileDrop) ? DragDropEffects.Copy : DragDropEffects.None;
            e.Handled = true;
        };
        drop.Drop += (_, e) =>
        {
            if (e.Data.GetData(DataFormats.FileDrop) is string[] files) Enqueue(files);
        };

        var models = TranscriptionModelRegistry.All(_host.Library.CustomTranscriptionModels).Where(_host.IsUsable).Select(m => (m.Name, m.DisplayName)).ToList();
        if (models.Count > 0 && !models.Any(m => m.Name == _modelName)) _modelName = models[0].Name;
        var model = TranscriptionModelRegistry.Find(_modelName, _host.Library.CustomTranscriptionModels);
        var langs = (model?.SupportedLanguages ?? Languages.All).Keys.Select(k => (k, k == "auto" ? Loc.T("Auto-detect") : Languages.DisplayName(k))).OrderBy(x => x.k == "auto" ? "" : x.Item2);

        var speakersRow = UiKit.HStack(
            UiKit.Combo([(0, Loc.T("Automatic")), .. Enumerable.Range(2, 9).Select(n => (n, Loc.F("{0} speakers", n)))], _speakerCount, v => _speakerCount = v, 160));
        var diarizationReady = Diarizer.IsDownloaded;
        var options = UiKit.Card(Loc.T("Options"),
            UiKit.Row(Loc.T("Model"), models.Count == 0 ? UiKit.Text(Loc.T("Download a model first"), 13, secondary: true) : UiKit.Combo(models, _modelName, v => { _modelName = v; Render(); }, 280)),
            UiKit.Row(Loc.T("Language"), UiKit.Combo(langs, model?.SupportsLanguage(_language) == true ? _language : "auto", v => _language = v, 280)),
            UiKit.Row(Loc.T("Identify speakers"), ToggleFor(_identifySpeakers, v => _identifySpeakers = v),
                diarizationReady ? Loc.T("Labels who said what (runs on this PC).") : Loc.F("Needs the speaker models ({0}).", ModelDownloads.Format(Diarizer.DownloadSize))),
            UiKit.Row(Loc.T("Speakers"), speakersRow));
        if (!diarizationReady)
        {
            var active = _host.Downloads.Get("diarization");
            if (active != null)
            {
                var bar = new ProgressBar { Height = 6, Maximum = 1, Margin = new Thickness(0, 6, 0, 0) };
                bar.SetBinding(System.Windows.Controls.Primitives.RangeBase.ValueProperty, new Binding(nameof(active.Progress)) { Source = active });
                ((StackPanel)options.Child).Children.Add(bar);
            }
            else
            {
                ((StackPanel)options.Child).Children.Add(UiKit.HStack(UiKit.Button(Loc.T("Download Speaker Models"), () =>
                    _host.Downloads.Start("diarization", Diarizer.Downloads, () => { _host.Ui.Toast(Loc.T("Speaker identification is ready"), ToastKind.Success); Render(); }),
                    Icons.Download)));
            }
        }

        Content = UiKit.Page(Loc.T("Transcribe File"), Loc.T("Turn recordings, meetings and videos into a transcript with each speaker identified. Export to TXT, Markdown, SRT, WebVTT or JSON."),
            drop, options, UiKit.Text(Loc.T("Queue"), 16, FontWeights.SemiBold).Margin(0, 6, 0, 8), _queue);
        RenderQueue();
    }

    private static CheckBox ToggleFor(bool value, Action<bool> set)
    {
        var cb = new CheckBox { IsChecked = value, MinWidth = 0 };
        cb.Click += (_, _) => set(cb.IsChecked == true);
        return cb;
    }

    private void ChooseFiles()
    {
        var dialog = new OpenFileDialog
        {
            Multiselect = true,
            Filter = Loc.T("Audio or Video File") + "|" + string.Join(";", FileTranscriptionService.SupportedExtensions.Select(e => "*" + e)) + "|" + Loc.T("All files") + "|*.*",
        };
        if (dialog.ShowDialog() == true) Enqueue(dialog.FileNames);
    }

    private void Enqueue(IEnumerable<string> files)
    {
        if (string.IsNullOrEmpty(_modelName))
        {
            _host.Ui.Toast(Loc.T("No transcription model is ready. Download a model or add an API key first."), ToastKind.Error);
            return;
        }
        foreach (var f in files)
        {
            if (!FileTranscriptionService.SupportedExtensions.Contains(Path.GetExtension(f).ToLowerInvariant()))
            {
                _host.Ui.Toast(Loc.F("{0} is not a supported audio or video file", Path.GetFileName(f)), ToastKind.Warning);
                continue;
            }
            _host.FileTranscription.Enqueue(f, _modelName, _identifySpeakers, _speakerCount == 0 ? null : _speakerCount, _language == "auto" ? null : _language);
        }
    }

    private void RenderQueue()
    {
        _queue.Children.Clear();
        var jobs = _host.FileTranscription.Jobs;
        if (jobs.Count == 0)
        {
            _queue.Children.Add(UiKit.Caption(Loc.T("No files yet.")));
            return;
        }
        foreach (var job in jobs) _queue.Children.Add(JobRow(job));
    }

    private UIElement JobRow(FileTranscriptionJob job)
    {
        var status = new TextBlock { FontSize = 12, Opacity = 0.75, TextWrapping = TextWrapping.Wrap };
        var bar = new ProgressBar { Height = 6, Maximum = 1, Margin = new Thickness(0, 6, 0, 0) };
        var actions = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        void Update()
        {
            status.Text = job.Status switch
            {
                FileJobStatus.Queued => Loc.T("Waiting…"),
                FileJobStatus.Converting => Loc.T("Preparing audio…"),
                FileJobStatus.Diarizing => Loc.T("Identifying speakers…"),
                FileJobStatus.Transcribing => Loc.F("Transcribing… {0:P0}", job.Progress),
                FileJobStatus.Completed => Loc.T("Done") + (job.Warning != null ? " — " + Loc.T(job.Warning) : ""),
                FileJobStatus.Failed => Loc.T("Failed") + ": " + job.Error,
                _ => Loc.T("Cancelled"),
            };
            bar.Value = job.Progress;
            bar.Visibility = job.IsActive ? Visibility.Visible : Visibility.Collapsed;
            actions.Children.Clear();
            if (job.IsActive) actions.Children.Add(UiKit.Button(Loc.T("Cancel"), () => _host.FileTranscription.Cancel(job)));
            if (job.Status == FileJobStatus.Completed && job.Transcript != null)
                actions.Children.Add(UiKit.Button(Loc.T("View Transcript"), () => new FileTranscriptWindow(job.TranscriptionId!.Value, job.Transcript).Show(), Icons.File, accent: true));
            if (job.Status is FileJobStatus.Failed or FileJobStatus.Cancelled)
                actions.Children.Add(UiKit.Button(Loc.T("Retry"), () => _host.FileTranscription.Retry(job), Icons.Retry));
        }
        Update();
        PropertyChangedEventHandler handler = (_, _) => Dispatcher.BeginInvoke(Update);
        job.PropertyChanged += handler;
        Unloaded += (_, _) => job.PropertyChanged -= handler;

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(UiKit.VStack(UiKit.Text(job.FileName, 14, FontWeights.SemiBold), status, bar));
        Grid.SetColumn(actions, 1);
        grid.Children.Add(actions);
        return new Border { Child = grid }.Style("Card");
    }
}

/// <summary>Transcript viewer: speaker renaming, paragraphs with timestamps, export (FileTranscriptView.swift).</summary>
public sealed class FileTranscriptWindow : Window
{
    private readonly Guid _recordId;
    private readonly FileTranscript _transcript;
    private readonly StackPanel _body = new();

    public FileTranscriptWindow(Guid recordId, FileTranscript transcript)
    {
        _recordId = recordId;
        _transcript = transcript;
        Title = transcript.SourceFileName;
        Width = 820;
        Height = 760;
        FlowDirection = Loc.Direction;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Render();
    }

    private void Render()
    {
        var t = _transcript;
        var speakers = UiKit.Wrap();
        foreach (var i in t.Speakers)
        {
            var box = new TextBox { Text = t.Name(i), Width = 160, Margin = new Thickness(0, 0, 10, 8) };
            var index = i;
            void Commit()
            {
                if (box.Text.Trim() == t.Name(index)) return;
                t.Rename(index, box.Text);
                AppHost.Current.FileTranscription.SaveTranscript(_recordId, t);
                RenderBody();
            }
            box.LostFocus += (_, _) => Commit();
            box.KeyDown += (_, e) => { if (e.Key == System.Windows.Input.Key.Enter) Commit(); };
            speakers.Children.Add(box);
        }

        var export = UiKit.Wrap();
        foreach (var f in Enum.GetValues<ExportFormat>())
        {
            var format = f;
            export.Children.Add(UiKit.Button(FileTranscriptExporter.Extension(f).ToUpperInvariant(), () => Export(format), Icons.Export));
        }
        export.Children.Add(UiKit.Button(Loc.T("Copy"), () =>
        {
            Platform.ClipboardService.SetText(FileTranscriptExporter.Export(t, ExportFormat.Text), false);
            AppHost.Current.Ui.Toast(Loc.T("Copied to clipboard"), ToastKind.Success);
        }, Icons.Copy));

        var header = UiKit.VStack(
            UiKit.Text(t.SourceFileName, 20, FontWeights.SemiBold),
            UiKit.Caption($"{t.Timestamp(t.Duration)} · {t.ModelName} · {Loc.F("{0} speakers", t.Speakers.Count())}").Margin(0, 2, 0, 12));
        if (t.Speakers.Any()) header.Children.Add(UiKit.Card(Loc.T("Speakers"), Loc.T("Rename a speaker and press Enter."), speakers));
        header.Children.Add(UiKit.Card(Loc.T("Export"), export));
        RenderBody();
        var root = new StackPanel { Margin = new Thickness(24) };
        root.Children.Add(header);
        root.Children.Add(_body);
        Content = new ScrollViewer { Content = root, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    }

    private void RenderBody()
    {
        _body.Children.Clear();
        foreach (var p in _transcript.Paragraphs)
        {
            var rtl = BidiText.IsRtl(p.Text.FirstOrDefault(char.IsLetter));
            var stamp = new TextBlock { Text = _transcript.Timestamp(p.Start), FlowDirection = FlowDirection.LeftToRight, Opacity = 0.6, FontSize = 12, Margin = new Thickness(0, 0, 10, 0) };
            var head = UiKit.HStack(stamp);
            if (p.SpeakerIndex is { } i) head.Children.Add(UiKit.Text(_transcript.Name(i), 13, FontWeights.SemiBold));
            _body.Children.Add(head.Margin(0, 10, 0, 2));
            _body.Children.Add(new TextBox
            {
                Text = p.Text, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, BorderThickness = new Thickness(0), Background = Brushes.Transparent,
                FlowDirection = rtl ? FlowDirection.RightToLeft : FlowDirection.LeftToRight, FontSize = 14,
            });
        }
    }

    private void Export(ExportFormat format)
    {
        var dialog = new SaveFileDialog
        {
            FileName = FileTranscriptExporter.DefaultFileName(_transcript, format),
            Filter = $"{format}|*.{FileTranscriptExporter.Extension(format)}",
        };
        if (dialog.ShowDialog(this) != true) return;
        File.WriteAllText(dialog.FileName, FileTranscriptExporter.Export(_transcript, format), new System.Text.UTF8Encoding(false));
        AppHost.Current.Ui.Toast(Loc.T("Exported"), ToastKind.Success);
    }
}
