using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Zerm.App.Localization;
using Zerm.App.Platform;
using Zerm.Core.Data;
using Zerm.Core.Dictation;
using Zerm.Core.Enhancement;
using Zerm.Core.Models;
using Zerm.Core.Prompts;
using Zerm.Core.Settings;
using Zerm.Core.Text;

namespace Zerm.App.Views.Pages;

/// <summary>Port of PowerModeView.swift: per-app and per-website overrides.</summary>
public sealed class PowerModesPage : ContentControl
{
    private readonly AppHost _host = AppHost.Current;

    public PowerModesPage() => Render();

    /// <summary>Templates (PowerModeTemplate): bind installed/running apps and set prompt + text cleanup.</summary>
    private static readonly (string Name, string Emoji, Guid Prompt, bool Formatting, PunctuationCleanupMode Punct, string[] Apps)[] Templates =
    [
        ("Code", "⌨️", PredefinedPrompts.CodingId, false, PunctuationCleanupMode.RemoveTrailingPeriod,
            ["Code", "Cursor", "devenv", "WindowsTerminal", "pwsh", "powershell", "cmd", "idea64", "rider64", "zed", "windsurf"]),
        ("Messages", "💬", PredefinedPrompts.ChatId, false, PunctuationCleanupMode.RemoveTrailingPeriod,
            ["Slack", "WhatsApp", "Telegram", "Discord", "ms-teams", "Teams", "Signal"]),
        ("Writing", "✍️", PredefinedPrompts.DefaultId, true, PunctuationCleanupMode.Keep,
            ["WINWORD", "OUTLOOK", "olk", "Notion", "Obsidian", "notepad", "ONENOTE"]),
    ];

    private void Render()
    {
        var lib = _host.Library;
        var s = _host.Settings;
        var list = new StackPanel();
        foreach (var mode in lib.PowerModes)
        {
            var m = mode;
            var enabled = new CheckBox { IsChecked = m.IsEnabled, MinWidth = 0, ToolTip = Loc.T("Enabled") };
            enabled.Click += (_, _) => { m.IsEnabled = enabled.IsChecked == true; lib.Save(); };
            var summary = new List<string>();
            if (m.AppConfigs.Count > 0) summary.Add(string.Join(", ", m.AppConfigs.Select(a => a.AppName)));
            if (m.UrlConfigs.Count > 0) summary.Add(string.Join(", ", m.UrlConfigs.Select(u => u.Url)));
            if (m.IsDefault) summary.Insert(0, Loc.T("Default for every other app"));
            var overrides = new List<string>();
            if (m.OutputMode is { } om) overrides.Add(EnhancementPage.ModeTitle(om));
            if (m.SelectedPrompt is { } pid && lib.Prompts.FirstOrDefault(p => p.Id == pid) is { } prompt) overrides.Add(Loc.T(prompt.Title));
            if (m.SelectedTranscriptionModelName != null) overrides.Add(TranscriptionModelRegistry.Find(m.SelectedTranscriptionModelName, lib.CustomTranscriptionModels)?.DisplayName ?? m.SelectedTranscriptionModelName);
            if (m.SelectedLanguage != null) overrides.Add(Languages.DisplayName(m.SelectedLanguage));
            if (m.AutoSendKey != AutoSendKey.None) overrides.Add(Loc.T("Auto Send"));

            var left = UiKit.HStack(enabled,
                new TextBlock { Text = m.Emoji, FontSize = 22, FontFamily = new FontFamily("Segoe UI Emoji"), Margin = new Thickness(6, 0, 12, 0), VerticalAlignment = VerticalAlignment.Center },
                UiKit.VStack(UiKit.Text(m.Name, 15, FontWeights.SemiBold),
                    UiKit.Caption(summary.Count > 0 ? string.Join(" · ", summary) : Loc.T("No apps or websites yet")),
                    UiKit.Caption(overrides.Count > 0 ? string.Join(" · ", overrides) : Loc.T("Uses your global settings"))));
            var right = UiKit.HStack(
                UiKit.IconButton(Icons.Edit, Loc.T("Edit"), () => Edit(m)),
                UiKit.IconButton(Icons.Delete, Loc.T("Delete"), () =>
                {
                    if (!UiKit.Confirm(Loc.F("Delete the Power Mode \"{0}\"?", m.Name))) return;
                    lib.PowerModes.Remove(m);
                    lib.Save();
                    Render();
                }));
            var grid = new Grid();
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.Children.Add(left);
            Grid.SetColumn(right, 1);
            grid.Children.Add(right);
            list.Children.Add(new Border { Child = grid }.Style("Card"));
        }

        var templates = UiKit.Wrap();
        foreach (var t in Templates)
        {
            var tpl = t;
            templates.Children.Add(UiKit.Button($"{t.Emoji} {Loc.T(t.Name)}", () => AddTemplate(tpl)));
        }

        Content = UiKit.Page(Loc.T("Power Modes"),
            Loc.T("Power Modes switch model, language, prompt and output automatically for the app or website you're dictating into. Anything you don't override uses your global settings."),
            UiKit.Card(null, UiKit.Row(Loc.T("Enable Power Modes"), UiKit.Toggle(s, nameof(s.PowerModeEnabled)), Loc.T("Alt+1…0 picks a Power Mode while recording."))),
            UiKit.HStack(UiKit.Button(Loc.T("New Power Mode"), () => Edit(null), Icons.Add, accent: true)).Margin(0, 0, 0, 12),
            list,
            UiKit.Card(Loc.T("Templates"), Loc.T("Creates a Power Mode for the matching apps that are running now."), templates));
    }

    private void AddTemplate((string Name, string Emoji, Guid Prompt, bool Formatting, PunctuationCleanupMode Punct, string[] Apps) t)
    {
        var lib = _host.Library;
        var running = ActiveWindowService.RunningApps().ToList();
        var bound = lib.PowerModes.SelectMany(m => m.AppConfigs).Select(a => a.ProcessName.ToLowerInvariant()).ToHashSet();
        var mode = new PowerModeConfig
        {
            Name = lib.PowerModes.Any(m => m.Name == Loc.T(t.Name)) ? Loc.T(t.Name) + " 2" : Loc.T(t.Name),
            Emoji = t.Emoji,
            SelectedPrompt = t.Prompt,
            TextFormatting = t.Formatting,
            PunctuationCleanup = t.Punct,
            AppConfigs = t.Apps.Where(a => !bound.Contains(a.ToLowerInvariant()))
                .Select(a => new PowerModeApp { ProcessName = a, AppName = running.FirstOrDefault(r => r.ProcessName.Equals(a, StringComparison.OrdinalIgnoreCase)).Title ?? a })
                .ToList(),
        };
        lib.SavePowerMode(mode);
        Render();
        Edit(mode);
    }

    private void Edit(PowerModeConfig? mode)
    {
        var editor = new PowerModeEditorWindow(mode) { Owner = Window.GetWindow(this) };
        if (editor.ShowDialog() == true) Render();
    }
}

public sealed class PowerModeEditorWindow : Window
{
    public PowerModeEditorWindow(PowerModeConfig? existing)
    {
        var host = AppHost.Current;
        var lib = host.Library;
        var m = existing?.Clone() ?? new PowerModeConfig { Name = "", Emoji = "🚀" };
        Title = existing == null ? Loc.T("New Power Mode") : Loc.T("Edit Power Mode");
        Width = 720;
        Height = 820;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        FlowDirection = Loc.Direction;

        var name = new TextBox { Text = m.Name, Width = 280 };
        var emoji = new ComboBox { Width = 80, IsEditable = true, Text = m.Emoji, FontFamily = new FontFamily("Segoe UI Emoji"), FontSize = 16 };
        foreach (var e in new[] { "⚡", "🚀", "💬", "✍️", "⌨️", "📧", "🧠", "📝", "🎯", "💼", "🌐", "🔥", "🎨", "📚", "🛠️" }) emoji.Items.Add(e);

        // Apps
        var apps = new WrapPanel();
        void RenderApps()
        {
            apps.Children.Clear();
            foreach (var a in m.AppConfigs.ToList())
                apps.Children.Add(Chip($"{a.AppName} ({a.ProcessName})", () => { m.AppConfigs.Remove(a); RenderApps(); }));
        }
        RenderApps();
        var running = ActiveWindowService.RunningApps().ToList();
        var appPicker = UiKit.Combo(running.Select(r => (r.ProcessName, $"{r.Title} ({r.ProcessName})")), "", p =>
        {
            if (m.AppConfigs.Any(a => a.ProcessName.Equals(p, StringComparison.OrdinalIgnoreCase))) return;
            m.AppConfigs.Add(new PowerModeApp { ProcessName = p, AppName = running.First(r => r.ProcessName == p).Title });
            RenderApps();
        }, 300);
        var manualApp = new TextBox { Width = 180, ToolTip = Loc.T("Process name, e.g. chrome") };
        var addManual = UiKit.Button(Loc.T("Add"), () =>
        {
            var p = Path.GetFileNameWithoutExtension(manualApp.Text.Trim());
            if (p.Length == 0) return;
            m.AppConfigs.Add(new PowerModeApp { ProcessName = p, AppName = p });
            manualApp.Text = "";
            RenderApps();
        });

        // URLs
        var urls = new WrapPanel();
        void RenderUrls()
        {
            urls.Children.Clear();
            foreach (var u in m.UrlConfigs.ToList())
                urls.Children.Add(Chip(u.Url, () => { m.UrlConfigs.Remove(u); RenderUrls(); }));
        }
        RenderUrls();
        var urlBox = new TextBox { Width = 280, ToolTip = Loc.T("e.g. github.com or mail.google.com") };
        var addUrl = UiKit.Button(Loc.T("Add"), () =>
        {
            var u = PowerModeConfig.CleanUrl(urlBox.Text);
            if (u.Length == 0) return;
            m.UrlConfigs.Add(new PowerModeUrl { Url = u });
            urlBox.Text = "";
            RenderUrls();
        });

        // Overrides
        var models = new List<(string, string)> { ("", Loc.T("Use global")) };
        models.AddRange(TranscriptionModelRegistry.All(lib.CustomTranscriptionModels).Where(host.IsUsable).Select(x => (x.Name, x.DisplayName)));
        var model = UiKit.Combo(models, m.SelectedTranscriptionModelName ?? "", v => m.SelectedTranscriptionModelName = v.Length == 0 ? null : v);
        var langs = new List<(string, string)> { ("", Loc.T("Use global")) };
        langs.AddRange(Languages.All.Select(l => (l.Key, l.Key == "auto" ? Loc.T("Auto-detect") : Languages.DisplayName(l.Key))));
        var language = UiKit.Combo(langs, m.SelectedLanguage ?? "", v => m.SelectedLanguage = v.Length == 0 ? null : v);
        ComboBox Tri(bool? value, Action<bool?> set) => UiKit.Combo([(0, Loc.T("Use global")), (1, Loc.T("On")), (2, Loc.T("Off"))],
            value == null ? 0 : value.Value ? 1 : 2, v => set(v == 0 ? null : v == 1), 160);
        var formatting = Tri(m.TextFormatting, v => m.TextFormatting = v);
        var lowercase = Tri(m.Lowercase, v => m.Lowercase = v);
        var punct = UiKit.Combo([(-1, Loc.T("Use global")), (0, Loc.T("Keep punctuation")), (1, Loc.T("Remove all punctuation")), (2, Loc.T("Remove trailing period"))],
            m.PunctuationCleanup == null ? -1 : (int)m.PunctuationCleanup, v => m.PunctuationCleanup = v < 0 ? null : (PunctuationCleanupMode)v, 220);
        var output = UiKit.Combo([(-1, Loc.T("Use global")), (0, Loc.T("Instant")), (1, Loc.T("Instant + Refine")), (2, Loc.T("Enhanced"))],
            m.OutputMode == null ? -1 : (int)m.OutputMode, v => m.OutputMode = v < 0 ? null : (DictationOutputMode)v, 220);
        var providers = new List<(string, string)> { ("", Loc.T("Use global")) };
        providers.AddRange(AIProviders.All.Where(p => host.Enhancement.IsConfigured(p.Name)).Select(p => (p.Name, p.Name)));
        var aiModel = new TextBox { Width = 220, Text = m.SelectedAIModel ?? "", ToolTip = Loc.T("Leave empty to use the provider's model") };
        var provider = UiKit.Combo(providers, m.SelectedAIProvider ?? "", v => { m.SelectedAIProvider = v.Length == 0 ? null : v; aiModel.Text = ""; });
        var prompts = new List<(Guid, string)> { (Guid.Empty, Loc.T("Use global")) };
        prompts.AddRange(lib.Prompts.Select(p => (p.Id, Loc.T(p.Title))));
        var prompt = UiKit.Combo(prompts, m.SelectedPrompt ?? Guid.Empty, v => m.SelectedPrompt = v == Guid.Empty ? null : v);
        var context = Tri(m.ContextAwareness, v => m.ContextAwareness = v);
        var autoSend = UiKit.Combo([(AutoSendKey.None, Loc.T("Off")), (AutoSendKey.Enter, "Enter"), (AutoSendKey.ShiftEnter, "Shift+Enter"), (AutoSendKey.CtrlEnter, "Ctrl+Enter")],
            m.AutoSendKey, v => m.AutoSendKey = v, 160);
        var isDefault = new CheckBox { IsChecked = m.IsDefault, Content = Loc.T("Use for apps without their own Power Mode") };
        var hotkey = new ShortcutRecorder(m.Hotkey, c => m.Hotkey = c);

        var errors = UiKit.Caption("");
        errors.Foreground = new SolidColorBrush(Color.FromRgb(0xFF, 0x45, 0x3A));
        var save = UiKit.Button(Loc.T("Save"), () =>
        {
            m.Name = name.Text.Trim();
            m.Emoji = string.IsNullOrWhiteSpace(emoji.Text) ? "⚡" : emoji.Text.Trim();
            m.IsDefault = isDefault.IsChecked == true;
            m.SelectedAIModel = m.SelectedAIProvider != null && aiModel.Text.Trim().Length > 0 ? aiModel.Text.Trim() : null;
            var problems = lib.Validate(m);
            if (problems.Count > 0)
            {
                errors.Text = Loc.T("Cannot Save Power Mode") + ": " + string.Join(" ", problems);
                return;
            }
            lib.SavePowerMode(m);
            DialogResult = true;
        }, accent: true);

        var stack = UiKit.VStack(
            UiKit.Card(Loc.T("General"), UiKit.Row(Loc.T("Name"), name), UiKit.Row(Loc.T("Emoji"), emoji)),
            UiKit.Card(Loc.T("Applications"), Loc.T("Activates when one of these apps is in front."), UiKit.HStack(appPicker, manualApp.Margin(8, 0, 8, 0), addManual), apps.Margin(0, 8, 0, 0)),
            UiKit.Card(Loc.T("Websites"), Loc.T("Activates when the browser tab's address contains one of these (Chrome, Edge, Firefox, Brave, Opera, Vivaldi, Arc)."), UiKit.HStack(urlBox, addUrl.Margin(8, 0, 0, 0)), urls.Margin(0, 8, 0, 0)),
            UiKit.Card(Loc.T("Transcription"), UiKit.Row(Loc.T("Model"), model), UiKit.Row(Loc.T("Language"), language)),
            UiKit.Card(Loc.T("Text"), UiKit.Row(Loc.T("Text Formatting"), formatting), UiKit.Row(Loc.T("Punctuation"), punct), UiKit.Row(Loc.T("Lowercase"), lowercase)),
            UiKit.Card(Loc.T("AI Enhancement"), UiKit.Row(Loc.T("Output"), output), UiKit.Row(Loc.T("AI Provider"), provider), UiKit.Row(Loc.T("AI Model"), aiModel),
                UiKit.Row(Loc.T("Enhancement Prompt"), prompt), UiKit.Row(Loc.T("Context Awareness"), context, Loc.T("Screen OCR, Enhanced mode only."))),
            UiKit.Card(Loc.T("Advanced"), UiKit.Row(Loc.T("Auto Send"), autoSend, Loc.T("Press a key after pasting, e.g. to send a chat message.")),
                UiKit.Row(Loc.T("Keyboard Shortcut"), hotkey, Loc.T("Starts dictation with this Power Mode.")), isDefault),
            errors,
            UiKit.HStack(save, UiKit.Button(Loc.T("Cancel"), () => DialogResult = false)));
        Content = new ScrollViewer { Content = new Border { Padding = new Thickness(24), Child = stack }, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    }

    private static Border Chip(string text, Action remove)
    {
        var x = new Button { Content = UiKit.Glyph(Icons.Close, 9), Padding = new Thickness(4), Margin = new Thickness(6, 0, 0, 0), Background = Brushes.Transparent, BorderThickness = new Thickness(0) };
        x.Click += (_, _) => remove();
        return new Border
        {
            CornerRadius = new CornerRadius(14), Padding = new Thickness(12, 4, 6, 4), Margin = new Thickness(0, 0, 8, 8),
            Background = (Brush)Application.Current.FindResource("SubtleFillColorSecondaryBrush"),
            Child = UiKit.HStack(new TextBlock { Text = text, VerticalAlignment = VerticalAlignment.Center }, x),
        };
    }
}
