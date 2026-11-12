using System.Globalization;
using System.Text.Json;
using System.Windows;
using System.Windows.Markup;

namespace Zerm.App.Localization;

/// <summary>
/// English source strings are the keys (as in Localizable.xcstrings); Hebrew comes from the macOS
/// translations plus Windows-specific additions. The language applies at startup.
/// </summary>
public static class Loc
{
    private static Dictionary<string, string> _table = new();

    public static bool IsHebrew { get; private set; }
    public static FlowDirection Direction => IsHebrew ? FlowDirection.RightToLeft : FlowDirection.LeftToRight;

    public static void Initialize(string setting)
    {
        var code = setting == "system" ? CultureInfo.CurrentUICulture.TwoLetterISOLanguageName : setting;
        IsHebrew = code == "he";
        _table = new();
        if (!IsHebrew) return;
        foreach (var name in new[] { "Zerm.he.json", "Zerm.he.windows.json" })
        {
            using var stream = typeof(Loc).Assembly.GetManifestResourceStream(name);
            if (stream == null) continue;
            foreach (var (k, v) in JsonSerializer.Deserialize<Dictionary<string, string>>(stream) ?? new())
                _table[k] = v;
        }
        var culture = new CultureInfo("he-IL");
        CultureInfo.DefaultThreadCurrentUICulture = culture;
        CultureInfo.DefaultThreadCurrentCulture = culture;
        Thread.CurrentThread.CurrentUICulture = culture;
        Thread.CurrentThread.CurrentCulture = culture;
    }

    public static string T(string english) => _table.TryGetValue(english, out var t) ? t : english;

    public static string F(string english, params object[] args) => string.Format(T(english), args);

    /// <summary>Strings requested at runtime that have no translation (diagnostics).</summary>
    public static IEnumerable<string> Missing(IEnumerable<string> keys) => keys.Where(k => !_table.ContainsKey(k));
}

/// <summary>XAML: Text="{l:T Dashboard}".</summary>
[MarkupExtensionReturnType(typeof(string))]
public sealed class TExtension(string key) : MarkupExtension
{
    public string Key { get; set; } = key;
    public override object ProvideValue(IServiceProvider serviceProvider) => Loc.T(Key);
}
