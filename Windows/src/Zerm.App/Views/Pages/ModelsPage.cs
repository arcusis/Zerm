using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;
using Zerm.App.Localization;
using Zerm.Core.Data;
using Zerm.Core.Dictation;
using Zerm.Core.Models;
using Zerm.Core.Transcription;

namespace Zerm.App.Views.Pages;

/// <summary>Port of ModelManagementView.swift.</summary>
public sealed class ModelsPage : ContentControl
{
    private readonly AppHost _host = AppHost.Current;
    private string _filter = "Recommended";

    public ModelsPage()
    {
        Render();
        _host.Downloads.Changed += Rerender;
        _host.Secrets.Changed += OnSecret;
        Unloaded += (_, _) =>
        {
            _host.Downloads.Changed -= Rerender;
            _host.Secrets.Changed -= OnSecret;
        };
    }

    private void OnSecret(string _) => Rerender();
    private void Rerender() => Dispatcher.BeginInvoke(Render);

    private void Render()
    {
        var current = _host.CurrentModel;
        var currentCard = UiKit.Card(Loc.T("Default Model"),
            UiKit.Row(Loc.T("Transcription model"), UiKit.Text(current?.DisplayName ?? Loc.T("None selected"), 14, FontWeights.SemiBold),
                _host.IsUsable(current) ? (current!.IsLocal ? Loc.F("Runs on this PC ({0})", WhisperRuntimeLabel(current)) : Loc.T("Cloud model")) : Loc.T("Download a model or add an API key to start dictating.")),
            UiKit.Row(Loc.T("Language"), LanguagePicker(current), Loc.T("Auto-detect works for most models. Pick a language to force it.")));

        var filters = UiKit.Wrap();
        foreach (var (key, label) in new[] { ("Recommended", "Recommended"), ("Local", "Local"), ("Cloud", "Cloud"), ("Custom", "Custom") })
        {
            var b = new RadioButton { Content = Loc.T(label), IsChecked = _filter == key, GroupName = "filter", Margin = new Thickness(0, 0, 16, 0) };
            b.Checked += (_, _) => { _filter = key; Render(); };
            filters.Children.Add(b);
        }
        filters.Margin = new Thickness(0, 4, 0, 12);

        var list = new StackPanel();
        IEnumerable<TranscriptionModel> models = _filter switch
        {
            "Local" => TranscriptionModelRegistry.Local,
            "Cloud" => TranscriptionModelRegistry.Cloud,
            "Custom" => _host.Library.CustomTranscriptionModels,
            _ => TranscriptionModelRegistry.All(_host.Library.CustomTranscriptionModels).Where(m => m.IsRecommended || m.IsDownloaded || m.Name == current?.Name),
        };
        foreach (var m in models) list.Children.Add(ModelCard(m, current));
        if (_filter == "Cloud") list.Children.Insert(0, ApiKeysCard());
        if (_filter == "Custom") list.Children.Insert(0, CustomModelCard());

        Content = UiKit.Page(Loc.T("Models"), Loc.T("Choose how Zerm turns speech into text: on this PC (private, offline) or with a cloud provider."),
            currentCard, filters, list);
    }

    private static string WhisperRuntimeLabel(TranscriptionModel m) =>
        m.Provider == ModelProvider.Whisper
            ? (WhisperTranscriber.LoadedRuntime == "not loaded" ? Loc.T("GPU when available") : WhisperTranscriber.UsesGpu ? Loc.T("GPU") : Loc.T("CPU"))
            : Loc.T("CPU");

    private ComboBox LanguagePicker(TranscriptionModel? model)
    {
        // A fresh control per render: a WPF element can only have one parent.
        var _languageCombo = new ComboBox { Width = 260, DisplayMemberPath = "Label", SelectedValuePath = "Value" };
        var langs = (model?.SupportedLanguages ?? Languages.All).Keys
            .Select(code => new UiKit.ComboItem(code, code == "auto" ? Loc.T("Auto-detect") : Languages.DisplayName(code)))
            .OrderBy(i => (string)i.Value == "auto" ? "" : i.Label)
            .ToList();
        if (model?.IsHebrewOptimized == true && model.Provider == ModelProvider.Whisper)
            langs = langs.Where(l => (string)l.Value is "auto" or "he" or "en").ToList();
        _languageCombo.ItemsSource = langs;
        _languageCombo.SetBinding(System.Windows.Controls.Primitives.Selector.SelectedValueProperty, UiKit.Bind(_host.Settings, nameof(_host.Settings.SelectedLanguage)));
        if (_languageCombo.SelectedValue == null) _languageCombo.SelectedValue = "auto";
        return _languageCombo;
    }

    private Border ModelCard(TranscriptionModel m, TranscriptionModel? current)
    {
        var isCurrent = m.Name == current?.Name;
        var title = UiKit.HStack(UiKit.Text(m.DisplayName, 15, FontWeights.SemiBold).Margin(0, 0, 10, 0));
        if (isCurrent) title.Children.Add(UiKit.Pill(Loc.T("Default"), Color.FromRgb(0x32, 0xD7, 0x4B)));
        if (m.IsRecommended) title.Children.Add(UiKit.Pill(Loc.T("Recommended"), Color.FromRgb(0x0A, 0x84, 0xFF)));
        if (m.IsHebrewOptimized) title.Children.Add(UiKit.Pill(Loc.T("Hebrew"), Color.FromRgb(0xAF, 0x52, 0xDE)));
        title.Children.Add(UiKit.Pill(m.IsLocal ? Loc.T("Local") : m.ProviderKey, Color.FromRgb(0x8E, 0x8E, 0x93)));

        var info = UiKit.VStack(title, UiKit.Text(Loc.T(m.Description), 13, secondary: true).Margin(0, 4, 0, 4));
        if (m.IsLocal)
        {
            var specs = $"{ModelDownloads.Format(m.SizeBytes)} · {Loc.T("Accuracy")} {m.Accuracy * 100:F0}% · {Loc.T("Speed")} {m.Speed * 100:F0}% · ~{m.RamGb:F1} GB RAM";
            if (m.SupportedLanguages.Count(l => l.Key != "auto") == 1) specs += " · " + Loc.T("English only");
            info.Children.Add(UiKit.Caption(specs));
            if (m.License != null) info.Children.Add(UiKit.Caption($"{m.Creator} · {m.License}"));
        }

        var actions = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        var download = m.Download;
        var active = _host.Downloads.Get(m.Name);
        if (m.IsLocal && !m.IsDownloaded)
        {
            if (active != null)
            {
                var bar = new ProgressBar { Width = 160, Height = 6, Maximum = 1, VerticalAlignment = VerticalAlignment.Center };
                bar.SetBinding(System.Windows.Controls.Primitives.RangeBase.ValueProperty, new Binding(nameof(active.Progress)) { Source = active });
                var status = new TextBlock { FontSize = 11, Opacity = 0.7, Width = 200, TextTrimming = TextTrimming.CharacterEllipsis };
                status.SetBinding(TextBlock.TextProperty, new Binding(nameof(active.Status)) { Source = active });
                actions.Children.Add(UiKit.VStack(bar, status).Margin(0, 0, 8, 0));
                actions.Children.Add(UiKit.Button(Loc.T("Pause"), () => _host.Downloads.Cancel(m.Name), Icons.Pause));
            }
            else
            {
                var label = download != null && ModelDownloader.HasPartial(download) ? Loc.T("Resume") : Loc.T("Download");
                actions.Children.Add(UiKit.Button(label, () => StartDownload(m), Icons.Download, accent: true));
                if (download != null && ModelDownloader.HasPartial(download))
                    actions.Children.Add(UiKit.IconButton(Icons.Close, Loc.T("Cancel download"), () => { ModelDownloader.DeletePartial(download); Render(); }));
            }
        }
        else
        {
            if (!isCurrent)
            {
                var use = UiKit.Button(Loc.T("Set as Default"), () => SetDefault(m), Icons.Check, accent: true);
                use.IsEnabled = _host.IsUsable(m);
                if (!use.IsEnabled) use.ToolTip = Loc.F("Add an API key for {0} first.", m.ProviderKey);
                actions.Children.Add(use);
            }
            if (m.IsLocal)
                actions.Children.Add(UiKit.IconButton(Icons.Delete, Loc.T("Delete model"), () => DeleteModel(m)));
            if (m.Provider == ModelProvider.Custom)
                actions.Children.Add(UiKit.IconButton(Icons.Delete, Loc.T("Remove"), () =>
                {
                    _host.Library.CustomModels.RemoveAll(c => c.ToModel().Name == m.Name);
                    _host.Library.Save();
                    Render();
                }));
        }

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(info);
        Grid.SetColumn(actions, 1);
        grid.Children.Add(actions);
        var card = new Border { Child = grid }.Style("Card");
        if (isCurrent) card.BorderBrush = new SolidColorBrush(SystemColors.AccentColor);
        return card;
    }

    private void StartDownload(TranscriptionModel m)
    {
        if (m.Download is not { } spec) return;
        _host.Downloads.Start(m.Name, [spec], () =>
        {
            _host.Ui.Toast(Loc.F("{0} is ready", m.DisplayName), ToastKind.Success);
            if (!_host.IsUsable(_host.CurrentModel)) SetDefault(m);
            Render();
        });
        Render();
    }

    private void SetDefault(TranscriptionModel m)
    {
        _host.Settings.CurrentTranscriptionModel = m.Name;
        if (!m.SupportsLanguage(_host.Settings.SelectedLanguage)) _host.Settings.SelectedLanguage = "auto";
        if (m.IsLocal && m.Provider == ModelProvider.Whisper)
            _host.Ui.Toast(Loc.F("Preparing {0}… the first load can take a minute while the GPU warms up.", m.DisplayName), ToastKind.Info, TimeSpan.FromSeconds(4));
        Render();
    }

    private void DeleteModel(TranscriptionModel m)
    {
        if (!UiKit.Confirm(Loc.F("Delete {0}? You can download it again later.", m.DisplayName))) return;
        if (_host.Transcription.LoadedModel == m.Name) _host.Transcription.Unload();
        try
        {
            if (File.Exists(m.LocalPath)) File.Delete(m.LocalPath);
            if (Directory.Exists(m.LocalPath)) Directory.Delete(m.LocalPath, true);
        }
        catch (Exception ex)
        {
            _host.Ui.Toast(ex.Message, ToastKind.Error);
        }
        Render();
    }

    private Border ApiKeysCard()
    {
        var stack = new StackPanel();
        foreach (var provider in TranscriptionModelRegistry.Cloud.Select(m => m.Provider).Distinct())
            stack.Children.Add(ApiKeyRow(provider));
        return UiKit.Card(Loc.T("API Keys"), Loc.T("Keys are encrypted with your Windows account and never leave this PC except to call the provider."), stack);
    }

    private UIElement ApiKeyRow(ModelProvider provider)
    {
        var name = TranscriptionModelRegistry.Cloud.First(m => m.Provider == provider).ProviderKey;
        var has = !string.IsNullOrWhiteSpace(_host.Secrets.ApiKey(name));
        var box = new PasswordBox { Width = 240, ToolTip = Loc.T("Paste API key") };
        var status = new TextBlock { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 0, 0), FontSize = 12, Text = has ? "✓ " + Loc.T("Saved") : "" };
        status.Foreground = new SolidColorBrush(Color.FromRgb(0x32, 0xD7, 0x4B));
        var save = UiKit.Button(Loc.T("Save & Verify"), async () =>
        {
            var key = box.Password.Trim();
            if (key.Length == 0) return;
            status.Foreground = (Brush)Application.Current.FindResource("TextFillColorSecondaryBrush");
            status.Text = Loc.T("Verifying…");
            var (ok, message) = await CloudTranscription.VerifyKeyAsync(provider, key, CancellationToken.None);
            if (ok)
            {
                _host.Secrets.SetApiKey(name, key);
                box.Password = "";
            }
            status.Foreground = new SolidColorBrush(ok ? Color.FromRgb(0x32, 0xD7, 0x4B) : Color.FromRgb(0xFF, 0x45, 0x3A));
            status.Text = ok ? "✓ " + Loc.T("Key verified") : message;
        });
        var row = UiKit.HStack(box, save.Margin(8, 0, 0, 0), status);
        if (has) row.Children.Insert(2, UiKit.IconButton(Icons.Delete, Loc.T("Remove key"), () => _host.Secrets.SetApiKey(name, null)));
        return UiKit.Row(name, row);
    }

    private Border CustomModelCard()
    {
        var display = new TextBox { Width = 260 };
        var endpoint = new TextBox { Width = 360, Text = "https://api.together.ai/v1/audio/transcriptions" };
        var modelId = new TextBox { Width = 260, Text = "openai/whisper-large-v3" };
        var key = new PasswordBox { Width = 260 };
        var multilingual = new CheckBox { Content = Loc.T("Multilingual"), IsChecked = true };
        var status = UiKit.Caption("");
        var presets = UiKit.Combo(
            [("together", "Together AI"), ("deepinfra", "DeepInfra"), ("openrouter", "OpenRouter"), ("groq", "Groq")], "together", p =>
            {
                (endpoint.Text, modelId.Text) = p switch
                {
                    "deepinfra" => ("https://api.deepinfra.com/v1/audio/transcriptions", "openai/whisper-large-v3-turbo"),
                    "openrouter" => ("https://openrouter.ai/api/v1/audio/transcriptions", "openai/whisper-large-v3"),
                    "groq" => ("https://api.groq.com/openai/v1/audio/transcriptions", "whisper-large-v3-turbo"),
                    _ => ("https://api.together.ai/v1/audio/transcriptions", "openai/whisper-large-v3"),
                };
            }, 200);
        var add = UiKit.Button(Loc.T("Verify & Add"), async () =>
        {
            if (string.IsNullOrWhiteSpace(display.Text) || !Uri.TryCreate(endpoint.Text.Trim(), UriKind.Absolute, out _) || string.IsNullOrWhiteSpace(modelId.Text))
            {
                status.Text = Loc.T("Fill in a name, a valid endpoint URL and a model ID.");
                return;
            }
            status.Text = Loc.T("Verifying…");
            var (ok, message) = await CloudTranscription.VerifyCustomEndpointAsync(endpoint.Text.Trim(), modelId.Text.Trim(), key.Password.Trim(), CancellationToken.None);
            if (!ok)
            {
                status.Text = message;
                return;
            }
            var custom = new CustomCloudModel
            {
                DisplayName = display.Text.Trim(), Endpoint = endpoint.Text.Trim(), ModelId = modelId.Text.Trim(),
                IsMultilingual = multilingual.IsChecked == true, Verified = true,
            };
            _host.Library.CustomModels.Add(custom);
            _host.Library.Save();
            if (key.Password.Trim().Length > 0) _host.Secrets.Set(custom.ApiKeyId, key.Password.Trim());
            _host.Ui.Toast(Loc.F("{0} added", custom.DisplayName), ToastKind.Success);
            Render();
        }, Icons.Add, accent: true);
        return UiKit.Card(Loc.T("Add Custom Model"), Loc.T("Any OpenAI-compatible /audio/transcriptions endpoint. Zerm sends a one-second test tone to verify it."),
            UiKit.Row(Loc.T("Preset"), presets),
            UiKit.Row(Loc.T("Name"), display),
            UiKit.Row(Loc.T("Endpoint"), endpoint),
            UiKit.Row(Loc.T("Model ID"), modelId),
            UiKit.Row(Loc.T("API key"), key),
            UiKit.Row(Loc.T("Languages"), multilingual),
            UiKit.HStack(add, status.VCenter()));
    }
}
