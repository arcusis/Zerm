namespace Zerm.Core;

/// <summary>Filesystem layout under %LOCALAPPDATA%\Zerm (override with ZERM_DATA_DIR for tests).</summary>
public static class AppPaths
{
    private static string? _root;

    public static string Root
    {
        get
        {
            if (_root != null) return _root;
            var env = Environment.GetEnvironmentVariable("ZERM_DATA_DIR");
            _root = string.IsNullOrWhiteSpace(env)
                ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Zerm")
                : env;
            Directory.CreateDirectory(_root);
            return _root;
        }
        set
        {
            _root = value;
            Directory.CreateDirectory(value);
        }
    }

    private static string Dir(string name)
    {
        var path = Path.Combine(Root, name);
        Directory.CreateDirectory(path);
        return path;
    }

    public static string Recordings => Dir("Recordings");
    public static string WhisperModels => Dir("WhisperModels");
    public static string SherpaModels => Dir("SherpaOnnxModels");
    public static string TtsModels => Dir("TTSModels");
    public static string DiarizationModels => Dir("DiarizationModels");
    public static string FileTranscription => Dir("FileTranscription");
    public static string CustomSounds => Dir("CustomSounds");
    public static string Logs => Dir("Logs");
    public static string SettingsFile => Path.Combine(Root, "settings.json");
    public static string DataFile => Path.Combine(Root, "library.json");
    public static string SecretsFile => Path.Combine(Root, "secrets.dat");
    public static string Database => Path.Combine(Root, "history.db");
}
