use std::sync::atomic::{AtomicU16, AtomicUsize, Ordering};

#[cfg(target_os = "macos")]
use std::sync::{atomic::AtomicBool, Arc};

pub static HOTKEY_KEY_CODE: AtomicU16 = AtomicU16::new(61); // Right Option default (macOS)
pub static HOTKEY_FLAG_BIT: AtomicUsize = AtomicUsize::new(1 << 19); // Option flag

#[derive(Clone, Copy, Debug)]
pub struct HotkeyEvent {
    pub pressed: bool,
    pub backend: &'static str,
    pub key_code: u16,
}

#[derive(Clone, Copy, Debug)]
pub struct HotkeyInstallStatus {
    pub installed: bool,
    pub nsevent: bool,
    pub cgeventtap: bool,
}

pub fn set_hotkey(key_code: u16, flag_bit: usize) {
    HOTKEY_KEY_CODE.store(key_code, Ordering::SeqCst);
    HOTKEY_FLAG_BIT.store(flag_bit, Ordering::SeqCst);
}

#[cfg(target_os = "macos")]
fn modifier_key_matches(key_code: u16, target_key: u16, target_flag: usize) -> bool {
    // Some external keyboards and layouts report the physical "right" modifier
    // as the left-side key code. For modifier-only push-to-talk, accepting the
    // modifier family is more reliable than binding to one side-specific code.
    const SHIFT_FLAG: usize = 1 << 17;
    const CONTROL_FLAG: usize = 1 << 18;
    const OPTION_FLAG: usize = 1 << 19;
    const COMMAND_FLAG: usize = 1 << 20;

    match target_flag {
        OPTION_FLAG => matches!(key_code, 58 | 61),
        COMMAND_FLAG => matches!(key_code, 54 | 55),
        SHIFT_FLAG => matches!(key_code, 56 | 60),
        CONTROL_FLAG => matches!(key_code, 59 | 62),
        _ => key_code == target_key,
    }
}

#[cfg(target_os = "macos")]
fn dispatch_modifier_event(
    key_code: u16,
    raw_flags: usize,
    backend: &'static str,
    pressed: &AtomicBool,
    on_event: &Arc<dyn Fn(HotkeyEvent) + Send + Sync>,
) {
    let target_key = HOTKEY_KEY_CODE.load(Ordering::Relaxed);
    let target_flag = HOTKEY_FLAG_BIT.load(Ordering::Relaxed);
    if !modifier_key_matches(key_code, target_key, target_flag) {
        return;
    }

    let mod_held = (raw_flags & target_flag) != 0;
    let was = pressed.load(Ordering::SeqCst);
    if mod_held && !was {
        pressed.store(true, Ordering::SeqCst);
        on_event(HotkeyEvent {
            pressed: true,
            backend,
            key_code,
        });
    } else if !mod_held && was {
        pressed.store(false, Ordering::SeqCst);
        on_event(HotkeyEvent {
            pressed: false,
            backend,
            key_code,
        });
    }
}

/// Install a global hotkey listener. Returns `true` if installation
/// succeeded. Handler is called on press and release.
///
/// On macOS this taps NSEvent's global flags-changed monitor so we can
/// detect modifier-only hotkeys like Right Option. A CoreGraphics HID event
/// tap is also installed as a fallback for hardware/layouts that do not
/// reliably surface modifier-only events through NSEvent.
///
/// On Windows / Linux this is currently a no-op stub. Wire up
/// `tauri-plugin-global-shortcut` to fall back to a key combo such as
/// `Ctrl+Shift+Space`.
pub fn install<F>(on_event: F) -> HotkeyInstallStatus
where
    F: Fn(HotkeyEvent) + Send + Sync + 'static,
{
    install_impl(on_event)
}

#[cfg(target_os = "macos")]
fn install_impl<F>(on_event: F) -> HotkeyInstallStatus
where
    F: Fn(HotkeyEvent) + Send + Sync + 'static,
{
    use block2::RcBlock;
    use core_foundation::runloop::{kCFRunLoopCommonModes, CFRunLoop};
    use core_graphics::event::{
        CGEventTap, CGEventTapLocation, CGEventTapOptions, CGEventTapPlacement, CGEventType,
        CallbackResult, EventField,
    };
    use objc2_app_kit::{NSEvent, NSEventMask};
    use std::ptr::NonNull;
    use std::sync::atomic::AtomicBool;
    use std::sync::Arc;

    let pressed = Arc::new(AtomicBool::new(false));
    let on_event: Arc<dyn Fn(HotkeyEvent) + Send + Sync> = Arc::new(on_event);

    let pressed_in = pressed.clone();
    let on_event_in = on_event.clone();

    let block = RcBlock::new(move |event_ptr: NonNull<NSEvent>| {
        let event = unsafe { event_ptr.as_ref() };
        dispatch_modifier_event(
            event.keyCode(),
            event.modifierFlags().0,
            "nsevent",
            &pressed_in,
            &on_event_in,
        );
    });

    let monitor =
        NSEvent::addGlobalMonitorForEventsMatchingMask_handler(NSEventMask::FlagsChanged, &block);

    let pressed_in = pressed.clone();
    let on_event_in = on_event.clone();
    let event_tap = CGEventTap::new(
        CGEventTapLocation::HID,
        CGEventTapPlacement::HeadInsertEventTap,
        CGEventTapOptions::ListenOnly,
        vec![CGEventType::FlagsChanged],
        move |_proxy, event_type, event| {
            if matches!(
                event_type,
                CGEventType::TapDisabledByTimeout | CGEventType::TapDisabledByUserInput
            ) {
                return CallbackResult::Keep;
            }
            let key_code = event.get_integer_value_field(EventField::KEYBOARD_EVENT_KEYCODE) as u16;
            dispatch_modifier_event(
                key_code,
                event.get_flags().bits() as usize,
                "cgeventtap",
                &pressed_in,
                &on_event_in,
            );
            CallbackResult::Keep
        },
    );

    let mut event_tap_installed = false;
    if let Ok(event_tap) = event_tap {
        if let Ok(loop_source) = event_tap.mach_port().create_runloop_source(0) {
            CFRunLoop::get_main().add_source(&loop_source, unsafe { kCFRunLoopCommonModes });
            event_tap.enable();
            std::mem::forget(loop_source);
            std::mem::forget(event_tap);
            event_tap_installed = true;
        }
    }

    let nsevent_installed = monitor.is_some();
    if nsevent_installed {
        // Leak the monitor so it lives for the app's lifetime.
        std::mem::forget(monitor);
    }

    HotkeyInstallStatus {
        installed: nsevent_installed || event_tap_installed,
        nsevent: nsevent_installed,
        cgeventtap: event_tap_installed,
    }
}

#[cfg(not(target_os = "macos"))]
fn install_impl<F>(_on_event: F) -> HotkeyInstallStatus
where
    F: Fn(HotkeyEvent) + Send + Sync + 'static,
{
    log::warn!(
        "global hotkey is not yet implemented on this platform — \
         install tauri-plugin-global-shortcut and wire a key combo"
    );
    HotkeyInstallStatus {
        installed: false,
        nsevent: false,
        cgeventtap: false,
    }
}
