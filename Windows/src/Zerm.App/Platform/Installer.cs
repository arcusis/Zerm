using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using Microsoft.Win32;
using Zerm.Core;

namespace Zerm.App.Platform;

/// <summary>
/// Per-user install (no admin): copies Zerm to %LOCALAPPDATA%\Programs\Zerm, creates a Start menu
/// shortcut (so Windows Search finds it) and registers an entry in Settings › Apps with an uninstaller.
/// Paths can be redirected with ZERM_INSTALL_DIR / ZERM_START_MENU_DIR / ZERM_UNINSTALL_KEY for tests.
/// </summary>
public static class Installer
{
    public const string AppId = "Arcusis.Zerm";
    private const string DefaultUninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\Zerm";

    public static string InstallDir => Environment.GetEnvironmentVariable("ZERM_INSTALL_DIR") is { Length: > 0 } d
        ? d
        : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "Zerm");

    public static string StartMenuDir => Environment.GetEnvironmentVariable("ZERM_START_MENU_DIR") is { Length: > 0 } d
        ? d
        : Environment.GetFolderPath(Environment.SpecialFolder.Programs);

    public static string ShortcutPath => Path.Combine(StartMenuDir, "Zerm.lnk");
    public static string UninstallKey => Environment.GetEnvironmentVariable("ZERM_UNINSTALL_KEY") is { Length: > 0 } k ? k : DefaultUninstallKey;
    public static string InstalledExe => Path.Combine(InstallDir, "Zerm.exe");

    /// <summary>True for the one-file build (everything bundled inside Zerm.exe).</summary>
    public static bool IsSingleFile => string.IsNullOrEmpty(typeof(Installer).Assembly.Location);

    /// <summary>Folder of the exe itself (for a single-file build AppContext.BaseDirectory is the extraction folder).</summary>
    private static string CurrentDir => Path.TrimEndingDirectorySeparator(Path.GetDirectoryName(Environment.ProcessPath)!);

    public static bool IsRunningInstalled =>
        string.Equals(CurrentDir, Path.TrimEndingDirectorySeparator(InstallDir), StringComparison.OrdinalIgnoreCase);

    public static bool IsInstalled => File.Exists(InstalledExe) && File.Exists(ShortcutPath);

    /// <summary>Development builds (bin\Debug, bin\Release) never offer to install themselves.</summary>
    public static bool IsDevelopmentBuild =>
        CurrentDir.Contains(@"\bin\Debug\", StringComparison.OrdinalIgnoreCase) || CurrentDir.Contains(@"\bin\Release\", StringComparison.OrdinalIgnoreCase);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int SetCurrentProcessExplicitAppUserModelID(string appId);

    /// <summary>Ties the running process to the Start menu shortcut (taskbar grouping, notifications).</summary>
    public static void ApplyAppIdentity()
    {
        try { SetCurrentProcessExplicitAppUserModelID(AppId); } catch { }
    }

    /// <summary>Copies the app, creates the shortcut and the Apps &amp; features entry. Returns the installed exe path.</summary>
    public static string Install()
    {
        var source = CurrentDir;
        var target = InstallDir;
        if (!IsRunningInstalled && IsSingleFile)
        {
            // One file: the exe carries the whole app.
            Directory.CreateDirectory(target);
            File.Copy(Environment.ProcessPath!, InstalledExe, overwrite: true);
        }
        else if (!IsRunningInstalled)
        {
            Directory.CreateDirectory(target);
            foreach (var file in Directory.EnumerateFiles(source, "*", SearchOption.AllDirectories))
            {
                var dest = Path.Combine(target, Path.GetRelativePath(source, file));
                Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
                File.Copy(file, dest, overwrite: true);
            }
        }
        CreateShortcut();
        Register();
        Log.Info($"Installed to {target}");
        return InstalledExe;
    }

    public static void CreateShortcut()
    {
        Directory.CreateDirectory(StartMenuDir);
        var link = (IShellLinkW)new ShellLink();
        link.SetPath(InstalledExe);
        link.SetWorkingDirectory(InstallDir);
        link.SetDescription("Zerm — voice dictation, file transcription and Read Aloud");
        link.SetIconLocation(InstalledExe, 0);
        var store = (IPropertyStore)link;
        var key = new PropertyKey(new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), 5); // PKEY_AppUserModel_ID
        var value = new PropVariant(AppId);
        store.SetValue(ref key, ref value);
        store.Commit();
        value.Dispose();
        ((IPersistFile)link).Save(ShortcutPath, true);
        Marshal.FinalReleaseComObject(link);
    }

    private static void Register()
    {
        using var key = Registry.CurrentUser.CreateSubKey(UninstallKey);
        var version = typeof(Installer).Assembly.GetName().Version?.ToString(3) ?? "1.0.0";
        long sizeKb = 0;
        try { sizeKb = Directory.EnumerateFiles(InstallDir, "*", SearchOption.AllDirectories).Sum(f => new FileInfo(f).Length) / 1024; } catch { }
        key.SetValue("DisplayName", "Zerm");
        key.SetValue("DisplayVersion", version);
        key.SetValue("Publisher", "Arcusis");
        key.SetValue("DisplayIcon", $"\"{InstalledExe}\",0");
        key.SetValue("InstallLocation", InstallDir);
        key.SetValue("UninstallString", $"\"{InstalledExe}\" --uninstall");
        key.SetValue("QuietUninstallString", $"\"{InstalledExe}\" --uninstall --quiet");
        key.SetValue("URLInfoAbout", "https://arcusis.github.io/Zerm/");
        key.SetValue("InstallDate", DateTime.Now.ToString("yyyyMMdd"));
        key.SetValue("EstimatedSize", (int)Math.Min(int.MaxValue, sizeKb), RegistryValueKind.DWord);
        key.SetValue("NoModify", 1, RegistryValueKind.DWord);
        key.SetValue("NoRepair", 1, RegistryValueKind.DWord);
    }

    /// <summary>Removes the shortcut, the Apps entry, the login item and (after exit) the program folder.</summary>
    public static void Uninstall(bool removeUserData)
    {
        try { File.Delete(ShortcutPath); } catch { }
        try { Registry.CurrentUser.DeleteSubKeyTree(UninstallKey, false); } catch { }
        LaunchAtLogin.Sync(false);
        var folders = new List<string> { InstallDir };
        if (removeUserData) folders.Add(AppPaths.Root);
        if (IsRunningInstalled || removeUserData)
        {
            // The program folder is in use while we run; remove it a few seconds after this process exits.
            var removal = string.Join(" & ", folders.Select(f => $"rmdir /s /q \"{f}\""));
            Process.Start(new ProcessStartInfo("cmd.exe", $"/d /c ping -n 4 127.0.0.1 >nul & {removal}")
            {
                CreateNoWindow = true,
                UseShellExecute = false,
                WorkingDirectory = Path.GetTempPath(),
            });
        }
        else if (Directory.Exists(InstallDir))
        {
            Directory.Delete(InstallDir, true);
        }
        Log.Info("Uninstalled");
    }

    // MARK: - COM interop for .lnk files

    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    private class ShellLink;

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("000214F9-0000-0000-C000-000000000046")]
    private interface IShellLinkW
    {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder file, int cch, IntPtr fd, uint flags);
        void GetIDList(out IntPtr ppidl);
        void SetIDList(IntPtr pidl);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder name, int cch);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string name);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder dir, int cch);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string dir);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder args, int cch);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string args);
        void GetHotkey(out short hotkey);
        void SetHotkey(short hotkey);
        void GetShowCmd(out int showCmd);
        void SetShowCmd(int showCmd);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder path, int cch, out int icon);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string path, int icon);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string path, uint reserved);
        void Resolve(IntPtr hwnd, uint flags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string file);
    }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
    private interface IPropertyStore
    {
        void GetCount(out uint count);
        void GetAt(uint index, out PropertyKey key);
        void GetValue(ref PropertyKey key, out PropVariant value);
        void SetValue(ref PropertyKey key, ref PropVariant value);
        void Commit();
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    private struct PropertyKey(Guid fmtid, uint pid)
    {
        public Guid FormatId = fmtid;
        public uint PropertyId = pid;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct PropVariant : IDisposable
    {
        [FieldOffset(0)] private ushort _vt;
        [FieldOffset(8)] private IntPtr _ptr;

        public PropVariant(string value)
        {
            _vt = 31; // VT_LPWSTR
            _ptr = Marshal.StringToCoTaskMemUni(value);
        }

        public void Dispose()
        {
            if (_ptr != IntPtr.Zero) Marshal.FreeCoTaskMem(_ptr);
            _ptr = IntPtr.Zero;
        }
    }

    /// <summary>Reads a shortcut's target (used to verify the install).</summary>
    public static string? ShortcutTarget(string lnk)
    {
        if (!File.Exists(lnk)) return null;
        var link = (IShellLinkW)new ShellLink();
        ((IPersistFile)link).Load(lnk, 0);
        var sb = new System.Text.StringBuilder(520);
        link.GetPath(sb, sb.Capacity, IntPtr.Zero, 0);
        Marshal.FinalReleaseComObject(link);
        return sb.ToString();
    }
}
