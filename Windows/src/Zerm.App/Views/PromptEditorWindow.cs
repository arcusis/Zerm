using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Zerm.App.Localization;
using Zerm.Core.Enhancement;
using Zerm.Core.Prompts;

namespace Zerm.App.Views;

/// <summary>Port of PromptEditorView.swift.</summary>
public sealed class PromptEditorWindow : Window
{
    public PromptEditorWindow(CustomPrompt? existing)
    {
        var host = AppHost.Current;
        var isNew = existing == null;
        var prompt = existing?.Clone() ?? new CustomPrompt { Title = "", PromptText = PredefinedPrompts.Template("System Default") };
        Title = isNew ? Loc.T("New Prompt") : Loc.T("Edit Prompt");
        Width = 720;
        Height = 760;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        FlowDirection = Loc.Direction;

        var title = new TextBox { Text = prompt.Title, IsEnabled = !prompt.IsPredefined, Width = 320 };
        var icon = new ComboBox { Width = 120, FontFamily = new FontFamily(Icons.FontFamily) };
        foreach (var (symbol, glyph) in Icons.PromptIcons) icon.Items.Add(new ComboBoxItem { Content = glyph, Tag = symbol, FontSize = 16 });
        icon.SelectedItem = icon.Items.Cast<ComboBoxItem>().FirstOrDefault(i => (string)i.Tag == prompt.Icon) ?? icon.Items[0];
        var description = new TextBox { Text = prompt.Description ?? "", Width = 420, IsEnabled = !prompt.IsPredefined };
        var text = new TextBox
        {
            Text = prompt.PromptText, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, Height = 260,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto, IsReadOnly = prompt.IsPredefined, FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 12,
        };
        var useSystem = new CheckBox { Content = Loc.T("Use system instructions (recommended)"), IsChecked = prompt.UseSystemInstructions, IsEnabled = !prompt.IsPredefined };
        var triggers = new TextBox { Text = string.Join(", ", prompt.TriggerWords), Width = 420 };
        var providers = new List<(string, string)> { ("", Loc.T("Use global provider")) };
        providers.AddRange(AIProviders.All.Select(p => (p.Name, p.Name)));
        var provider = UiKit.Combo(providers, prompt.ProviderOverride ?? "", _ => { }, 220);
        var model = new TextBox { Text = prompt.ModelOverride ?? "", Width = 220, ToolTip = Loc.T("Leave empty to use the provider's model") };

        var templates = UiKit.Combo(PromptTexts.Templates.Select(t => (t.Title, Loc.T(t.Title))), "", t =>
        {
            var tpl = PromptTexts.Templates.First(x => x.Title == t);
            text.Text = tpl.Text;
            if (title.Text.Length == 0) title.Text = tpl.Title == "System Default" ? "" : tpl.Title;
            icon.SelectedItem = icon.Items.Cast<ComboBoxItem>().FirstOrDefault(i => (string)i.Tag == tpl.Icon) ?? icon.SelectedItem;
        }, 200);

        var save = UiKit.Button(Loc.T("Save"), () =>
        {
            if (string.IsNullOrWhiteSpace(title.Text) || string.IsNullOrWhiteSpace(text.Text))
            {
                MessageBox.Show(this, Loc.T("A prompt needs a title and instructions."), "Zerm");
                return;
            }
            prompt.Title = title.Text.Trim();
            prompt.Icon = (string)((ComboBoxItem)icon.SelectedItem).Tag;
            prompt.Description = description.Text.Trim();
            prompt.PromptText = text.Text;
            prompt.UseSystemInstructions = useSystem.IsChecked == true;
            prompt.TriggerWords = triggers.Text.Split(',').Select(t => t.Trim()).Where(t => t.Length > 0).ToList();
            prompt.ProviderOverride = provider.SelectedValue is string p && p.Length > 0 ? p : null;
            prompt.ModelOverride = prompt.ProviderOverride != null && model.Text.Trim().Length > 0 ? model.Text.Trim() : null;
            var lib = host.Library;
            var index = lib.Prompts.FindIndex(x => x.Id == prompt.Id);
            if (index >= 0) lib.Prompts[index] = prompt;
            else lib.Prompts.Add(prompt);
            lib.Save();
            DialogResult = true;
        }, accent: true);
        var cancel = UiKit.Button(Loc.T("Cancel"), () => DialogResult = false);

        var stack = UiKit.VStack(
            UiKit.Row(Loc.T("Title"), title),
            UiKit.Row(Loc.T("Icon"), icon),
            UiKit.Row(Loc.T("Description"), description));
        if (isNew) stack.Children.Add(UiKit.Row(Loc.T("Start from template"), templates));
        stack.Children.Add(UiKit.Text(Loc.T("Instructions"), 14, FontWeights.SemiBold).Margin(0, 10, 0, 4));
        if (prompt.IsPredefined) stack.Children.Add(UiKit.Caption(Loc.T("Built-in prompts are kept up to date by Zerm; you can change their trigger words and provider.")).Margin(0, 0, 0, 4));
        stack.Children.Add(text);
        stack.Children.Add(useSystem.Margin(0, 8, 0, 0));
        stack.Children.Add(UiKit.Row(Loc.T("Trigger words"), triggers, Loc.T("Comma-separated. Say one at the start or end of a dictation to use this prompt.")));
        stack.Children.Add(UiKit.Row(Loc.T("Provider override"), provider));
        stack.Children.Add(UiKit.Row(Loc.T("Model override"), model));
        stack.Children.Add(UiKit.HStack(save, cancel).Margin(0, 16, 0, 0));
        Content = new ScrollViewer { Content = new Border { Padding = new Thickness(24), Child = stack }, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    }
}
