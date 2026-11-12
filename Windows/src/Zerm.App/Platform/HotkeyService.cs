using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows.Threading;
using Zerm.Core;
using Zerm.Core.Settings;

namespace Zerm.App.Platform;

public enum HotkeySlot { Dictation1, Dictation2, ReadAloud }

public enum ShortcutAction { Cancel, PasteLast, PasteLastEnhanced, RetryLast }

/// <summary>
/// Global keyboard and mouse hooks (WH_KEYBOARD_LL / WH_MOUSE_LL) — the Windows counterpart of
/// HotkeyManager.swift. Side-specific modifiers, custom combinations, single keys, Escape and the
/// recorder-only shortcuts. Events are raised on the UI dispatcher.
/// </summary>
public sealed class HotkeyService : IDisposable
{
    private readonly AppSettings _settings;
    private readonly Dispatcher _dispatcher;
    private readonly Native.HookProc _keyboardProc;
    private readonly Native.HookProc _mouseProc;
    private IntPtr _keyboardHook, _mouseHook;

    private readonly HashSet<int> _down = [];
    private readonly Dictionary<HotkeySlot, bool> _slotDown = new();
    private readonly Dictionary<HotkeySlot, bool> _otherKeyDuringHold = new();
    private DispatcherTimer? _middleTimer;

    public event Action<HotkeySlot>? TriggerDown;
    /// <summary>
    /// Arguments: slot, true when no other key was pressed while the trigger was held, and how long it was
    /// held — measured in the hook, so a busy UI thread can't turn a tap into a hold.
    /// </summary>
    public event Action<HotkeySlot, bool, TimeSpan>? TriggerUp;
    private readonly Dictionary<HotkeySlot, DateTime> _downAt = new();
    public event Action? EscapePressed;
    public event Action<ShortcutAction>? ShortcutPressed;
    public event Action? ToggleEnhancementPressed;
    public event Action<int>? PromptNumberPressed;
    public event Action<int>? PowerModeNumberPressed;
    public event Action? MiddleClickToggle;
    public event Action<KeyCombo?>? KeyCaptured;
    public event Action<Guid>? PowerModeHotkeyPressed;

    /// <summary>True while the recorder is on screen: Escape and Ctrl+E / Ctrl+digit / Alt+digit are active.</summary>
    public bool RecorderVisible { get; set; }

    /// <summary>Test hook: accept synthetic key presses from other processes (ZERM_TEST_ALLOW_INJECTED=1).</summary>
    private static readonly bool AllowInjected = Environment.GetEnvironmentVariable("ZERM_TEST_ALLOW_INJECTED") == "1";
    public bool IsCapturing { get; private set; }
    public bool IsInstalled => _keyboardHook != IntPtr.Zero;
    public Func<IEnumerable<(Guid Id, KeyCombo Combo)>>? PowerModeHotkeys { get; set; }

    public HotkeyService(AppSettings settings, Dispatcher dispatcher)
    {
        _settings = settings;
        _dispatcher = dispatcher;
        _keyboardProc = KeyboardProc;
        _mouseProc = MouseProc;
    }

    private Thread? _hookThread;
    private uint _hookThreadId;
    private readonly object _stateGate = new();

    /// <summary>
    /// Installs the hooks on a dedicated thread with its own message loop. Hook callbacks are delivered
    /// on the installing thread, so keeping them off the UI thread means a busy UI never delays key
    /// events (or makes Windows drop the hook for exceeding its timeout).
    /// </summary>
    public bool Install()
    {
        var ready = new ManualResetEventSlim();
        var ok = false;
        _hookThread = new Thread(() =>
        {
            _hookThreadId = Native.GetCurrentThreadId();
            var module = Native.GetModuleHandle(Process.GetCurrentProcess().MainModule?.ModuleName);
            _keyboardHook = Native.SetWindowsHookEx(Native.WH_KEYBOARD_LL, _keyboardProc, module, 0);
            _mouseHook = Native.SetWindowsHookEx(Native.WH_MOUSE_LL, _mouseProc, module, 0);
            ok = _keyboardHook != IntPtr.Zero;
            if (!ok) Log.Error($"Keyboard hook failed: {Marshal.GetLastWin32Error()}");
            ready.Set();
            while (Native.GetMessage(out var msg, IntPtr.Zero, 0, 0) > 0)
            {
                Native.TranslateMessage(ref msg);
                Native.DispatchMessage(ref msg);
            }
            if (_keyboardHook != IntPtr.Zero) Native.UnhookWindowsHookEx(_keyboardHook);
            if (_mouseHook != IntPtr.Zero) Native.UnhookWindowsHookEx(_mouseHook);
            _keyboardHook = _mouseHook = IntPtr.Zero;
        })
        { IsBackground = true, Name = "Zerm hotkey hook", Priority = ThreadPriority.Highest };
        _hookThread.Start();
        ready.Wait(TimeSpan.FromSeconds(5));
        return ok;
    }

    public void BeginCapture() => IsCapturing = true;
    public void EndCapture() => IsCapturing = false;

    public static bool IsModifier(int vk) => vk is Native.VK_SHIFT or Native.VK_CONTROL or Native.VK_MENU
        or Native.VK_LSHIFT or Native.VK_RSHIFT or Native.VK_LCONTROL or Native.VK_RCONTROL
        or Native.VK_LMENU or Native.VK_RMENU or Native.VK_LWIN or Native.VK_RWIN;

    public static int VirtualKey(TriggerKey key) => key switch
    {
        TriggerKey.RightCtrl => Native.VK_RCONTROL,
        TriggerKey.LeftCtrl => Native.VK_LCONTROL,
        TriggerKey.RightAlt => Native.VK_RMENU,
        TriggerKey.LeftAlt => Native.VK_LMENU,
        TriggerKey.RightShift => Native.VK_RSHIFT,
        TriggerKey.RightWin => Native.VK_RWIN,
        TriggerKey.CapsLock => 0x14,
        TriggerKey.ScrollLock => 0x91,
        TriggerKey.Pause => 0x13,
        TriggerKey.F13 => 0x7C,
        _ => 0,
    };

    private (bool Ctrl, bool Alt, bool Shift, bool Win) Modifiers() => (
        _down.Contains(Native.VK_LCONTROL) || _down.Contains(Native.VK_RCONTROL),
        _down.Contains(Native.VK_LMENU) || _down.Contains(Native.VK_RMENU),
        _down.Contains(Native.VK_LSHIFT) || _down.Contains(Native.VK_RSHIFT),
        _down.Contains(Native.VK_LWIN) || _down.Contains(Native.VK_RWIN));

    private bool Matches(KeyCombo? combo, int vk)
    {
        if (combo == null || combo.IsEmpty || combo.VirtualKey != vk) return false;
        var m = Modifiers();
        return m.Ctrl == combo.Ctrl && m.Alt == combo.Alt && m.Shift == combo.Shift && m.Win == combo.Win;
    }

    private IEnumerable<(HotkeySlot Slot, TriggerKey Key, KeyCombo Custom)> Slots()
    {
        yield return (HotkeySlot.Dictation1, _settings.Hotkey1, _settings.Hotkey1Custom);
        yield return (HotkeySlot.Dictation2, _settings.Hotkey2, _settings.Hotkey2Custom);
        if (_settings.TtsEnabled) yield return (HotkeySlot.ReadAloud, _settings.ReadAloudHotkey, _settings.ReadAloudCustom);
    }

    private void Raise(Action a) => _dispatcher.BeginInvoke(a);

    private IntPtr KeyboardProc(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode < 0) return Native.CallNextHookEx(_keyboardHook, nCode, wParam, lParam);
        try
        {
            var data = Marshal.PtrToStructure<Native.KBDLLHOOKSTRUCT>(lParam);
            // Ignore our own synthetic input (paste, auto-send) and other software's injected keys.
            if (data.dwExtraInfo == Native.ZermInputTag || ((data.flags & Native.LLKHF_INJECTED) != 0 && !AllowInjected))
                return Native.CallNextHookEx(_keyboardHook, nCode, wParam, lParam);

            var vk = (int)data.vkCode;
            var msg = wParam.ToInt32();
            var isDown = msg is Native.WM_KEYDOWN or Native.WM_SYSKEYDOWN;
            var isUp = msg is Native.WM_KEYUP or Native.WM_SYSKEYUP;
            lock (_stateGate)
            {
                var repeat = isDown && _down.Contains(vk);
                if (isDown) _down.Add(vk);
                if (isUp) _down.Remove(vk);
                if (Handle(vk, isDown, isUp, repeat)) return new IntPtr(1); // swallow
            }
        }
        catch (Exception ex)
        {
            Log.Error("Keyboard hook error", ex);
        }
        return Native.CallNextHookEx(_keyboardHook, nCode, wParam, lParam);
    }

    /// <summary>Self-test entry: runs a key event through the same logic as the hook, without touching OS input.</summary>
    private readonly HashSet<int> _simulatedDown = [];

    public void Simulate(int vk, bool down)
    {
        lock (_stateGate)
        {
            if (down) _simulatedDown.Add(vk);
            else _simulatedDown.Remove(vk);
            var repeat = down && _down.Contains(vk);
            if (down) _down.Add(vk);
            else _down.Remove(vk);
            Handle(vk, down, !down, repeat);
        }
    }

    /// <returns>true to swallow the key event.</returns>
    private bool Handle(int vk, bool isDown, bool isUp, bool repeat)
    {
        if (IsCapturing)
        {
            if (!isDown || IsModifier(vk)) return isUp && !IsModifier(vk);
            if (vk == Native.VK_ESCAPE && !Modifiers().Ctrl && !Modifiers().Alt)
            {
                Raise(() => KeyCaptured?.Invoke(null));
                return true;
            }
            var m = Modifiers();
            var combo = new KeyCombo(vk, m.Ctrl, m.Alt, m.Shift, m.Win);
            Raise(() => KeyCaptured?.Invoke(combo));
            return true;
        }

        // Any other key pressed while a bare-modifier trigger is held marks the hold as a combination.
        if (isDown && !repeat)
            foreach (var slot in _slotDown.Where(kv => kv.Value).Select(kv => kv.Key).ToList())
                _otherKeyDuringHold[slot] = true;

        foreach (var (slot, key, custom) in Slots())
        {
            if (key == TriggerKey.None) continue;
            if (key == TriggerKey.Custom)
            {
                if (isDown && Matches(custom, vk))
                {
                    if (!repeat && !_slotDown.GetValueOrDefault(slot))
                    {
                        _slotDown[slot] = true;
                        _downAt[slot] = DateTime.Now;
                        _otherKeyDuringHold[slot] = false;
                        Raise(() => TriggerDown?.Invoke(slot));
                    }
                    return true;
                }
                if (isUp && _slotDown.GetValueOrDefault(slot) && custom.VirtualKey == vk)
                {
                    _slotDown[slot] = false;
                    var held = DateTime.Now - _downAt.GetValueOrDefault(slot, DateTime.Now);
                    Raise(() => TriggerUp?.Invoke(slot, true, held));
                    return true;
                }
                continue;
            }

            var target = VirtualKey(key);
            if (vk != target) continue;
            var swallow = !IsModifier(vk); // CapsLock, ScrollLock, Pause, F13 never reach the app.
            if (isDown && !repeat)
            {
                _slotDown[slot] = true;
                _downAt[slot] = DateTime.Now;
                _otherKeyDuringHold[slot] = false;
                Raise(() => TriggerDown?.Invoke(slot));
            }
            else if (isUp && _slotDown.GetValueOrDefault(slot))
            {
                _slotDown[slot] = false;
                var clean = !_otherKeyDuringHold.GetValueOrDefault(slot);
                var held = DateTime.Now - _downAt.GetValueOrDefault(slot, DateTime.Now);
                Raise(() => TriggerUp?.Invoke(slot, clean, held));
            }
            return swallow;
        }

        if (!isDown || repeat) return false;

        foreach (var (action, combo) in new[]
                 {
                     (ShortcutAction.Cancel, _settings.CancelShortcut),
                     (ShortcutAction.PasteLast, _settings.PasteLastTranscriptionShortcut),
                     (ShortcutAction.PasteLastEnhanced, _settings.PasteLastEnhancementShortcut),
                     (ShortcutAction.RetryLast, _settings.RetryLastTranscriptionShortcut),
                 })
        {
            if (action == ShortcutAction.Cancel && !RecorderVisible) continue;
            if (Matches(combo, vk))
            {
                Raise(() => ShortcutPressed?.Invoke(action));
                return true;
            }
        }

        if (PowerModeHotkeys != null)
            foreach (var (id, combo) in PowerModeHotkeys())
                if (Matches(combo, vk))
                {
                    Raise(() => PowerModeHotkeyPressed?.Invoke(id));
                    return true;
                }

        if (!RecorderVisible) return false;

        var mods = Modifiers();
        if (vk == Native.VK_ESCAPE && !mods.Ctrl && !mods.Alt && !mods.Shift && _settings.CancelShortcut.IsEmpty)
        {
            Raise(() => EscapePressed?.Invoke());
            return true;
        }
        if (mods.Ctrl && !mods.Alt && !mods.Shift && vk == 0x45) // Ctrl+E
        {
            Raise(() => ToggleEnhancementPressed?.Invoke());
            return true;
        }
        if (vk is >= 0x30 and <= 0x39 && !mods.Shift && !mods.Win && (mods.Ctrl ^ mods.Alt))
        {
            var n = vk == 0x30 ? 10 : vk - 0x30;
            if (mods.Ctrl) Raise(() => PromptNumberPressed?.Invoke(n));
            else Raise(() => PowerModeNumberPressed?.Invoke(n));
            return true;
        }
        return false;
    }

    private IntPtr MouseProc(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0 && _settings.MiddleClickToggleEnabled)
        {
            var msg = wParam.ToInt32();
            if (msg == Native.WM_MBUTTONDOWN)
            {
                Raise(() =>
                {
                    _middleTimer?.Stop();
                    _middleTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(Math.Max(0, _settings.MiddleClickActivationDelayMs)) };
                    _middleTimer.Tick += (_, _) =>
                    {
                        _middleTimer?.Stop();
                        MiddleClickToggle?.Invoke();
                    };
                    _middleTimer.Start();
                });
            }
            else if (msg == Native.WM_MBUTTONUP)
            {
                // Released before the activation delay: an ordinary middle click, not a toggle.
                Raise(() => _middleTimer?.Stop());
            }
        }
        return Native.CallNextHookEx(_mouseHook, nCode, wParam, lParam);
    }

    /// <summary>Physical state of a trigger (used by the push-to-talk release watchdog).</summary>
    public bool IsPhysicallyDown(HotkeySlot slot)
    {
        var (key, custom) = slot switch
        {
            HotkeySlot.Dictation1 => (_settings.Hotkey1, _settings.Hotkey1Custom),
            HotkeySlot.Dictation2 => (_settings.Hotkey2, _settings.Hotkey2Custom),
            _ => (_settings.ReadAloudHotkey, _settings.ReadAloudCustom),
        };
        var vk = key == TriggerKey.Custom ? custom.VirtualKey : VirtualKey(key);
        lock (_stateGate) return vk != 0 && (Native.IsDown(vk) || _simulatedDown.Contains(vk));
    }

    /// <summary>Synthesizes a release the OS never delivered.</summary>
    public void ForceRelease(HotkeySlot slot)
    {
        lock (_stateGate)
        {
            if (!_slotDown.GetValueOrDefault(slot)) return;
            _slotDown[slot] = false;
        }
        TriggerUp?.Invoke(slot, true, DateTime.Now - _downAt.GetValueOrDefault(slot, DateTime.Now));
    }

    public bool IsSlotDown(HotkeySlot slot)
    {
        lock (_stateGate) return _slotDown.GetValueOrDefault(slot);
    }

    public void Dispose()
    {
        if (_hookThreadId != 0) Native.PostThreadMessage(_hookThreadId, 0x0012 /* WM_QUIT */, IntPtr.Zero, IntPtr.Zero);
        _hookThread?.Join(1000);
    }

    public static string Describe(KeyCombo? combo)
    {
        if (combo == null || combo.IsEmpty) return "Not set";
        var parts = new List<string>();
        if (combo.Ctrl) parts.Add("Ctrl");
        if (combo.Alt) parts.Add("Alt");
        if (combo.Shift) parts.Add("Shift");
        if (combo.Win) parts.Add("Win");
        parts.Add(KeyName(combo.VirtualKey));
        return string.Join("+", parts);
    }

    public static string KeyName(int vk) => vk switch
    {
        0x20 => "Space",
        0x0D => "Enter",
        0x09 => "Tab",
        0x08 => "Backspace",
        0x1B => "Esc",
        0x2E => "Delete",
        0x2D => "Insert",
        0x24 => "Home",
        0x23 => "End",
        0x21 => "PageUp",
        0x22 => "PageDown",
        0x25 => "Left",
        0x26 => "Up",
        0x27 => "Right",
        0x28 => "Down",
        0xC0 => "`",
        >= 0x70 and <= 0x87 => "F" + (vk - 0x6F),
        >= 0x30 and <= 0x39 or >= 0x41 and <= 0x5A => ((char)vk).ToString(),
        >= 0x60 and <= 0x69 => "Num" + (vk - 0x60),
        _ => System.Windows.Input.KeyInterop.KeyFromVirtualKey(vk).ToString(),
    };

    public static string Describe(TriggerKey key, KeyCombo custom) => key switch
    {
        TriggerKey.None => "None",
        TriggerKey.Custom => Describe(custom),
        TriggerKey.RightCtrl => "Right Ctrl",
        TriggerKey.LeftCtrl => "Left Ctrl",
        TriggerKey.RightAlt => "Right Alt",
        TriggerKey.LeftAlt => "Left Alt",
        TriggerKey.RightShift => "Right Shift",
        TriggerKey.RightWin => "Right Windows key",
        TriggerKey.CapsLock => "Caps Lock",
        TriggerKey.ScrollLock => "Scroll Lock",
        TriggerKey.Pause => "Pause",
        TriggerKey.F13 => "F13",
        _ => key.ToString(),
    };
}
