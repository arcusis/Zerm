namespace Zerm.App.Views;

/// <summary>SF Symbol names used by the shared data mapped to Segoe Fluent Icons glyphs.</summary>
public static class Icons
{
    public const string FontFamily = "Segoe Fluent Icons, Segoe MDL2 Assets";

    public static readonly IReadOnlyList<(string Symbol, string Glyph)> PromptIcons =
    [
        ("doc.text.fill", "\uE8A5"), ("checkmark.seal.fill", "\uE73E"), ("bubble.left.and.bubble.right.fill", "\uE8BD"),
        ("message.fill", "\uE8F2"), ("curlybraces", "\uE943"), ("envelope.fill", "\uE715"), ("pencil.circle.fill", "\uE70F"),
        ("terminal.fill", "\uE756"), ("briefcase.fill", "\uE821"), ("person.2.fill", "\uE716"), ("book.fill", "\uE82D"),
        ("lightbulb.fill", "\uEA80"), ("star.fill", "\uE734"), ("flag.fill", "\uE7C1"), ("list.bullet", "\uE8FD"),
        ("calendar", "\uE787"), ("clock.fill", "\uE823"), ("megaphone.fill", "\uE789"), ("heart.fill", "\uEB51"),
        ("globe", "\uE774"), ("translate", "\uF2B7"), ("mic.fill", "\uE720"), ("brain.head.profile", "\uE945"),
    ];

    public static string Glyph(string? symbol) =>
        PromptIcons.FirstOrDefault(p => p.Symbol == symbol).Glyph ?? "\uE8A5";

    public const string Mic = "\uE720", Sparkle = "\uE945", Speaker = "\uE767", Stop = "\uE71A", History = "\uE81C",
        Dashboard = "\uE9D9", Models = "\uE950", Book = "\uE82D", File = "\uE8E5", Wand = "\uE945", Sliders = "\uE9E9",
        Settings = "\uE713", Copy = "\uE8C8", Delete = "\uE74D", Play = "\uE768", Retry = "\uE72C", Add = "\uE710",
        Edit = "\uE70F", Folder = "\uE838", Voice = "\uE8D4", Chevron = "\uE76C", Search = "\uE721", Info = "\uE946",
        Warning = "\uE7BA", Error = "\uEA39", Check = "\uE73E", Download = "\uE896", Pause = "\uE769", Close = "\uE711",
        Keyboard = "\uE765", Shield = "\uE83D", Export = "\uEDE1", Filter = "\uE71C";
}
