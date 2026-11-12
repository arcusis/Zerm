using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;
using Zerm.App.Localization;
using Zerm.Core.Dictation;
using Zerm.Core.Enhancement;
using Zerm.Core.LocalLlm;
using Zerm.Core.Net;
using Zerm.Core.Prompts;
using Zerm.Core.Settings;

namespace Zerm.App.Views.Pages;

/// <summary>Port of EnhancementSettingsView.swift.</summary>
public sealed class EnhancementPage : ContentControl
{
    private readonly AppHost _host = AppHost.Current;

    public EnhancementPage()
    {
        Render();
        _host.Downloads.Changed += Rerender;
        Unloaded += (_, _) => _host.Downloads.Changed -= Rerender;
    }

    private void Rerender() => Dispatcher.BeginInvoke(Render);

    public static string ModeTitle(DictationOutputMode m) => m switch
    {
        DictationOutputMode.Instant => Loc.T("Instant"),
        DictationOutputMode.InstantRefine => Loc.T("Instant + Refine"),
        _ => Loc.T("Enhanced"),
    };

    public static string ModeSubtitle(DictationOutputMode m) => m switch
    {
        DictationOutputMode.Instant => Loc.T("Paste immediately. No AI."),
        DictationOutputMode.InstantRefine => Loc.T("Paste immediately, then improve the text in place when the app allows a direct edit. Otherwise the raw text stays and the refinement is kept in History."),
        _ => Loc.T("Wait for the AI, then paste once."),
    };

    private void Render()
    {
        var s = _host.Settings;
        var modes = new StackPanel();
        // Super Enhancement is offered as its own choice: Enhanced output with the deep, local rewrite.
        var superChosen = s.SuperEnhancement && s.OutputMode == DictationOutputMode.Enhanced;
        foreach (var m in Enum.GetValues<DictationOutputMode>())
        {
            var rb = new RadioButton
            {
                GroupName = "mode", IsChecked = s.OutputMode == m && !superChosen, Margin = new Thickness(0, 4, 0, 4),
                Content = UiKit.VStack(UiKit.Text(ModeTitle(m), 14, FontWeights.SemiBold), UiKit.Caption(ModeSubtitle(m))),
            };
            var mode = m;
            rb.Checked += (_, _) =>
            {
                s.OutputMode = mode;
                if (mode != DictationOutputMode.Instant) s.LastEnhancingOutputMode = mode;
                if (s.SuperEnhancement) { s.SuperEnhancement = false; Dispatcher.BeginInvoke(Render); }
            };
            modes.Children.Add(rb);
        }
        var super = new RadioButton
        {
            GroupName = "mode", IsChecked = superChosen, Margin = new Thickness(0, 4, 0, 4),
            Content = UiKit.VStack(
                UiKit.HStack(UiKit.Text(Loc.T("Super Enhancement"), 14, FontWeights.SemiBold), UiKit.Pill(Loc.T("On this PC"), Color.FromRgb(0x32, 0xD7, 0x4B)).Margin(8, 0, 0, 0)),
                UiKit.Caption(Loc.T("Wait for a deep rewrite that understands you were speaking — repeats, restarts and corrections removed, clean sentences, nothing dropped. Slower."))),
        };
        super.Checked += (_, _) =>
        {
            s.OutputMode = DictationOutputMode.Enhanced;
            s.LastEnhancingOutputMode = DictationOutputMode.Enhanced;
            if (!s.SuperEnhancement)
            {
                s.SuperEnhancement = true;
                _ = _host.PrewarmLlmAsync();
                Dispatcher.BeginInvoke(Render);
            }
        };
        modes.Children.Add(super);
        var output = UiKit.Card(Loc.T("Output"), Loc.T("Ctrl+E while recording switches AI on or off for that recording."), modes);

        var insights = UiKit.Button(Loc.T("See what enhancement changed"), () => ShellWindow.ShowAndNavigate("Insights"), Icons.Filter);
        insights.HorizontalAlignment = HorizontalAlignment.Left;
        insights.Margin = new Thickness(0, 0, 0, 12);
        var content = new List<UIElement> { insights, output, SuperCard(), ProviderCard(), PromptsCard(), OptionsCard() };
        Content = UiKit.Page(Loc.T("Enhancement"), Loc.T("Clean up, format or transform your dictation with AI — on this PC or with a provider you choose."), [.. content]);
    }

    // MARK: - Super Enhancement

    private Border SuperCard()
    {
        var s = _host.Settings;
        var stack = new StackPanel();
        stack.Children.Add(UiKit.Text(Loc.T("Super Enhancement model"), 14, FontWeights.SemiBold));
        var used = LocalLlmCatalog.ResolveForSuper(s.SuperEnhancementModel);
        var e4b = LocalLlmCatalog.Find("gemma-4-e4b")!;
        if (used == null)
        {
            var warn = UiKit.Caption(Loc.T("Download an on-device model below to use Super Enhancement."));
            warn.Foreground = new SolidColorBrush(Color.FromRgb(0xFF, 0x9F, 0x0A));
            stack.Children.Add(warn);
        }
        else
        {
            stack.Children.Add(UiKit.Caption(Loc.F("Runs with {0} on this PC — two passes, about 2–4 s per dictation.", used.DisplayName)));
        }
        if (used?.Id != e4b.Id)
        {
            stack.Children.Add(UiKit.Caption(Loc.T("Recommended: Gemma 4 E4B. In testing it handled corrections and Hebrew reliably, where smaller models sometimes kept mistakes.")).Margin(0, 6, 0, 0));
            stack.Children.Add(LlmRow(e4b, false, Render));
        }
        var card = UiKit.Card(null, stack);
        if (s.SuperEnhancement) card.BorderBrush = new SolidColorBrush(SystemColors.AccentColor);
        return card;
    }

    // MARK: - Provider

    private Border ProviderCard()
    {
        var s = _host.Settings;
        var providers = AIProviders.All.Select(p => (p.Name, p.Name == AIProviders.OnDevice ? Loc.T("On-Device (private, offline)") : p.Name));
        var picker = UiKit.Combo(providers, s.SelectedAIProvider, v => { s.SelectedAIProvider = v; Render(); }, 260);
        var info = AIProviders.Find(s.SelectedAIProvider)!;
        var stack = new StackPanel();
        stack.Children.Add(UiKit.Row(Loc.T("Provider"), picker));
        var configured = _host.Enhancement.IsConfigured(info.Name);
        var status = UiKit.Text(configured ? "✓ " + Loc.T("Configured") : Loc.T("Needs setup"), 12);
        status.Foreground = new SolidColorBrush(configured ? Color.FromRgb(0x32, 0xD7, 0x4B) : Color.FromRgb(0xFF, 0x9F, 0x0A));
        stack.Children.Add(status);

        switch (info.Kind)
        {
            case ProviderKind.OnDevice:
                stack.Children.Add(OnDeviceModels());
                break;
            case ProviderKind.Ollama:
                stack.Children.Add(UiKit.Row(Loc.T("Server"), UiKit.TextBox(s, nameof(s.OllamaBaseUrl))));
                var models = new ComboBox { Width = 260, IsEditable = true, Text = s.OllamaSelectedModel };
                models.LostFocus += (_, _) => s.OllamaSelectedModel = models.Text;
                models.SelectionChanged += (_, _) => { if (models.SelectedItem is string m) s.OllamaSelectedModel = m; };
                var refresh = UiKit.Button(Loc.T("Refresh Models"), async () =>
                {
                    try
                    {
                        var list = await EnhancementClient.OllamaModels(s.OllamaBaseUrl, CancellationToken.None);
                        models.ItemsSource = list;
                        _host.Ui.Toast(Loc.F("{0} models found", list.Count), ToastKind.Success);
                    }
                    catch (Exception ex)
                    {
                        _host.Ui.Toast(Loc.F("Ollama is not reachable: {0}", ex.Message), ToastKind.Error);
                    }
                });
                stack.Children.Add(UiKit.Row(Loc.T("Model"), UiKit.HStack(models, refresh.Margin(8, 0, 0, 0))));
                stack.Children.Add(UiKit.Caption(Loc.T("Install Ollama from ollama.com, then run: ollama pull llama3.2")));
                break;
            case ProviderKind.LocalCli:
                stack.Children.Add(UiKit.Row(Loc.T("Command"), UiKit.TextBox(s, nameof(s.LocalCliCommand), 380)));
                stack.Children.Add(UiKit.Row(Loc.T("Template"), UiKit.Combo(EnhancementClient.CliTemplates.Select(t => (t.Command, t.Name)), "", v => { s.LocalCliCommand = v; Render(); }, 200)));
                stack.Children.Add(UiKit.Row(Loc.T("Timeout (seconds)"), UiKit.SliderWithValue(s, nameof(s.LocalCliTimeoutSeconds), 5, 120, 5, "{0:F0} s")));
                stack.Children.Add(UiKit.Caption(Loc.T("The prompt is sent on standard input and in the ZERM_SYSTEM_PROMPT, ZERM_USER_PROMPT and ZERM_FULL_PROMPT environment variables. The command's output replaces your text.")));
                break;
            case ProviderKind.Custom:
                stack.Children.Add(UiKit.Row(Loc.T("Base URL"), UiKit.TextBox(s, nameof(s.CustomProviderBaseUrl), 360), Loc.T("OpenAI-compatible, e.g. https://api.example.com/v1")));
                stack.Children.Add(UiKit.Row(Loc.T("Model"), UiKit.TextBox(s, nameof(s.CustomProviderModel))));
                stack.Children.Add(KeyRow(AIProviders.Custom, verify: false));
                break;
            default:
                var model = new ComboBox { Width = 260, IsEditable = info.Name == AIProviders.OpenRouter };
                model.ItemsSource = info.Models.Count > 0 ? info.Models : [_host.Enhancement.ModelFor(info.Name)];
                model.SelectedItem = _host.Enhancement.ModelFor(info.Name);
                model.Text = _host.Enhancement.ModelFor(info.Name);
                model.SelectionChanged += (_, _) => { if (model.SelectedItem is string m) s.SetModelFor(info.Name, m); };
                model.LostFocus += (_, _) => { if (model.IsEditable && model.Text.Length > 0) s.SetModelFor(info.Name, model.Text); };
                stack.Children.Add(UiKit.Row(Loc.T("Model"), model));
                stack.Children.Add(KeyRow(info.Name, verify: true));
                break;
        }
        return UiKit.Card(Loc.T("AI Provider"), stack);
    }

    private UIElement KeyRow(string provider, bool verify)
    {
        var has = _host.Secrets.Has(SecretStoreKey(provider));
        var box = new PasswordBox { Width = 260, ToolTip = Loc.T("Paste API key") };
        var status = UiKit.Caption(has ? "✓ " + Loc.T("Saved") : "");
        var save = UiKit.Button(verify ? Loc.T("Save & Verify") : Loc.T("Save"), async () =>
        {
            var key = box.Password.Trim();
            if (key.Length == 0) return;
            if (verify)
            {
                status.Text = Loc.T("Verifying…");
                var (ok, msg) = await VerifyAsync(provider, key);
                if (!ok)
                {
                    status.Text = msg;
                    return;
                }
            }
            _host.Secrets.SetApiKey(provider, key);
            box.Password = "";
            status.Text = "✓ " + Loc.T("Key verified");
            Render();
        });
        var row = UiKit.HStack(box, save.Margin(8, 0, 0, 0), status.VCenter().Margin(8, 0, 0, 0));
        if (has) row.Children.Add(UiKit.IconButton(Icons.Delete, Loc.T("Remove key"), () => { _host.Secrets.SetApiKey(provider, null); Render(); }));
        return UiKit.Row(Loc.F("{0} API key", provider), row);
    }

    private static string SecretStoreKey(string provider) => Core.Settings.SecretStore.KeyId(provider);

    private static async Task<(bool, string)> VerifyAsync(string provider, string key)
    {
        var info = AIProviders.Find(provider)!;
        return provider switch
        {
            AIProviders.Anthropic => await Core.Transcription.CloudTranscription.VerifyGet(info.KeyCheckUrl!, r => r.Header("x-api-key", key).Header("anthropic-version", "2023-06-01"), CancellationToken.None),
            AIProviders.Gemini => await Core.Transcription.CloudTranscription.VerifyGet("https://generativelanguage.googleapis.com/v1beta/models", r => r.Header("x-goog-api-key", key), CancellationToken.None),
            _ => await Core.Transcription.CloudTranscription.VerifyGet(info.KeyCheckUrl!, r => r.Bearer(key), CancellationToken.None),
        };
    }

    private UIElement OnDeviceModels()
    {
        var s = _host.Settings;
        var stack = new StackPanel { Margin = new Thickness(0, 8, 0, 0) };
        var selected = LocalLlmCatalog.ResolveForEnhancement(s.ModelFor(AIProviders.OnDevice))?.Id ?? s.ModelFor(AIProviders.OnDevice) ?? LocalLlmCatalog.DefaultId;
        foreach (var p in LocalLlmCatalog.Packages.Where(p => p.ForEnhancement))
            stack.Children.Add(LlmRow(p, selected == p.Id, () => { s.SetModelFor(AIProviders.OnDevice, p.Id); Render(); }));
        stack.Children.Add(UiKit.Caption(Loc.T("Runs entirely on this PC with llama.cpp — on your GPU when available. No account or API key.")));
        return stack;
    }

    public static UIElement LlmRow(LocalLlmPackage p, bool selected, Action select)
    {
        var host = AppHost.Current;
        var downloaded = LocalLlmCatalog.IsDownloaded(p);
        var title = UiKit.HStack(UiKit.Text(p.DisplayName, 14, FontWeights.SemiBold).Margin(0, 0, 8, 0));
        if (p.Id == LocalLlmCatalog.DefaultId) title.Children.Add(UiKit.Pill(Loc.T("Recommended"), Color.FromRgb(0x0A, 0x84, 0xFF)));
        if (selected && downloaded) title.Children.Add(UiKit.Pill(Loc.T("In use"), Color.FromRgb(0x32, 0xD7, 0x4B)));
        var left = UiKit.VStack(title, UiKit.Caption($"{Loc.T(p.Description)} · {ModelDownloads.Format(p.SizeBytes)} · {p.License}"));
        var right = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        var active = host.Downloads.Get("llm:" + p.Id);
        if (active != null)
        {
            var bar = new ProgressBar { Width = 150, Height = 6, Maximum = 1, VerticalAlignment = VerticalAlignment.Center };
            bar.SetBinding(System.Windows.Controls.Primitives.RangeBase.ValueProperty, new Binding(nameof(active.Progress)) { Source = active });
            var st = new TextBlock { FontSize = 11, Opacity = 0.7, Width = 190, TextTrimming = TextTrimming.CharacterEllipsis };
            st.SetBinding(TextBlock.TextProperty, new Binding(nameof(active.Status)) { Source = active });
            right.Children.Add(UiKit.VStack(bar, st).Margin(0, 0, 8, 0));
            right.Children.Add(UiKit.Button(Loc.T("Pause"), () => host.Downloads.Cancel("llm:" + p.Id), Icons.Pause));
        }
        else if (!downloaded)
        {
            var spec = LocalLlmCatalog.Spec(p);
            right.Children.Add(UiKit.Button(Core.Models.ModelDownloader.HasPartial(spec) ? Loc.T("Resume") : Loc.T("Download"),
                () => host.Downloads.Start("llm:" + p.Id, [spec], () =>
                {
                    host.Ui.Toast(Loc.F("{0} is ready", p.DisplayName), ToastKind.Success);
                    select();
                }), Icons.Download, accent: true));
        }
        else
        {
            if (!selected) right.Children.Add(UiKit.Button(Loc.T("Use"), select));
            right.Children.Add(UiKit.IconButton(Icons.Delete, Loc.T("Delete model"), () =>
            {
                if (!UiKit.Confirm(Loc.F("Delete {0}? You can download it again later.", p.DisplayName))) return;
                host.LocalLlm.UnloadNow();
                try { File.Delete(LocalLlmCatalog.PathFor(p)); } catch (Exception ex) { host.Ui.Toast(ex.Message, ToastKind.Error); }
                select();
            }));
        }
        var grid = new Grid { Margin = new Thickness(0, 6, 0, 6) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(left);
        Grid.SetColumn(right, 1);
        grid.Children.Add(right);
        return grid;
    }

    // MARK: - Prompts

    private Border PromptsCard()
    {
        var s = _host.Settings;
        var lib = _host.Library;
        var wrap = new WrapPanel();
        var n = 1;
        foreach (var prompt in lib.Prompts)
        {
            var isSelected = s.SelectedPromptId == prompt.Id;
            var tile = new Button
            {
                Width = 150, Height = 96, Margin = new Thickness(0, 0, 10, 10), Padding = new Thickness(8),
                ToolTip = Loc.T(prompt.Description ?? prompt.Title) + (n <= 10 ? $"  (Ctrl+{n % 10})" : ""),
                Content = UiKit.VStack(
                    UiKit.Glyph(Icons.Glyph(prompt.Icon), 22).Center(),
                    UiKit.Text(Loc.T(prompt.Title), 13, FontWeights.SemiBold).Center().Margin(0, 6, 0, 0),
                    UiKit.Caption(prompt.TriggerWords.Count > 0 ? $"\"{prompt.TriggerWords[0]}...\"" + (prompt.TriggerWords.Count > 1 ? $" +{prompt.TriggerWords.Count - 1}" : "") : "").Center()),
            };
            if (isSelected)
            {
                tile.BorderBrush = new SolidColorBrush(SystemColors.AccentColor);
                tile.BorderThickness = new Thickness(2);
            }
            var p = prompt;
            tile.Click += (_, _) => { s.SelectedPromptId = p.Id; Render(); };
            tile.MouseDoubleClick += (_, _) => Edit(p);
            var menu = new ContextMenu();
            var edit = new MenuItem { Header = Loc.T("Edit") };
            edit.Click += (_, _) => Edit(p);
            menu.Items.Add(edit);
            if (!p.IsPredefined)
            {
                var del = new MenuItem { Header = Loc.T("Delete") };
                del.Click += (_, _) =>
                {
                    if (!UiKit.Confirm(Loc.F("Delete the prompt \"{0}\"?", p.Title))) return;
                    lib.Prompts.Remove(p);
                    if (s.SelectedPromptId == p.Id) s.SelectedPromptId = PredefinedPrompts.DefaultId;
                    lib.Save();
                    Render();
                };
                menu.Items.Add(del);
            }
            tile.ContextMenu = menu;
            wrap.Children.Add(tile);
            n++;
        }
        var add = new Button { Width = 150, Height = 96, Margin = new Thickness(0, 0, 10, 10), Content = UiKit.VStack(UiKit.Glyph(Icons.Add, 22).Center(), UiKit.Text(Loc.T("New Prompt"), 13).Center().Margin(0, 6, 0, 0)) };
        add.Click += (_, _) => Edit(null);
        wrap.Children.Add(add);
        return UiKit.Card(Loc.T("Prompts"), Loc.T("Click to select, double-click or right-click to edit. Ctrl+1…0 picks a prompt while recording."), wrap);
    }

    private void Edit(CustomPrompt? prompt)
    {
        var editor = new PromptEditorWindow(prompt) { Owner = Window.GetWindow(this) };
        if (editor.ShowDialog() == true) Render();
    }

    private Border OptionsCard()
    {
        var s = _host.Settings;
        return UiKit.Card(Loc.T("Context & Behavior"),
            UiKit.Row(Loc.T("Clipboard context"), UiKit.Toggle(s, nameof(s.UseClipboardContext)), Loc.T("Send the clipboard text with the request so names and terms are spelled correctly.")),
            UiKit.Row(Loc.T("Screen context"), UiKit.Toggle(s, nameof(s.UseScreenCaptureContext)), Loc.T("Read the text of the active window with Windows OCR (Enhanced mode only).")),
            UiKit.Row(Loc.T("Prompt trigger words"), UiKit.Toggle(s, nameof(s.AllowPromptTriggeredEnhancement)), Loc.T("Saying a prompt's trigger word at the start or end selects that prompt.")),
            UiKit.Row(Loc.T("Skip short dictations"), UiKit.Toggle(s, nameof(s.SkipShortEnhancement)), Loc.T("Don't send dictations of a few words to the AI.")),
            UiKit.Row(Loc.T("Short means up to"), UiKit.SliderWithValue(s, nameof(s.ShortEnhancementWordThreshold), 1, 10, 1, "{0} words")),
            UiKit.Row(Loc.T("Enhanced timeout"), UiKit.SliderWithValue(s, nameof(s.EnhancementTimeoutSeconds), 5, 60, 1, "{0} s")),
            UiKit.Row(Loc.T("Retry once on timeout"), UiKit.Toggle(s, nameof(s.EnhancementRetryOnTimeout))));
    }
}
