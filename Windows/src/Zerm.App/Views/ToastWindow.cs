using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using Zerm.App.Localization;
using Zerm.App.Platform;
using Zerm.Core.Dictation;

namespace Zerm.App.Views;

/// <summary>Non-activating notifications above the recorder position (NotificationManager.swift).</summary>
public sealed class ToastWindow : Window
{
    private static readonly List<ToastWindow> Open = [];
    private readonly DispatcherTimer _timer;

    public string Message { get; }

    public static void Show(string message, ToastKind kind, TimeSpan duration, ToastAction? action = null)
    {
        Core.Log.Info($"Toast [{kind}]: {message}");
        // Collapse identical consecutive notifications.
        if (Open.LastOrDefault() is { } last && last.Message == message) last.Close();
        while (Open.Count >= 3) Open[0].Close();
        var toast = new ToastWindow(message, kind, duration, action);
        Open.Add(toast);
        toast.Show();
        Layout();
    }

    private static void Layout()
    {
        var screen = System.Windows.Forms.Screen.FromPoint(System.Windows.Forms.Cursor.Position);
        var area = screen.WorkingArea;
        var bottom = area.Bottom - 96.0;
        foreach (var t in Enumerable.Reverse(Open))
        {
            var scale = PresentationSource.FromVisual(t)?.CompositionTarget?.TransformFromDevice.M11 ?? 1.0;
            t.UpdateLayout();
            t.Left = (area.Left + area.Width / 2.0) * scale - t.ActualWidth / 2;
            t.Top = bottom * scale - t.ActualHeight;
            bottom -= (t.ActualHeight + 6) / scale;
        }
    }

    private ToastWindow(string message, ToastKind kind, TimeSpan duration, ToastAction? action)
    {
        Message = message;
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ShowInTaskbar = false;
        ShowActivated = false;
        Topmost = true;
        ResizeMode = ResizeMode.NoResize;
        SizeToContent = SizeToContent.WidthAndHeight;
        FlowDirection = Loc.Direction;
        Title = "Zerm";

        var (glyph, color) = kind switch
        {
            ToastKind.Success => (Icons.Check, Color.FromRgb(0x32, 0xD7, 0x4B)),
            ToastKind.Warning => (Icons.Warning, Color.FromRgb(0xFF, 0x9F, 0x0A)),
            ToastKind.Error => (Icons.Error, Color.FromRgb(0xFF, 0x45, 0x3A)),
            _ => (Icons.Info, Color.FromRgb(0x0A, 0x84, 0xFF)),
        };
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        row.Children.Add(new TextBlock
        {
            Text = glyph, FontFamily = new FontFamily(Icons.FontFamily), Foreground = new SolidColorBrush(color),
            FontSize = 15, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0),
        });
        row.Children.Add(new TextBlock
        {
            Text = message, Foreground = Brushes.White, FontSize = 13, TextWrapping = TextWrapping.Wrap, MaxWidth = 420,
            FlowDirection = UiKit.DirectionOf(message),
            VerticalAlignment = VerticalAlignment.Center,
        });
        if (action != null)
        {
            var button = new Button
            {
                Content = action.Label, Margin = new Thickness(12, 0, 0, 0), Padding = new Thickness(10, 3, 10, 3),
                Focusable = false, VerticalAlignment = VerticalAlignment.Center,
            };
            button.Click += (_, _) =>
            {
                action.Run();
                Close();
            };
            row.Children.Add(button);
        }
        Content = new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(0xF0, 0x1C, 0x1C, 0x1E)),
            BorderBrush = new SolidColorBrush(Color.FromArgb(0x30, 0xFF, 0xFF, 0xFF)),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(12),
            Padding = new Thickness(14, 10, 14, 10),
            Margin = new Thickness(8),
            Child = row,
            Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 12, ShadowDepth = 2, Opacity = 0.35 },
        };
        MouseLeftButtonUp += (_, _) => { if (action == null) Close(); };
        SourceInitialized += (_, _) => Native.MakeNonActivating(new WindowInteropHelper(this).Handle);
        _timer = new DispatcherTimer { Interval = duration };
        _timer.Tick += (_, _) => Close();
        _timer.Start();
        Closed += (_, _) =>
        {
            _timer.Stop();
            Open.Remove(this);
            Layout();
        };
    }
}
