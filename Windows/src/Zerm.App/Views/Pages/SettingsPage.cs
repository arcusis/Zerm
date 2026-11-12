using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;
using Zerm.App.Localization;
using Zerm.App.Platform;
using Zerm.Core;
using Zerm.Core.Data;
using Zerm.Core.Dictation;
using Zerm.Core.Prompts;
using Zerm.Core.Settings;
using Zerm.Core.Text;

namespace Zerm.App.Views.Pages;

/// <summary>Port of SettingsView.swift (General, Shortcuts, Recording, Text, Storage, Diagnostics, About).</summary>
public sealed class SettingsPage : ContentControl
{
    private readonly AppHost _host = AppHost.Current;

    public SettingsPage() => Render();

    private static IEnumerable<(HotkeyMode, string)> Modes =>
        [(HotkeyMode.Toggle, Loc.T("Toggle")), (HotkeyMode.PushToTalk, Loc.T("Push to Talk")), (HotkeyMode.Hybrid, Loc.T("Hybrid"))];

    private void Render()
    {
        var s = _host.Settings;

        var general = UiKit.Card(Loc.T("General"),
            UiKit.Row(Loc.T("Language"), UiKit.Combo([("system", Loc.T("System")), ("en", "English"), ("he", "עברית")], s.UiLanguage, v =>
            {
                s.UiLanguage = v;
                s.SaveNow();
                if (UiKit.Confirm(Loc.T("Restart Zerm now to change the language?"))) Restart();
            }, 200)),
            UiKit.Row(Loc.T("Launch at login"), Toggle(s.LaunchAtLogin, v => { s.LaunchAtLogin = v; LaunchAtLogin.Sync(v); })),
            UiKit.Row(Loc.T("Start in the background"), UiKit.Toggle(s, nameof(s.StartMinimized)), Loc.T("Open to the system tray instead of showing this window.")),
            UiKit.Row(Loc.T("Onboarding"), UiKit.Button(Loc.T("Show Again"), () => new OnboardingWindow().Show())),
            InstallRow());

        var shortcuts = UiKit.Card(Loc.T("Shortcuts"), Loc.T("Toggle: press to start, press again to stop. Push to Talk: hold while speaking. Hybrid: tap for hands-free, hold for push-to-talk."),
            HotkeyRow(Loc.T("Shortcut 1"), nameof(s.Hotkey1), nameof(s.Hotkey1Custom), nameof(s.HotkeyMode1)),
            HotkeyRow(Loc.T("Shortcut 2"), nameof(s.Hotkey2), nameof(s.Hotkey2Custom), nameof(s.HotkeyMode2)),
            UiKit.Divider(),
            UiKit.Row(Loc.T("Paste Last Transcription (Original)"), new ShortcutRecorder(s.PasteLastTranscriptionShortcut, c => s.PasteLastTranscriptionShortcut = c ?? KeyCombo.Empty)),
            UiKit.Row(Loc.T("Paste Last Transcription (Enhanced)"), new ShortcutRecorder(s.PasteLastEnhancementShortcut, c => s.PasteLastEnhancementShortcut = c ?? KeyCombo.Empty)),
            UiKit.Row(Loc.T("Retry Last Transcription"), new ShortcutRecorder(s.RetryLastTranscriptionShortcut, c => s.RetryLastTranscriptionShortcut = c ?? KeyCombo.Empty),
                Loc.T("The result is copied to the clipboard.")),
            UiKit.Row(Loc.T("Custom Cancel Shortcut"), new ShortcutRecorder(s.CancelShortcut, c => s.CancelShortcut = c ?? KeyCombo.Empty),
                Loc.T("Cancels with a single press. When empty, press Esc twice.")),
            UiKit.Row(Loc.T("Middle-Click Recording"), UiKit.Toggle(s, nameof(s.MiddleClickToggleEnabled)), Loc.T("Hold the middle mouse button to toggle the recorder.")),
            UiKit.Row(Loc.T("Activation Delay"), UiKit.SliderWithValue(s, nameof(s.MiddleClickActivationDelayMs), 0, 1000, 50, "{0} ms")),
            UiKit.Caption(Loc.T("While recording: Ctrl+E turns AI on or off, Ctrl+1…0 picks a prompt, Alt+1…0 picks a Power Mode.")));

        var paste = UiKit.Card(Loc.T("Paste Options"),
            UiKit.Row(Loc.T("Add a space after pasted text"), UiKit.Toggle(s, nameof(s.AppendTrailingSpace))),
            UiKit.Row(Loc.T("Restore Clipboard After Paste"), UiKit.Toggle(s, nameof(s.RestoreClipboardAfterPaste)), Loc.T("Puts back what you had copied. Dictated text never appears in Windows clipboard history (Win+V).")),
            UiKit.Row(Loc.T("Restore Delay"), UiKit.Combo([(0.25, "250 ms"), (0.5, "500 ms"), (1.0, "1 s"), (2.0, "2 s"), (3.0, "3 s"), (4.0, "4 s"), (5.0, "5 s")],
                s, nameof(s.ClipboardRestoreDelay), 120)));

        var recording = UiKit.Card(Loc.T("Recording"),
            UiKit.Row(Loc.T("Stop automatically after silence"), UiKit.Toggle(s, nameof(s.AutoStopAfterSilence))),
            UiKit.Row(Loc.T("Silence before stopping"), UiKit.SliderWithValue(s, nameof(s.AutoStopSilenceSeconds), 0.6, 8, 0.1, "{0:F1} s")),
            UiKit.Row(Loc.T("Stop if no speech within"), UiKit.SliderWithValue(s, nameof(s.AutoStopInitialSilenceSeconds), 2, 20, 0.5, "{0:F1} s")),
            UiKit.Row(Loc.T("Speech level threshold"), UiKit.SliderWithValue(s, nameof(s.AutoStopLevelThreshold), 0.02, 0.5, 0.01, "{0:F2}")),
            UiKit.Row(Loc.T("Voice activity detection"), UiKit.Toggle(s, nameof(s.VadEnabled)), Loc.T("Skips silence before local transcription to avoid hallucinated text.")));

        var text = UiKit.Card(Loc.T("Text"),
            UiKit.Row(Loc.T("Text Formatting"), UiKit.Toggle(s, nameof(s.TextFormattingEnabled)), Loc.T("Splits long dictations into paragraphs.")),
            UiKit.Row(Loc.T("Punctuation"), UiKit.Combo([(PunctuationCleanupMode.Keep, Loc.T("Keep")), (PunctuationCleanupMode.RemoveAll, Loc.T("Remove all")), (PunctuationCleanupMode.RemoveTrailingPeriod, Loc.T("Remove trailing period"))],
                s, nameof(s.PunctuationCleanupMode), 220)),
            UiKit.Row(Loc.T("Lowercase"), UiKit.Toggle(s, nameof(s.LowercaseTranscription))),
            UiKit.Caption(Loc.T("Spoken commands always work: \"new line\", \"new paragraph\", \"comma\", \"period\", \"question mark\", \"scratch that\" and more.")));

        var storage = UiKit.Card(Loc.T("Storage"),
            UiKit.Row(Loc.T("Storage Usage"), UiKit.Text(StorageSummary(), 13, secondary: true)),
            UiKit.Row(Loc.T("Auto-delete Transcripts"), UiKit.Toggle(s, nameof(s.TranscriptionCleanupEnabled))),
            UiKit.Row(Loc.T("Delete After"), UiKit.Combo([(1, Loc.T("Immediately")), (60, Loc.T("1 hour")), (1440, Loc.T("1 day")), (4320, Loc.T("3 days")), (10080, Loc.T("7 days")), (20160, Loc.T("14 days")), (43200, Loc.T("30 days"))],
                s, nameof(s.TranscriptionRetentionMinutes), 160)),
            UiKit.Row(Loc.T("Auto-delete Audio Files"), UiKit.Toggle(s, nameof(s.AudioCleanupEnabled))),
            UiKit.Row(Loc.T("Keep Audio For"), UiKit.Combo([(1, Loc.T("1 day")), (3, Loc.T("3 days")), (7, Loc.T("7 days")), (14, Loc.T("14 days")), (30, Loc.T("30 days")), (90, Loc.T("90 days"))],
                s, nameof(s.AudioRetentionDays), 160)),
            UiKit.Wrap(
                UiKit.Button(Loc.T("Run Cleanup Now"), () =>
                {
                    var (t, a) = _host.History.Cleanup(s.TranscriptionCleanupEnabled ? s.TranscriptionRetentionMinutes : null, s.AudioCleanupEnabled ? s.AudioRetentionDays : null);
                    _host.Ui.Toast(Loc.F("Removed {0} transcripts and {1} audio files", t, a), ToastKind.Success);
                    Render();
                }),
                UiKit.Button(Loc.T("Reset Statistics"), () => { if (UiKit.Confirm(Loc.T("Reset all dashboard statistics?"))) _host.History.ResetUsage(); }),
                UiKit.Button(Loc.T("Export Settings"), ExportSettings, Icons.Export),
                UiKit.Button(Loc.T("Import Settings"), ImportSettings, Icons.Folder),
                UiKit.Button(Loc.T("Open Data Folder"), () => DictationController.OpenUri(AppPaths.Root), Icons.Folder)));

        var diagnostics = UiKit.Card(Loc.T("Diagnostics"),
            UiKit.Row(Loc.T("Debug Logging"), UiKit.Toggle(s, nameof(s.DebugLoggingEnabled))),
            UiKit.Row(Loc.T("Whisper runtime"), UiKit.Text(Core.Transcription.WhisperTranscriber.LoadedRuntime, 13, secondary: true)),
            UiKit.HStack(UiKit.Button(Loc.T("Open Logs"), () => DictationController.OpenUri(AppPaths.Logs), Icons.Folder)));

        var about = UiKit.Card(Loc.T("About"),
            UiKit.Text($"Zerm for Windows {typeof(App).Assembly.GetName().Version?.ToString(3)}", 14, FontWeights.SemiBold),
            UiKit.Caption(Loc.T("Zerm is based on the open-source project VoiceInk by Beingpax and is distributed under the GNU GPLv3.")),
            UiKit.Caption("Whisper (whisper.cpp), sherpa-onnx, llama.cpp, NAudio — see NOTICE for model licenses."),
            UiKit.HStack(UiKit.Button(Loc.T("Website"), () => DictationController.OpenUri("https://arcusis.github.io/Zerm/")),
                UiKit.Button("GitHub", () => DictationController.OpenUri("https://github.com/arcusis/Zerm"))).Margin(0, 8, 0, 0));

        Content = UiKit.Page(Loc.T("Settings"), null, general, shortcuts, paste, recording, text, storage, diagnostics, about);
    }

    private static UIElement InstallRow()
    {
        if (Installer.IsRunningInstalled)
            return UiKit.Row(Loc.T("Installation"),
                UiKit.Button(Loc.T("Uninstall…"), () => System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(Installer.InstalledExe, "--uninstall") { UseShellExecute = false }), Icons.Delete),
                Loc.T("Installed — Zerm appears in the Start menu, Windows Search and Settings › Apps."));
        return UiKit.Row(Loc.T("Installation"),
            UiKit.Button(Loc.T("Install Zerm"), () => ((App)Application.Current).InstallAndRelaunch(), Icons.Download, accent: true),
            Loc.T("Adds Zerm to the Start menu and Windows Search, and to Settings › Apps for uninstalling."));
    }

    private static CheckBox Toggle(bool value, Action<bool> set)
    {
        var cb = new CheckBox { IsChecked = value, MinWidth = 0 };
        cb.Click += (_, _) => set(cb.IsChecked == true);
        return cb;
    }

    private UIElement HotkeyRow(string label, string keyProp, string customProp, string modeProp)
    {
        var s = _host.Settings;
        var key = (TriggerKey)typeof(AppSettings).GetProperty(keyProp)!.GetValue(s)!;
        var custom = (KeyCombo)typeof(AppSettings).GetProperty(customProp)!.GetValue(s)!;
        var picker = UiKit.Combo(VoicesPage.TriggerChoices(custom), key, v => { typeof(AppSettings).GetProperty(keyProp)!.SetValue(s, v); Render(); }, 200);
        var mode = UiKit.Combo(Modes, s, modeProp, 150);
        var row = UiKit.HStack(picker, mode.Margin(8, 0, 0, 0));
        if (key == TriggerKey.Custom)
            row.Children.Add(new ShortcutRecorder(custom, c => typeof(AppSettings).GetProperty(customProp)!.SetValue(s, c ?? KeyCombo.Empty), false).Margin(8, 0, 0, 0));
        return UiKit.Row(label, row, key is TriggerKey.RightAlt ? Loc.T("On some keyboard layouts Right Alt is AltGr.") : null);
    }

    private static string StorageSummary()
    {
        try
        {
            var files = Directory.GetFiles(AppPaths.Recordings, "*.wav");
            var bytes = files.Sum(f => new FileInfo(f).Length);
            var models = Directory.GetFiles(AppPaths.Root, "*", SearchOption.AllDirectories).Where(f => !f.StartsWith(AppPaths.Recordings)).Sum(f => new FileInfo(f).Length);
            return Loc.F("{0} recordings ({1}) · models and data {2}", files.Length, ModelDownloads.Format(bytes), ModelDownloads.Format(models));
        }
        catch
        {
            return "";
        }
    }

    /// <summary>Settings backup (ImportExportService.swift): settings, prompts, Power Modes, dictionary, custom models — no API keys.</summary>
    private void ExportSettings()
    {
        var dialog = new SaveFileDialog { FileName = $"Zerm Settings {DateTime.Now:yyyy-MM-dd}.json", Filter = "JSON|*.json" };
        if (dialog.ShowDialog() != true) return;
        var lib = _host.Library;
        var doc = new JsonObject
        {
            ["version"] = typeof(App).Assembly.GetName().Version?.ToString(3),
            ["platform"] = "windows",
            ["customPrompts"] = JsonSerializer.SerializeToNode(lib.Prompts.Where(p => !p.IsPredefined), Library.JsonOptions),
            ["powerModeConfigs"] = JsonSerializer.SerializeToNode(lib.PowerModes, Library.JsonOptions),
            ["vocabularyWords"] = new JsonArray(lib.Vocabulary.Select(v => (JsonNode)new JsonObject { ["word"] = v.Word }).ToArray()),
            ["wordReplacements"] = new JsonObject(lib.Replacements.Select(r => KeyValuePair.Create(r.OriginalText, (JsonNode?)r.ReplacementText))),
            ["customCloudModels"] = JsonSerializer.SerializeToNode(lib.CustomModels, Library.JsonOptions),
            ["generalSettings"] = JsonSerializer.SerializeToNode(_host.Settings, AppSettings.JsonOptions),
        };
        File.WriteAllText(dialog.FileName, doc.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
        _host.Ui.Toast(Loc.T("Settings exported"), ToastKind.Success);
    }

    private void ImportSettings()
    {
        var dialog = new OpenFileDialog { Filter = "JSON|*.json" };
        if (dialog.ShowDialog() != true) return;
        try
        {
            var doc = JsonNode.Parse(File.ReadAllText(dialog.FileName))!;
            var lib = _host.Library;
            if (doc["customPrompts"] is JsonArray prompts)
                foreach (var p in prompts.Deserialize<List<CustomPrompt>>(Library.JsonOptions) ?? [])
                    if (!p.IsPredefined && lib.Prompts.All(x => x.Id != p.Id)) lib.Prompts.Add(p);
            if (doc["powerModeConfigs"] is JsonArray modes)
                foreach (var m in modes.Deserialize<List<PowerModeConfig>>(Library.JsonOptions) ?? [])
                {
                    // macOS exports bind apps by bundle id; those entries simply never match on Windows.
                    var i = lib.PowerModes.FindIndex(x => x.Id == m.Id);
                    if (i >= 0) lib.PowerModes[i] = m;
                    else lib.PowerModes.Add(m);
                }
            if (doc["vocabularyWords"] is JsonArray words)
                foreach (var w in words)
                    if (w?["word"]?.GetValue<string>() is { } word && lib.Vocabulary.All(v => !v.Word.Equals(word, StringComparison.OrdinalIgnoreCase)))
                        lib.Vocabulary.Add(new VocabularyWord { Word = word });
            if (doc["wordReplacements"] is JsonObject reps)
                foreach (var (original, replacement) in reps)
                    lib.AddReplacement(original, replacement?.GetValue<string>() ?? "");
            if (doc["customCloudModels"] is JsonArray custom)
                foreach (var c in custom.Deserialize<List<CustomCloudModel>>(Library.JsonOptions) ?? [])
                    if (lib.CustomModels.All(x => x.Id != c.Id)) lib.CustomModels.Add(c);
            lib.Save();
            if (doc["generalSettings"] is JsonObject general && doc["platform"]?.GetValue<string>() == "windows")
            {
                var imported = general.Deserialize<AppSettings>(AppSettings.JsonOptions);
                if (imported != null)
                {
                    File.WriteAllText(AppPaths.SettingsFile, general.ToJsonString());
                    if (UiKit.Confirm(Loc.T("Settings imported. Restart Zerm now to apply them?"))) { Restart(); return; }
                }
            }
            _host.Ui.Toast(Loc.T("Settings imported"), ToastKind.Success);
            Render();
        }
        catch (Exception ex)
        {
            _host.Ui.Toast(Loc.T("Import failed") + ": " + ex.Message, ToastKind.Error);
        }
    }

    private static void Restart()
    {
        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(Environment.ProcessPath!, "--show --restarted") { UseShellExecute = false });
        ((App)Application.Current).Quit();
    }
}
