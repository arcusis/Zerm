using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Zerm.App.Localization;
using Zerm.Core.Data;
using Zerm.Core.Settings;
using Zerm.Core.Text;

namespace Zerm.App.Views.Pages;

/// <summary>
/// Enhancement Insights: what the AI actually changed in your dictations, how often it helped,
/// what it cost in time, and a verdict on whether it's worth keeping on.
/// </summary>
public sealed class InsightsPage : ContentControl
{
    private readonly AppHost _host = AppHost.Current;
    private UsageRange _range = UsageRange.Month;
    private string _filter = "changed";
    private int _shown = 25;

    public InsightsPage()
    {
        Render();
        _host.History.Changed += OnChanged;
        Unloaded += (_, _) => _host.History.Changed -= OnChanged;
    }

    private void OnChanged() => Dispatcher.BeginInvoke(Render);

    private void Render()
    {
        var since = _range == UsageRange.AllTime ? DateTime.MinValue : UsageMetrics.RangeStart(_range, DateTime.Today);
        var records = _host.History.Since(since);
        var i = EnhancementInsights.From(records);

        var picker = UiKit.Combo([(UsageRange.Week, Loc.T("7 Days")), (UsageRange.Month, Loc.T("30 Days")), (UsageRange.AllTime, Loc.T("All Time"))],
            _range, r => { _range = r; _shown = 25; Render(); }, 180);
        picker.HorizontalAlignment = HorizontalAlignment.Left;
        picker.Margin = new Thickness(0, 0, 0, 14);

        var verdict = new Border
        {
            CornerRadius = new CornerRadius(14), Padding = new Thickness(20, 16, 20, 16), Margin = new Thickness(0, 0, 0, 14),
            Background = new SolidColorBrush(Color.FromArgb(0x30, SystemColors.AccentColor.R, SystemColors.AccentColor.G, SystemColors.AccentColor.B)),
            BorderBrush = new SolidColorBrush(SystemColors.AccentColor), BorderThickness = new Thickness(1),
            Child = UiKit.VStack(UiKit.Text(Loc.T("Verdict"), 13, FontWeights.SemiBold, true), UiKit.Text(Loc.T(i.Verdict()), 16, FontWeights.SemiBold).Margin(0, 4, 0, 0)),
        };

        var cards = new UniformGridPanel(200);
        cards.Add(Stat(Loc.T("Dictations"), $"{i.Dictations}", Loc.F("{0} sent to the AI", i.Attempted)));
        cards.Add(Stat(Loc.T("Wording improved"), i.Enhanced == 0 ? "–" : $"{i.UsefulRate:P0}", Loc.F("{0} of {1} enhanced", i.Reworded, i.Enhanced)));
        cards.Add(Stat(Loc.T("Words changed"), i.Enhanced == 0 ? "–" : $"{i.AverageChangedFraction:P0}", Loc.T("average per enhanced dictation")));
        cards.Add(Stat(Loc.T("Time per enhancement"), i.Attempted == 0 ? "–" : $"{i.AverageSeconds:F1} s", Loc.F("{0:F0} s in total", i.TotalSeconds)));

        var breakdown = UiKit.Card(Loc.T("What the AI did"),
            Bar(Loc.T("Wording changed"), i.Reworded, i.Dictations, DiffView.LevelColor(ChangeLevel.Wording)),
            Bar(Loc.T("Punctuation & capitals only"), i.PunctuationOnly, i.Dictations, DiffView.LevelColor(ChangeLevel.PunctuationOnly)),
            Bar(Loc.T("No change"), i.Unchanged, i.Dictations, DiffView.LevelColor(ChangeLevel.None)),
            Bar(Loc.T("Skipped (too short)"), i.SkippedShort, i.Dictations, Color.FromRgb(0x64, 0xD2, 0xFF)),
            Bar(Loc.T("Skipped (not set up)"), i.SkippedSetup, i.Dictations, Color.FromRgb(0xBF, 0x5A, 0xF2)),
            Bar(Loc.T("Failed or timed out"), i.Failed, i.Dictations, Color.FromRgb(0xFF, 0x45, 0x3A)),
            Bar(Loc.T("Discarded by the language guard"), i.Rejected, i.Dictations, Color.FromRgb(0xFF, 0x6B, 0x6B)),
            Bar(Loc.T("Instant (no AI)"), i.NotAttempted, i.Dictations, Color.FromRgb(0x48, 0x48, 0x4A)));
        if (i.FailureReasons.Count > 0)
            ((StackPanel)breakdown.Child).Children.Add(UiKit.Caption(Loc.T("Reasons") + ": " + string.Join(", ", i.FailureReasons.OrderByDescending(r => r.Value).Select(r => $"{r.Key} × {r.Value}"))).Margin(0, 8, 0, 0));

        var children = new List<UIElement> { picker, verdict, cards, breakdown };
        if (i.ByPrompt.Count > 0)
        {
            var table = new StackPanel();
            foreach (var (prompt, (count, reworded)) in i.ByPrompt.OrderByDescending(p => p.Value.Count))
                table.Children.Add(UiKit.Row(Loc.T(prompt), UiKit.Text(Loc.F("{0} enhanced · wording improved in {1:P0}", count, count == 0 ? 0 : reworded / (double)count), 13, secondary: true)));
            children.Add(UiKit.Card(Loc.T("By prompt"), table));
        }

        // The actual changes, newest first.
        var enhanced = records.Where(r => r.EnhancementOutcome == "Enhanced" && r.EnhancedText != null && r.SegmentsJson == null)
            .Select(r => (Record: r, Level: WordDiff.Classify(r.Text, r.EnhancedText!)))
            .Where(x => _filter == "all" || (_filter == "changed" ? x.Level == ChangeLevel.Wording : x.Level != ChangeLevel.Wording))
            .ToList();
        var filter = UiKit.Combo([("changed", Loc.T("Wording changed")), ("unchanged", Loc.T("Little or no change")), ("all", Loc.T("All enhanced"))],
            _filter, f => { _filter = f; _shown = 25; Render(); }, 200);
        var list = new StackPanel();
        foreach (var (r, _) in enhanced.Take(_shown))
        {
            var head = UiKit.HStack(UiKit.Caption(r.Timestamp.ToString("g")).VCenter(), UiKit.Caption($"  ·  {Loc.T(r.PromptName ?? "")}  ·  {r.AiEnhancementModelName}").VCenter());
            list.Children.Add(new Border { Child = UiKit.VStack(head.Margin(0, 0, 0, 6), DiffView.Build(r)) }.Style("Card"));
        }
        if (enhanced.Count == 0) list.Children.Add(UiKit.Caption(Loc.T("No enhanced dictations match this filter.")));
        if (enhanced.Count > _shown)
            list.Children.Add(UiKit.Button(Loc.T("Load More"), () => { _shown += 25; Render(); }).Center());
        children.Add(UiKit.HStack(UiKit.Text(Loc.T("What changed"), 18, FontWeights.SemiBold).VCenter(), filter.Margin(16, 0, 0, 0)).Margin(0, 8, 0, 8));
        children.Add(UiKit.Caption(Loc.T("Red words were removed by the AI, green words were added.")).Margin(0, 0, 0, 10));
        children.Add(list);

        Content = UiKit.Page(Loc.T("Enhancement Insights"), Loc.T("See exactly what AI enhancement changes in your dictations and whether it's worth the wait."), [.. children]);
    }

    private static Border Stat(string title, string value, string detail) => new Border
    {
        Child = UiKit.VStack(UiKit.Text(title, 13, FontWeights.SemiBold),
            new TextBlock { Text = value, FontSize = 26, FontWeight = FontWeights.Black, Margin = new Thickness(0, 6, 0, 2) },
            UiKit.Caption(detail)),
        Margin = new Thickness(0, 0, 12, 12),
    }.Style("Card");

    private static UIElement Bar(string label, int count, int total, Color color)
    {
        var fraction = total == 0 ? 0 : count / (double)total;
        var grid = new Grid { Margin = new Thickness(0, 4, 0, 4) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(230) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(90) });
        grid.Children.Add(UiKit.Text(label, 13).VCenter());
        var track = new Border { Height = 10, CornerRadius = new CornerRadius(5), Background = (Brush)Application.Current.FindResource("SubtleFillColorSecondaryBrush"), VerticalAlignment = VerticalAlignment.Center };
        var fill = new Border { Height = 10, CornerRadius = new CornerRadius(5), Background = new SolidColorBrush(color), HorizontalAlignment = HorizontalAlignment.Left };
        var barGrid = new Grid();
        barGrid.Children.Add(track);
        barGrid.Children.Add(fill);
        barGrid.SizeChanged += (_, _) => fill.Width = Math.Max(fraction > 0 ? 4 : 0, barGrid.ActualWidth * fraction);
        Grid.SetColumn(barGrid, 1);
        grid.Children.Add(barGrid);
        var number = UiKit.Text($"{count}  ({fraction:P0})", 12, secondary: true).VCenter();
        number.Margin = new Thickness(10, 0, 0, 0);
        Grid.SetColumn(number, 2);
        grid.Children.Add(number);
        return grid;
    }
}
