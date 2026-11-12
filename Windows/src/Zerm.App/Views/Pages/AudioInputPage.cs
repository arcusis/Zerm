using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Microsoft.Win32;
using Zerm.App.Localization;
using Zerm.App.Platform;
using Zerm.Core;
using Zerm.Core.Dictation;

namespace Zerm.App.Views.Pages;

/// <summary>Port of AudioInputSettingsView + MicTestView + recording feedback settings.</summary>
public sealed class AudioInputPage : ContentControl
{
    private readonly AppHost _host = AppHost.Current;
    private readonly AudioRecorder _test = new();
    private DispatcherTimer? _meterTimer;

    public AudioInputPage()
    {
        Render();
        Unloaded += (_, _) => StopTest();
    }

    private void Render()
    {
        var s = _host.Settings;
        var devices = new StackPanel();
        List<AudioDevice> list;
        try { list = AudioRecorder.InputDevices(); }
        catch (Exception ex) { list = []; Log.Error("Device enumeration failed", ex); }
        var useDefault = new RadioButton { GroupName = "mic", Content = Loc.T("System default microphone"), IsChecked = string.IsNullOrEmpty(s.InputDeviceId), Margin = new Thickness(0, 3, 0, 3) };
        useDefault.Checked += (_, _) => s.InputDeviceId = null;
        devices.Children.Add(useDefault);
        foreach (var d in list)
        {
            var rb = new RadioButton
            {
                GroupName = "mic", Content = d.Name + (d.IsDefault ? $"  ({Loc.T("default")})" : ""), IsChecked = s.InputDeviceId == d.Id, Margin = new Thickness(0, 3, 0, 3),
            };
            var id = d.Id;
            rb.Checked += (_, _) => s.InputDeviceId = id;
            devices.Children.Add(rb);
        }
        if (list.Count == 0) devices.Children.Add(UiKit.Caption(Loc.T("No microphones found. Check that one is connected and allowed in Windows privacy settings.")));
        var mic = UiKit.Card(Loc.T("Microphone"), devices,
            UiKit.HStack(UiKit.Button(Loc.T("Refresh"), Render, Icons.Retry),
                UiKit.Button(Loc.T("Microphone Privacy Settings"), () => DictationController.OpenUri("ms-settings:privacy-microphone"), Icons.Shield)).Margin(0, 10, 0, 0));

        var meter = new ProgressBar { Height = 10, Maximum = 1, Width = 320, HorizontalAlignment = HorizontalAlignment.Left };
        var testLabel = UiKit.Caption(Loc.T("Speak to see the level."));
        var testButton = UiKit.Button(Loc.T("Test Microphone"), () => { }, Icons.Mic);
        testButton.Click += async (_, _) =>
        {
            if (_meterTimer != null)
            {
                StopTest();
                testButton.Content = Loc.T("Test Microphone");
                return;
            }
            try
            {
                var id = s.InputDeviceId;
                var opening = Task.Run(() => _test.Start(id));
                if (await Task.WhenAny(opening, Task.Delay(5000)) != opening)
                    throw new TimeoutException(Loc.T("The microphone is not responding. Unplug and reconnect it, or pick another one in Audio Input."));
                await opening;
                testLabel.Text = Loc.F("Listening on {0}", _test.DeviceName ?? "");
                testButton.Content = Loc.T("Stop Test");
                _meterTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(33) };
                _meterTimer.Tick += (_, _) => meter.Value = Math.Max(_test.Level, _test.PeakLevel * 0.65);
                _meterTimer.Start();
            }
            catch (Exception ex)
            {
                testLabel.Text = ex.Message;
            }
        };
        var test = UiKit.Card(Loc.T("Microphone Test"), UiKit.HStack(testButton), meter.Margin(0, 10, 0, 4), testLabel);

        var custom = UiKit.VStack(
            SoundRow(Loc.T("Start sound"), s.CustomStartSound, v => s.CustomStartSound = v),
            SoundRow(Loc.T("Stop sound"), s.CustomStopSound, v => s.CustomStopSound = v));
        var feedback = UiKit.Card(Loc.T("Recording Feedback"),
            UiKit.Row(Loc.T("Sound feedback"), UiKit.Toggle(s, nameof(s.SoundFeedbackEnabled)), Loc.T("Play a sound when recording starts and when text is pasted.")),
            custom,
            UiKit.Divider(),
            UiKit.Row(Loc.T("Mute audio while recording"), UiKit.Toggle(s, nameof(s.SystemMuteEnabled)), Loc.T("Silences music and videos so they don't end up in your dictation.")),
            UiKit.Row(Loc.T("Keep playing on headphones"), UiKit.Toggle(s, nameof(s.SkipMuteWithHeadphones)), Loc.T("Don't mute when the output is a headset or headphones.")),
            UiKit.Row(Loc.T("Resume delay"), UiKit.SliderWithValue(s, nameof(s.AudioResumptionDelay), 0, 5, 0.5, "{0:F1} s")));

        Content = UiKit.Page(Loc.T("Audio Input"), Loc.T("Choose the microphone Zerm records from and how recording sounds."), mic, test, feedback);
    }

    private UIElement SoundRow(string label, string? current, Action<string?> set)
    {
        var name = UiKit.Caption(current == null ? Loc.T("Default") : Path.GetFileName(current)).VCenter().Margin(0, 0, 10, 0);
        var choose = UiKit.Button(Loc.T("Choose…"), () =>
        {
            var dialog = new OpenFileDialog { Filter = Loc.T("Audio") + "|*.wav;*.mp3;*.m4a;*.aiff;*.wma" };
            if (dialog.ShowDialog() != true) return;
            if (SoundPlayer.ValidateCustomSound(dialog.FileName) is { } error)
            {
                _host.Ui.Toast(Loc.T(error), ToastKind.Warning);
                return;
            }
            var dest = Path.Combine(AppPaths.CustomSounds, Guid.NewGuid().ToString("N")[..8] + Path.GetExtension(dialog.FileName));
            File.Copy(dialog.FileName, dest, true);
            set(dest);
            Render();
        });
        var reset = UiKit.IconButton(Icons.Retry, Loc.T("Use default"), () => { set(null); Render(); });
        return UiKit.Row(label, UiKit.HStack(name, choose, reset));
    }

    private void StopTest()
    {
        _meterTimer?.Stop();
        _meterTimer = null;
        _ = Task.Run(_test.Stop);
    }
}
