//! Native platform abstraction boundary for Zerm.
//!
//! The current app still contains direct macOS/Tauri calls in `lib.rs`. This
//! module defines the contracts that those calls should move behind as the app
//! becomes a native writing layer across macOS, Windows, and Linux.

mod error;
pub mod macos_permissions;
mod services;
mod support;
mod types;

pub use error::{PlatformError, PlatformErrorKind, PlatformResult};
pub use services::{
    AppContextProvider, AudioDeviceService, ClipboardService, HotkeyCallback, HotkeyProvider,
    HotkeyRegistration, NativePlatform, PermissionService, TextInjector,
};
pub use support::{LinuxSessionKind, PlatformKind, PlatformSupport, SupportLevel};
pub use types::{
    AppContext, AppIdentity, AudioDeviceDirection, AudioDeviceInfo, ClipboardSnapshot,
    HotkeyDescriptor, HotkeyEvent, HotkeyEventKind, HotkeyModifier, PermissionKind,
    PermissionState, PermissionStatus, TextInjectionOutcome, TextInjectionRequest,
    TextInsertionStrategy,
};
