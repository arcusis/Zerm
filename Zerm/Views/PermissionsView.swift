import SwiftUI
import AVFoundation
import Cocoa
import KeyboardShortcuts
import ScreenCaptureKit

class PermissionManager: ObservableObject {
    @Published var audioPermissionStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published var isAccessibilityEnabled = false
    @Published var isScreenRecordingEnabled = false
    @Published var isKeyboardShortcutSet = false
    /// Shown when Screen Recording is toggled on in Settings but the process must relaunch.
    @Published var screenRecordingNeedsRelaunch = false

    private var pollTask: Task<Void, Never>?

    init() {
        setupNotificationObservers()
        checkAllPermissions()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        pollTask?.cancel()
    }

    private func setupNotificationObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func applicationDidBecomeActive() {
        // After returning from System Settings, re-check several times —
        // macOS often updates TCC a beat after the toggle flips.
        checkAllPermissions()
        pollPermissions(forSeconds: 4)
    }

    func checkAllPermissions() {
        checkAccessibilityPermissions()
        checkScreenRecordingPermission()
        checkAudioPermissionStatus()
        checkKeyboardShortcut()
    }

    /// Re-check on an interval so refresh / Settings return picks up grants without relaunch when possible.
    func pollPermissions(forSeconds seconds: TimeInterval = 3) {
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            let steps = max(1, Int(seconds / 0.5))
            for _ in 0..<steps {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { return }
                self.checkAllPermissions()
                if self.isAccessibilityEnabled && self.isScreenRecordingEnabled {
                    self.screenRecordingNeedsRelaunch = false
                    return
                }
            }
        }
    }

    func checkAccessibilityPermissions() {
        // Prefer the non-prompting check; also accept plain AXIsProcessTrusted.
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
        let withOptions = AXIsProcessTrustedWithOptions(options)
        let plain = AXIsProcessTrusted()
        let accessibilityEnabled = withOptions || plain
        DispatchQueue.main.async {
            self.isAccessibilityEnabled = accessibilityEnabled
        }
    }

    /// Opens System Settings and optionally shows the system accessibility prompt to re-bind trust.
    func openAccessibilitySettings(promptIfNeeded: Bool = true) {
        if promptIfNeeded, !isAccessibilityEnabled {
            // This presents the system dialog that links this exact binary to TCC.
            let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            _ = AXIsProcessTrustedWithOptions(options)
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        pollPermissions(forSeconds: 8)
    }

    func checkScreenRecordingPermission() {
        let preflight = CGPreflightScreenCaptureAccess()
        DispatchQueue.main.async {
            self.isScreenRecordingEnabled = preflight
            if preflight {
                self.screenRecordingNeedsRelaunch = false
            }
        }
        // Secondary async probe via ScreenCaptureKit — on some macOS versions
        // CGPreflight lags behind the Settings toggle until relaunch.
        if !preflight {
            Task { @MainActor in
                let kitGranted = await Self.probeScreenCaptureKitAccess()
                if kitGranted {
                    // TCC is effectively granted; process just needs a relaunch for CGPreflight.
                    self.screenRecordingNeedsRelaunch = true
                }
            }
        }
    }

    func requestScreenRecordingPermission() {
        let already = CGPreflightScreenCaptureAccess()
        if !already {
            CGRequestScreenCaptureAccess()
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        pollPermissions(forSeconds: 8)
        // After the user toggles, macOS often still returns false until relaunch.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let preflight = CGPreflightScreenCaptureAccess()
            let kit = await Self.probeScreenCaptureKitAccess()
            if !preflight && kit {
                self.screenRecordingNeedsRelaunch = true
            }
        }
    }

    /// True if ScreenCaptureKit can enumerate displays (permission present for this process).
    private static func probeScreenCaptureKitAccess() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return true
        } catch {
            return false
        }
    }

    func checkAudioPermissionStatus() {
        DispatchQueue.main.async {
            self.audioPermissionStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        }
    }

    func requestAudioPermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                self.audioPermissionStatus = granted ? .authorized : .denied
            }
        }
    }

    func checkKeyboardShortcut() {
        DispatchQueue.main.async {
            self.isKeyboardShortcutSet = KeyboardShortcuts.getShortcut(for: .toggleMiniRecorder) != nil
        }
    }
}

struct PermissionCard: View {
    let icon: String
    let title: String
    let description: String
    let isGranted: Bool
    let buttonTitle: String
    let buttonAction: () -> Void
    let checkPermission: () -> Void
    var infoTipMessage: String?
    var infoTipLink: String?
    @State private var isRefreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                // Icon with background
                ZStack {
                    Circle()
                        .fill(isGranted ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                        .frame(width: 44, height: 44)

                    Image(systemName: isGranted ? "\(icon).fill" : icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(isGranted ? .green : .orange)
                        .symbolRenderingMode(.hierarchical)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(title)
                            .font(.headline)
                        if let message = infoTipMessage {
                            if let link = infoTipLink, !link.isEmpty {
                                InfoTip(message, learnMoreURL: link)
                            } else {
                                InfoTip(message)
                            }
                        }
                    }
                    Text(description)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // Status indicator with refresh
                HStack(spacing: 12) {
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.5)) {
                            isRefreshing = true
                        }
                        checkPermission()
                        
                        // Reset the animation after a delay
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            isRefreshing = false
                        }
                    }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.secondary)
                            .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    
                    if isGranted {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.green)
                            .symbolRenderingMode(.hierarchical)
                    } else {
                        Image(systemName: "xmark.seal.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.orange)
                            .symbolRenderingMode(.hierarchical)
                    }
                }
            }
            
            if !isGranted {
                Button(action: buttonAction) {
                    HStack {
                        Text(buttonTitle)
                        Spacer()
                        Image(systemName: "arrow.right")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(
                        LinearGradient(
                            colors: [Color.accentColor, Color.accentColor.opacity(0.8)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .background(CardBackground(isSelected: false))
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.05), radius: 5, y: 2)
    }
}

struct PermissionsView: View {
    @EnvironmentObject private var hotkeyManager: HotkeyManager
    @StateObject private var permissionManager = PermissionManager()
    
    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                // Header
                CompactHeroSection(
                    icon: "shield.lefthalf.filled",
                    title: "App Permissions",
                    description: "Zerm requires the following permissions to function properly"
                )
                
                // Permission Cards
                VStack(spacing: 16) {
                    // Keyboard Shortcut Permission
                    PermissionCard(
                        icon: "keyboard",
                        title: "Keyboard Shortcut",
                        description: "Set up a keyboard shortcut to use Zerm anywhere",
                        isGranted: hotkeyManager.selectedHotkey1 != .none,
                        buttonTitle: "Configure Shortcut",
                        buttonAction: {
                            NotificationCenter.default.post(
                                name: .navigateToDestination,
                                object: nil,
                                userInfo: ["destination": "Settings"]
                            )
                        },
                        checkPermission: { permissionManager.checkKeyboardShortcut() },
                        infoTipMessage: "Not a macOS permission — this is simply whether you have picked a key to start dictation with. Without one there is no way to open the recorder except from the menu bar. Configure Shortcut takes you to the Settings pane where you choose it.",
                        infoTipLink: Links.docString(.shortcuts)
                    )
                    
                    // Audio Permission
                    PermissionCard(
                        icon: "mic",
                        title: "Microphone Access",
                        description: "Allow Zerm to record your voice for transcription",
                        isGranted: permissionManager.audioPermissionStatus == .authorized,
                        buttonTitle: permissionManager.audioPermissionStatus == .notDetermined ? "Request Permission" : "Open System Settings",
                        buttonAction: {
                            if permissionManager.audioPermissionStatus == .notDetermined {
                                permissionManager.requestAudioPermission()
                            } else {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        },
                        checkPermission: { permissionManager.checkAudioPermissionStatus() },
                        infoTipMessage: "The one permission Zerm cannot work without — no microphone access means no audio to transcribe. macOS only asks once, so if you declined the first time you have to grant it in System Settings under Privacy & Security › Microphone.",
                        infoTipLink: Links.docString(.permissions)
                    )
                    
                    // Accessibility Permission
                    PermissionCard(
                        icon: "hand.raised",
                        title: "Accessibility Access",
                        description: "Allow Zerm to paste transcribed text directly at your cursor position",
                        isGranted: permissionManager.isAccessibilityEnabled,
                        buttonTitle: "Open System Settings",
                        buttonAction: {
                            permissionManager.openAccessibilitySettings(promptIfNeeded: true)
                        },
                        checkPermission: {
                            permissionManager.checkAccessibilityPermissions()
                            permissionManager.pollPermissions(forSeconds: 3)
                        },
                        infoTipMessage: "Zerm uses Accessibility permissions to paste the transcribed text directly into other applications at your cursor's position. This allows for a seamless dictation experience across your Mac. After enabling Zerm in System Settings, use the refresh button — if it stays red, fully quit Zerm (Cmd+Q) and reopen.",
                        infoTipLink: Links.docString(.permissions)
                    )

                    // Screen Recording Permission
                    PermissionCard(
                        icon: "rectangle.on.rectangle",
                        title: "Screen Recording Access",
                        description: permissionManager.screenRecordingNeedsRelaunch
                            ? "Permission looks granted — fully quit Zerm (Cmd+Q) and reopen to finish enabling Screen Recording"
                            : "Allow Zerm to understand context from your screen for transcript Enhancement",
                        isGranted: permissionManager.isScreenRecordingEnabled,
                        buttonTitle: permissionManager.screenRecordingNeedsRelaunch ? "Quit Zerm to Finish" : "Request Permission",
                        buttonAction: {
                            if permissionManager.screenRecordingNeedsRelaunch {
                                NSApp.terminate(nil)
                            } else {
                                permissionManager.requestScreenRecordingPermission()
                            }
                        },
                        checkPermission: {
                            permissionManager.checkScreenRecordingPermission()
                            permissionManager.pollPermissions(forSeconds: 3)
                        },
                        infoTipMessage: "Zerm captures on-screen text to understand the context of your voice input, which significantly improves transcription accuracy. Your privacy is important: this data is processed locally and is not stored. After toggling Screen Recording on, macOS often requires a full quit and relaunch before the check turns green.",
                        infoTipLink: Links.docString(.contextualAwareness)
                    )
                }
            }
            .padding(24)
        }
        .background(Color(NSColor.controlBackgroundColor))
        .onAppear {
            permissionManager.checkAllPermissions()
            permissionManager.pollPermissions(forSeconds: 2)
        }
    }
}

#Preview {
    PermissionsView()
} 
