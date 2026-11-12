using System.IO.Pipes;
using System.Windows;
using System.Windows.Threading;
using Zerm.App.Localization;
using Zerm.App.Views;
using Zerm.Core;
using Zerm.Core.Dictation;
using Zerm.Core.Settings;
using Forms = System.Windows.Forms;

namespace Zerm.App;

public partial class App : Application
{
    private const string InstanceName = "Zerm.Windows.SingleInstance";
    private Mutex? _mutex;
    private Forms.NotifyIcon? _tray;
    private AppHost? _host;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        Platform.Installer.ApplyAppIdentity();
        if (HandleInstallCommands(e.Args)) return;

        // Test modes run isolated (own data folder, no hooks) next to a normal instance.
        var testMode = e.Args.Contains("--snapshot") || e.Args.Contains("--selftest");
        var first = true;
        if (!testMode) _mutex = new Mutex(true, InstanceName, out first);
        // After "Restart" the previous instance may still be shutting down.
        if (!first && e.Args.Contains("--restarted"))
        {
            try { first = _mutex!.WaitOne(TimeSpan.FromSeconds(10)); }
            catch (AbandonedMutexException) { first = true; }
        }
        if (!first)
        {
            SignalRunningInstance(e.Args);
            Shutdown();
            return;
        }

        DispatcherUnhandledException += (_, ex) =>
        {
            Log.Error("Unhandled UI exception", ex.Exception);
            ex.Handled = true;
            ToastWindow.Show(Loc.T("Something went wrong") + ": " + ex.Exception.Message, ToastKind.Error, TimeSpan.FromSeconds(5));
        };
        AppDomain.CurrentDomain.UnhandledException += (_, ex) => Log.Error("Unhandled exception", ex.ExceptionObject as Exception);
        TaskScheduler.UnobservedTaskException += (_, ex) =>
        {
            Log.Error("Unobserved task exception", ex.Exception);
            ex.SetObserved();
        };

        PowerThrottling.OptOut();
        var settings = AppSettings.Load();
        Loc.Initialize(settings.UiLanguage);
        Log.Info($"Zerm for Windows starting (data: {AppPaths.Root})");

        _host = new AppHost(Dispatcher);
        if (e.Args.SkipWhile(a => a != "--snapshot").Skip(1).FirstOrDefault() is { } snapshotDir)
        {
            Dispatcher.InvokeAsync(async () =>
            {
                try { await Snapshotter.RunAsync(snapshotDir); }
                catch (Exception ex) { Log.Error("Snapshot failed", ex); }
                Quit();
            });
            return;
        }
        var selfTest = e.Args.SkipWhile(a => a != "--selftest").Skip(1).Take(2).ToArray();
        if (selfTest.Length == 2)
        {
            Dispatcher.InvokeAsync(async () =>
            {
                try { await SelfTest.RunAsync(selfTest[0], selfTest[1]); }
                catch (Exception ex) { Log.Error("Self-test failed", ex); }
                Quit();
            });
            return;
        }
        if (!_host.Hotkeys.Install())
            ToastWindow.Show(Loc.T("Hotkey not working — Zerm could not install its keyboard hook."), ToastKind.Error, TimeSpan.FromSeconds(6));

        CreateTray();
        ListenForOtherInstances();
        // A downloaded Zerm.exe installs itself first; the installed copy then runs onboarding.
        if (EnsureInstalled()) return;
        StartupTasks();

        var showWindow = e.Args.Contains("--show") || !_host.Settings.HasCompletedOnboarding || !_host.Settings.StartMinimized;
        var page = e.Args.SkipWhile(a => a != "--page").Skip(1).FirstOrDefault();
        if (!_host.Settings.HasCompletedOnboarding && !e.Args.Contains("--skip-onboarding"))
            new OnboardingWindow().Show();
        else if (showWindow || page != null)
            ShellWindow.ShowAndNavigate(page ?? "Dashboard");
        else
            ToastWindow.Show(Loc.F("Zerm is running. Press {0} to dictate.", Platform.HotkeyService.Describe(_host.Settings.Hotkey1, _host.Settings.Hotkey1Custom)),
                ToastKind.Info, TimeSpan.FromSeconds(4));
    }

    /// <summary>"--install" and "--uninstall [--quiet]" (the Settings › Apps uninstall entry runs the latter).</summary>
    private bool HandleInstallCommands(string[] args)
    {
        if (args.Contains("--install"))
        {
            try
            {
                // Updating: close the installed copy if it's running, replace it, and reopen it.
                var installedRunning = InstalledProcesses();
                if (installedRunning.Count > 0)
                {
                    SignalRunningInstance(["--quit"]);
                    foreach (var p in installedRunning) p.WaitForExit(8000);
                }
                var exe = Platform.Installer.Install();
                var running = System.Diagnostics.Process.GetProcessesByName("Zerm").Any(p => p.Id != Environment.ProcessId);
                if (installedRunning.Count > 0 || (!running && !args.Contains("--no-launch")))
                    System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(exe, "--show --restarted") { UseShellExecute = false });
            }
            catch (Exception ex)
            {
                Log.Error("Install failed", ex);
                MessageBox.Show(Loc.T("Install failed") + ": " + ex.Message, "Zerm", MessageBoxButton.OK, MessageBoxImage.Error);
            }
            Shutdown();
            return true;
        }
        if (args.Contains("--uninstall"))
        {
            var quiet = args.Contains("--quiet");
            Loc.Initialize(AppSettings.Load().UiLanguage);
            if (!quiet && MessageBox.Show(Loc.T("Uninstall Zerm from this PC?"), "Zerm", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes)
            {
                Shutdown();
                return true;
            }
            var removeData = !quiet && MessageBox.Show(Loc.T("Also delete your history, settings and downloaded models?"), "Zerm",
                MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No) == MessageBoxResult.Yes;
            // Close the installed copy if it is running (never a copy running from somewhere else).
            var installed = InstalledProcesses();
            if (installed.Count > 0)
            {
                SignalRunningInstance(["--quit"]);
                foreach (var p in installed) p.WaitForExit(5000);
            }
            Platform.Installer.Uninstall(removeData);
            if (!quiet) MessageBox.Show(Loc.T("Zerm was uninstalled."), "Zerm", MessageBoxButton.OK, MessageBoxImage.Information);
            Shutdown();
            return true;
        }
        return false;
    }

    private static List<System.Diagnostics.Process> InstalledProcesses() =>
        System.Diagnostics.Process.GetProcessesByName("Zerm").Where(p =>
        {
            try { return p.Id != Environment.ProcessId && p.MainModule?.FileName.StartsWith(Platform.Installer.InstallDir, StringComparison.OrdinalIgnoreCase) == true; }
            catch { return false; }
        }).ToList();

    /// <summary>Installed copies keep their Start menu shortcut; other copies offer to install once.</summary>
    /// <returns>true when this process is handing over to the freshly installed copy.</returns>
    private bool EnsureInstalled()
    {
        var host = _host!;
        try
        {
            if (Platform.Installer.IsRunningInstalled)
            {
                if (!File.Exists(Platform.Installer.ShortcutPath)) Platform.Installer.Install();
                return false;
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"Shortcut repair failed: {ex.Message}");
            return false;
        }
        if (Platform.Installer.IsDevelopmentBuild || host.Settings.InstallOffered) return false;
        host.Settings.InstallOffered = true;
        host.Settings.SaveNow();
        if (MessageBox.Show(Loc.T("Install Zerm on this PC? It will appear in the Start menu and Windows Search, and in Settings › Apps for uninstalling."),
                "Zerm", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes)
            return false;
        InstallAndRelaunch();
        return true;
    }

    public void InstallAndRelaunch()
    {
        try
        {
            var exe = Platform.Installer.Install();
            if (Platform.Installer.IsRunningInstalled) return;
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(exe, "--show --restarted") { UseShellExecute = false });
            Quit();
        }
        catch (Exception ex)
        {
            Log.Error("Install failed", ex);
            ToastWindow.Show(Loc.T("Install failed") + ": " + ex.Message, ToastKind.Error, TimeSpan.FromSeconds(6));
        }
    }

    private void StartupTasks()
    {
        var host = _host!;
        // Whisper first (dictation must be ready soonest), then the on-device LLM.
        _ = host.PrewarmAsync().ContinueWith(_ => host.PrewarmLlmAsync());
        _ = Task.Run(() =>
        {
            try
            {
                var s = host.Settings;
                var (t, a) = host.History.Cleanup(s.TranscriptionCleanupEnabled ? s.TranscriptionRetentionMinutes : null,
                    s.AudioCleanupEnabled ? s.AudioRetentionDays : null);
                if (t + a > 0) Log.Info($"Retention cleanup removed {t} transcripts and {a} audio files");
            }
            catch (Exception ex)
            {
                Log.Error("Retention cleanup failed", ex);
            }
        });
        var daily = new DispatcherTimer { Interval = TimeSpan.FromHours(6) };
        daily.Tick += (_, _) => host.History.Cleanup(host.Settings.TranscriptionCleanupEnabled ? host.Settings.TranscriptionRetentionMinutes : null,
            host.Settings.AudioCleanupEnabled ? host.Settings.AudioRetentionDays : null);
        daily.Start();
        LaunchAtLogin.Sync(host.Settings.LaunchAtLogin);
    }

    private void CreateTray()
    {
        var host = _host!;
        _tray = new Forms.NotifyIcon
        {
            Icon = new System.Drawing.Icon(GetResourceStream(new Uri("pack://application:,,,/Assets/Zerm.ico"))!.Stream),
            Text = "Zerm",
            Visible = true,
        };
        _tray.DoubleClick += (_, _) => ShellWindow.ShowAndNavigate(null);
        var menu = new Forms.ContextMenuStrip();
        menu.Opening += (_, _) => BuildTrayMenu(menu);
        BuildTrayMenu(menu);
        _tray.ContextMenuStrip = menu;
    }

    /// <summary>Tray menu (MenuBarView.swift).</summary>
    private void BuildTrayMenu(Forms.ContextMenuStrip menu)
    {
        var host = _host!;
        menu.Items.Clear();
        menu.RightToLeft = Loc.IsHebrew ? Forms.RightToLeft.Yes : Forms.RightToLeft.No;
        menu.Items.Add(Loc.T("Toggle Recorder"), null, (_, _) => _ = host.Dictation.ToggleAsync());
        menu.Items.Add(new Forms.ToolStripSeparator());
        var enhance = new Forms.ToolStripMenuItem(Loc.T("AI Enhancement")) { Checked = host.Settings.OutputMode != DictationOutputMode.Instant };
        enhance.Click += (_, _) =>
        {
            if (host.Settings.OutputMode == DictationOutputMode.Instant)
                host.Settings.OutputMode = host.Settings.LastEnhancingOutputMode == DictationOutputMode.Instant ? DictationOutputMode.InstantRefine : host.Settings.LastEnhancingOutputMode;
            else
            {
                host.Settings.LastEnhancingOutputMode = host.Settings.OutputMode;
                host.Settings.OutputMode = DictationOutputMode.Instant;
            }
        };
        menu.Items.Add(enhance);
        var super = new Forms.ToolStripMenuItem(Loc.T("Super Enhancement")) { Checked = host.Settings.SuperEnhancement && host.Settings.OutputMode != DictationOutputMode.Instant };
        super.Click += (_, _) =>
        {
            var on = !(host.Settings.SuperEnhancement && host.Settings.OutputMode != DictationOutputMode.Instant);
            host.Settings.SuperEnhancement = on;
            if (on && host.Settings.OutputMode == DictationOutputMode.Instant) host.Settings.OutputMode = DictationOutputMode.Enhanced;
            if (on) _ = host.PrewarmLlmAsync();
        };
        menu.Items.Add(super);
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add(Loc.T("Retry Last Transcription"), null, (_, _) => _ = host.Dictation.RetryLastAsync());
        menu.Items.Add(Loc.T("Copy Last Transcription"), null, (_, _) =>
        {
            if (host.History.Latest() is { } last) Platform.ClipboardService.SetText(last.DisplayText);
        });
        menu.Items.Add(Loc.T("History"), null, (_, _) => ShellWindow.ShowAndNavigate("History"));
        menu.Items.Add(Loc.T("Transcribe File"), null, (_, _) => ShellWindow.ShowAndNavigate("TranscribeFile"));
        menu.Items.Add(Loc.T("Settings"), null, (_, _) => ShellWindow.ShowAndNavigate("Settings"));
        var login = new Forms.ToolStripMenuItem(Loc.T("Launch at Login")) { Checked = host.Settings.LaunchAtLogin };
        login.Click += (_, _) =>
        {
            host.Settings.LaunchAtLogin = !host.Settings.LaunchAtLogin;
            LaunchAtLogin.Sync(host.Settings.LaunchAtLogin);
        };
        menu.Items.Add(login);
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add(Loc.T("Open Zerm"), null, (_, _) => ShellWindow.ShowAndNavigate(null));
        menu.Items.Add(Loc.T("Quit Zerm"), null, (_, _) => Quit());
    }

    public void Quit()
    {
        _tray?.Dispose();
        _tray = null;
        _host?.Dispose();
        Shutdown();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _tray?.Dispose();
        try { _mutex?.ReleaseMutex(); } catch { }
        base.OnExit(e);
    }

    private static void SignalRunningInstance(string[] args)
    {
        try
        {
            using var client = new NamedPipeClientStream(".", InstanceName, PipeDirection.Out);
            client.Connect(1000);
            using var writer = new StreamWriter(client);
            writer.Write(string.Join(" ", args.Length == 0 ? ["--show"] : args));
        }
        catch { }
    }

    /// <summary>A second launch brings the running instance's window forward.</summary>
    private void ListenForOtherInstances()
    {
        Task.Run(async () =>
        {
            while (true)
            {
                try
                {
                    await using var server = new NamedPipeServerStream(InstanceName, PipeDirection.In);
                    await server.WaitForConnectionAsync();
                    using var reader = new StreamReader(server);
                    var message = await reader.ReadToEndAsync();
                    await Dispatcher.InvokeAsync(() =>
                    {
                        if (message.Contains("--quit")) Quit();
                        else if (message.Contains("--toggle")) _ = _host!.Dictation.ToggleAsync();
                        else ShellWindow.ShowAndNavigate(null);
                    });
                }
                catch (Exception ex)
                {
                    Log.Warn($"Instance pipe: {ex.Message}");
                    await Task.Delay(1000);
                }
            }
        });
    }
}

/// <summary>HKCU Run key entry for "Launch at Login".</summary>
public static class LaunchAtLogin
{
    private const string Key = @"Software\Microsoft\Windows\CurrentVersion\Run";

    public static void Sync(bool enabled)
    {
        try
        {
            using var run = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(Key, true);
            if (run == null) return;
            if (enabled) run.SetValue("Zerm", $"\"{Environment.ProcessPath}\"");
            else if (run.GetValue("Zerm") != null) run.DeleteValue("Zerm");
        }
        catch (Exception ex)
        {
            Log.Warn($"Launch at login: {ex.Message}");
        }
    }
}
