namespace Zerm.Core;

/// <summary>Minimal file logger (Logs\zerm-yyyyMMdd.log). Never logs transcript text.</summary>
public static class Log
{
    private static readonly object Gate = new();
    public static bool DebugEnabled { get; set; }

    public static void Info(string message) => Write("INFO", message);
    public static void Warn(string message) => Write("WARN", message);
    public static void Error(string message, Exception? ex = null) =>
        Write("ERROR", ex == null ? message : $"{message}: {ex.GetType().Name}: {ex.Message}\n{ex.StackTrace}");
    public static void Debug(string message)
    {
        if (DebugEnabled) Write("DEBUG", message);
    }

    private static void Write(string level, string message)
    {
        var line = $"{DateTime.Now:HH:mm:ss.fff} [{level}] {message}";
        System.Diagnostics.Debug.WriteLine(line);
        try
        {
            lock (Gate)
                File.AppendAllText(Path.Combine(AppPaths.Logs, $"zerm-{DateTime.Now:yyyyMMdd}.log"), line + Environment.NewLine);
        }
        catch
        {
            // Logging must never take the app down.
        }
    }
}
