using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Zerm.App.Localization;
using Zerm.Core.Data;
using Zerm.Core.Dictation;
using Zerm.Core.Text;

namespace Zerm.App.Views.Pages;

/// <summary>Port of DictionarySettingsView (vocabulary, word replacements) plus filler words.</summary>
public sealed class VocabularyPage : ContentControl
{
    private readonly AppHost _host = AppHost.Current;
    private bool _ascending = true;

    public VocabularyPage() => Render();

    private void Render()
    {
        var lib = _host.Library;

        // Vocabulary
        var input = new TextBox { Width = 360, ToolTip = Loc.T("e.g. Prakash, Zerm") };
        var error = UiKit.Caption("");
        error.Foreground = new SolidColorBrush(Color.FromRgb(0xFF, 0x45, 0x3A));
        void AddWords()
        {
            var message = lib.AddVocabulary(input.Text);
            if (message != null) error.Text = message;
            else Render();
        }
        input.KeyDown += (_, e) => { if (e.Key == System.Windows.Input.Key.Enter) AddWords(); };
        var chips = new WrapPanel { Margin = new Thickness(0, 10, 0, 0) };
        var words = _ascending ? lib.Vocabulary.OrderBy(v => v.Word, StringComparer.CurrentCultureIgnoreCase) : lib.Vocabulary.OrderByDescending(v => v.Word, StringComparer.CurrentCultureIgnoreCase);
        foreach (var w in words)
        {
            var remove = new Button
            {
                Content = UiKit.Glyph(Icons.Close, 9), Padding = new Thickness(4), Margin = new Thickness(6, 0, 0, 0),
                Background = Brushes.Transparent, BorderThickness = new Thickness(0), ToolTip = Loc.T("Remove"),
            };
            var word = w;
            remove.Click += (_, _) => { lib.Vocabulary.Remove(word); lib.Save(); Render(); };
            chips.Children.Add(new Border
            {
                CornerRadius = new CornerRadius(14), Padding = new Thickness(12, 4, 6, 4), Margin = new Thickness(0, 0, 8, 8),
                Background = (Brush)Application.Current.FindResource("SubtleFillColorSecondaryBrush"),
                BorderBrush = (Brush)Application.Current.FindResource("CardStrokeColorDefaultBrush"), BorderThickness = new Thickness(1),
                Child = UiKit.HStack(new TextBlock { Text = w.Word, VerticalAlignment = VerticalAlignment.Center }, remove),
            });
        }
        if (lib.Vocabulary.Count == 0) chips.Children.Add(UiKit.Caption(Loc.T("No words yet.")));
        var vocab = UiKit.Card(Loc.T("Vocabulary"),
            Loc.T("Add words to help Zerm recognize them properly. They bias local and cloud transcription and are spelled exactly by AI enhancement."),
            UiKit.HStack(input, UiKit.Button(Loc.T("Add"), AddWords, Icons.Add, accent: true).Margin(8, 0, 0, 0),
                UiKit.Button(_ascending ? "A → Z" : "Z → A", () => { _ascending = !_ascending; Render(); })),
            error, chips);

        // Replacements
        var original = new TextBox { Width = 280, ToolTip = Loc.T("Original text (use commas for multiple)") };
        var replacement = new TextBox { Width = 220, ToolTip = Loc.T("Replacement text") };
        var repError = UiKit.Caption("");
        repError.Foreground = new SolidColorBrush(Color.FromRgb(0xFF, 0x45, 0x3A));
        var table = new Grid { Margin = new Thickness(0, 12, 0, 0) };
        table.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        table.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        table.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        table.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var row = 0;
        void Cell(UIElement e, int col)
        {
            Grid.SetRow(e, row);
            Grid.SetColumn(e, col);
            table.Children.Add(e);
        }
        table.RowDefinitions.Add(new RowDefinition());
        Cell(UiKit.Text(Loc.T("On"), 12, FontWeights.SemiBold, true), 0);
        Cell(UiKit.Text(Loc.T("Original"), 12, FontWeights.SemiBold, true).Margin(8, 0, 0, 4), 1);
        Cell(UiKit.Text(Loc.T("Replacement"), 12, FontWeights.SemiBold, true).Margin(8, 0, 0, 4), 2);
        foreach (var r in lib.Replacements.OrderBy(r => r.OriginalText, StringComparer.CurrentCultureIgnoreCase))
        {
            row++;
            table.RowDefinitions.Add(new RowDefinition());
            var item = r;
            var on = new CheckBox { IsChecked = r.IsEnabled, MinWidth = 0, VerticalAlignment = VerticalAlignment.Center };
            on.Click += (_, _) => { item.IsEnabled = on.IsChecked == true; lib.Save(); };
            Cell(on, 0);
            Cell(UiKit.Text(r.OriginalText).Margin(8, 4, 8, 4).VCenter(), 1);
            Cell(UiKit.Text(r.ReplacementText).Margin(8, 4, 8, 4).VCenter(), 2);
            Cell(UiKit.HStack(
                UiKit.IconButton(Icons.Edit, Loc.T("Edit"), () =>
                {
                    var o = UiKit.Prompt(Loc.T("Edit Replacement"), Loc.T("Original text (use commas for multiple)"), item.OriginalText);
                    if (o == null) return;
                    var n = UiKit.Prompt(Loc.T("Edit Replacement"), Loc.T("Replacement text"), item.ReplacementText);
                    if (n == null) return;
                    var err = lib.AddReplacement(o, n, item.Id);
                    if (err != null) _host.Ui.Toast(err, ToastKind.Warning);
                    Render();
                }),
                UiKit.IconButton(Icons.Delete, Loc.T("Delete"), () => { lib.Replacements.Remove(item); lib.Save(); Render(); })), 3);
        }
        void AddReplacement()
        {
            var err = lib.AddReplacement(original.Text, replacement.Text);
            if (err != null) repError.Text = Loc.T(err);
            else Render();
        }
        replacement.KeyDown += (_, e) => { if (e.Key == System.Windows.Input.Key.Enter) AddReplacement(); };
        var preview = new TextBox { Width = 360, Text = Loc.T("my website link is here") };
        var previewOut = UiKit.Caption("");
        void UpdatePreview() => previewOut.Text = "→ " + WordReplacer.Apply(preview.Text, lib.ReplacementRules);
        preview.TextChanged += (_, _) => UpdatePreview();
        UpdatePreview();
        var replacements = UiKit.Card(Loc.T("Word Replacements"),
            Loc.T("Automatically replace words or phrases after transcription — case-insensitive, whole words only."),
            UiKit.Wrap(original, UiKit.Glyph(Icons.Chevron, 12).Margin(8, 0, 8, 0), replacement, UiKit.Button(Loc.T("Add"), AddReplacement, Icons.Add, accent: true).Margin(8, 0, 0, 0)),
            repError,
            lib.Replacements.Count == 0 ? UiKit.Caption(Loc.T("No replacements yet.")).Margin(0, 10, 0, 0) : table,
            UiKit.Divider(),
            UiKit.Row(Loc.T("Try it"), UiKit.VStack(preview, previewOut)));

        // Filler words
        var s = _host.Settings;
        var fillers = new TextBox { Width = 420, Text = string.Join(", ", s.FillerWords) };
        fillers.LostFocus += (_, _) =>
            s.FillerWords = fillers.Text.Split(',').Select(w => w.Trim().ToLowerInvariant()).Where(w => w.Length > 0).Distinct().ToList();
        var filler = UiKit.Card(Loc.T("Filler Words"),
            UiKit.Row(Loc.T("Remove filler words"), UiKit.Toggle(s, nameof(s.RemoveFillerWords)), Loc.T("Removes um, uh and similar words from every transcription.")),
            UiKit.Row(Loc.T("Words"), fillers),
            UiKit.Button(Loc.T("Restore Defaults"), () => { s.FillerWords = [.. TranscriptionOutputFilter.DefaultFillerWords]; Render(); }));

        Content = UiKit.Page(Loc.T("Vocabulary"), Loc.T("Teach Zerm your names, terms and preferred spellings."), vocab, replacements, filler);
    }
}
