using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;
using Zerm.App.Localization;
using Zerm.App.Platform;
using Zerm.Core.Dictation;
using Zerm.Core.LocalLlm;
using Zerm.Core.Settings;
using Zerm.Core.TextToSpeech;

namespace Zerm.App.Views.Pages;

/// <summary>Port of ReadAloudSpeakView.swift.</summary>
public sealed class SpeakPage : ContentControl
{
    private readonly AppHost _host = AppHost.Current;

    public SpeakPage()
    {
        Render();
        _host.ReadAloud.Changed += Rerender;
        Unloaded += (_, _) => _host.ReadAloud.Changed -= Rerender;
    }

    private void Rerender() => Dispatcher.BeginInvoke(Render);

    private void Render()
    {
        var s = _host.Settings;
        var modes = UiKit.Wrap();
        foreach (var m in Enum.GetValues<ReadAloudMode>())
        {
            var rb = new RadioButton { Content = Loc.T(TtsNaturalizer.Title(m)), GroupName = "readmode", IsChecked = s.TtsReadingMode == m, Margin = new Thickness(0, 0, 16, 0) };
            var mode = m;
            rb.Checked += (_, _) => { s.TtsReadingMode = mode; Render(); };
            modes.Children.Add(rb);
        }
        var aiMode = s.TtsReadingMode != ReadAloudMode.Exact;
        var model = LocalLlmCatalog.ResolveForReading(s.ModelFor("Reading"));
        var modeCard = UiKit.Card(Loc.T("Reading mode"), modes, UiKit.Caption(Loc.T(TtsNaturalizer.Subtitle(s.TtsReadingMode))).Margin(0, 6, 0, 0));
        if (aiMode)
        {
            var line = model != null
                ? UiKit.Caption(Loc.F("Local AI model: {0}", model.DisplayName))
                : UiKit.Caption(Loc.F("Download a model in Models & Voices before using {0}.", Loc.T(TtsNaturalizer.Title(s.TtsReadingMode))));
            if (model == null) line.Foreground = new SolidColorBrush(Color.FromRgb(0xFF, 0x9F, 0x0A));
            ((StackPanel)modeCard.Child).Children.Add(line.Margin(0, 6, 0, 0));
        }

        var input = new TextBox
        {
            AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, Height = 160, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Text = Loc.T("Select text in any app and press your Read Aloud shortcut — or paste text here."),
        };
        input.GotFocus += (_, _) => { if (input.Text == Loc.T("Select text in any app and press your Read Aloud shortcut — or paste text here.")) input.Text = ""; };
        var button = _host.ReadAloud.IsActive
            ? UiKit.Button(Loc.T("Stop Read Aloud"), () => _host.ReadAloud.Stop(), Icons.Stop, accent: true)
            : UiKit.Button(Loc.T("Read This Text"), () =>
            {
                if (!string.IsNullOrWhiteSpace(input.Text)) _ = _host.ReadAloud.SpeakTextAsync(input.Text);
            }, Icons.Speaker, accent: true);
        button.IsEnabled = _host.ReadAloud.IsActive || !aiMode || model != null || true;
        var shortcut = HotkeyService.Describe(s.ReadAloudHotkey, s.ReadAloudCustom);
        var speak = UiKit.Card(Loc.T("Speak"), Loc.F("Shortcut: {0}. Press it again (or Esc) to stop.", shortcut), input.Margin(0, 0, 0, 10), button);

        var children = new List<UIElement> { modeCard, speak };
        if (_host.ReadAloud.LastPrepared is { } last)
            children.Add(UiKit.Card(Loc.T("Last Prepared Version"), new TextBox { Text = last, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, BorderThickness = new Thickness(0), MaxHeight = 240, VerticalScrollBarVisibility = ScrollBarVisibility.Auto }));
        Content = UiKit.Page(Loc.T("Speak Selected Content"), Loc.T("Zerm reads text aloud in a natural voice — exactly as written, or retold, summarized, explained or simplified by the on-device AI."), [.. children]);
    }
}

/// <summary>Port of ReadAloudHistoryView.swift.</summary>
public sealed class ReadAloudHistoryPage : ContentControl
{
    private readonly AppHost _host = AppHost.Current;
    private readonly TextBox _search = new() { MinWidth = 160, VerticalAlignment = VerticalAlignment.Center, ToolTip = Loc.T("Search source or spoken text") };
    private readonly StackPanel _list = new();
    private string _mode = "";
    private bool _newest = true;

    public ReadAloudHistoryPage()
    {
        _search.TextChanged += (_, _) => RenderList();
        var sort = UiKit.Combo([(true, Loc.T("Newest First")), (false, Loc.T("Oldest First"))], true, v => { _newest = v; RenderList(); }, 150);
        var filter = UiKit.Combo(new[] { ("", Loc.T("All Modes")) }.Concat(Enum.GetValues<ReadAloudMode>().Select(m => (m.ToString(), Loc.T(TtsNaturalizer.Title(m))))),
            "", v => { _mode = v; RenderList(); }, 160);
        var clear = UiKit.Button(Loc.T("Clear History"), () =>
        {
            if (UiKit.Confirm(Loc.T("Clear all Read Aloud history?"))) { _host.History.DeleteReadAloud(); RenderList(); }
        }, Icons.Delete);
        Content = UiKit.Page(Loc.T("Read Aloud History"), null,
            Toolbar(UiKit.Glyph(Icons.Search, 14).Margin(0, 0, 8, 0), _search, sort.Margin(8, 0, 0, 0), filter.Margin(8, 0, 0, 0), clear.Margin(8, 0, 0, 0)).Margin(0, 0, 0, 12),
            _list);
        RenderList();
    }

    // Single-row toolbar: the search box (index 1) stretches, everything else keeps its natural size,
    // so Clear History stays aligned on the right instead of wrapping under the search icon.
    private static Grid Toolbar(params FrameworkElement[] items)
    {
        var grid = new Grid();
        for (var i = 0; i < items.Length; i++)
        {
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = i == 1 ? new GridLength(1, GridUnitType.Star) : GridLength.Auto });
            items[i].VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(items[i], i);
            grid.Children.Add(items[i]);
        }
        return grid;
    }

    private void RenderList()
    {
        _list.Children.Clear();
        var q = _search.Text.Trim();
        var items = _host.History.ReadAloudHistory()
            .Where(e => _mode == "" || e.Mode == _mode)
            .Where(e => q.Length == 0 || e.SourceText.Contains(q, StringComparison.CurrentCultureIgnoreCase) || e.SpokenText.Contains(q, StringComparison.CurrentCultureIgnoreCase)
                        || Loc.T(e.Mode).Contains(q, StringComparison.CurrentCultureIgnoreCase))
            .ToList();
        if (!_newest) items.Reverse();
        if (items.Count == 0)
        {
            _list.Children.Add(UiKit.Card(null, UiKit.Text(Loc.T("No Read Aloud History"), 15, FontWeights.SemiBold),
                UiKit.Caption(Loc.T("Select text anywhere and press your Read Aloud shortcut."))));
            return;
        }
        foreach (var e in items)
        {
            var entry = e;
            var mode = Enum.TryParse<ReadAloudMode>(e.Mode, out var m) ? Loc.T(TtsNaturalizer.Title(m)) : e.Mode;
            var body = UiKit.VStack(
                UiKit.HStack(UiKit.Text(mode, 13, FontWeights.SemiBold), UiKit.Caption("  ·  " + e.Timestamp.ToString("g")).VCenter()),
                new TextBlock { Text = e.SpokenText, TextWrapping = TextWrapping.Wrap, MaxHeight = 40, TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(0, 4, 0, 2), FlowDirection = UiKit.DirectionOf(e.SpokenText) },
                UiKit.Caption(Loc.T("Source") + ": " + e.SourceText.ReplaceLineEndings(" ")),
                UiKit.Caption(string.Join(" • ", new[] { e.Provider, e.Voice, e.Model }.Where(x => !string.IsNullOrEmpty(x)))));
            var actions = UiKit.HStack(
                UiKit.IconButton(Icons.Play, Loc.T("Read again"), () => _ = _host.ReadAloud.SpeakTextAsync(entry.SpokenText)),
                UiKit.IconButton(Icons.Copy, Loc.T("Copy"), () => ClipboardService.SetText(entry.SpokenText, false)),
                UiKit.IconButton(Icons.Delete, Loc.T("Delete"), () => { _host.History.DeleteReadAloud(entry.Id); RenderList(); }));
            var grid = new Grid();
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.Children.Add(body);
            Grid.SetColumn(actions, 1);
            grid.Children.Add(actions);
            _list.Children.Add(new Border { Child = grid }.Style("Card"));
        }
    }
}

/// <summary>Port of TextToSpeechSettingsView.swift (Models &amp; Voices).</summary>
public sealed class VoicesPage : ContentControl
{
    private readonly AppHost _host = AppHost.Current;

    public VoicesPage()
    {
        Render();
        _host.Downloads.Changed += Rerender;
        Unloaded += (_, _) => _host.Downloads.Changed -= Rerender;
    }

    private void Rerender() => Dispatcher.BeginInvoke(Render);

    public static IEnumerable<(TriggerKey, string)> TriggerChoices(KeyCombo custom) =>
        Enum.GetValues<TriggerKey>().Select(k => (k, k == TriggerKey.Custom ? Loc.T("Custom shortcut") : Loc.T(HotkeyService.Describe(k, custom))));

    private void Render()
    {
        var s = _host.Settings;
        var provider = _host.ReadAloud.Provider(s.TtsProvider);
        var voices = provider.Voices;
        var voice = UiKit.Combo(voices.Select(v => (v.Id, v.ToString())), _host.ReadAloud.VoiceFor(provider), v => s.SetTtsVoice(provider.Name, v), 320);
        var trigger = UiKit.Combo(TriggerChoices(s.ReadAloudCustom), s.ReadAloudHotkey, v => { s.ReadAloudHotkey = v; Render(); }, 240);
        var main = UiKit.Card(Loc.T("Read Aloud"),
            UiKit.Row(Loc.T("Enable Read Aloud"), UiKit.Toggle(s, nameof(s.TtsEnabled))),
            UiKit.Row(Loc.T("Trigger key"), trigger, s.ReadAloudHotkey == s.Hotkey1 && s.ReadAloudHotkey != TriggerKey.Custom
                ? Loc.T("This key is also your dictation hotkey — pick a different one to avoid both firing.") : null));
        if (s.ReadAloudHotkey == TriggerKey.Custom)
            ((StackPanel)main.Child).Children.Add(UiKit.Row(Loc.T("Shortcut"), new ShortcutRecorder(s.ReadAloudCustom, c => s.ReadAloudCustom = c ?? KeyCombo.Empty, false)));
        ((StackPanel)main.Child).Children.Add(UiKit.Row(Loc.T("Voice provider"), UiKit.Combo(TtsProviders.Names.Select(n => (n, n == "Windows" ? Loc.T("Windows voices (offline)") : n == "Kokoro" ? Loc.T("Kokoro (on-device)") : n)), s.TtsProvider, v => { s.TtsProvider = v; Render(); })));
        ((StackPanel)main.Child).Children.Add(UiKit.Row(Loc.T("Voice"), voices.Count > 0 ? voice : UiKit.Caption(Loc.T("No voices available"))));
        ((StackPanel)main.Child).Children.Add(UiKit.Row(Loc.T("Speed"), UiKit.SliderWithValue(s, nameof(s.TtsSpeed), 0.5, 2.0, 0.05, "{0:F2}×")));
        ((StackPanel)main.Child).Children.Add(UiKit.Button(Loc.T("Preview voice"), () => _ = _host.ReadAloud.PreviewAsync(s.TtsProvider), Icons.Play));

        var cards = new List<UIElement> { main };
        if (provider.Name == "Kokoro") cards.Add(KokoroCard());
        if (provider.Name == "Windows")
            cards.Add(UiKit.Card(null, UiKit.Caption(Loc.T("Windows voices work offline. To read Hebrew or other languages, add a voice in Windows Settings › Time & language › Speech › Manage voices.")),
                UiKit.Button(Loc.T("Open Speech Settings"), () => DictationController.OpenUri("ms-settings:speech")).Margin(0, 8, 0, 0)));
        if (provider.RequiresApiKey) cards.Add(KeyCard(provider.Name));

        var modes = UiKit.Combo(Enum.GetValues<ReadAloudMode>().Select(m => (m, Loc.T(TtsNaturalizer.Title(m)))), s.TtsReadingMode, v => { s.TtsReadingMode = v; Render(); }, 220);
        var smart = UiKit.Card(Loc.T("Smart reading"),
            UiKit.Row(Loc.T("Smart text cleanup"), UiKit.Toggle(s, nameof(s.TtsSmartCleanup)), Loc.T("Instantly reads acronyms, URLs, file paths, code, and symbols the way a person would — offline, no delay.")),
            UiKit.Row(Loc.T("Reading mode"), modes, Loc.T(TtsNaturalizer.Subtitle(s.TtsReadingMode))),
            UiKit.Text(Loc.T("On-device reading models"), 13, FontWeights.SemiBold).Margin(0, 10, 0, 0));
        var selected = LocalLlmCatalog.ResolveForReading(s.ModelFor("Reading"))?.Id ?? s.ModelFor("Reading") ?? LocalLlmCatalog.DefaultId;
        foreach (var p in LocalLlmCatalog.Packages.Where(p => p.ForReading))
            ((StackPanel)smart.Child).Children.Add(EnhancementPage.LlmRow(p, selected == p.Id, () => { s.SetModelFor("Reading", p.Id); Render(); }));
        cards.Add(smart);

        Content = UiKit.Page(Loc.T("Models & Voices"), Loc.T("Choose the voice, speed and reading style for Read Aloud."), [.. cards]);
    }

    private UIElement KokoroCard()
    {
        var stack = new StackPanel();
        if (KokoroProvider.IsDownloaded)
        {
            stack.Children.Add(UiKit.Text("✓ " + Loc.T("Downloaded — runs fully offline"), 13));
            stack.Children.Add(UiKit.Button(Loc.T("Delete"), () =>
            {
                if (!UiKit.Confirm(Loc.T("Delete the Kokoro voice model?"))) return;
                try { Directory.Delete(KokoroProvider.ModelDir, true); } catch (Exception ex) { _host.Ui.Toast(ex.Message, ToastKind.Error); }
                Render();
            }, Icons.Delete).Margin(0, 8, 0, 0));
        }
        else if (_host.Downloads.Get("kokoro") is { } active)
        {
            var bar = new ProgressBar { Height = 6, Maximum = 1 };
            bar.SetBinding(System.Windows.Controls.Primitives.RangeBase.ValueProperty, new Binding(nameof(active.Progress)) { Source = active });
            var status = new TextBlock { FontSize = 12, Opacity = 0.7 };
            status.SetBinding(TextBlock.TextProperty, new Binding(nameof(active.Status)) { Source = active });
            stack.Children.Add(bar);
            stack.Children.Add(status);
            stack.Children.Add(UiKit.Button(Loc.T("Pause"), () => _host.Downloads.Cancel("kokoro"), Icons.Pause).Margin(0, 8, 0, 0));
        }
        else
        {
            stack.Children.Add(UiKit.Caption(Loc.F("Kokoro v0.19 · {0} · Apache-2.0 · English voices", ModelDownloads.Format(KokoroProvider.ArchiveSize))));
            stack.Children.Add(UiKit.Button(Loc.T("Download model"), () => _host.Downloads.Start("kokoro", [KokoroProvider.Download],
                () => { _host.Ui.Toast(Loc.T("Kokoro is ready"), ToastKind.Success); Render(); }), Icons.Download, accent: true).Margin(0, 8, 0, 0));
        }
        return UiKit.Card("Kokoro", stack);
    }

    private UIElement KeyCard(string provider)
    {
        var has = _host.Secrets.Has(Core.Settings.SecretStore.KeyId(provider));
        var box = new PasswordBox { Width = 280 };
        var status = UiKit.Caption(has ? "✓ " + Loc.T("Saved") : "");
        var save = UiKit.Button(Loc.T("Save & Verify"), async () =>
        {
            var key = box.Password.Trim();
            if (key.Length == 0) return;
            var old = _host.Secrets.ApiKey(provider);
            _host.Secrets.SetApiKey(provider, key);
            status.Text = Loc.T("Verifying…");
            var (ok, message) = await _host.ReadAloud.VerifyKeyAsync(provider);
            if (!ok) _host.Secrets.SetApiKey(provider, old);
            status.Text = ok ? "✓ " + message : message;
            if (ok) box.Password = "";
        });
        return UiKit.Card(Loc.F("{0} API key", provider), UiKit.HStack(box, save.Margin(8, 0, 0, 0), status.VCenter().Margin(8, 0, 0, 0)));
    }
}
