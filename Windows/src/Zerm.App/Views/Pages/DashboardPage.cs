using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using Zerm.App.Localization;
using Zerm.Core.Data;
using Zerm.Core.Settings;

namespace Zerm.App.Views.Pages;

/// <summary>Port of MetricsView.swift: time saved, six metric cards, trend charts.</summary>
public sealed class DashboardPage : ContentControl
{
    private readonly AppHost _host = AppHost.Current;

    public DashboardPage()
    {
        Render();
        _host.History.Changed += OnChanged;
        Unloaded += (_, _) => _host.History.Changed -= OnChanged;
    }

    private void OnChanged() => Dispatcher.BeginInvoke(Render);

    private static string RangeLabel(UsageRange r) => r switch
    {
        UsageRange.Week => Loc.T("last 7 days"),
        UsageRange.Month => Loc.T("last 30 days"),
        UsageRange.Year => Loc.T("last 12 months"),
        _ => Loc.T("all time"),
    };

    private void Render()
    {
        var days = _host.History.UsageDays();
        var today = DateTime.Today;
        var range = _host.Settings.DashboardUsageRange;
        var totals = UsageMetrics.Totals(days, range, today);
        var lifetime = UsageTotals.From(days);

        if (lifetime.Sessions == 0 && lifetime.ReadAloudSessions == 0)
        {
            var hint = UiKit.VStack(
                UiKit.Glyph(Icons.Mic, 40).Margin(0, 40, 0, 12),
                UiKit.Text(Loc.T("No Transcriptions Yet"), 20, FontWeights.SemiBold),
                UiKit.Text(Loc.T("Start your first recording to unlock value insights."), 14, secondary: true).Margin(0, 6, 0, 16),
                UiKit.Text(Loc.F("Press {0} anywhere to start dictating.", Platform.HotkeyService.Describe(_host.Settings.Hotkey1, _host.Settings.Hotkey1Custom)), 14));
            foreach (UIElement c in hint.Children) if (c is FrameworkElement f) f.HorizontalAlignment = HorizontalAlignment.Center;
            Content = UiKit.Page(Loc.T("Dashboard"), null, hint);
            return;
        }

        var accent = SystemColors.AccentColor;
        var hero = new Border
        {
            CornerRadius = new CornerRadius(20),
            Padding = new Thickness(28, 24, 28, 24),
            Margin = new Thickness(0, 0, 0, 16),
            Background = new LinearGradientBrush(
                [new GradientStop(accent, 0), new GradientStop(Color.FromArgb(0xD9, accent.R, accent.G, accent.B), 0.5), new GradientStop(Color.FromArgb(0xB3, accent.R, accent.G, accent.B), 1)],
                new Point(0, 0), new Point(1, 1)),
        };
        var heroStack = new StackPanel();
        if (totals.TimeSavedSeconds > 0)
        {
            heroStack.Children.Add(new TextBlock { Text = Loc.T("You saved"), Foreground = Brushes.White, FontSize = 16, Opacity = 0.9 });
            heroStack.Children.Add(new TextBlock { Text = Duration(totals.TimeSavedSeconds), Foreground = Brushes.White, FontSize = 38, FontWeight = FontWeights.Black });
            heroStack.Children.Add(new TextBlock { Text = Loc.F("with Zerm in the {0}", RangeLabel(range)), Foreground = Brushes.White, FontSize = 16, Opacity = 0.9 });
        }
        else
        {
            heroStack.Children.Add(new TextBlock { Text = Loc.F("No time saved in the {0}", RangeLabel(range)), Foreground = Brushes.White, FontSize = 22, FontWeight = FontWeights.Bold, TextWrapping = TextWrapping.Wrap });
        }
        heroStack.Children.Add(new TextBlock
        {
            Text = Loc.F("Dictated {0:N0} words across {1:N0} sessions.", totals.Words, totals.Sessions),
            Foreground = Brushes.White, Opacity = 0.85, Margin = new Thickness(0, 10, 0, 0), TextWrapping = TextWrapping.Wrap,
        });
        hero.Child = heroStack;

        var picker = UiKit.Combo(
            [(UsageRange.Week, Loc.T("7 Days")), (UsageRange.Month, Loc.T("30 Days")), (UsageRange.Year, Loc.T("12 Months")), (UsageRange.AllTime, Loc.T("All Time"))],
            range, r => { _host.Settings.DashboardUsageRange = r; Render(); }, 180);
        picker.HorizontalAlignment = HorizontalAlignment.Left;
        picker.Margin = new Thickness(0, 0, 0, 16);

        var (current, longest) = UsageMetrics.Streaks(days, today);
        string Detail(string value) => $"{RangeLabel(range)} · {value} {Loc.T("all time")}";
        var cards = new UniformGridPanel(240);
        cards.Add(Metric(Icons.Mic, Colors.MediumPurple, Loc.T("Sessions Recorded"), $"{totals.Sessions:N0}", Detail($"{lifetime.Sessions:N0}")));
        cards.Add(Metric(Icons.File, accent, Loc.T("Words Dictated"), $"{totals.Words:N0}", Detail($"{lifetime.Words:N0}")));
        cards.Add(Metric(Icons.Dashboard, Color.FromRgb(0xE0, 0xB0, 0x00), Loc.T("Words Per Minute"),
            totals.WordsPerMinute is { } wpm ? $"{wpm:F1}" : "–", Detail(lifetime.WordsPerMinute is { } l ? $"{l:F1}" : "–")));
        cards.Add(Metric(Icons.Keyboard, Colors.DarkOrange, Loc.T("Keystrokes Saved"), $"{totals.KeystrokesSaved:N0}", Detail($"{lifetime.KeystrokesSaved:N0}")));
        cards.Add(Metric(Icons.Speaker, Color.FromRgb(0x0A, 0x84, 0xFF), Loc.T("Words Read Aloud"), $"{totals.ReadAloudWords:N0}", Detail($"{lifetime.ReadAloudWords:N0}")));
        cards.Add(Metric("\uECAD", Color.FromRgb(0xFF, 0x45, 0x3A), Loc.T("Current Streak"), Loc.F("{0} days", current), Loc.F("Longest: {0}", longest)));

        var buckets = UsageMetrics.Buckets(days, range, today);
        var charts = UiKit.Card(Loc.T("Trends"),
            UiKit.Text(Loc.T("Words Dictated"), 13, FontWeights.SemiBold).Margin(0, 0, 0, 6),
            BarChart(buckets.Select(b => (b.Label, (double)b.Words)).ToList(), Color.FromRgb(0x0A, 0x84, 0xFF)),
            UiKit.Text(Loc.T("Words Per Minute"), 13, FontWeights.SemiBold).Margin(0, 14, 0, 6),
            LineChart(buckets.Select(b => (b.Label, b.Wpm ?? 0)).ToList(), Color.FromRgb(0xCE, 0x7F, 0x24)),
            DataTable(buckets));

        var copyInfo = UiKit.Button(Loc.T("Copy System Info"), () =>
        {
            var info = $"Zerm for Windows {typeof(App).Assembly.GetName().Version}\nWindows {Environment.OSVersion.Version}\n" +
                       $"CPU threads: {Environment.ProcessorCount}\nWhisper runtime: {Core.Transcription.WhisperTranscriber.LoadedRuntime}\n" +
                       $"Model: {_host.Settings.CurrentTranscriptionModel}\nAI provider: {_host.Settings.SelectedAIProvider}\nOutput: {_host.Settings.OutputMode}";
            Platform.ClipboardService.SetText(info, false);
            _host.Ui.Toast(Loc.T("System info copied"), Core.Dictation.ToastKind.Success);
        }, Icons.Copy);
        copyInfo.HorizontalAlignment = HorizontalAlignment.Left;

        Content = UiKit.Page(Loc.T("Dashboard"), null, hero, picker, cards, charts, copyInfo);
    }

    private static string Duration(double seconds)
    {
        var t = TimeSpan.FromSeconds(Math.Round(seconds));
        if (seconds >= 3600) return Loc.F("{0} hr {1} min", (int)t.TotalHours, t.Minutes);
        if (seconds >= 60) return Loc.F("{0} min {1} sec", t.Minutes, t.Seconds);
        return Loc.F("{0} sec", t.Seconds);
    }

    private static Border Metric(string glyph, Color color, string title, string value, string detail)
    {
        var icon = new Border
        {
            Width = 34, Height = 34, CornerRadius = new CornerRadius(10),
            Background = new SolidColorBrush(Color.FromArgb(0x26, color.R, color.G, color.B)),
            Child = UiKit.Glyph(glyph, 16, new SolidColorBrush(color)).Center(),
        };
        var stack = UiKit.VStack(
            UiKit.HStack(icon, UiKit.Text(title, 13, FontWeights.SemiBold).Margin(10, 0, 0, 0).VCenter()),
            new TextBlock { Text = value, FontSize = 26, FontWeight = FontWeights.Black, Margin = new Thickness(0, 10, 0, 2) },
            UiKit.Caption(detail));
        return new Border { Child = stack, Margin = new Thickness(0, 0, 12, 12), MinHeight = 130 }.Style("Card");
    }

    private static FrameworkElement BarChart(List<(string Label, double Value)> data, Color color)
    {
        var canvas = new Canvas { Height = 140, ClipToBounds = true };
        canvas.SizeChanged += (_, _) => Draw();
        void Draw()
        {
            canvas.Children.Clear();
            if (data.Count == 0 || canvas.ActualWidth <= 0) return;
            var max = Math.Max(1, data.Max(d => d.Value));
            var w = canvas.ActualWidth / data.Count;
            for (var i = 0; i < data.Count; i++)
            {
                var h = Math.Max(data[i].Value > 0 ? 2 : 0, (canvas.Height - 18) * data[i].Value / max);
                var rect = new Rectangle
                {
                    Width = Math.Max(2, w * 0.7), Height = h, RadiusX = 3, RadiusY = 3, Fill = new SolidColorBrush(color),
                    ToolTip = $"{data[i].Label}: {data[i].Value:N0}",
                };
                Canvas.SetLeft(rect, i * w + w * 0.15);
                Canvas.SetTop(rect, canvas.Height - 18 - h);
                canvas.Children.Add(rect);
                if (data.Count <= 12 || i % Math.Max(1, data.Count / 8) == 0)
                {
                    var label = new TextBlock { Text = data[i].Label, FontSize = 10, Opacity = 0.6 };
                    Canvas.SetLeft(label, i * w);
                    Canvas.SetTop(label, canvas.Height - 15);
                    canvas.Children.Add(label);
                }
            }
        }
        return canvas;
    }

    private static FrameworkElement LineChart(List<(string Label, double Value)> data, Color color)
    {
        var canvas = new Canvas { Height = 110, ClipToBounds = true };
        canvas.SizeChanged += (_, _) => Draw();
        void Draw()
        {
            canvas.Children.Clear();
            if (data.Count == 0 || canvas.ActualWidth <= 0) return;
            var max = Math.Max(1, data.Max(d => d.Value));
            var w = canvas.ActualWidth / Math.Max(1, data.Count - 1);
            var line = new Polyline { Stroke = new SolidColorBrush(color), StrokeThickness = 2 };
            for (var i = 0; i < data.Count; i++)
            {
                var p = new Point(i * w, canvas.Height - 6 - (canvas.Height - 12) * data[i].Value / max);
                line.Points.Add(p);
                if (data[i].Value > 0)
                {
                    var dot = new Ellipse { Width = 6, Height = 6, Fill = new SolidColorBrush(color), ToolTip = $"{data[i].Label}: {data[i].Value:F1}" };
                    Canvas.SetLeft(dot, p.X - 3);
                    Canvas.SetTop(dot, p.Y - 3);
                    canvas.Children.Add(dot);
                }
            }
            canvas.Children.Insert(0, line);
        }
        return canvas;
    }

    private static FrameworkElement DataTable(List<UsageBucket> buckets)
    {
        var grid = new DataGrid
        {
            AutoGenerateColumns = false, IsReadOnly = true, HeadersVisibility = DataGridHeadersVisibility.Column,
            MaxHeight = 260, Margin = new Thickness(0, 8, 0, 0), GridLinesVisibility = DataGridGridLinesVisibility.None,
            ItemsSource = buckets.Where(b => b.Sessions > 0).Reverse().Select(b => new
            {
                Period = b.Label, b.Sessions, Words = b.Words.ToString("N0"), Wpm = b.Wpm is { } w ? w.ToString("F1") : "–",
            }).ToList(),
        };
        grid.Columns.Add(new DataGridTextColumn { Header = Loc.T("Period"), Binding = new System.Windows.Data.Binding("Period"), Width = new DataGridLength(1, DataGridLengthUnitType.Star) });
        grid.Columns.Add(new DataGridTextColumn { Header = Loc.T("Sessions"), Binding = new System.Windows.Data.Binding("Sessions") });
        grid.Columns.Add(new DataGridTextColumn { Header = Loc.T("Words"), Binding = new System.Windows.Data.Binding("Words") });
        grid.Columns.Add(new DataGridTextColumn { Header = Loc.T("WPM"), Binding = new System.Windows.Data.Binding("Wpm") });
        return new Expander { Header = Loc.T("Show data table"), Content = grid, Margin = new Thickness(0, 12, 0, 0) };
    }
}

/// <summary>Wrapping grid with a minimum column width (adaptive LazyVGrid).</summary>
public sealed class UniformGridPanel : ContentControl
{
    private readonly System.Windows.Controls.Primitives.UniformGrid _grid = new();
    private readonly double _minWidth;

    public UniformGridPanel(double minWidth)
    {
        _minWidth = minWidth;
        Content = _grid;
        SizeChanged += (_, _) => _grid.Columns = Math.Max(1, (int)(ActualWidth / _minWidth));
    }

    public void Add(UIElement e) => _grid.Children.Add(e);
}

public static class LayoutExtensions
{
    public static T Center<T>(this T e) where T : FrameworkElement
    {
        e.HorizontalAlignment = HorizontalAlignment.Center;
        e.VerticalAlignment = VerticalAlignment.Center;
        return e;
    }

    public static T VCenter<T>(this T e) where T : FrameworkElement
    {
        e.VerticalAlignment = VerticalAlignment.Center;
        return e;
    }
}
