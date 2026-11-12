using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Data;
using System.Windows.Media;
using Zerm.App.Localization;

namespace Zerm.App.Views;

/// <summary>Small builders so every page shares one visual language (cards, setting rows, bound controls).</summary>
public static class UiKit
{
    public static T Style<T>(this T element, string key) where T : FrameworkElement
    {
        element.Style = (Style)Application.Current.Resources[key];
        return element;
    }

    public static T Margin<T>(this T e, double l, double t, double r, double b) where T : FrameworkElement
    {
        e.Margin = new Thickness(l, t, r, b);
        return e;
    }

    public static ScrollViewer Page(string title, string? subtitle, params UIElement[] content)
    {
        var stack = new StackPanel { MaxWidth = 860, Margin = new Thickness(32, 24, 32, 32), HorizontalAlignment = HorizontalAlignment.Stretch };
        stack.Children.Add(new TextBlock { Text = title }.Style("PageTitle"));
        if (subtitle != null) stack.Children.Add(new TextBlock { Text = subtitle }.Style("PageSubtitle"));
        else stack.Children.Add(new Border { Height = 14 });
        foreach (var c in content) stack.Children.Add(c);
        return new ScrollViewer { Content = stack, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
    }

    public static Border Card(string? title, params UIElement[] content) => Card(title, null, content);

    public static Border Card(string? title, string? caption, params UIElement[] content)
    {
        var stack = new StackPanel();
        if (title != null) stack.Children.Add(new TextBlock { Text = title }.Style("SectionTitle"));
        if (caption != null) stack.Children.Add(new TextBlock { Text = caption, Margin = new Thickness(0, -4, 0, 10) }.Style("Caption"));
        foreach (var c in content) stack.Children.Add(c);
        return new Border { Child = stack }.Style("Card");
    }

    public static TextBlock Text(string text, double size = 14, FontWeight? weight = null, bool secondary = false) => new()
    {
        Text = text,
        FontSize = size,
        FontWeight = weight ?? FontWeights.Normal,
        TextWrapping = TextWrapping.Wrap,
        Foreground = secondary ? (Brush)Application.Current.FindResource("TextFillColorSecondaryBrush") : (Brush)Application.Current.FindResource("TextFillColorPrimaryBrush"),
    };

    /// <summary>Direction of user content from its first strong character (Hebrew/Arabic → RTL).</summary>
    public static FlowDirection DirectionOf(string? text)
    {
        foreach (var c in text ?? "")
        {
            if (Core.FileTranscription.BidiText.IsRtl(c)) return FlowDirection.RightToLeft;
            if (char.IsLetter(c)) return FlowDirection.LeftToRight;
        }
        return Loc.Direction;
    }

    public static TextBlock Caption(string text) => new TextBlock { Text = text }.Style("Caption");

    public static TextBlock Glyph(string glyph, double size = 16, Brush? brush = null) => new()
    {
        Text = glyph,
        FontFamily = new FontFamily(Icons.FontFamily),
        FontSize = size,
        VerticalAlignment = VerticalAlignment.Center,
        Foreground = brush ?? (Brush)Application.Current.FindResource("TextFillColorPrimaryBrush"),
    };

    /// <summary>Label (+ caption) on the left, control on the right.</summary>
    public static Grid Row(string label, UIElement control, string? caption = null)
    {
        var grid = new Grid { Margin = new Thickness(0, 6, 0, 6) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var left = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 16, 0) };
        left.Children.Add(Text(label));
        if (caption != null) left.Children.Add(Caption(caption).Margin(0, 2, 0, 0));
        grid.Children.Add(left);
        if (control is FrameworkElement fe) fe.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(control, 1);
        grid.Children.Add(control);
        return grid;
    }

    public static Binding Bind(object source, string path, IValueConverter? converter = null) =>
        new(path) { Source = source, Mode = BindingMode.TwoWay, UpdateSourceTrigger = UpdateSourceTrigger.PropertyChanged, Converter = converter };

    public static CheckBox Toggle(object source, string path, string? content = null)
    {
        var cb = new CheckBox { Content = content, MinWidth = 0 };
        cb.SetBinding(ToggleButton.IsCheckedProperty, Bind(source, path));
        return cb;
    }

    public static ComboBox Combo<T>(IEnumerable<(T Value, string Label)> items, object source, string path, double width = 240)
    {
        var combo = new ComboBox { Width = width, DisplayMemberPath = "Label", SelectedValuePath = "Value" };
        combo.ItemsSource = items.Select(i => new ComboItem(i.Value!, i.Label)).ToList();
        combo.SetBinding(Selector.SelectedValueProperty, Bind(source, path));
        return combo;
    }

    public static ComboBox Combo<T>(IEnumerable<(T Value, string Label)> items, T selected, Action<T> changed, double width = 240)
    {
        var combo = new ComboBox { Width = width, DisplayMemberPath = "Label", SelectedValuePath = "Value" };
        combo.ItemsSource = items.Select(i => new ComboItem(i.Value!, i.Label)).ToList();
        combo.SelectedValue = selected;
        combo.SelectionChanged += (_, _) =>
        {
            if (combo.SelectedValue is T v) changed(v);
        };
        return combo;
    }

    public sealed record ComboItem(object Value, string Label);

    public static TextBox TextBox(object source, string path, double width = 280, bool multiline = false)
    {
        var tb = new TextBox { Width = width, TextWrapping = multiline ? TextWrapping.Wrap : TextWrapping.NoWrap, AcceptsReturn = multiline };
        tb.SetBinding(System.Windows.Controls.TextBox.TextProperty, new Binding(path) { Source = source, Mode = BindingMode.TwoWay, UpdateSourceTrigger = UpdateSourceTrigger.LostFocus });
        return tb;
    }

    public static StackPanel SliderWithValue(object source, string path, double min, double max, double step, string format, double width = 220)
    {
        var slider = new Slider { Minimum = min, Maximum = max, TickFrequency = step, IsSnapToTickEnabled = true, Width = width, VerticalAlignment = VerticalAlignment.Center };
        slider.SetBinding(RangeBase.ValueProperty, Bind(source, path));
        var label = new TextBlock { Width = 64, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10, 0, 0, 0) };
        label.SetBinding(TextBlock.TextProperty, new Binding(path) { Source = source, StringFormat = format });
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        row.Children.Add(slider);
        row.Children.Add(label);
        return row;
    }

    public static Button Button(string text, Action click, string? glyph = null, bool accent = false)
    {
        object content = text;
        if (glyph != null)
        {
            var sp = new StackPanel { Orientation = Orientation.Horizontal };
            sp.Children.Add(Glyph(glyph, 13, accent ? Brushes.White : null).Margin(0, 0, 8, 0));
            sp.Children.Add(new TextBlock { Text = text, VerticalAlignment = VerticalAlignment.Center });
            content = sp;
        }
        var b = new Button { Content = content, Padding = new Thickness(14, 6, 14, 6), Margin = new Thickness(0, 0, 8, 0) };
        if (accent && Application.Current.TryFindResource("AccentButtonStyle") is Style s) b.Style = s;
        b.Click += (_, _) => click();
        return b;
    }

    public static Button IconButton(string glyph, string tooltip, Action click)
    {
        var b = new Button { Content = Glyph(glyph, 14), ToolTip = tooltip, Padding = new Thickness(8, 6, 8, 6), Margin = new Thickness(2, 0, 2, 0) };
        b.Click += (_, _) => click();
        return b;
    }

    public static StackPanel HStack(params UIElement[] children)
    {
        var sp = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var c in children) sp.Children.Add(c);
        return sp;
    }

    public static WrapPanel Wrap(params UIElement[] children)
    {
        var wp = new WrapPanel();
        foreach (var c in children) wp.Children.Add(c);
        return wp;
    }

    public static StackPanel VStack(params UIElement[] children)
    {
        var sp = new StackPanel();
        foreach (var c in children) sp.Children.Add(c);
        return sp;
    }

    public static Separator Divider() => new() { Margin = new Thickness(0, 8, 0, 8), Opacity = 0.5 };

    public static Border Pill(string text, Color color) => new()
    {
        Background = new SolidColorBrush(Color.FromArgb(0x33, color.R, color.G, color.B)),
        CornerRadius = new CornerRadius(6),
        Padding = new Thickness(6, 1, 6, 2),
        Margin = new Thickness(0, 0, 6, 0),
        VerticalAlignment = VerticalAlignment.Center,
        Child = new TextBlock { Text = text, FontSize = 11, Foreground = new SolidColorBrush(color), FontWeight = FontWeights.SemiBold },
    };

    /// <summary>Re-runs <paramref name="update"/> whenever any listed property of <paramref name="source"/> changes.</summary>
    public static void OnChange(INotifyPropertyChanged source, Action update, params string[] properties)
    {
        source.PropertyChanged += (_, e) =>
        {
            if (properties.Length == 0 || properties.Contains(e.PropertyName))
                Application.Current.Dispatcher.BeginInvoke(update);
        };
    }

    public static bool Confirm(string message, string title = "Zerm") =>
        MessageBox.Show(Application.Current.Windows.OfType<Window>().FirstOrDefault(w => w.IsActive) ?? Application.Current.MainWindow!,
            message, title, MessageBoxButton.YesNo, MessageBoxImage.Question,
            MessageBoxResult.No, Loc.IsHebrew ? MessageBoxOptions.RtlReading | MessageBoxOptions.RightAlign : MessageBoxOptions.None) == MessageBoxResult.Yes;

    public static string? Prompt(string title, string label, string initial = "")
    {
        var box = new TextBox { Text = initial, MinWidth = 320, Margin = new Thickness(0, 8, 0, 12) };
        var ok = new Button { Content = Loc.T("OK"), IsDefault = true, MinWidth = 80, Margin = new Thickness(0, 0, 8, 0) };
        var cancel = new Button { Content = Loc.T("Cancel"), IsCancel = true, MinWidth = 80 };
        var w = new Window
        {
            Title = title, SizeToContent = SizeToContent.WidthAndHeight, ResizeMode = ResizeMode.NoResize,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, Owner = Application.Current.Windows.OfType<ShellWindow>().FirstOrDefault(),
            FlowDirection = Loc.Direction,
            Content = new StackPanel { Margin = new Thickness(20), Children = { Text(label), box, HStack(ok, cancel) } },
        };
        ok.Click += (_, _) => w.DialogResult = true;
        box.Loaded += (_, _) => { box.Focus(); box.SelectAll(); };
        return w.ShowDialog() == true ? box.Text : null;
    }
}
