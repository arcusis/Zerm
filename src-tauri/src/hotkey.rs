use std::sync::atomic::{AtomicU16, AtomicUsize, Ordering};

pub static HOTKEY_KEY_CODE: AtomicU16 = AtomicU16::new(61); // Right Option default (macOS)
pub static HOTKEY_FLAG_BIT: AtomicUsize = AtomicUsize::new(1 << 19); // Option flag

pub fn set_hotkey(key_code: u16, flag_bit: usize) {
    HOTKEY_KEY_CODE.store(key_code, Ordering::SeqCst);
    HOTKEY_FLAG_BIT.store(flag_bit, Ordering::SeqCst);
}

/// Install a global hotkey listener. Returns `true` if installation
/// succeeded. Handler is called with `true` on press, `false` on release.
///
/// On macOS this taps NSEvent's global flags-changed monitor so we can
/// detect modifier-only hotkeys like Right Option.
///
/// On Windows / Linux this is currently a no-op stub. Wire up
/// `tauri-plugin-global-shortcut` to fall back to a key combo such as
/// `Ctrl+Shift+Space`.
pub fn install<F>(on_event: F) -> bool
where
    F: Fn(bool) + Send + Sync + 'static,
{
    install_impl(on_event)
}

#[cfg(target_os = "macos")]
fn install_impl<F>(on_event: F) -> bool
where
    F: Fn(bool) + Send + Sync + 'static,
{
    use block2::RcBlock;
    use objc2_app_kit::{NSEvent, NSEventMask};
    use std::ptr::NonNull;
    use std::sync::atomic::AtomicBool;
    use std::sync::Arc;

    let pressed = Arc::new(AtomicBool::new(false));
    let on_event = Arc::new(on_event);

    let pressed_in = pressed.clone();
    let on_event_in = on_event.clone();

    let block = RcBlock::new(move |event_ptr: NonNull<NSEvent>| {
        let event = unsafe { event_ptr.as_ref() };
        let key_code: u16 = event.keyCode();
        let target_key = HOTKEY_KEY_CODE.load(Ordering::Relaxed);
        if key_code != target_key {
            return;
        }
        let flags = event.modifierFlags();
        let target_flag = HOTKEY_FLAG_BIT.load(Ordering::Relaxed);
        let mod_held = (flags.0 & target_flag) != 0;
        let was = pressed_in.load(Ordering::SeqCst);
        if mod_held && !was {
            pressed_in.store(true, Ordering::SeqCst);
            on_event_in(true);
        } else if !mod_held && was {
            pressed_in.store(false, Ordering::SeqCst);
            on_event_in(false);
        }
    });

    let monitor =
        NSEvent::addGlobalMonitorForEventsMatchingMask_handler(NSEventMask::FlagsChanged, &block);

    if monitor.is_some() {
        // Leak the monitor so it lives for the app's lifetime.
        std::mem::forget(monitor);
        true
    } else {
        false
    }
}

#[cfg(not(target_os = "macos"))]
fn install_impl<F>(_on_event: F) -> bool
where
    F: Fn(bool) + Send + Sync + 'static,
{
    log::warn!(
        "global hotkey is not yet implemented on this platform — \
         install tauri-plugin-global-shortcut and wire a key combo"
    );
    false
}
