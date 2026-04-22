use super::error::PlatformResult;
use super::support::PlatformSupport;
use super::types::{
    AppContext, AppIdentity, AudioDeviceInfo, ClipboardSnapshot, HotkeyDescriptor, HotkeyEvent,
    PermissionKind, PermissionStatus, TextInjectionOutcome, TextInjectionRequest,
};

/// Inserts text into the focused target using the best native strategy for the
/// current platform.
pub trait TextInjector: Send + Sync {
    fn insert_text(&self, request: TextInjectionRequest) -> PlatformResult<TextInjectionOutcome>;

    fn supported_strategies(&self) -> PlatformResult<Vec<super::types::TextInsertionStrategy>>;
}

/// Captures focused app/window/field context before recording starts.
pub trait AppContextProvider: Send + Sync {
    fn focused_app(&self) -> PlatformResult<Option<AppIdentity>>;

    fn focused_context(&self) -> PlatformResult<Option<AppContext>>;
}

pub type HotkeyCallback = Box<dyn Fn(HotkeyEvent) + Send + Sync + 'static>;

/// Registration token for a native global hotkey.
pub trait HotkeyRegistration: Send {
    fn unregister(&mut self) -> PlatformResult<()>;
}

/// Installs and manages native global hotkeys.
pub trait HotkeyProvider: Send + Sync {
    fn register(
        &self,
        descriptor: HotkeyDescriptor,
        callback: HotkeyCallback,
    ) -> PlatformResult<Box<dyn HotkeyRegistration>>;

    fn current_hotkey(&self) -> PlatformResult<Option<HotkeyDescriptor>>;
}

/// Native clipboard access with snapshot/restore support for safe paste flows.
pub trait ClipboardService: Send + Sync {
    fn snapshot(&self) -> PlatformResult<ClipboardSnapshot>;

    fn set_text(&self, text: &str) -> PlatformResult<ClipboardSnapshot>;

    fn restore(&self, snapshot: ClipboardSnapshot) -> PlatformResult<()>;
}

/// Reports and requests native OS permissions.
pub trait PermissionService: Send + Sync {
    fn status(&self, kind: PermissionKind) -> PlatformResult<PermissionStatus>;

    fn all_statuses(&self) -> PlatformResult<Vec<PermissionStatus>>;

    fn request(&self, kind: PermissionKind) -> PlatformResult<PermissionStatus>;

    fn open_settings(&self, kind: PermissionKind) -> PlatformResult<()>;
}

/// Lists and selects native audio devices.
pub trait AudioDeviceService: Send + Sync {
    fn input_devices(&self) -> PlatformResult<Vec<AudioDeviceInfo>>;

    fn default_input_device(&self) -> PlatformResult<Option<AudioDeviceInfo>>;

    fn select_input_device(&self, device_id: &str) -> PlatformResult<()>;
}

/// Aggregates platform services behind one native integration boundary.
///
/// Future macOS/Windows/Linux implementations can return concrete service
/// structs from a platform factory while the dictation pipeline depends on this
/// trait object instead of raw OS calls.
pub trait NativePlatform: Send + Sync {
    fn support(&self) -> PlatformSupport;

    fn text_injector(&self) -> &dyn TextInjector;

    fn app_context_provider(&self) -> &dyn AppContextProvider;

    fn hotkey_provider(&self) -> &dyn HotkeyProvider;

    fn clipboard_service(&self) -> &dyn ClipboardService;

    fn permission_service(&self) -> &dyn PermissionService;

    fn audio_device_service(&self) -> &dyn AudioDeviceService;
}
