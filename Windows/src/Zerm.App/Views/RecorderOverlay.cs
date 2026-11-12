using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using System.Windows.Threading;
using Zerm.App.Localization;
using Zerm.App.Platform;
using Zerm.Core.Dictation;
using Zerm.Core.Settings;

namespace Zerm.App.Views;

/// <summary>
/// The mini recorder (MiniRecorderView.swift): a non-activating floating black pill that never takes
/// focus from the app you're dictating into. 15-bar visualizer while recording, animated status while
/// transcribing/enhancing, prompt button on the left and Power Mode button on the right.
/// </summary>
public sealed class RecorderOverlay : Window
{
    private static RecorderOverlay? _instance;

    private readonly Rectangle[] _bars = new Rectangle[15];
    private readonly StackPanel _barsPanel;
    private readonly TextBlock _status;
    private readonly Button _promptButton;
    private readonly Button _powerButton;
    private readonly Border _pill;
    private readonly DispatcherTimer _timer;
    private readonly DateTime _start = DateTime.Now;
    private int _dots;
    private DateTime _lastDot;

    public static RecorderOverlay Instance => _instance ??= new RecorderOverlay();

    public static void ShowRecorder()
    {
        var w = Instance;
        w.Position();
        w.Refresh();
        if (!w.IsVisible)
        {
            w.Opacity = 0;
            w.Show();
            w.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(120)));
        }
        w._timer.Start();
    }

    public static void HideRecorder()
    {
        if (_instance == null || !_instance.IsVisible) return;
        _instance._timer.Stop();
        _instance.Hide();
    }

    private RecorderOverlay()
    {
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ShowInTaskbar = false;
        ShowActivated = false;
        Topmost = true;
        ResizeMode = ResizeMode.NoResize;
        SizeToContent = SizeToContent.WidthAndHeight;
        FlowDirection = FlowDirection.LeftToRight;
        Title = "Zerm Recorder";

        _barsPanel = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
        for (var i = 0; i < _bars.Length; i++)
        {
            _bars[i] = new Rectangle { Width = 3, Height = 4, RadiusX = 1.5, RadiusY = 1.5, Fill = Brushes.White, Margin = new Thickness(1, 0, 1, 0), VerticalAlignment = VerticalAlignment.Center };
            _barsPanel.Children.Add(_bars[i]);
        }
        _status = new TextBlock { Foreground = Brushes.White, FontSize = 12, FontWeight = FontWeights.Medium, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center, Visibility = Visibility.Collapsed };

        _promptButton = PillButton(Icons.Sparkle, Loc.T("Enhancement prompt"));
        _promptButton.Click += (_, _) => ShowPromptMenu();
        _powerButton = PillButton("⚡", Loc.T("Power Mode"));
        _powerButton.FontFamily = new FontFamily("Segoe UI Emoji");
        _powerButton.Click += (_, _) => ShowPowerModeMenu();

        var center = new Grid { Width = 112 };
        center.Children.Add(_barsPanel);
        center.Children.Add(_status);

        var row = new DockPanel { LastChildFill = true, Height = 40 };
        DockPanel.SetDock(_promptButton, Dock.Left);
        DockPanel.SetDock(_powerButton, Dock.Right);
        row.Children.Add(_promptButton);
        row.Children.Add(_powerButton);
        row.Children.Add(center);

        _pill = new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(0xF2, 0x0B, 0x0B, 0x0D)),
            BorderBrush = new SolidColorBrush(Color.FromArgb(0x40, 0xFF, 0xFF, 0xFF)),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(20),
            Width = 184,
            Padding = new Thickness(6, 0, 6, 0),
            Child = row,
            Margin = new Thickness(8),
            Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 12, ShadowDepth = 2, Opacity = 0.35 },
        };
        Content = _pill;

        _timer = new DispatcherTimer(DispatcherPriority.Render) { Interval = TimeSpan.FromMilliseconds(33) };
        _timer.Tick += (_, _) => Animate();
        SourceInitialized += (_, _) => Native.MakeNonActivating(new WindowInteropHelper(this).Handle);
        AppHost.Current.Dictation.Changed += () => Dispatcher.BeginInvoke(Refresh);
        AppHost.Current.Ui.StateChanged += _ => Refresh();
    }

    private static Button PillButton(string glyph, string tooltip)
    {
        var b = new Button
        {
            Content = glyph,
            FontFamily = new FontFamily(Icons.FontFamily),
            FontSize = 13,
            Width = 28,
            Height = 28,
            Padding = new Thickness(0),
            Foreground = Brushes.White,
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            ToolTip = tooltip,
            Focusable = false,
            VerticalAlignment = VerticalAlignment.Center,
        };
        return b;
    }

    /// <summary>Bottom centre of the screen with the mouse, 24 px above the taskbar.</summary>
    private void Position()
    {
        var screen = System.Windows.Forms.Screen.FromPoint(System.Windows.Forms.Cursor.Position);
        var source = PresentationSource.FromVisual(this);
        var scale = source?.CompositionTarget?.TransformFromDevice.M11 ?? 1.0;
        var area = screen.WorkingArea;
        UpdateLayout();
        var width = ActualWidth > 0 ? ActualWidth : 200;
        var height = ActualHeight > 0 ? ActualHeight : 56;
        Left = (area.Left + area.Width / 2.0) * scale - width / 2;
        Top = area.Bottom * scale - height - 24;
    }

    private void Refresh()
    {
        var host = AppHost.Current;
        var state = host.Ui.State;
        var dictation = host.Dictation;
        var prompt = host.Library.Prompts.FirstOrDefault(p => p.Id == dictation.EffectivePromptId);
        var enhancing = dictation.EffectiveOutputMode != DictationOutputMode.Instant;
        _promptButton.Content = enhancing ? Icons.Glyph(prompt?.Icon) : Icons.Sparkle;
        _promptButton.Opacity = enhancing ? 1 : 0.45;
        _promptButton.ToolTip = enhancing ? Loc.F("Prompt: {0}", Loc.T(prompt?.Title ?? "")) : Loc.T("AI enhancement is off (Ctrl+E)");
        var pm = dictation.ActivePowerMode;
        _powerButton.Content = pm?.Emoji ?? "✨";
        _powerButton.ToolTip = pm != null ? $"{Loc.T("Power Mode")}: {pm.Name}" : Loc.T("Power Mode");
        _powerButton.IsEnabled = host.Library.PowerModes.Any(m => m.IsEnabled);

        var reading = state is RecorderState.PreparingSpeech or RecorderState.GeneratingSpeech or RecorderState.Speaking;
        _promptButton.Visibility = reading ? Visibility.Hidden : Visibility.Visible;
        _powerButton.Visibility = reading ? Visibility.Hidden : Visibility.Visible;

        var showBars = state is RecorderState.Recording or RecorderState.Speaking or RecorderState.Starting or RecorderState.Idle;
        _barsPanel.Visibility = showBars ? Visibility.Visible : Visibility.Collapsed;
        _status.Visibility = showBars ? Visibility.Collapsed : Visibility.Visible;
    }

    private void Animate()
    {
        var host = AppHost.Current;
        var state = host.Ui.State;
        var t = (DateTime.Now - _start).TotalSeconds;
        if (state is RecorderState.Recording or RecorderState.Speaking)
        {
            var level = state == RecorderState.Speaking ? host.ReadAloud.Level : host.Dictation.Level;
            var amp = Math.Pow(Math.Clamp(level, 0, 1), 0.7);
            for (var i = 0; i < _bars.Length; i++)
            {
                var wave = 0.55 + 0.45 * Math.Sin(t * 8 + i * 0.4);
                var boost = 1 - 0.4 * Math.Abs(i - 7) / 7.0;
                _bars[i].Height = 4 + 24 * amp * wave * boost;
                _bars[i].Opacity = 1;
            }
        }
        else if (_barsPanel.Visibility == Visibility.Visible)
        {
            foreach (var bar in _bars)
            {
                bar.Height = 4;
                bar.Opacity = 0.5;
            }
        }

        if (_status.Visibility == Visibility.Visible)
        {
            var label = state switch
            {
                RecorderState.Transcribing => Loc.T("Transcribing"),
                RecorderState.Enhancing => Loc.T("Enhancing"),
                RecorderState.PreparingSpeech => Loc.T("Preparing…"),
                RecorderState.GeneratingSpeech => Loc.T("Thinking…"),
                _ => "",
            };
            var step = state == RecorderState.Enhancing ? 0.22 : 0.18;
            if ((DateTime.Now - _lastDot).TotalSeconds >= step)
            {
                _dots = (_dots + 1) % 6;
                _lastDot = DateTime.Now;
            }
            _status.Text = label.TrimEnd('…') + new string('.', Math.Min(_dots, 5));
        }
    }

    private void ShowPromptMenu()
    {
        var host = AppHost.Current;
        var menu = new ContextMenu { FlowDirection = Loc.Direction };
        var off = new MenuItem { Header = Loc.T("No AI (Instant)"), IsCheckable = true, IsChecked = host.Dictation.EffectiveOutputMode == DictationOutputMode.Instant };
        off.Click += (_, _) =>
        {
            if (host.Dictation.EffectiveOutputMode != DictationOutputMode.Instant) host.Dictation.ToggleEnhancementForThisRecording();
        };
        menu.Items.Add(off);
        menu.Items.Add(new Separator());
        var n = 1;
        foreach (var prompt in host.Library.Prompts)
        {
            var item = new MenuItem
            {
                Header = Loc.T(prompt.Title),
                InputGestureText = n <= 10 ? $"Ctrl+{n % 10}" : "",
                IsCheckable = true,
                IsChecked = host.Dictation.EffectiveOutputMode != DictationOutputMode.Instant && host.Dictation.EffectivePromptId == prompt.Id,
                Icon = new TextBlock { Text = Icons.Glyph(prompt.Icon), FontFamily = new FontFamily(Icons.FontFamily) },
            };
            var id = prompt.Id;
            item.Click += (_, _) => host.Dictation.SelectPrompt(id);
            menu.Items.Add(item);
            n++;
        }
        menu.PlacementTarget = _promptButton;
        menu.Placement = System.Windows.Controls.Primitives.PlacementMode.Top;
        menu.IsOpen = true;
    }

    private void ShowPowerModeMenu()
    {
        var host = AppHost.Current;
        var menu = new ContextMenu { FlowDirection = Loc.Direction };
        var n = 1;
        foreach (var mode in host.Library.PowerModes.Where(m => m.IsEnabled))
        {
            var item = new MenuItem
            {
                Header = $"{mode.Emoji}  {mode.Name}",
                InputGestureText = n <= 10 ? $"Alt+{n % 10}" : "",
                IsCheckable = true,
                IsChecked = host.Dictation.ActivePowerMode?.Id == mode.Id,
            };
            var m = mode;
            item.Click += (_, _) => host.Dictation.SelectPowerMode(m);
            menu.Items.Add(item);
            n++;
        }
        menu.PlacementTarget = _powerButton;
        menu.Placement = System.Windows.Controls.Primitives.PlacementMode.Top;
        menu.IsOpen = true;
    }
}
