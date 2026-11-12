using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Automation;
using Zerm.Core;
using Zerm.Core.Settings;

namespace Zerm.App.Platform;

/// <summary>Clipboard access with retries; dictated text is excluded from Windows clipboard history (Win+V) and cloud sync.</summary>
public static class ClipboardService
{
    public static T Retry<T>(Func<T> action, T fallback)
    {
        for (var i = 0; i < 10; i++)
        {
            try { return action(); }
            catch (COMException) { Thread.Sleep(30); }
            catch (ExternalException) { Thread.Sleep(30); }
        }
        return fallback;
    }

    public static string? GetText() => Retry(() => Clipboard.ContainsText() ? Clipboard.GetText() : null, null);

    public static bool SetText(string text, bool excludeFromHistory = true)
    {
        var data = new DataObject();
        data.SetData(DataFormats.UnicodeText, text);
        data.SetData(DataFormats.Text, text);
        if (excludeFromHistory)
        {
            data.SetData("ExcludeClipboardContentFromMonitorProcessing", new MemoryStream(new byte[4]));
            data.SetData("CanIncludeInClipboardHistory", new MemoryStream(BitConverter.GetBytes(0)));
            data.SetData("CanUploadToCloudClipboard", new MemoryStream(BitConverter.GetBytes(0)));
        }
        var ok = Retry(() => { Clipboard.SetDataObject(data, true); return true; }, false);
        return ok && Retry(() => Clipboard.GetText() == text, false);
    }

    /// <summary>Copies every retrievable format so the user's clipboard can be put back after a paste.</summary>
    public static DataObject? Snapshot() => Retry(() =>
    {
        var source = Clipboard.GetDataObject();
        if (source == null) return null;
        var copy = new DataObject();
        foreach (var format in source.GetFormats(false))
        {
            try
            {
                var value = source.GetData(format, false);
                if (value != null) copy.SetData(format, value);
            }
            catch { /* some formats cannot be read back */ }
        }
        return copy;
    }, null);

    public static void Restore(DataObject snapshot) => Retry(() => { Clipboard.SetDataObject(snapshot, true); return true; }, false);
}

/// <summary>Pastes text at the cursor (CursorPaster.swift): clipboard + Ctrl+V via SendInput, optional restore.</summary>
public sealed class Paster(AppSettings settings)
{
    public static async Task WaitForModifiersReleased(int minimumMs = 20, int maximumMs = 300)
    {
        await Task.Delay(minimumMs);
        var sw = Stopwatch.StartNew();
        int[] mods = [Native.VK_LSHIFT, Native.VK_RSHIFT, Native.VK_LMENU, Native.VK_RMENU, Native.VK_LWIN, Native.VK_RWIN, Native.VK_LCONTROL, Native.VK_RCONTROL];
        while (sw.ElapsedMilliseconds < maximumMs && mods.Any(Native.IsDown)) await Task.Delay(5);
    }

    /// <summary>Must be called on the UI thread (clipboard access).</summary>
    public async Task<bool> PasteAsync(string text)
    {
        // Self-test: never paste (the user may be working in another app).
        if (Environment.GetEnvironmentVariable("ZERM_TEST_NO_PASTE") == "1") return true;
        DataObject? snapshot = settings.RestoreClipboardAfterPaste ? ClipboardService.Snapshot() : null;
        if (!ClipboardService.SetText(text))
        {
            Log.Warn("Clipboard write could not be verified; typing the text instead");
            await TypeAsync(text);
            return true;
        }
        var sequence = Native.GetClipboardSequenceNumber();
        await WaitForModifiersReleased();
        SendChord(Native.VK_CONTROL, Native.VK_V);

        if (snapshot != null)
        {
            var delay = TimeSpan.FromSeconds(Math.Max(settings.ClipboardRestoreDelay, 0.25));
            _ = Task.Delay(delay).ContinueWith(_ => Application.Current.Dispatcher.Invoke(() =>
            {
                // Only restore if nobody copied something else in the meantime.
                if (Native.GetClipboardSequenceNumber() == sequence) ClipboardService.Restore(snapshot);
            }));
        }
        return true;
    }

    public static void SendChord(int modifier, int key)
    {
        Native.Send(
            Native.Key((ushort)modifier, false),
            Native.Key((ushort)key, false),
            Native.Key((ushort)key, true),
            Native.Key((ushort)modifier, true));
    }

    /// <summary>Types text as Unicode key events (fallback when the clipboard is locked by another app).</summary>
    public static async Task TypeAsync(string text)
    {
        foreach (var chunk in text.Chunk(20))
        {
            var inputs = new List<Native.INPUT>();
            foreach (var c in chunk)
            {
                if (c == '\n')
                {
                    inputs.Add(Native.Key(Native.VK_SHIFT, false));
                    inputs.Add(Native.Key(Native.VK_RETURN, false));
                    inputs.Add(Native.Key(Native.VK_RETURN, true));
                    inputs.Add(Native.Key(Native.VK_SHIFT, true));
                }
                else if (c != '\r')
                {
                    inputs.Add(Native.Unicode(c, false));
                    inputs.Add(Native.Unicode(c, true));
                }
            }
            Native.Send([.. inputs]);
            await Task.Delay(3);
        }
    }

    public static async Task AutoSendAsync(AutoSendKey key)
    {
        if (key == AutoSendKey.None) return;
        await Task.Delay(500);
        switch (key)
        {
            case AutoSendKey.Enter:
                Native.Send(Native.Key(Native.VK_RETURN, false), Native.Key(Native.VK_RETURN, true));
                break;
            case AutoSendKey.ShiftEnter:
                SendChord(Native.VK_SHIFT, Native.VK_RETURN);
                break;
            case AutoSendKey.CtrlEnter:
                SendChord(Native.VK_CONTROL, Native.VK_RETURN);
                break;
        }
    }
}

/// <summary>Reads the current selection in any app (SelectedTextService.swift).</summary>
public static class SelectedTextService
{
    public static async Task<string?> GetSelectedTextAsync()
    {
        await Paster.WaitForModifiersReleased(0, 1000);
        var viaAutomation = await Task.Run(TryAutomation);
        if (!string.IsNullOrWhiteSpace(viaAutomation)) return viaAutomation;

        // Fallback: synthetic Ctrl+C with the clipboard saved and restored.
        var snapshot = ClipboardService.Snapshot();
        var before = Native.GetClipboardSequenceNumber();
        Paster.SendChord(Native.VK_CONTROL, Native.VK_C);
        var sw = Stopwatch.StartNew();
        while (sw.ElapsedMilliseconds < 600 && Native.GetClipboardSequenceNumber() == before) await Task.Delay(20);
        string? text = null;
        if (Native.GetClipboardSequenceNumber() != before) text = ClipboardService.GetText();
        if (snapshot != null && Native.GetClipboardSequenceNumber() != before) ClipboardService.Restore(snapshot);
        return string.IsNullOrWhiteSpace(text) ? null : text;
    }

    private static string? TryAutomation()
    {
        try
        {
            var focused = AutomationElement.FocusedElement;
            if (focused == null) return null;
            if (focused.TryGetCurrentPattern(TextPattern.Pattern, out var p) && p is TextPattern tp)
            {
                var text = string.Concat(tp.GetSelection().Select(r => r.GetText(-1)));
                return string.IsNullOrWhiteSpace(text) ? null : text;
            }
        }
        catch (Exception ex)
        {
            Log.Debug($"UIA selection failed: {ex.Message}");
        }
        return null;
    }
}

/// <summary>
/// Instant + Refine: replaces the pasted raw text with the refined text in place, but only through a
/// direct UI Automation value write and only if the field is untouched since the paste.
/// </summary>
public sealed class RefineAnchor
{
    private readonly AutomationElement _element;
    private readonly IntPtr _window;
    private readonly string _valueAfterPaste;
    private readonly string _pasted;

    private RefineAnchor(AutomationElement element, IntPtr window, string valueAfterPaste, string pasted)
    {
        _element = element;
        _window = window;
        _valueAfterPaste = valueAfterPaste;
        _pasted = pasted;
    }

    public static async Task<RefineAnchor?> CaptureAsync(string pasted)
    {
        await Task.Delay(150); // let the target app apply the paste
        var window = Native.GetForegroundWindow();
        return await Task.Run(() =>
        {
            try
            {
                var element = AutomationElement.FocusedElement;
                if (element == null || !element.TryGetCurrentPattern(ValuePattern.Pattern, out var p)) return null;
                var vp = (ValuePattern)p;
                if (vp.Current.IsReadOnly) return null;
                var value = vp.Current.Value ?? "";
                return value.Contains(pasted.TrimEnd()) ? new RefineAnchor(element, window, value, pasted.TrimEnd()) : null;
            }
            catch
            {
                return null;
            }
        });
    }

    /// <returns>true when the text was replaced in place.</returns>
    public async Task<bool> TryReplaceAsync(string refined)
    {
        if (Native.GetForegroundWindow() != _window) return false;
        return await Task.Run(() =>
        {
            try
            {
                var vp = (ValuePattern)_element.GetCurrentPattern(ValuePattern.Pattern);
                var current = vp.Current.Value ?? "";
                if (current != _valueAfterPaste) return false; // the user kept typing
                var index = current.LastIndexOf(_pasted, StringComparison.Ordinal);
                if (index < 0) return false;
                vp.SetValue(current[..index] + refined.TrimEnd() + current[(index + _pasted.Length)..]);
                return true;
            }
            catch (Exception ex)
            {
                Log.Debug($"Refine write failed: {ex.Message}");
                return false;
            }
        });
    }
}

/// <summary>Foreground app and browser tab URL for Power Mode (ActiveWindowService.swift).</summary>
public static class ActiveWindowService
{
    private static readonly HashSet<string> Browsers = new(StringComparer.OrdinalIgnoreCase)
    {
        "chrome", "msedge", "firefox", "brave", "opera", "vivaldi", "arc", "zen", "librewolf", "thorium", "yandex", "chromium",
    };

    public static (string? ProcessName, IntPtr Window, string? Title) Foreground()
    {
        var hwnd = Native.GetForegroundWindow();
        try
        {
            Native.GetWindowThreadProcessId(hwnd, out var pid);
            using var p = Process.GetProcessById((int)pid);
            return (p.ProcessName, hwnd, Native.ForegroundTitle());
        }
        catch
        {
            return (null, hwnd, null);
        }
    }

    public static bool IsBrowser(string? process) => process != null && Browsers.Contains(process);

    /// <summary>Reads the address bar through UI Automation; gives up after the timeout.</summary>
    public static async Task<string?> BrowserUrlAsync(IntPtr window, TimeSpan timeout)
    {
        var task = Task.Run(() =>
        {
            try
            {
                var root = AutomationElement.FromHandle(window);
                var edit = root.FindFirst(TreeScope.Descendants, new AndCondition(
                    new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Edit),
                    new PropertyCondition(AutomationElement.IsValuePatternAvailableProperty, true)));
                if (edit?.GetCurrentPattern(ValuePattern.Pattern) is ValuePattern vp)
                {
                    var v = vp.Current.Value;
                    return string.IsNullOrWhiteSpace(v) || v.Contains(' ') ? null : v;
                }
            }
            catch { }
            return null;
        });
        return await Task.WhenAny(task, Task.Delay(timeout)) == task ? await task : null;
    }

    public static IEnumerable<(string ProcessName, string Title)> RunningApps() =>
        Process.GetProcesses()
            .Where(p => { try { return p.MainWindowHandle != IntPtr.Zero && !string.IsNullOrWhiteSpace(p.MainWindowTitle); } catch { return false; } })
            .Select(p => (p.ProcessName, Describe(p)))
            .DistinctBy(p => p.ProcessName.ToLowerInvariant())
            .Where(p => !p.ProcessName.Equals("Zerm", StringComparison.OrdinalIgnoreCase))
            .OrderBy(p => p.Item2);

    private static string Describe(Process p)
    {
        try { return p.MainModule?.FileVersionInfo.FileDescription is { Length: > 0 } d ? d : p.ProcessName; }
        catch { return p.ProcessName; }
    }
}
