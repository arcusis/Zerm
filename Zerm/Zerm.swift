import SwiftUI
import SwiftData
import Sparkle
import AppKit
import OSLog
import AppIntents
import FluidAudio
import Security

@main
struct ZermApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    let container: ModelContainer
    let containerInitializationFailed: Bool
    private let uiTestConfiguration: UITestLaunchConfiguration

    @StateObject private var engine: ZermEngine
    @StateObject private var whisperModelManager: WhisperModelManager
    @StateObject private var fluidAudioModelManager: FluidAudioModelManager
    @StateObject private var transcriptionModelManager: TranscriptionModelManager
    @StateObject private var recorderUIManager: RecorderUIManager
    @StateObject private var hotkeyManager: HotkeyManager
    @StateObject private var updaterViewModel: UpdaterViewModel
    @StateObject private var menuBarManager: MenuBarManager
    @StateObject private var ttsController: TTSController
    @StateObject private var meetingRecordingController: MeetingRecordingController
    @StateObject private var aiService = AIService()
    @StateObject private var enhancementService: AIEnhancementService
    @StateObject private var activeWindowService = ActiveWindowService.shared
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("enableAnnouncements") private var enableAnnouncements = true
    @State private var showMenuBarIcon = true

    // Audio cleanup manager for automatic deletion of old audio files
    private let audioCleanupManager = AudioCleanupManager.shared

    // Transcription auto-cleanup service for zero data retention
    private let transcriptionAutoCleanupService = TranscriptionAutoCleanupService.shared

    // Model prewarm service for optimizing model on wake from sleep
    private let prewarmService: ModelPrewarmService?

    init() {
        let uiTestConfiguration = UITestLaunchConfiguration.current
        self.uiTestConfiguration = uiTestConfiguration
        _showMenuBarIcon = State(initialValue: !uiTestConfiguration.isEnabled)

        // Disable HTTP response caching — prevents API responses from being stored in Cache.db
        URLCache.shared = URLCache(memoryCapacity: 0, diskCapacity: 0)

        if !uiTestConfiguration.isEnabled {
            AppDefaults.registerDefaults()
        }

        if !uiTestConfiguration.isEnabled,
           UserDefaults.standard.object(forKey: "powerModeUIFlag") == nil {
            let hasEnabledPowerModes = PowerModeManager.shared.configurations.contains { $0.isEnabled }
            UserDefaults.standard.set(hasEnabledPowerModes, forKey: "powerModeUIFlag")
        }

        let logger = Logger(subsystem: "com.arcusis.zerm", category: "Initialization")
        let schema = Schema([
            Transcription.self,
            VocabularyWord.self,
            WordReplacement.self,
            UsageDay.self
        ])
        var initializationFailed = false

        if uiTestConfiguration.isEnabled,
           let memoryContainer = Self.createInMemoryContainer(schema: schema, logger: logger) {
            container = memoryContainer
        }
        // Attempt 1: Try persistent storage
        else if let persistentContainer = Self.createPersistentContainer(schema: schema, logger: logger) {
            container = persistentContainer
        }
        // Attempt 2: Try in-memory storage
        else if let memoryContainer = Self.createInMemoryContainer(schema: schema, logger: logger) {
            container = memoryContainer

            logger.warning("Using in-memory storage as fallback. Data will not persist between sessions.")

            // Show alert to user about storage issue
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Storage Warning"
                alert.informativeText = "Zerm couldn't access its storage location. Your transcriptions will not be saved between sessions."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
        // All attempts failed
        else {
            logger.critical("ModelContainer initialization failed")
            initializationFailed = true

            // Create minimal in-memory container to satisfy initialization
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            container = (try? ModelContainer(for: schema, configurations: [config])) ?? {
                preconditionFailure("Unable to create ModelContainer. SwiftData is unavailable.")
            }()
        }

        containerInitializationFailed = initializationFailed

        // Initialize services with proper sharing of instances
        let aiService = AIService()
        _aiService = StateObject(wrappedValue: aiService)

        let updaterViewModel = UpdaterViewModel(startsUpdater: !uiTestConfiguration.isEnabled)
        _updaterViewModel = StateObject(wrappedValue: updaterViewModel)

        let enhancementService = AIEnhancementService(aiService: aiService, modelContext: container.mainContext)
        _enhancementService = StateObject(wrappedValue: enhancementService)

        // 1. Create modelsDirectory URL
        let appSupportDirectory = uiTestConfiguration.storageRoot
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("com.arcusis.zerm")
        let modelsDirectory = appSupportDirectory.appendingPathComponent("WhisperModels")

        // 2. Create model managers
        let whisperModelManager = WhisperModelManager(modelsDirectory: modelsDirectory)
        let fluidAudioModelManager = FluidAudioModelManager()
        let transcriptionModelManager = TranscriptionModelManager(
            whisperModelManager: whisperModelManager,
            fluidAudioModelManager: fluidAudioModelManager
        )

        // 3. Create UI manager
        let recorderUIManager = RecorderUIManager()

        // 4. Create engine
        let engine = ZermEngine(
            modelContext: container.mainContext,
            whisperModelManager: whisperModelManager,
            transcriptionModelManager: transcriptionModelManager,
            enhancementService: enhancementService
        )

        // 5. Configure circular deps
        recorderUIManager.configure(engine: engine, recorder: engine.recorder)
        engine.recorderUIManager = recorderUIManager

        // 6. Initialize model state
        // Migration and refreshAllAvailableModels must run before loadCurrentTranscriptionModel so renamed keys are remapped and imported models are present when restoring the saved selection.
        if !uiTestConfiguration.isEnabled {
            StreamingKeysMigration.run()
            // Restores History rows blanked by 2.8.3's empty on-device enhancements.
            if !containerInitializationFailed {
                EmptyEnhancementRepair.run(modelContext: container.mainContext)
            }
        }
        whisperModelManager.createModelsDirectoryIfNeeded()
        whisperModelManager.loadAvailableModels()
        transcriptionModelManager.refreshAllAvailableModels()
        if uiTestConfiguration.scenario == .nativeApple,
           let nativeModel = transcriptionModelManager.allAvailableModels.first(where: { $0.provider == .nativeApple }) {
            transcriptionModelManager.currentTranscriptionModel = nativeModel
        } else if !uiTestConfiguration.isEnabled {
            transcriptionModelManager.loadCurrentTranscriptionModel()
        }

        _whisperModelManager = StateObject(wrappedValue: whisperModelManager)
        _fluidAudioModelManager = StateObject(wrappedValue: fluidAudioModelManager)
        _transcriptionModelManager = StateObject(wrappedValue: transcriptionModelManager)
        _recorderUIManager = StateObject(wrappedValue: recorderUIManager)
        _engine = StateObject(wrappedValue: engine)

        // Meeting capture is application-scoped. Views only observe this coordinator so
        // navigation, window closure, and menu-bar-only operation can never orphan an active
        // recording or remove its only Stop action.
        let meetingRecordingController = MeetingRecordingController(engine: engine)
        _meetingRecordingController = StateObject(wrappedValue: meetingRecordingController)

        // 7. Create other services that depend on engine
        let hotkeyManager = HotkeyManager(engine: engine, recorderUIManager: recorderUIManager)
        _hotkeyManager = StateObject(wrappedValue: hotkeyManager)

        let menuBarManager = MenuBarManager(
            initialMenuBarOnly: uiTestConfiguration.isEnabled ? false : nil
        )
        _menuBarManager = StateObject(wrappedValue: menuBarManager)
        menuBarManager.configure(modelContainer: container, engine: engine)

        // Read Aloud (text-to-speech) — mirror of the dictation flow.
        // HotkeyManager owns the trigger (modifier-key dropdown or custom shortcut),
        // consistent with dictation; it calls back into the controller.
        let ttsController = TTSController(engine: engine, recorderUIManager: recorderUIManager)
        hotkeyManager.onReadAloudTriggered = { [weak ttsController] in ttsController?.toggle() }
        recorderUIManager.onCancelSpeaking = { [weak ttsController] in ttsController?.stop() }
        meetingRecordingController.onWillStartCapture = { [weak ttsController] in
            ttsController?.prepareForMeetingCapture()
        }
        _ttsController = StateObject(wrappedValue: ttsController)

        let activeWindowService = ActiveWindowService.shared
        activeWindowService.configure(with: enhancementService)
        _activeWindowService = StateObject(wrappedValue: activeWindowService)

        prewarmService = uiTestConfiguration.isEnabled
            ? nil
            : ModelPrewarmService(
                transcriptionModelManager: transcriptionModelManager,
                whisperModelManager: whisperModelManager,
                modelContext: container.mainContext
            )

        appDelegate.menuBarManager = menuBarManager
        appDelegate.onWillTerminate = { [weak meetingRecordingController] in
            meetingRecordingController?.prepareForTermination()
        }

        // Ensure no lingering recording state from previous runs
        if !uiTestConfiguration.isEnabled {
            Task {
                await recorderUIManager.resetOnLaunch()
            }
        }

        // Warm the launch-at-login cache off the main thread — reading it lazily from a
        // view would block the main thread on XPC. See `LaunchAtLoginStore`.
        if !uiTestConfiguration.isEnabled {
            LaunchAtLoginStore.shared.loadIfNeeded()
        }

        // Never load native ML runtimes in the XCTest host. It launches the whole app and then
        // immediately calls exit(), which races C++ static destruction against an in-flight
        // onnxruntime session construction and segfaults on the way out.
        ProcessLifecycle.isTerminating = uiTestConfiguration.isEnabled || NSClassFromString("XCTestCase") != nil

        // Pre-warm only Kokoro (~330 MB) so speech can start promptly. Do not load the
        // multi-gigabyte local LLM at launch: many users run Zerm alongside memory-intensive
        // development work. Dictation pre-warms it while audio is being captured when needed;
        // Read Aloud loads it on demand and the manager releases it after a short idle window.
        if !uiTestConfiguration.isEnabled {
            Task { await KokoroModelManager.shared.prewarmIfNeeded() }
            AppShortcuts.updateAppShortcutParameters()
        }

        // Durable usage metrics. The backfill must land before the first recording of the
        // run, otherwise that session would be counted once live and once by the sweep.
        if !uiTestConfiguration.isEnabled {
            UsageStatsService.shared.configure(container: container)
            let transcriptContext = container.mainContext
            Task { await UsageStatsService.shared.backfillIfNeeded(from: transcriptContext) }

            // Start cleanup service for the app's lifetime, not tied to window lifecycle
            TranscriptionAutoCleanupService.shared.startMonitoring(modelContext: container.mainContext)
        }
    }

    // MARK: - Container Creation Helpers

    private static func createPersistentContainer(schema: Schema, logger: Logger) -> ModelContainer? {
        do {
            // Create app-specific Application Support directory URL
            let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("com.arcusis.zerm", isDirectory: true)

            // Create the directory if it doesn't exist
            try? FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true)

            // Define storage locations
            let defaultStoreURL = appSupportURL.appendingPathComponent("default.store")
            let dictionaryStoreURL = appSupportURL.appendingPathComponent("dictionary.store")
            let usageStoreURL = appSupportURL.appendingPathComponent("usage.store")

            // Transcript configuration
            let transcriptSchema = Schema([Transcription.self])
            let transcriptConfig = ModelConfiguration(
                "default",
                schema: transcriptSchema,
                url: defaultStoreURL,
                cloudKitDatabase: .none
            )

            // Dictionary configuration
            let dictionarySchema = Schema([VocabularyWord.self, WordReplacement.self])
            let cloudContainer = "iCloud.com.arcusis.zerm"
            let canUseCloudKit = hasCloudKitEntitlement(for: cloudContainer)
            if !canUseCloudKit {
                logger.notice("iCloud container entitlement absent — dictionary sync disabled for this build")
            }
            let dictionaryCloudKit: ModelConfiguration.CloudKitDatabase =
                canUseCloudKit ? .private(cloudContainer) : .none
            let dictionaryConfig = ModelConfiguration(
                "dictionary",
                schema: dictionarySchema,
                url: dictionaryStoreURL,
                cloudKitDatabase: dictionaryCloudKit
            )

            // Usage configuration — aggregate counts only, kept out of `default.store` so
            // transcript retention can never delete the user's lifetime metrics. See `UsageDay`.
            let usageSchema = Schema([UsageDay.self])
            let usageConfig = ModelConfiguration(
                "usage",
                schema: usageSchema,
                url: usageStoreURL,
                cloudKitDatabase: .none
            )

            // Initialize container
            return try ModelContainer(
                for: schema,
                configurations: transcriptConfig, dictionaryConfig, usageConfig
            )
        } catch {
            logger.error("❌ Failed to create persistent ModelContainer: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Whether the running binary actually carries the iCloud container entitlement.
    ///
    /// `Zerm.entitlements` declares the container, but an entitlement is only *granted* by a
    /// signature backed by a provisioning profile. Ad-hoc and unsigned builds — `make local`,
    /// a plain `xcodebuild` Debug build, and the unit-test host — are signed with no team, so
    /// the entitlement is absent at runtime. CoreData+CloudKit does not degrade gracefully
    /// there: `PFCloudKitSetupAssistant` asks CloudKit for the container and CloudKit traps
    /// (`EXC_BREAKPOINT` on `com.apple.coredata.cloudkit.queue`), killing the app during
    /// launch. Checking the real entitlement — rather than a `#if LOCAL_BUILD` flag that only
    /// covers one of those build paths — keeps every unsigned build alive with sync disabled,
    /// while a properly signed Release still gets iCloud.
    private static func hasCloudKitEntitlement(for container: String) -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                task,
                "com.apple.developer.icloud-container-identifiers" as CFString,
                nil
              ),
              let identifiers = value as? [String]
        else {
            return false
        }
        return identifiers.contains(container)
    }

    private static func createInMemoryContainer(schema: Schema, logger: Logger) -> ModelContainer? {
        do {
            // Transcript configuration
            let transcriptSchema = Schema([Transcription.self])
            let transcriptConfig = ModelConfiguration(
                "default",
                schema: transcriptSchema,
                isStoredInMemoryOnly: true
            )

            // Dictionary configuration
            let dictionarySchema = Schema([VocabularyWord.self, WordReplacement.self])
            let dictionaryConfig = ModelConfiguration(
                "dictionary",
                schema: dictionarySchema,
                isStoredInMemoryOnly: true
            )

            // Usage configuration
            let usageSchema = Schema([UsageDay.self])
            let usageConfig = ModelConfiguration(
                "usage",
                schema: usageSchema,
                isStoredInMemoryOnly: true
            )

            return try ModelContainer(for: schema, configurations: transcriptConfig, dictionaryConfig, usageConfig)
        } catch {
            logger.error("❌ Failed to create in-memory ModelContainer: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    var body: some Scene {
        WindowGroup(id: UITestLaunchConfiguration.mainWindowSceneID) {
            if hasCompletedOnboarding || uiTestConfiguration.isEnabled {
                ContentView()
                    .environmentObject(engine)
                    .environmentObject(whisperModelManager)
                    .environmentObject(fluidAudioModelManager)
                    .environmentObject(transcriptionModelManager)
                    .environmentObject(recorderUIManager)
                    .environmentObject(hotkeyManager)
                    .environmentObject(updaterViewModel)
                    .environmentObject(menuBarManager)
                    .environmentObject(ttsController)
                    .environmentObject(meetingRecordingController)
                    .environmentObject(aiService)
                    .environmentObject(enhancementService)
                    .modelContainer(container)
                    .uiTestEnvironment(uiTestConfiguration)
                    .onAppear {
                        // Check if container initialization failed
                        if containerInitializationFailed {
                            let alert = NSAlert()
                            alert.messageText = "Critical Storage Error"
                            alert.informativeText = "Zerm cannot initialize its storage system. The app cannot continue.\n\nPlease try reinstalling the app or contact support if the issue persists."
                            alert.alertStyle = .critical
                            alert.addButton(withTitle: "Quit")
                            alert.runModal()

                            NSApplication.shared.terminate(nil)
                            return
                        }

                        if !uiTestConfiguration.isEnabled {
                            updaterViewModel.silentlyCheckForUpdates()
                            if enableAnnouncements {
                                AnnouncementsService.shared.start()
                            }

                            // Start automatic audio cleanup only outside deterministic UI tests.
                            if !UserDefaults.standard.bool(forKey: "IsTranscriptionCleanupEnabled") {
                                audioCleanupManager.startAutomaticCleanup(modelContext: container.mainContext)
                            }
                        }
                    }
                    .background(WindowAccessor { window in
                        WindowManager.shared.configureWindow(window)
                    })
                    .onDisappear {
                        AnnouncementsService.shared.stop()
                        // Deliberately NOT unloading Whisper here. For a menu-bar dictation
                        // app, "main window closed" is the steady state — evicting the model
                        // on window close threw away the warm context and made the next
                        // dictation pay a ~800 ms reload. Release is driven by real memory
                        // pressure instead (ZermEngine.startMemoryPressureMonitor).

                        // Stop the automatic audio cleanup process
                        audioCleanupManager.stopAutomaticCleanup()
                    }
            } else {
                OnboardingView(hasCompletedOnboarding: $hasCompletedOnboarding)
                    .environmentObject(hotkeyManager)
                    .environmentObject(engine)
                    .environmentObject(whisperModelManager)
                    .environmentObject(fluidAudioModelManager)
                    .environmentObject(transcriptionModelManager)
                    .environmentObject(recorderUIManager)
                    .environmentObject(aiService)
                    .environmentObject(enhancementService)
                    .frame(minWidth: 880, minHeight: 780)
                    .background(WindowAccessor { window in
                        if window.identifier == nil || window.identifier != NSUserInterfaceItemIdentifier("com.arcusis.zerm.onboardingWindow") {
                            WindowManager.shared.configureOnboardingPanel(window)
                        }
                    })
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 950, height: 730)
        .commands {
            #if DEBUG
            UITestOpenMainWindowCommands(configuration: uiTestConfiguration)
            #else
            CommandGroup(replacing: .newItem) { }
            #endif

            SidebarCommands()

            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updaterViewModel: updaterViewModel)
            }
        }

        Settings {
            SettingsRootView()
                .environmentObject(whisperModelManager)
                .environmentObject(fluidAudioModelManager)
                .environmentObject(transcriptionModelManager)
                .environmentObject(recorderUIManager)
                .environmentObject(hotkeyManager)
                .environmentObject(updaterViewModel)
                .environmentObject(menuBarManager)
                .environmentObject(ttsController)
                .environmentObject(meetingRecordingController)
                .environmentObject(enhancementService)
                .modelContainer(container)
                .uiTestEnvironment(uiTestConfiguration)
        }

        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarView()
                .environmentObject(engine)
                .environmentObject(whisperModelManager)
                .environmentObject(fluidAudioModelManager)
                .environmentObject(transcriptionModelManager)
                .environmentObject(recorderUIManager)
                .environmentObject(hotkeyManager)
                .environmentObject(menuBarManager)
                .environmentObject(updaterViewModel)
                .environmentObject(meetingRecordingController)
                .environmentObject(aiService)
                .environmentObject(enhancementService)
                .uiTestEnvironment(uiTestConfiguration)
        } label: {
            let image: NSImage = {
                let ratio = $0.size.height / $0.size.width
                $0.size.height = 22
                $0.size.width = 22 / ratio
                return $0
            }(NSImage(named: "menuBarIcon")!)

            Image(nsImage: image)
        }
        .menuBarExtraStyle(.menu)

    }
}

struct CheckForUpdatesView: View {
    @ObservedObject var updaterViewModel: UpdaterViewModel

    var body: some View {
        Button("Check for Updates…", action: updaterViewModel.checkForUpdates)
            .disabled(!updaterViewModel.canCheckForUpdates)
    }
}

struct WindowAccessor: NSViewRepresentable {
    let callback: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                callback(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
