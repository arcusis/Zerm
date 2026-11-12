using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Zerm.App.Localization;
using Zerm.App.Views.Pages;

namespace Zerm.App.Views;

/// <summary>Main window (ContentView.swift): sidebar navigation and the page area.</summary>
public sealed class ShellWindow : Window
{
    private static ShellWindow? _instance;

    private sealed record NavItem(string Key, string Title, string Glyph, int Indent = 0);

    private static readonly (string? Header, NavItem[] Items)[] Sections =
    [
        (null, [new("Dashboard", "Dashboard", Icons.Dashboard)]),
        ("Speech",
        [
            new("History", "History", Icons.History),
            new("Models", "Models", Icons.Models),
            new("Vocabulary", "Vocabulary", Icons.Book),
            new("Speak", "Speak", Icons.Speaker),
            new("ReadAloudHistory", "Read Aloud History", Icons.History),
            new("Voices", "Models & Voices", Icons.Voice),
            new("TranscribeFile", "Transcribe File", Icons.File),
            new("Enhancement", "Enhancement", Icons.Wand),
            new("Insights", "Enhancement Insights", Icons.Filter),
        ]),
        ("Automation", [new("PowerModes", "Power Modes", Icons.Sliders)]),
        ("System", [new("AudioInput", "Audio Input", Icons.Mic)]),
    ];

    private readonly ListBox _nav;
    private readonly ContentControl _content = new();
    private readonly Dictionary<string, Func<FrameworkElement>> _pages;
    private readonly Dictionary<string, ListBoxItem> _items = new();
    private string _current = "";

    public static void ShowAndNavigate(string? page)
    {
        _instance ??= new ShellWindow();
        if (page != null) _instance.Navigate(page);
        else if (_instance._current == "") _instance.Navigate("Dashboard");
        _instance.Show();
        if (_instance.WindowState == WindowState.Minimized) _instance.WindowState = WindowState.Normal;
        _instance.Activate();
        _instance.Topmost = true;
        _instance.Topmost = false;
    }

    public static ShellWindow? Instance => _instance;

    public static ShellWindow CreateForSnapshot() => _instance ??= new ShellWindow();

    public object CurrentContent => _content.Content;

    private ShellWindow()
    {
        Title = "Zerm";
        Width = 1080;
        Height = 760;
        MinWidth = 760;
        MinHeight = 560;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        FlowDirection = Loc.Direction;
        Icon = new System.Windows.Media.Imaging.BitmapImage(new Uri("pack://application:,,,/Assets/Zerm.ico"));

        _pages = new()
        {
            ["Dashboard"] = () => new DashboardPage(),
            ["History"] = () => new HistoryPage(),
            ["Models"] = () => new ModelsPage(),
            ["Vocabulary"] = () => new VocabularyPage(),
            ["Speak"] = () => new SpeakPage(),
            ["ReadAloudHistory"] = () => new ReadAloudHistoryPage(),
            ["Voices"] = () => new VoicesPage(),
            ["TranscribeFile"] = () => new TranscribeFilePage(),
            ["Enhancement"] = () => new EnhancementPage(),
            ["Insights"] = () => new InsightsPage(),
            ["PowerModes"] = () => new PowerModesPage(),
            ["AudioInput"] = () => new AudioInputPage(),
            ["Settings"] = () => new SettingsPage(),
        };

        _nav = new ListBox { BorderThickness = new Thickness(0), Background = Brushes.Transparent, Padding = new Thickness(6, 0, 6, 0) };
        ScrollViewer.SetHorizontalScrollBarVisibility(_nav, ScrollBarVisibility.Disabled);
        foreach (var (header, items) in Sections)
        {
            if (header != null)
                _nav.Items.Add(new ListBoxItem
                {
                    Content = new TextBlock { Text = Loc.T(header) }.Style("SidebarHeader"),
                    IsEnabled = false, Focusable = false, Padding = new Thickness(0),
                });
            foreach (var item in items) _nav.Items.Add(_items[item.Key] = Item(item));
        }
        _nav.SelectionChanged += (_, _) =>
        {
            if (_nav.SelectedItem is ListBoxItem { Tag: string key } && key != _current) Navigate(key);
        };

        var settingsItem = Item(new NavItem("Settings", "Settings", Icons.Settings));
        _items["Settings"] = settingsItem;
        var bottom = new ListBox { BorderThickness = new Thickness(0), Background = Brushes.Transparent, Padding = new Thickness(6, 0, 6, 8) };
        bottom.Items.Add(settingsItem);
        bottom.SelectionChanged += (_, _) =>
        {
            if (bottom.SelectedItem != null)
            {
                _nav.SelectedItem = null;
                if (_current != "Settings") Navigate("Settings");
            }
        };
        _nav.SelectionChanged += (_, _) => { if (_nav.SelectedItem != null) bottom.SelectedItem = null; };

        var brand = UiKit.HStack(
            new Image { Source = new System.Windows.Media.Imaging.BitmapImage(new Uri("pack://application:,,,/Assets/logo.png")), Width = 28, Height = 28, Margin = new Thickness(0, 0, 10, 0) },
            new TextBlock { Text = "Zerm", FontSize = 20, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
        brand.Margin = new Thickness(18, 18, 0, 8);

        var sidebar = new DockPanel { Width = 230 };
        DockPanel.SetDock(brand, Dock.Top);
        DockPanel.SetDock(bottom, Dock.Bottom);
        sidebar.Children.Add(brand);
        sidebar.Children.Add(bottom);
        sidebar.Children.Add(_nav);
        var sidebarBorder = new Border
        {
            Child = sidebar,
            Background = (Brush)Application.Current.FindResource("LayerFillColorDefaultBrush") ?? Brushes.Transparent,
            BorderBrush = (Brush)Application.Current.FindResource("CardStrokeColorDefaultBrush"),
            BorderThickness = Loc.IsHebrew ? new Thickness(1, 0, 0, 0) : new Thickness(0, 0, 1, 0),
        };

        var root = new DockPanel();
        DockPanel.SetDock(sidebarBorder, Dock.Left);
        root.Children.Add(sidebarBorder);
        root.Children.Add(_content);
        Content = root;

        Closing += (_, e) =>
        {
            // Closing the window keeps Zerm running in the tray, like the macOS menu-bar app.
            e.Cancel = true;
            Hide();
        };
        AppHost.Current.NavigationRequested += page => ShowAndNavigate(page);
    }

    private static ListBoxItem Item(NavItem item)
    {
        var row = UiKit.HStack(UiKit.Glyph(item.Glyph, 15).Margin(0, 0, 12, 0), new TextBlock { Text = Loc.T(item.Title), VerticalAlignment = VerticalAlignment.Center });
        return new ListBoxItem { Content = row, Tag = item.Key, Padding = new Thickness(10, 7, 10, 7), Margin = new Thickness(0, 1, 0, 1) };
    }

    public void Navigate(string key)
    {
        if (!_pages.TryGetValue(key, out var factory)) key = "Dashboard";
        _current = key;
        try
        {
            _content.Content = _pages[key]();
        }
        catch (Exception ex)
        {
            Core.Log.Error($"Page {key} failed to load", ex);
            _content.Content = UiKit.Page(Loc.T("Something went wrong"), ex.Message);
        }
        if (_items.TryGetValue(key, out var item) && !item.IsSelected) item.IsSelected = true;
    }
}
