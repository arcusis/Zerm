import Foundation
import KeyboardShortcuts
import Carbon
import AppKit
import os

extension KeyboardShortcuts.Name {
    static let toggleMiniRecorder = Self("toggleMiniRecorder")
    static let toggleMiniRecorder2 = Self("toggleMiniRecorder2")
    static let pasteLastTranscription = Self("pasteLastTranscription")
    static let pasteLastEnhancement = Self("pasteLastEnhancement")
    static let retryLastTranscription = Self("retryLastTranscription")
    static let openHistoryWindow = Self("openHistoryWindow")
    static let quickAddToDictionary = Self("quickAddToDictionary")
}

@MainActor
class HotkeyManager: ObservableObject {
    @Published var selectedHotkey1: HotkeyOption {
        didSet {
            UserDefaults.standard.set(selectedHotkey1.rawValue, forKey: "selectedHotkey1")
            setupHotkeyMonitoring()
        }
    }
    @Published var selectedHotkey2: HotkeyOption {
        didSet {
            if selectedHotkey2 == .none {
                KeyboardShortcuts.setShortcut(nil, for: .toggleMiniRecorder2)
            }
            UserDefaults.standard.set(selectedHotkey2.rawValue, forKey: "selectedHotkey2")
            setupHotkeyMonitoring()
        }
    }
    @Published var hotkeyMode1: HotkeyMode {
        didSet {
            UserDefaults.standard.set(hotkeyMode1.rawValue, forKey: "hotkeyMode1")
        }
    }
    @Published var hotkeyMode2: HotkeyMode {
        didSet {
            UserDefaults.standard.set(hotkeyMode2.rawValue, forKey: "hotkeyMode2")
        }
    }
    @Published var isMiddleClickToggleEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isMiddleClickToggleEnabled, forKey: "isMiddleClickToggleEnabled")
            setupHotkeyMonitoring()
        }
    }
    @Published var middleClickActivationDelay: Int {
        didSet {
            UserDefaults.standard.set(middleClickActivationDelay, forKey: "middleClickActivationDelay")
        }
    }
    /// Modifier key (or Custom) that triggers Read Aloud, mirroring the dictation hotkey dropdown.
    @Published var readAloudHotkey: HotkeyOption {
        didSet {
            UserDefaults.standard.set(readAloudHotkey.rawValue, forKey: "readAloudHotkey")
            setupHotkeyMonitoring()
        }
    }
    /// Invoked when the Read Aloud trigger fires (wired to TTSController.toggle()).
    var onReadAloudTriggered: (() -> Void)?
    private var readAloudKeyState = false

    /// True while a `KeyboardShortcuts.Recorder` field has focus and is capturing keys.
    private var isRecordingShortcut = false
    private var recorderActiveObserver: NSObjectProtocol?
    /// Posted by KeyboardShortcuts whenever a recorder gains/loses focus. The name is
    /// internal to the package, so it is reconstructed from its raw value here.
    private static let recorderActiveStatusDidChange = Notification.Name("KeyboardShortcuts_recorderActiveStatusDidChange")

    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "HotkeyManager")
    private var engine: ZermEngine
    private var recorderUIManager: RecorderUIManager
    private var miniRecorderShortcutManager: MiniRecorderShortcutManager
    private var powerModeShortcutManager: PowerModeShortcutManager

    // MARK: - Helper Properties
    private var canProcessHotkeyAction: Bool {
        engine.recordingState != .transcribing && engine.recordingState != .enhancing && engine.recordingState != .busy && engine.recordingState != .speaking && engine.recordingState != .preparingSpeech && engine.recordingState != .generatingSpeech
    }
    
    // NSEvent monitoring for modifier keys
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    
    // Middle-click event monitoring
    private var middleClickMonitors: [Any?] = []
    private var middleClickTask: Task<Void, Never>?
    
    // Key state tracking
    private var currentKeyState = false
    private var keyPressEventTime: TimeInterval?
    private var isHandsFreeMode = false

    // Debounce for Fn key
    private var fnDebounceTask: Task<Void, Never>?
    private var pendingFnKeyState: Bool? = nil
    private var pendingFnEventTime: TimeInterval? = nil
    // Monitor that tracks whether another key was pressed while Fn is held.
    // When a key-down fires during Fn hold, we cancel the recording trigger so that
    // Fn+F1 / Fn+F11 / etc. work normally without accidentally starting a recording.
    // (VoiceInk #720)
    private var fnKeyDownMonitor: Any?
    private var fnCompanionKeyPressed = false

    // Keyboard shortcut state tracking
    private var shortcutKeyPressEventTime: TimeInterval?
    private var isShortcutHandsFreeMode = false
    private var shortcutCurrentKeyState = false
    private var lastShortcutTriggerTime: Date?
    private let shortcutCooldownInterval: TimeInterval = 0.5

    private static let hybridPressThreshold: TimeInterval = 0.5

    enum HotkeyMode: String, CaseIterable {
        case toggle = "toggle"
        case pushToTalk = "pushToTalk"
        case hybrid = "hybrid"

        var displayName: String {
            switch self {
            case .toggle: return "Toggle"
            case .pushToTalk: return "Push to Talk"
            case .hybrid: return "Hybrid"
            }
        }
    }

    enum HotkeyOption: String, CaseIterable {
        case none = "none"
        case rightOption = "rightOption"
        case leftOption = "leftOption"
        case leftControl = "leftControl" 
        case rightControl = "rightControl"
        case fn = "fn"
        case rightCommand = "rightCommand"
        case rightShift = "rightShift"
        case custom = "custom"
        
        var displayName: String {
            switch self {
            case .none: return "None"
            case .rightOption: return "Right Option (⌥)"
            case .leftOption: return "Left Option (⌥)"
            case .leftControl: return "Left Control (⌃)"
            case .rightControl: return "Right Control (⌃)"
            case .fn: return "Fn"
            case .rightCommand: return "Right Command (⌘)"
            case .rightShift: return "Right Shift (⇧)"
            case .custom: return "Custom"
            }
        }
        
        var keyCode: CGKeyCode? {
            switch self {
            case .rightOption: return 0x3D
            case .leftOption: return 0x3A
            case .leftControl: return 0x3B
            case .rightControl: return 0x3E
            case .fn: return 0x3F
            case .rightCommand: return 0x36
            case .rightShift: return 0x3C
            case .custom, .none: return nil
            }
        }
        
        var isModifierKey: Bool {
            return self != .custom && self != .none
        }
    }
    
    init(engine: ZermEngine, recorderUIManager: RecorderUIManager) {
        self.selectedHotkey1 = HotkeyOption(rawValue: UserDefaults.standard.string(forKey: "selectedHotkey1") ?? "") ?? .rightCommand
        self.selectedHotkey2 = HotkeyOption(rawValue: UserDefaults.standard.string(forKey: "selectedHotkey2") ?? "") ?? .none

        self.hotkeyMode1 = HotkeyMode(rawValue: UserDefaults.standard.string(forKey: "hotkeyMode1") ?? "") ?? .hybrid
        self.hotkeyMode2 = HotkeyMode(rawValue: UserDefaults.standard.string(forKey: "hotkeyMode2") ?? "") ?? .hybrid

        self.isMiddleClickToggleEnabled = UserDefaults.standard.bool(forKey: "isMiddleClickToggleEnabled")
        self.middleClickActivationDelay = UserDefaults.standard.integer(forKey: "middleClickActivationDelay")
        self.readAloudHotkey = HotkeyOption(rawValue: UserDefaults.standard.string(forKey: "readAloudHotkey") ?? "") ?? .none

        self.engine = engine
        self.recorderUIManager = recorderUIManager
        self.miniRecorderShortcutManager = MiniRecorderShortcutManager(engine: engine, recorderUIManager: recorderUIManager)
        self.powerModeShortcutManager = PowerModeShortcutManager(engine: engine)

        KeyboardShortcuts.onKeyUp(for: .pasteLastTranscription) { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                LastTranscriptionService.pasteLastTranscription(from: self.engine.modelContext)
            }
        }

        KeyboardShortcuts.onKeyUp(for: .pasteLastEnhancement) { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                LastTranscriptionService.pasteLastEnhancement(from: self.engine.modelContext)
            }
        }

        KeyboardShortcuts.onKeyUp(for: .retryLastTranscription) { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                LastTranscriptionService.retryLastTranscription(
                    from: self.engine.modelContext,
                    transcriptionModelManager: self.engine.transcriptionModelManager,
                    serviceRegistry: self.engine.serviceRegistry,
                    enhancementService: self.engine.enhancementService
                )
            }
        }

        KeyboardShortcuts.onKeyUp(for: .openHistoryWindow) { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                HistoryWindowController.shared.showHistoryWindow(
                    modelContainer: self.engine.modelContext.container,
                    engine: self.engine
                )
            }
        }

        KeyboardShortcuts.onKeyUp(for: .quickAddToDictionary) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                DictionaryQuickAddManager.shared.toggle(modelContainer: self.engine.modelContext.container)
            }
        }

        // While the user is recording a shortcut, every one of our own triggers must stand
        // down. Otherwise pressing the modifier they want to bind (⌥, right ⌘, …) fires
        // dictation or Read Aloud instead: the recorder widget pops up, Read Aloud injects a
        // synthetic ⌘C into the focused window — which is the settings window — and the
        // recorder captures that ⌘C, sees it is taken by Edit ▸ Copy and puts up a modal
        // sheet. Repeat and the sheets nest, deadlocking the app. KeyboardShortcuts already
        // broadcasts recorder focus for exactly this purpose.
        recorderActiveObserver = NotificationCenter.default.addObserver(
            forName: Self.recorderActiveStatusDidChange,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let isActive = (notification.userInfo?["isActive"] as? Bool) ?? false
            Task { @MainActor in self?.setShortcutRecordingActive(isActive) }
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            self.setupHotkeyMonitoring()
        }
    }

    /// Suspends (and later restores) every Zerm-owned trigger while a shortcut recorder has focus.
    private func setShortcutRecordingActive(_ isActive: Bool) {
        guard isRecordingShortcut != isActive else { return }
        isRecordingShortcut = isActive

        if isActive {
            logger.notice("Shortcut recorder focused — suspending hotkey monitoring")
            removeAllMonitoring()
        } else {
            logger.notice("Shortcut recorder dismissed — restoring hotkey monitoring")
            setupHotkeyMonitoring()
        }
    }

    private func setupHotkeyMonitoring() {
        removeAllMonitoring()

        // Stay silent until the recorder gives focus back.
        guard !isRecordingShortcut else { return }

        setupModifierKeyMonitoring()
        setupCustomShortcutMonitoring()
        setupMiddleClickMonitoring()
    }
    
    private func setupModifierKeyMonitoring() {
        // Only set up if at least one hotkey is a modifier key
        guard (selectedHotkey1.isModifierKey && selectedHotkey1 != .none) || (selectedHotkey2.isModifierKey && selectedHotkey2 != .none) || (readAloudHotkey.isModifierKey && readAloudHotkey != .none) else { return }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self = self else { return }
            Task { @MainActor in
                await self.handleModifierKeyEvent(event)
            }
        }

        // On macOS 26 and newer, Input Monitoring permission is required for global
        // keyboard event monitoring.  addGlobalMonitorForEvents returns nil when the
        // permission is missing — surfacing a notification gives the user actionable
        // guidance rather than a silently broken hotkey. (VoiceInk #735)
        if globalEventMonitor == nil {
            logger.warning("Global event monitor is nil — Accessibility / Input Monitoring permission may be missing")
            Task { @MainActor in
                NotificationManager.shared.showNotification(
                    title: "Hotkey not working — enable Accessibility in System Settings",
                    type: .warning,
                    duration: 6.0
                )
            }
        }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self = self else { return event }
            Task { @MainActor in
                await self.handleModifierKeyEvent(event)
            }
            return event
        }
    }
    
    private func setupMiddleClickMonitoring() {
        guard isMiddleClickToggleEnabled else { return }

        // Mouse Down
        let downMonitor = NSEvent.addGlobalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
            guard let self = self, event.buttonNumber == 2 else { return }

            self.middleClickTask?.cancel()
            self.middleClickTask = Task {
                do {
                    let delay = UInt64(self.middleClickActivationDelay) * 1_000_000 // ms to ns
                    try await Task.sleep(nanoseconds: delay)
                    
                    guard self.isMiddleClickToggleEnabled, !Task.isCancelled else { return }
                    
                    Task { @MainActor in
                        guard self.canProcessHotkeyAction else { return }
                        await self.recorderUIManager.toggleMiniRecorder()
                    }
                } catch {
                    // Cancelled
                }
            }
        }

        // Mouse Up
        let upMonitor = NSEvent.addGlobalMonitorForEvents(matching: .otherMouseUp) { [weak self] event in
            guard let self = self, event.buttonNumber == 2 else { return }
            self.middleClickTask?.cancel()
        }

        middleClickMonitors = [downMonitor, upMonitor]
    }
    
    private func setupCustomShortcutMonitoring() {
        if selectedHotkey1 == .custom {
            KeyboardShortcuts.onKeyDown(for: .toggleMiniRecorder) { [weak self] in
                let eventTime = ProcessInfo.processInfo.systemUptime
                Task { @MainActor in await self?.handleCustomShortcutKeyDown(eventTime: eventTime, mode: self?.hotkeyMode1 ?? .toggle) }
            }
            KeyboardShortcuts.onKeyUp(for: .toggleMiniRecorder) { [weak self] in
                let eventTime = ProcessInfo.processInfo.systemUptime
                Task { @MainActor in await self?.handleCustomShortcutKeyUp(eventTime: eventTime, mode: self?.hotkeyMode1 ?? .toggle) }
            }
        }
        if selectedHotkey2 == .custom {
            KeyboardShortcuts.onKeyDown(for: .toggleMiniRecorder2) { [weak self] in
                let eventTime = ProcessInfo.processInfo.systemUptime
                Task { @MainActor in await self?.handleCustomShortcutKeyDown(eventTime: eventTime, mode: self?.hotkeyMode2 ?? .toggle) }
            }
            KeyboardShortcuts.onKeyUp(for: .toggleMiniRecorder2) { [weak self] in
                let eventTime = ProcessInfo.processInfo.systemUptime
                Task { @MainActor in await self?.handleCustomShortcutKeyUp(eventTime: eventTime, mode: self?.hotkeyMode2 ?? .toggle) }
            }
        }
        if readAloudHotkey == .custom {
            KeyboardShortcuts.onKeyDown(for: .readSelectedTextAloud) { [weak self] in
                Task { @MainActor in
                    guard let self, !self.isRecordingShortcut else { return }
                    self.onReadAloudTriggered?()
                }
            }
        }
    }
    
    private func removeAllMonitoring() {
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }
        
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
        
        for monitor in middleClickMonitors {
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
        middleClickMonitors = []
        middleClickTask?.cancel()

        if let monitor = fnKeyDownMonitor {
            NSEvent.removeMonitor(monitor)
            fnKeyDownMonitor = nil
        }
        fnCompanionKeyPressed = false

        resetKeyStates()
    }
    
    private func resetKeyStates() {
        currentKeyState = false
        keyPressEventTime = nil
        isHandsFreeMode = false
        shortcutCurrentKeyState = false
        shortcutKeyPressEventTime = nil
        isShortcutHandsFreeMode = false
        readAloudKeyState = false
    }
    
    /// Device-dependent modifier bits AppKit keeps in the raw flags (IOKit `NX_DEVICE*KEYMASK`).
    /// Unlike `NSEvent.ModifierFlags.option` and friends, these distinguish the two physical keys.
    private enum SidedModifier {
        static let leftControl: UInt = 0x0000_0001
        static let leftShift: UInt = 0x0000_0002
        static let rightShift: UInt = 0x0000_0004
        static let leftCommand: UInt = 0x0000_0008
        static let rightCommand: UInt = 0x0000_0010
        static let leftOption: UInt = 0x0000_0020
        static let rightOption: UInt = 0x0000_0040
        static let rightControl: UInt = 0x0000_2000
    }

    /// Whether the *specific physical key* bound to `option` is currently held.
    ///
    /// `NSEvent.ModifierFlags` only carries side-agnostic bits — `.option` is set by either
    /// Option key — so a left-Option binding and a right-Option binding were indistinguishable.
    /// That desynchronised the press/release state machines: releasing one Option key while the
    /// other was still held looked like "still pressed", and the flag stayed stuck down, after
    /// which that hotkey never fired again for the rest of the session (the failure mode behind
    /// Read Aloud going dead when it shares a modifier family with the dictation hotkey).
    ///
    /// Falls back to the side-agnostic bit when neither device bit is present, so remapping
    /// software that strips them keeps working as before.
    static func isModifierPressed(_ option: HotkeyOption, flags: NSEvent.ModifierFlags) -> Bool {
        func isDown(left: UInt, right: UInt, wanted: UInt, generic: NSEvent.ModifierFlags) -> Bool {
            let raw = flags.rawValue
            guard raw & (left | right) != 0 else { return flags.contains(generic) }
            return raw & wanted != 0
        }

        switch option {
        case .leftOption:
            return isDown(left: SidedModifier.leftOption, right: SidedModifier.rightOption,
                          wanted: SidedModifier.leftOption, generic: .option)
        case .rightOption:
            return isDown(left: SidedModifier.leftOption, right: SidedModifier.rightOption,
                          wanted: SidedModifier.rightOption, generic: .option)
        case .leftControl:
            return isDown(left: SidedModifier.leftControl, right: SidedModifier.rightControl,
                          wanted: SidedModifier.leftControl, generic: .control)
        case .rightControl:
            return isDown(left: SidedModifier.leftControl, right: SidedModifier.rightControl,
                          wanted: SidedModifier.rightControl, generic: .control)
        case .rightCommand:
            return isDown(left: SidedModifier.leftCommand, right: SidedModifier.rightCommand,
                          wanted: SidedModifier.rightCommand, generic: .command)
        case .rightShift:
            return isDown(left: SidedModifier.leftShift, right: SidedModifier.rightShift,
                          wanted: SidedModifier.rightShift, generic: .shift)
        case .fn:
            return flags.contains(.function)
        case .custom, .none:
            return false
        }
    }

    private func handleModifierKeyEvent(_ event: NSEvent) async {
        let keycode = event.keyCode
        let flags = event.modifierFlags
        let eventTime = event.timestamp

        // Read Aloud trigger — independent of dictation. Simple tap-to-toggle on key down.
        if readAloudHotkey.isModifierKey, readAloudHotkey != .none, readAloudHotkey.keyCode == keycode {
            let pressed = Self.isModifierPressed(readAloudHotkey, flags: flags)
            if pressed != readAloudKeyState {
                readAloudKeyState = pressed
                if pressed { onReadAloudTriggered?() }
            }
            return
        }

        let activeMode: HotkeyMode
        let activeHotkey: HotkeyOption?
        if selectedHotkey1.isModifierKey && selectedHotkey1.keyCode == keycode {
            activeHotkey = selectedHotkey1
            activeMode = hotkeyMode1
        } else if selectedHotkey2.isModifierKey && selectedHotkey2.keyCode == keycode {
            activeHotkey = selectedHotkey2
            activeMode = hotkeyMode2
        } else {
            activeHotkey = nil
            activeMode = .toggle
        }

        guard let hotkey = activeHotkey else { return }

        // Same sided test as the Read Aloud branch above — see `isModifierPressed`.
        let isKeyPressed = Self.isModifierPressed(hotkey, flags: flags)

        switch hotkey {
        case .custom, .none:
            return // Should not reach here
        case .fn:
            pendingFnKeyState = isKeyPressed
            pendingFnEventTime = eventTime
            fnDebounceTask?.cancel()

            if isKeyPressed {
                // Fn just went DOWN — install a companion-key monitor.
                // If the user presses any other key while Fn is held (e.g. Fn+F1),
                // we record the companion press and cancel the recording trigger so
                // function-key combos work normally. (VoiceInk #720)
                fnCompanionKeyPressed = false
                fnKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
                    self?.fnCompanionKeyPressed = true
                }
            } else {
                // Fn just went UP — tear down the companion-key monitor.
                if let monitor = fnKeyDownMonitor {
                    NSEvent.removeMonitor(monitor)
                    fnKeyDownMonitor = nil
                }
            }

            fnDebounceTask = Task { [pendingState = isKeyPressed, pendingTime = eventTime] in
                try? await Task.sleep(nanoseconds: 75_000_000) // 75ms
                guard !Task.isCancelled, self.pendingFnKeyState == pendingState else { return }
                // Skip the trigger if a companion key was pressed — this was a Fn+Fkey combo.
                if pendingState && self.fnCompanionKeyPressed { return }
                Task { @MainActor in
                    await self.processKeyPress(isKeyPressed: pendingState, eventTime: pendingTime, mode: activeMode)
                }
            }
            return
        case .rightOption, .leftOption, .leftControl, .rightControl, .rightCommand, .rightShift:
            break
        }

        await processKeyPress(isKeyPressed: isKeyPressed, eventTime: eventTime, mode: activeMode)
    }

    private func processKeyPress(isKeyPressed: Bool, eventTime: TimeInterval, mode: HotkeyMode) async {
        guard isKeyPressed != currentKeyState else { return }
        currentKeyState = isKeyPressed

        if isKeyPressed {
            keyPressEventTime = eventTime

            switch mode {
            case .toggle, .hybrid:
                if isHandsFreeMode {
                    isHandsFreeMode = false
                    guard canProcessHotkeyAction else { return }
                    logger.notice("processKeyPress: toggling mini recorder (hands-free toggle)")
                    await recorderUIManager.toggleMiniRecorder()
                    return
                }

                if !recorderUIManager.isMiniRecorderVisible {
                    guard canProcessHotkeyAction else { return }
                    logger.notice("processKeyPress: toggling mini recorder (key down while not visible)")
                    await recorderUIManager.toggleMiniRecorder()
                }

            case .pushToTalk:
                if !recorderUIManager.isMiniRecorderVisible {
                    guard canProcessHotkeyAction else { return }
                    logger.notice("processKeyPress: starting recording (push-to-talk key down)")
                    await recorderUIManager.toggleMiniRecorder()
                }
            }
        } else {
            switch mode {
            case .toggle:
                isHandsFreeMode = true

            case .pushToTalk:
                if recorderUIManager.isMiniRecorderVisible {
                    guard canProcessHotkeyAction else { return }
                    logger.notice("processKeyPress: stopping recording (push-to-talk key up)")
                    await recorderUIManager.toggleMiniRecorder()
                }

            case .hybrid:
                let pressDuration = keyPressEventTime.map { eventTime - $0 } ?? 0
                if pressDuration >= Self.hybridPressThreshold && engine.recordingState == .recording {
                    guard canProcessHotkeyAction else { return }
                    logger.notice("processKeyPress: stopping recording (hybrid push-to-talk, duration=\(pressDuration, privacy: .public)s)")
                    await recorderUIManager.toggleMiniRecorder()
                } else {
                    isHandsFreeMode = true
                }
            }

            keyPressEventTime = nil
        }
    }
    
    private func handleCustomShortcutKeyDown(eventTime: TimeInterval, mode: HotkeyMode) async {
        guard !isRecordingShortcut else { return }

        if let lastTrigger = lastShortcutTriggerTime,
           Date().timeIntervalSince(lastTrigger) < shortcutCooldownInterval {
            return
        }

        guard !shortcutCurrentKeyState else { return }
        shortcutCurrentKeyState = true
        lastShortcutTriggerTime = Date()
        shortcutKeyPressEventTime = eventTime

        switch mode {
        case .toggle, .hybrid:
            if isShortcutHandsFreeMode {
                isShortcutHandsFreeMode = false
                guard canProcessHotkeyAction else { return }
                logger.notice("handleCustomShortcutKeyDown: toggling mini recorder (hands-free toggle)")
                await recorderUIManager.toggleMiniRecorder()
                return
            }

            if !recorderUIManager.isMiniRecorderVisible {
                guard canProcessHotkeyAction else { return }
                logger.notice("handleCustomShortcutKeyDown: toggling mini recorder (key down while not visible)")
                await recorderUIManager.toggleMiniRecorder()
            }

        case .pushToTalk:
            if !recorderUIManager.isMiniRecorderVisible {
                guard canProcessHotkeyAction else { return }
                logger.notice("handleCustomShortcutKeyDown: starting recording (push-to-talk key down)")
                await recorderUIManager.toggleMiniRecorder()
            }
        }
    }

    private func handleCustomShortcutKeyUp(eventTime: TimeInterval, mode: HotkeyMode) async {
        guard shortcutCurrentKeyState else { return }
        shortcutCurrentKeyState = false

        switch mode {
        case .toggle:
            isShortcutHandsFreeMode = true

        case .pushToTalk:
            if recorderUIManager.isMiniRecorderVisible {
                guard canProcessHotkeyAction else { return }
                logger.notice("handleCustomShortcutKeyUp: stopping recording (push-to-talk key up)")
                await recorderUIManager.toggleMiniRecorder()
            }

        case .hybrid:
            let pressDuration = shortcutKeyPressEventTime.map { eventTime - $0 } ?? 0
            if pressDuration >= Self.hybridPressThreshold && engine.recordingState == .recording {
                guard canProcessHotkeyAction else { return }
                logger.notice("handleCustomShortcutKeyUp: stopping recording (hybrid push-to-talk, duration=\(pressDuration, privacy: .public)s)")
                await recorderUIManager.toggleMiniRecorder()
            } else {
                isShortcutHandsFreeMode = true
            }
        }

        shortcutKeyPressEventTime = nil
    }
    
    // Computed property for backward compatibility with UI
    var isShortcutConfigured: Bool {
        let isHotkey1Configured = (selectedHotkey1 == .custom) ? (KeyboardShortcuts.getShortcut(for: .toggleMiniRecorder) != nil) : true
        let isHotkey2Configured = (selectedHotkey2 == .custom) ? (KeyboardShortcuts.getShortcut(for: .toggleMiniRecorder2) != nil) : true
        return isHotkey1Configured && isHotkey2Configured
    }
    
    func updateShortcutStatus() {
        // Called when a custom shortcut changes
        if selectedHotkey1 == .custom || selectedHotkey2 == .custom {
            setupHotkeyMonitoring()
        }
    }
    
    deinit {
        if let recorderActiveObserver {
            NotificationCenter.default.removeObserver(recorderActiveObserver)
        }
        middleClickTask?.cancel()

        // Hand the monitors over by value. Calling removeAllMonitoring() from a Task
        // spawned in deinit would capture `self` and resurrect an object that is
        // already being deallocated (a hard error under the Swift 6 language mode).
        let monitors = ([globalEventMonitor, localEventMonitor, fnKeyDownMonitor] + middleClickMonitors)
            .compactMap { $0 }
        Task { @MainActor in
            monitors.forEach(NSEvent.removeMonitor)
        }
    }
}
