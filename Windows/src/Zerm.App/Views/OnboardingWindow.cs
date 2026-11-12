using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;
using System.Windows.Threading;
using Zerm.App.Localization;
using Zerm.App.Platform;
using Zerm.Core;
using Zerm.Core.Models;
using Zerm.Core.Settings;

namespace Zerm.App.Views;

/// <summary>First-run setup (OnboardingView.swift): welcome → microphone → model → shortcut → try it.</summary>
public sealed class OnboardingWindow : Window
{
    private readonly AppHost _host = AppHost.Current;
    private readonly ContentControl _content = new();
    private int _step;
    private readonly AudioRecorder _test = new();
    private DispatcherTimer? _meter;

    public static string? DetectedGpu { get; private set; }

    public OnboardingWindow()
    {
        Title = Loc.T("Welcome to Zerm");
        Width = 760;
        Height = 620;
        ResizeMode = ResizeMode.CanMinimize;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        FlowDirection = Loc.Direction;
        Icon = new System.Windows.Media.Imaging.BitmapImage(new Uri("pack://application:,,,/Assets/Zerm.ico"));
        Background = new LinearGradientBrush(Color.FromRgb(0x14, 0x14, 0x18), Color.FromRgb(0x05, 0x05, 0x07), 90);
        Foreground = Brushes.White;
        Content = _content;
        Closed += (_, _) => StopMeter();
        DetectGpu();
        Show(0);
    }

    /// <summary>A discrete GPU makes the large Whisper models fast (Vulkan); otherwise recommend a lighter model.</summary>
    public static void DetectGpu()
    {
        if (DetectedGpu != null) return;
        try
        {
            using var searcher = new System.Management.ManagementObjectSearcher("SELECT Name FROM Win32_VideoController");
            DetectedGpu = searcher.Get().Cast<System.Management.ManagementObject>().Select(o => o["Name"]?.ToString() ?? "")
                .FirstOrDefault(n => n.Contains("NVIDIA", StringComparison.OrdinalIgnoreCase) || n.Contains("Radeon", StringComparison.OrdinalIgnoreCase)
                                     || n.Contains("Arc", StringComparison.OrdinalIgnoreCase)) ?? "";
        }
        catch
        {
            DetectedGpu = "";
        }
    }

    public static TranscriptionModel RecommendedModel()
    {
        DetectGpu();
        var hebrew = Loc.IsHebrew || System.Globalization.CultureInfo.CurrentCulture.TwoLetterISOLanguageName == "he";
        if (hebrew) return TranscriptionModelRegistry.Find("ivrit-large-v3-turbo")!;
        return !string.IsNullOrEmpty(DetectedGpu)
            ? TranscriptionModelRegistry.Find("ggml-large-v3-turbo-q5_0")!
            : TranscriptionModelRegistry.Find("ggml-base-q8_0")!;
    }

    private static TextBlock White(string text, double size, FontWeight? weight = null, double opacity = 1) => new()
    {
        Text = text, FontSize = size, FontWeight = weight ?? FontWeights.Normal, Foreground = Brushes.White, Opacity = opacity,
        TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center,
    };

    private static Button Pill(string text, Action click)
    {
        var b = new Button
        {
            Content = text, Padding = new Thickness(28, 10, 28, 10), FontSize = 15, FontWeight = FontWeights.SemiBold,
            Background = Brushes.White, Foreground = Brushes.Black, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 24, 0, 0),
        };
        b.Click += (_, _) => click();
        return b;
    }

    private static Button Link(string text, Action click)
    {
        var b = new Button
        {
            Content = text, Background = Brushes.Transparent, BorderThickness = new Thickness(0), Foreground = Brushes.White, Opacity = 0.7,
            HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 10, 0, 0),
        };
        b.Click += (_, _) => click();
        return b;
    }

    public void GoTo(int step) => Show(step);

    private void Show(int step)
    {
        _step = step;
        StopMeter();
        var stack = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(60, 30, 60, 30), MaxWidth = 560 };
        switch (step)
        {
            case 0:
                stack.Children.Add(new Image { Source = new System.Windows.Media.Imaging.BitmapImage(new Uri("pack://application:,,,/Assets/logo.png")), Width = 110, Height = 110 });
                stack.Children.Add(White(Loc.T("Welcome to the Future of Typing"), 34, FontWeights.Bold).Margin(0, 18, 0, 8));
                stack.Children.Add(White(Loc.T("A New Way to Type"), 18, opacity: 0.8));
                stack.Children.Add(White(Loc.T("Speak anywhere on Windows and Zerm types it for you — offline and private by default."), 15, opacity: 0.7).Margin(0, 14, 0, 0));
                stack.Children.Add(Pill(Loc.T("Get Started"), () => Show(1)));
                stack.Children.Add(Link(Loc.T("Skip Tour"), Finish));
                break;
            case 1:
                stack.Children.Add(White(Loc.T("Microphone Selection"), 28, FontWeights.Bold));
                stack.Children.Add(White(Loc.T("Pick the microphone Zerm should listen to, then say a few words."), 15, opacity: 0.75).Margin(0, 8, 0, 18));
                var devices = AudioRecorder.InputDevices();
                var combo = new ComboBox { Width = 380, DisplayMemberPath = "Name", ItemsSource = devices, HorizontalAlignment = HorizontalAlignment.Center };
                combo.SelectedItem = devices.FirstOrDefault(d => d.Id == _host.Settings.InputDeviceId) ?? devices.FirstOrDefault(d => d.IsDefault) ?? devices.FirstOrDefault();
                var bar = new ProgressBar { Width = 380, Height = 10, Maximum = 1, Margin = new Thickness(0, 16, 0, 0) };
                async void StartMeter()
                {
                    StopMeter();
                    try
                    {
                        var id = (combo.SelectedItem as AudioDevice)?.Id;
                        var opening = Task.Run(() => _test.Start(id));
                        if (await Task.WhenAny(opening, Task.Delay(5000)) != opening) return; // stuck driver: no meter
                        await opening;
                        _meter = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(33) };
                        _meter.Tick += (_, _) => bar.Value = Math.Max(_test.Level, _test.PeakLevel * 0.65);
                        _meter.Start();
                    }
                    catch (Exception ex)
                    {
                        Log.Warn($"Onboarding mic test: {ex.Message}");
                    }
                }
                combo.SelectionChanged += (_, _) =>
                {
                    _host.Settings.InputDeviceId = (combo.SelectedItem as AudioDevice)?.Id;
                    StartMeter();
                };
                stack.Children.Add(combo);
                stack.Children.Add(bar);
                if (devices.Count == 0) stack.Children.Add(White(Loc.T("No microphones found. Check that one is connected and allowed in Windows privacy settings."), 13, opacity: 0.8).Margin(0, 10, 0, 0));
                StartMeter();
                stack.Children.Add(Pill(Loc.T("Continue"), () => Show(2)));
                break;
            case 2:
                var model = RecommendedModel();
                stack.Children.Add(White(Loc.T("Download AI Model"), 28, FontWeights.Bold));
                stack.Children.Add(White(Loc.T("Zerm transcribes on your PC so your voice never leaves it."), 15, opacity: 0.75).Margin(0, 8, 0, 18));
                stack.Children.Add(White(model.DisplayName, 20, FontWeights.SemiBold));
                var why = !string.IsNullOrEmpty(DetectedGpu) ? Loc.F("Recommended for your graphics card ({0}).", DetectedGpu) : Loc.T("Recommended for this PC.");
                stack.Children.Add(White($"{why} {ModelDownloads.Format(model.SizeBytes)}", 13, opacity: 0.7).Margin(0, 4, 0, 14));
                var progress = new ProgressBar { Width = 380, Height = 8, Maximum = 1, Visibility = Visibility.Collapsed };
                var status = White("", 12, opacity: 0.7);
                var next = Pill(model.IsDownloaded ? Loc.T("Continue") : Loc.T("Download"), () => { });
                next.Click += (_, _) =>
                {
                    if (model.IsDownloaded)
                    {
                        _host.Settings.CurrentTranscriptionModel = model.Name;
                        Show(3);
                        return;
                    }
                    next.IsEnabled = false;
                    progress.Visibility = Visibility.Visible;
                    var item = _host.Downloads.Start(model.Name, [model.Download!], () =>
                    {
                        _host.Settings.CurrentTranscriptionModel = model.Name;
                        next.Content = Loc.T("Continue");
                        next.IsEnabled = true;
                        status.Text = Loc.T("Ready — Zerm is preparing the model in the background.");
                    });
                    progress.SetBinding(System.Windows.Controls.Primitives.RangeBase.ValueProperty, new Binding(nameof(item.Progress)) { Source = item });
                    status.SetBinding(TextBlock.TextProperty, new Binding(nameof(item.Status)) { Source = item });
                };
                stack.Children.Add(progress);
                stack.Children.Add(status);
                stack.Children.Add(next);
                stack.Children.Add(Link(Loc.T("Choose another model or a cloud provider"), () => { Finish(); ShellWindow.ShowAndNavigate("Models"); }));
                break;
            case 3:
                var s = _host.Settings;
                stack.Children.Add(White(Loc.T("Keyboard Shortcut"), 28, FontWeights.Bold));
                stack.Children.Add(White(Loc.T("Press this key anywhere to dictate. Tap it for hands-free, or hold it while you speak."), 15, opacity: 0.75).Margin(0, 8, 0, 18));
                var key = new ComboBox { Width = 260, DisplayMemberPath = "Label", SelectedValuePath = "Value", HorizontalAlignment = HorizontalAlignment.Center };
                key.ItemsSource = Enum.GetValues<TriggerKey>().Where(k => k is not (TriggerKey.None or TriggerKey.Custom))
                    .Select(k => new UiKit.ComboItem(k, Loc.T(HotkeyService.Describe(k, s.Hotkey1Custom)))).ToList();
                key.SelectedValue = s.Hotkey1 == TriggerKey.Custom ? TriggerKey.RightCtrl : s.Hotkey1;
                key.SelectionChanged += (_, _) => { if (key.SelectedValue is TriggerKey k) s.Hotkey1 = k; };
                var mode = new ComboBox { Width = 260, DisplayMemberPath = "Label", SelectedValuePath = "Value", HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 10, 0, 0) };
                mode.ItemsSource = new[] { new UiKit.ComboItem(HotkeyMode.Hybrid, Loc.T("Hybrid")), new UiKit.ComboItem(HotkeyMode.Toggle, Loc.T("Toggle")), new UiKit.ComboItem(HotkeyMode.PushToTalk, Loc.T("Push to Talk")) };
                mode.SelectedValue = s.HotkeyMode1;
                mode.SelectionChanged += (_, _) => { if (mode.SelectedValue is HotkeyMode m) s.HotkeyMode1 = m; };
                stack.Children.Add(key);
                stack.Children.Add(mode);
                stack.Children.Add(Pill(Loc.T("Continue"), () => Show(4)));
                break;
            default:
                stack.Children.Add(White(Loc.T("Try It Out!"), 28, FontWeights.Bold));
                stack.Children.Add(White(Loc.F("Click in the box, press {0}, speak, then press it again (or just stop talking).",
                    HotkeyService.Describe(_host.Settings.Hotkey1, _host.Settings.Hotkey1Custom)), 15, opacity: 0.75).Margin(0, 8, 0, 18));
                var box = new TextBox { Height = 120, Width = 480, TextWrapping = TextWrapping.Wrap, AcceptsReturn = true, FontSize = 15 };
                var hint = Loc.T("Click here and start speaking...");
                box.Text = hint;
                box.GotFocus += (_, _) => { if (box.Text == hint) box.Text = ""; };
                stack.Children.Add(box);
                stack.Children.Add(Pill(Loc.T("Complete Setup"), Finish));
                break;
        }
        _content.Content = stack;
    }

    private void StopMeter()
    {
        _meter?.Stop();
        _meter = null;
        _ = Task.Run(_test.Stop);
    }

    private void Finish()
    {
        _host.Settings.HasCompletedOnboarding = true;
        _host.Settings.SaveNow();
        Close();
        ShellWindow.ShowAndNavigate("Dashboard");
    }
}
