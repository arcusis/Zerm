using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Zerm.App.Platform;
using Zerm.Core;
using Zerm.Core.Dictation;
using Zerm.Core.Settings;

namespace Zerm.App.Views;

/// <summary>
/// "Zerm.exe --selftest &lt;report.txt&gt; &lt;speech.wav&gt;": end-to-end checks run inside Zerm's own process.
/// A test window with a text box takes focus; dictation is triggered through the real hotkey logic
/// (simulated key events, nothing injected into the OS input stream), the recorder streams the given
/// WAV instead of the microphone, and the pasted text is read back from the text box.
/// </summary>
public static class SelfTest
{
    public static async Task RunAsync(string report, string speechWav)
    {
        var lines = new List<string>();
        void Report(string line)
        {
            lines.Add(line);
            Log.Info("SELFTEST " + line);
        }

        var host = AppHost.Current;
        Report($"hook installed on dedicated thread: {host.Hotkeys.Install()}");
        // Real microphone path (WASAPI), independent of the simulated audio used below.
        try
        {
            var devices = AudioRecorder.InputDevices();
            using var mic = new AudioRecorder();
            var opening = Task.Run(() => mic.Start(null));
            if (await Task.WhenAny(opening, Task.Delay(5000)) != opening) throw new TimeoutException("the microphone driver is not responding");
            await opening;
            await Task.Delay(1500);
            var captured = await Task.Run(mic.Stop);
            Report($"[microphone] devices={devices.Count} default={devices.FirstOrDefault(d => d.IsDefault)?.Name} device={mic.DeviceName} captured={Core.Audio.AudioUtil.DurationSeconds(captured.Length):F2}s callbacks={(DateTime.Now - mic.LastCallback).TotalSeconds < 2}");
        }
        catch (Exception ex)
        {
            Report("[microphone] FAILED " + ex.Message);
        }

        Environment.SetEnvironmentVariable("ZERM_TEST_AUDIO_FILE", speechWav);
        var box = new TextBox { AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, FontSize = 16 };
        var window = new Window { Title = "Zerm Self-Test", Width = 640, Height = 260, Content = box, WindowStartupLocation = WindowStartupLocation.CenterScreen, Topmost = true };
        window.Show();
        window.Activate();
        box.Focus();
        await Wait(800);
        Report($"foreground is test window: {Native.GetForegroundWindow() == new System.Windows.Interop.WindowInteropHelper(window).Handle}");
        Report($"model: {host.Settings.CurrentTranscriptionModel}, usable: {host.IsUsable(host.CurrentModel)}");
        var sw = Stopwatch.StartNew();
        await host.PrewarmAsync();
        Report($"prewarm: {sw.ElapsedMilliseconds} ms, runtime {Core.Transcription.WhisperTranscriber.LoadedRuntime}");
        host.Settings.OutputMode = DictationOutputMode.Enhanced;
        host.Settings.SelectedAIProvider = Core.Enhancement.AIProviders.OnDevice;
        sw.Restart();
        await host.PrewarmLlmAsync();
        Report($"llm warm-up: {sw.ElapsedMilliseconds} ms");

        var hwnd = new System.Windows.Interop.WindowInteropHelper(window).Handle;
        async Task<string> Dictate(string label, HotkeyMode mode, bool hold)
        {
            box.Clear();
            window.Activate();
            box.Focus();
            await Wait(300);
            // Never paste into whatever app the user is working in.
            if (Native.GetForegroundWindow() != hwnd)
            {
                Report($"[{label}] SKIPPED — the test window is not in the foreground");
                return "";
            }
            host.Settings.HotkeyMode1 = mode;
            var timer = Stopwatch.StartNew();
            if (!hold)
            {
                await Task.Run(() =>
                {
                    host.Hotkeys.Simulate(Native.VK_RCONTROL, down: true);
                    Thread.Sleep(120);
                    host.Hotkeys.Simulate(Native.VK_RCONTROL, down: false);
                });
            }
            else host.Hotkeys.Simulate(Native.VK_RCONTROL, down: true);
            if (hold)
            {
                await WaitFor(() => host.Dictation.State == RecorderState.Recording, 5000);
                await Task.Delay(TimeSpan.FromSeconds(Core.Audio.AudioUtil.DurationSeconds(Core.Audio.AudioUtil.LoadAs16kMono(speechWav).Length) + 0.3));
                host.Hotkeys.Simulate(Native.VK_RCONTROL, down: false);
            }
            var started = await WaitFor(() => host.Dictation.State == RecorderState.Recording, 5000);
            var finished = await WaitFor(() => !host.Dictation.RecorderVisible && host.Dictation.State == RecorderState.Idle, 60000);
            await Wait(600);
            Report($"[{label}] started={started} finished={finished} total={timer.ElapsedMilliseconds} ms text=[{box.Text}]");
            return box.Text;
        }

        try
        {
            host.Settings.OutputMode = DictationOutputMode.Instant;
            await Dictate("instant/hybrid-tap (auto-stop)", HotkeyMode.Hybrid, hold: false);
            await Dictate("instant/push-to-talk", HotkeyMode.PushToTalk, hold: true);

            host.Settings.OutputMode = DictationOutputMode.Enhanced;
            host.Settings.SelectedAIProvider = Core.Enhancement.AIProviders.OnDevice;
            await Dictate("enhanced/on-device", HotkeyMode.Toggle, hold: false);

            host.Settings.OutputMode = DictationOutputMode.InstantRefine;
            await Dictate("instant+refine", HotkeyMode.Hybrid, hold: false);
            await Wait(9000);
            Report($"[instant+refine] after refine text=[{box.Text}]");
            var last = host.History.Latest();
            Report($"[instant+refine] history enhanced=[{last?.EnhancedText}] outcome={last?.EnhancementOutcome}");

            // Power Mode: an app-specific mode (this process) switches prompt, punctuation and lowercase.
            var pm = new Core.Data.PowerModeConfig
            {
                Name = "SelfTest", Emoji = "🧪", AppConfigs = [new() { ProcessName = "Zerm", AppName = "Zerm" }],
                OutputMode = DictationOutputMode.Instant, Lowercase = true, PunctuationCleanup = Core.Text.PunctuationCleanupMode.RemoveTrailingPeriod,
            };
            host.Library.SavePowerMode(pm);
            host.Settings.PowerModeEnabled = true;
            await Dictate("power-mode (lowercase, no trailing period)", HotkeyMode.Hybrid, hold: false);
            Report($"[power-mode] history powerMode={host.History.Latest()?.PowerModeName}");
            host.Library.PowerModes.Remove(pm);
            host.Library.Save();

            // File transcription with speaker identification through the app's queue.
            var job = host.FileTranscription.Enqueue(speechWav, host.Settings.CurrentTranscriptionModel, true, null, null);
            var fileDone = await WaitFor(() => !job.IsActive, 120000);
            Report($"[file] done={fileDone} status={job.Status} speakers={job.Transcript?.Speakers.Count()} warning={job.Warning} text=[{job.Transcript?.PlainText}]");

            // Super Enhancement on messy speech, verified through History with pasting disabled.
            {
                var voices = new Core.TextToSpeech.WindowsVoicesProvider();
                var messy = await voices.SynthesizeAsync(
                    "so the the deploy is is done I mean almost done we just need the the migration from Dana and yesterday no wait the day before yesterday the server crashed twice",
                    voices.Voices[0].Id, 1.0, CancellationToken.None);
                var messyPath = Path.Combine(Path.GetTempPath(), "zerm-selftest-messy.wav");
                var resampled = Core.Audio.AudioUtil.ToMono16k(new NAudio.Wave.SampleProviders.WdlResamplingSampleProvider(
                    new PcmProvider(messy), Core.Audio.AudioUtil.SampleRate));
                Core.Audio.AudioUtil.WriteWav16k(messyPath, resampled);
                Environment.SetEnvironmentVariable("ZERM_TEST_AUDIO_FILE", messyPath);
                Environment.SetEnvironmentVariable("ZERM_TEST_NO_PASTE", "1");
                host.Settings.OutputMode = DictationOutputMode.Enhanced;
                host.Settings.SuperEnhancement = true;
                host.Settings.PowerModeEnabled = false;
                await host.PrewarmLlmAsync();
                var t = Stopwatch.StartNew();
                await Task.Run(() =>
                {
                    host.Hotkeys.Simulate(Native.VK_RCONTROL, down: true);
                    Thread.Sleep(120);
                    host.Hotkeys.Simulate(Native.VK_RCONTROL, down: false);
                });
                await WaitFor(() => host.Dictation.State == RecorderState.Recording, 5000);
                await WaitFor(() => !host.Dictation.RecorderVisible && host.Dictation.State == RecorderState.Idle, 90000);
                var rec = host.History.Latest();
                Report($"[super] {t.ElapsedMilliseconds} ms prompt={rec?.PromptName} ai={rec?.AiEnhancementModelName} outcome={rec?.EnhancementOutcome}");
                Report($"[super] raw      = {rec?.Text}");
                Report($"[super] enhanced = {rec?.EnhancedText}");
                host.Settings.SuperEnhancement = false;
                host.Settings.PowerModeEnabled = true;
                Environment.SetEnvironmentVariable("ZERM_TEST_NO_PASTE", null);
                Environment.SetEnvironmentVariable("ZERM_TEST_AUDIO_FILE", speechWav);
            }

            // Escape twice cancels a recording.
            host.Settings.OutputMode = DictationOutputMode.Instant;
            host.Settings.HotkeyMode1 = HotkeyMode.Hybrid;
            box.Clear();
            host.Hotkeys.Simulate(Native.VK_RCONTROL, true);
            host.Hotkeys.Simulate(Native.VK_RCONTROL, false);
            await WaitFor(() => host.Dictation.State == RecorderState.Recording, 5000);
            await Task.Delay(500);
            host.Hotkeys.Simulate(Native.VK_ESCAPE, true);
            host.Hotkeys.Simulate(Native.VK_ESCAPE, false);
            await Task.Delay(300);
            host.Hotkeys.Simulate(Native.VK_ESCAPE, true);
            host.Hotkeys.Simulate(Native.VK_ESCAPE, false);
            var cancelled = await WaitFor(() => !host.Dictation.RecorderVisible, 3000);
            await Wait(500);
            Report($"[double-esc] cancelled={cancelled} text=[{box.Text}] lastRow={host.History.Query(limit: 1).FirstOrDefault()?.Status}");

            // Paste last transcription shortcut.
            box.Clear();
            if (Native.GetForegroundWindow() == hwnd) await host.Dictation.PasteLastAsync(false);
            await Wait(500);
            Report($"[paste-last] text=[{box.Text}]");

            // Read Aloud of text (Windows voice) end to end.
            host.Settings.TtsProvider = "Windows";
            var ra = Stopwatch.StartNew();
            var speak = host.ReadAloud.SpeakTextAsync("Zerm can read selected text aloud.");
            var speaking = await WaitFor(() => host.Ui.State == RecorderState.Speaking, 10000);
            await speak;
            Report($"[read-aloud] speaking={speaking} done in {ra.ElapsedMilliseconds} ms, history={host.History.ReadAloudHistory().FirstOrDefault()?.SpokenText}");

            // Read Aloud from a selection in another window (Ctrl+C / UI Automation path).
            box.Text = "Selected text for Read Aloud.";
            window.Activate();
            box.Focus();
            box.SelectAll();
            await Wait(300);
            var selected = Native.GetForegroundWindow() == hwnd ? await SelectedTextService.GetSelectedTextAsync() : "(skipped: not foreground)";
            Report($"[selection] read=[{selected}]");
        }
        catch (Exception ex)
        {
            Report("EXCEPTION " + ex);
        }
        finally
        {
            window.Close();
            await File.WriteAllLinesAsync(report, lines);
        }
    }

    private sealed class PcmProvider(Core.TextToSpeech.PcmAudio audio) : NAudio.Wave.ISampleProvider
    {
        private int _pos;
        public NAudio.Wave.WaveFormat WaveFormat { get; } = NAudio.Wave.WaveFormat.CreateIeeeFloatWaveFormat(audio.SampleRate, 1);

        public int Read(Span<float> buffer)
        {
            var n = Math.Min(buffer.Length, audio.Samples.Length - _pos);
            audio.Samples.AsSpan(_pos, n).CopyTo(buffer);
            _pos += n;
            return n;
        }
    }

    private static async Task Wait(int ms)
    {
        await Task.Delay(ms);
        await Application.Current.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
    }

    private static async Task<bool> WaitFor(Func<bool> condition, int timeoutMs)
    {
        var sw = Stopwatch.StartNew();
        while (sw.ElapsedMilliseconds < timeoutMs)
        {
            if (condition()) return true;
            await Task.Delay(50);
        }
        return condition();
    }
}
