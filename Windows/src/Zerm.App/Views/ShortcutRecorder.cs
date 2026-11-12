using System.Windows;
using System.Windows.Controls;
using Zerm.App.Localization;
using Zerm.App.Platform;
using Zerm.Core.Settings;

namespace Zerm.App.Views;

/// <summary>Click, then press a key combination (the KeyboardShortcuts recorder on macOS). Esc cancels.</summary>
public sealed class ShortcutRecorder : StackPanel
{
    private readonly Button _button;
    private readonly Action<KeyCombo?> _changed;
    private KeyCombo? _value;

    public ShortcutRecorder(KeyCombo? value, Action<KeyCombo?> changed, bool clearable = true)
    {
        _value = value;
        _changed = changed;
        Orientation = Orientation.Horizontal;
        _button = new Button { MinWidth = 170, Padding = new Thickness(12, 5, 12, 5) };
        _button.Click += (_, _) => Begin();
        Children.Add(_button);
        if (clearable)
            Children.Add(UiKit.IconButton(Icons.Close, Loc.T("Clear"), () =>
            {
                _value = null;
                _changed(KeyCombo.Empty);
                Update();
            }));
        Update();
        Unloaded += (_, _) => End();
    }

    private void Update() => _button.Content = _value == null || _value.IsEmpty ? Loc.T("Record Shortcut") : HotkeyService.Describe(_value);

    private void Begin()
    {
        var hk = AppHost.Current.Hotkeys;
        _button.Content = Loc.T("Press keys… (Esc to cancel)");
        hk.KeyCaptured -= OnCaptured;
        hk.KeyCaptured += OnCaptured;
        hk.BeginCapture();
    }

    private void OnCaptured(KeyCombo? combo)
    {
        End();
        if (combo != null)
        {
            var hasModifier = combo.Ctrl || combo.Alt || combo.Win || combo.VirtualKey is >= 0x70 and <= 0x87;
            if (!hasModifier)
            {
                AppHost.Current.Ui.Toast(Loc.T("Use at least one of Ctrl, Alt or Win (or a function key)."), Core.Dictation.ToastKind.Warning);
            }
            else
            {
                _value = combo;
                _changed(combo);
            }
        }
        Update();
    }

    private void End()
    {
        var hk = AppHost.Current.Hotkeys;
        hk.KeyCaptured -= OnCaptured;
        hk.EndCapture();
    }
}
