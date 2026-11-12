using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using Zerm.App.Localization;
using Zerm.App.Views.Pages;
using Zerm.Core.Data;
using Zerm.Core.Text;

namespace Zerm.App.Views;

/// <summary>Word-level diff of raw transcript vs. AI text: removed words struck through in red, added words in green.</summary>
public static class DiffView
{
    private static readonly Color Red = Color.FromRgb(0xFF, 0x45, 0x3A);
    private static readonly Color Green = Color.FromRgb(0x32, 0xD7, 0x4B);

    public static string LevelLabel(ChangeLevel level) => level switch
    {
        ChangeLevel.None => Loc.T("No change"),
        ChangeLevel.PunctuationOnly => Loc.T("Punctuation & capitals only"),
        _ => Loc.T("Wording changed"),
    };

    public static Color LevelColor(ChangeLevel level) => level switch
    {
        ChangeLevel.None => Color.FromRgb(0x8E, 0x8E, 0x93),
        ChangeLevel.PunctuationOnly => Color.FromRgb(0xFF, 0x9F, 0x0A),
        _ => Green,
    };

    public static FrameworkElement Build(string original, string enhanced, double? seconds = null)
    {
        var diff = WordDiff.Compare(original, enhanced);
        var text = new TextBlock { TextWrapping = TextWrapping.Wrap, FontSize = 14, LineHeight = 22, FlowDirection = UiKit.DirectionOf(enhanced) };
        foreach (var part in diff.Parts)
        {
            var run = new Run(part.Text);
            switch (part.Kind)
            {
                case DiffKind.Removed:
                    run.Foreground = new SolidColorBrush(Red);
                    run.TextDecorations = TextDecorations.Strikethrough;
                    break;
                case DiffKind.Added:
                    run.Foreground = new SolidColorBrush(Green);
                    run.Background = new SolidColorBrush(Color.FromArgb(0x26, Green.R, Green.G, Green.B));
                    break;
            }
            text.Inlines.Add(run);
        }

        var summary = new List<string> { Loc.F("{0} words removed, {1} added", diff.RemovedWords, diff.AddedWords) };
        if (diff.Level == ChangeLevel.Wording) summary.Add(Loc.F("{0:P0} of words changed", diff.ChangedFraction));
        if (seconds is { } s) summary.Add(Loc.F("AI took {0:F1} s", s));
        var header = UiKit.HStack(UiKit.Pill(LevelLabel(diff.Level), LevelColor(diff.Level)), UiKit.Caption(string.Join("  ·  ", summary)).VCenter());
        return UiKit.VStack(header.Margin(0, 0, 0, 8), text);
    }

    public static FrameworkElement Build(TranscriptionRecord r) => Build(r.Text, r.EnhancedText ?? r.Text, r.EnhancementDuration);
}
