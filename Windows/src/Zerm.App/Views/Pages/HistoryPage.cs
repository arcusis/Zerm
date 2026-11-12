using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Microsoft.Win32;
using NAudio.Wave;
using Zerm.App.Localization;
using Zerm.App.Platform;
using Zerm.Core.Data;
using Zerm.Core.Dictation;
using Zerm.Core.FileTranscription;

namespace Zerm.App.Views.Pages;

/// <summary>Port of InlineHistoryView.swift.</summary>
public sealed class HistoryPage : ContentControl
{
    private const int PageSize = 20;
    private readonly AppHost _host = AppHost.Current;
    private readonly StackPanel _list = new();
    private readonly TextBox _search = new() { MinWidth = 280 };
    private readonly TextBlock _count = new() { VerticalAlignment = VerticalAlignment.Center, Opacity = 0.7 };
    private readonly HashSet<Guid> _selected = [];
    private readonly Border _selectionBar;
    private readonly TextBlock _selectionText = new() { VerticalAlignment = VerticalAlignment.Center, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 16, 0) };
    private readonly Button _loadMore;
    private bool _newestFirst = true;
    private bool _audioOnly;
    private int _loaded;
    private WaveOut? _player;
    private System.Windows.Threading.DispatcherTimer? _debounce;

    public HistoryPage()
    {
        _search.SetValue(System.Windows.Controls.Primitives.TextBoxBase.AcceptsReturnProperty, false);
        _search.ToolTip = Loc.T("Search transcriptions...");
        _search.TextChanged += (_, _) =>
        {
            _debounce?.Stop();
            _debounce = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(250) };
            _debounce.Tick += (_, _) => { _debounce.Stop(); Reload(); };
            _debounce.Start();
        };
        var sort = UiKit.Combo([(true, Loc.T("Newest First")), (false, Loc.T("Oldest First"))], true, v => { _newestFirst = v; Reload(); }, 150);
        var filter = UiKit.Combo([(false, Loc.T("All Dictations")), (true, Loc.T("With Audio"))], false, v => { _audioOnly = v; Reload(); }, 150);
        var toolbar = UiKit.Wrap(UiKit.Glyph(Icons.Search, 14).Margin(0, 0, 8, 0), _search, sort.Margin(8, 0, 0, 0), filter.Margin(8, 0, 0, 0), _count.Margin(12, 0, 0, 0));
        toolbar.Margin = new Thickness(0, 0, 0, 12);

        _selectionBar = new Border
        {
            Visibility = Visibility.Collapsed,
            Child = UiKit.Wrap(_selectionText,
                UiKit.Button(Loc.T("Export"), ExportSelected, Icons.Export),
                UiKit.Button(Loc.T("Delete"), DeleteSelected, Icons.Delete),
                UiKit.Button(Loc.T("Select All"), SelectAll),
                UiKit.Button(Loc.T("Deselect All"), () => { _selected.Clear(); Reload(); })),
        }.Style("Card");

        _loadMore = UiKit.Button(Loc.T("Load More"), LoadMore);
        _loadMore.HorizontalAlignment = HorizontalAlignment.Center;

        Content = UiKit.Page(Loc.T("Dictation History"), Loc.T("Every dictation is saved here with its audio, so you can copy, retry, or re-enhance it."),
            toolbar, _selectionBar, _list, _loadMore);
        Reload();
        _host.History.Changed += OnChanged;
        Unloaded += (_, _) =>
        {
            _host.History.Changed -= OnChanged;
            _player?.Dispose();
        };
    }

    private void OnChanged() => Dispatcher.BeginInvoke(() =>
    {
        // Refresh the visible window without losing the user's scroll/paging.
        var keep = Math.Max(_loaded, PageSize);
        _list.Children.Clear();
        _loaded = 0;
        Append(keep);
    });

    private void Reload()
    {
        _list.Children.Clear();
        _loaded = 0;
        Append(PageSize);
    }

    private void LoadMore() => Append(PageSize);

    private void Append(int count)
    {
        var rows = _host.History.Query(_search.Text, _newestFirst, _audioOnly, count, _loaded);
        foreach (var r in rows) _list.Children.Add(Row(r));
        _loaded += rows.Count;
        var total = _host.History.Count(_search.Text, _audioOnly);
        _count.Text = Loc.F("{0} results", total);
        _loadMore.Visibility = _loaded < total ? Visibility.Visible : Visibility.Collapsed;
        if (total == 0)
            _list.Children.Add(UiKit.Card(null, UiKit.Text(string.IsNullOrWhiteSpace(_search.Text) ? Loc.T("No transcriptions yet. Press your shortcut to start dictating.") : Loc.T("No Results"), 14, secondary: true)));
        UpdateSelectionBar();
    }

    private UIElement Row(TranscriptionRecord r)
    {
        var check = new CheckBox { IsChecked = _selected.Contains(r.Id), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 4, 0), MinWidth = 0 };
        check.Checked += (_, _) => { _selected.Add(r.Id); UpdateSelectionBar(); };
        check.Unchecked += (_, _) => { _selected.Remove(r.Id); UpdateSelectionBar(); };

        var header = new DockPanel();
        var copy = UiKit.IconButton(Icons.Copy, Loc.T("Copy"), () => Copy(r.DisplayText));
        DockPanel.SetDock(check, Dock.Left);
        DockPanel.SetDock(copy, Dock.Right);
        header.Children.Add(check);
        header.Children.Add(copy);
        var meta = UiKit.HStack(UiKit.Text(r.Timestamp.ToString("g"), 12, secondary: true));
        if (r.Status == TranscriptionStatus.Failed) meta.Children.Add(UiKit.Pill(Loc.T("Failed"), Color.FromRgb(0xFF, 0x45, 0x3A)).Margin(8, 0, 0, 0));
        if (r.HasEnhancement) meta.Children.Add(UiKit.Pill(Loc.T("Enhanced"), Color.FromRgb(0x0A, 0x84, 0xFF)).Margin(8, 0, 0, 0));
        if (r.SegmentsJson != null) meta.Children.Add(UiKit.Pill(Loc.T("File"), Color.FromRgb(0x8E, 0x8E, 0x93)).Margin(8, 0, 0, 0));
        if (r.PowerModeName != null) meta.Children.Add(UiKit.Text($"{r.PowerModeEmoji} {r.PowerModeName}", 12, secondary: true).Margin(8, 0, 0, 0));
        var preview = new TextBlock
        {
            Text = r.DisplayText, TextWrapping = TextWrapping.Wrap, MaxHeight = 40, TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(0, 4, 0, 0),
            FlowDirection = UiKit.DirectionOf(r.DisplayText), TextAlignment = Loc.IsHebrew == (UiKit.DirectionOf(r.DisplayText) == FlowDirection.RightToLeft) ? TextAlignment.Left : TextAlignment.Right,
        };
        header.Children.Add(UiKit.VStack(meta, preview));

        var expander = new Expander { Header = header, Margin = new Thickness(0, 0, 0, 8), HorizontalContentAlignment = HorizontalAlignment.Stretch };
        expander.Expanded += (_, _) => expander.Content ??= Details(r);
        return expander;
    }

    private UIElement Details(TranscriptionRecord r)
    {
        var stack = new StackPanel { Margin = new Thickness(28, 8, 8, 8) };
        if (r.HasEnhancement)
        {
            var tabs = new TabControl { Margin = new Thickness(0, 0, 0, 8) };
            tabs.Items.Add(new TabItem { Header = Loc.T("Enhanced"), Content = TextBoxFor(r.EnhancedText!) });
            tabs.Items.Add(new TabItem { Header = Loc.T("Original"), Content = TextBoxFor(r.Text) });
            tabs.Items.Add(new TabItem { Header = Loc.T("Changes"), Content = DiffView.Build(r).Margin(4, 8, 4, 4) });
            stack.Children.Add(tabs);
        }
        else
        {
            stack.Children.Add(TextBoxFor(r.Text));
        }

        var actions = UiKit.Wrap(UiKit.Button(Loc.T("Copy"), () => Copy(r.DisplayText), Icons.Copy));
        if (r.HasEnhancement) actions.Children.Add(UiKit.Button(Loc.T("Copy Original"), () => Copy(r.Text), Icons.Copy));
        if (r.HasAudio)
        {
            actions.Children.Add(UiKit.Button(Loc.T("Play Audio"), () => Play(r.AudioFilePath!), Icons.Play));
            actions.Children.Add(UiKit.Button(Loc.T("Retry Transcription"), () => _ = _host.Dictation.RetryLastAsync(r), Icons.Retry));
        }
        if (r.Status == TranscriptionStatus.Completed && r.SegmentsJson == null)
            actions.Children.Add(UiKit.Button(Loc.T("Enhance"), () => _ = ReEnhance(r), Icons.Wand));
        if (FileTranscript.FromJson(r.SegmentsJson) is { } transcript)
            actions.Children.Add(UiKit.Button(Loc.T("Open File Transcript"), () => new FileTranscriptWindow(r.Id, transcript).Show(), Icons.File));
        actions.Children.Add(UiKit.Button(Loc.T("Delete"), () =>
        {
            if (UiKit.Confirm(Loc.T("Delete this transcription?"))) _host.History.Delete([r.Id]);
        }, Icons.Delete));
        stack.Children.Add(actions);

        var details = new List<string>();
        if (r.TranscriptionModelName != null) details.Add($"{Loc.T("Model")}: {r.TranscriptionModelName}");
        if (r.Duration > 0) details.Add($"{Loc.T("Audio")}: {r.Duration:F1}s");
        if (r.TranscriptionDuration is { } td) details.Add($"{Loc.T("Transcription")}: {td:F2}s");
        if (r.AiEnhancementModelName != null) details.Add($"{Loc.T("AI")}: {r.AiEnhancementModelName}");
        if (r.PromptName != null) details.Add($"{Loc.T("Prompt")}: {Loc.T(r.PromptName)}");
        if (r.EnhancementDuration is { } ed) details.Add($"{Loc.T("Enhancement")}: {ed:F2}s");
        if (r.EnhancementOutcome != null && r.EnhancementOutcome != "Enhanced")
            details.Add($"{Loc.T("Enhancement")}: {r.EnhancementOutcome}{(r.EnhancementOutcomeReason != null ? $" ({r.EnhancementOutcomeReason})" : "")}");
        stack.Children.Add(UiKit.Caption(string.Join("   ·   ", details)).Margin(0, 8, 0, 0));
        return stack;
    }

    private static TextBox TextBoxFor(string text) => new()
    {
        Text = text, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 350,
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto, BorderThickness = new Thickness(0),
        FlowDirection = UiKit.DirectionOf(text),
    };

    private async Task ReEnhance(TranscriptionRecord r)
    {
        _host.Ui.Toast(Loc.T("Enhancing…"), ToastKind.Info);
        var outcome = await Task.Run(() => _host.Pipeline.ReEnhanceAsync(r, null, CancellationToken.None));
        if (outcome.Kind == Core.Enhancement.EnhancementOutcomeKind.Enhanced) _host.Ui.Toast(Loc.T("Enhanced"), ToastKind.Success);
    }

    private void Play(string path)
    {
        _player?.Dispose();
        var reader = new AudioFileReader(path);
        _player = new WaveOut();
        _player.Init(reader);
        _player.PlaybackStopped += (_, _) => reader.Dispose();
        _player.Play();
    }

    private void Copy(string text)
    {
        ClipboardService.SetText(text, false);
        _host.Ui.Toast(Loc.T("Copied to clipboard"), ToastKind.Success, TimeSpan.FromSeconds(1.5));
    }

    private void UpdateSelectionBar()
    {
        _selectionBar.Visibility = _selected.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        _selectionText.Text = Loc.F("{0} selected", _selected.Count);
    }

    private void SelectAll()
    {
        foreach (var r in _host.History.Query(_search.Text, _newestFirst, _audioOnly, 100_000)) _selected.Add(r.Id);
        Reload();
    }

    private void DeleteSelected()
    {
        if (!UiKit.Confirm(Loc.F("Delete {0} selected items? This cannot be undone.", _selected.Count))) return;
        _host.History.Delete(_selected.ToList());
        _selected.Clear();
        Reload();
    }

    private void ExportSelected()
    {
        var dialog = new SaveFileDialog { FileName = "Zerm History.csv", Filter = "CSV|*.csv" };
        if (dialog.ShowDialog() != true) return;
        var records = _selected.Select(_host.History.Get).Where(r => r != null).OrderBy(r => r!.Timestamp);
        var sb = new StringBuilder("Timestamp,Original,Enhanced,Model,Prompt,Duration\n");
        static string Csv(string? s) => "\"" + (s ?? "").Replace("\"", "\"\"") + "\"";
        foreach (var r in records)
            sb.AppendLine(string.Join(",", Csv(r!.Timestamp.ToString("s")), Csv(r.Text), Csv(r.EnhancedText), Csv(r.TranscriptionModelName), Csv(r.PromptName), r.Duration.ToString("F1", System.Globalization.CultureInfo.InvariantCulture)));
        File.WriteAllText(dialog.FileName, sb.ToString(), new UTF8Encoding(true));
        _host.Ui.Toast(Loc.T("Exported"), ToastKind.Success);
    }
}
