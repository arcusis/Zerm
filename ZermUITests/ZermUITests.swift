import XCTest

final class ZermUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    @MainActor
    func testTaskFirstSidebarDestinationsAndKeyboardSemantics() {
        app = launch()

        assertExists("sidebar-group-speech")
        assertExists("sidebar-group-automation")
        assertExists("sidebar-group-system")

        for route in [
            "dashboard", "dictationHistory", "meetingsRecord", "meetingsHistory",
            "readAloudSpeak", "readAloudHistory", "enhancement", "powerModes", "permissions"
        ] {
            let link = element("sidebar-\(route)")
            XCTAssertTrue(link.waitForExistence(timeout: 3), "Missing sidebar route \(route)")
            link.click()
            XCTAssertTrue(element("destination-\(route)").waitForExistence(timeout: 3), "Route \(route) did not open")
        }

        app.typeKey("s", modifierFlags: [.command, .control])
        XCTAssertTrue(
            waitFor(element("sidebar-meetingsRecord"), predicate: "hittable == false"),
            "Sidebar shortcut did not hide the sidebar"
        )
        app.typeKey("s", modifierFlags: [.command, .control])
        XCTAssertTrue(
            waitFor(element("sidebar-meetingsRecord"), predicate: "hittable == true"),
            "Sidebar shortcut did not restore the sidebar"
        )
    }

    @MainActor
    func testMeetingPreflightUsesExplicitSelectedApplicationAndFixedNativeLanguage() {
        app = launch(scenario: "nativeApple")
        openSidebarRoute("meetingsRecord")

        assertExists("meeting-prepare-title")
        let applicationPicker = element("meeting-application-picker")
        XCTAssertTrue(applicationPicker.waitForExistence(timeout: 3))
        XCTAssertTrue(String(describing: applicationPicker.value).contains("Example Meeting"))
        XCTAssertFalse(element("meeting-all-system-warning").exists)

        let disclosure = element("meeting-language-disclosure")
        XCTAssertTrue(disclosure.waitForExistence(timeout: 3))
        XCTAssertFalse(disclosure.label.localizedCaseInsensitiveContains("auto-detect"))
        XCTAssertTrue(element("meeting-start-recording").isEnabled)
    }

    @MainActor
    func testMeetingPreflightRequiresExplicitAllSystemFallbackWarning() {
        app = launch(scenario: "nativeApple")
        openSidebarRoute("meetingsRecord")

        choosePicker(identifier: "meeting-call-audio-source", option: "All system audio")
        assertExists("meeting-all-system-warning")
        XCTAssertFalse(element("meeting-application-picker").exists)
        XCTAssertTrue(element("meeting-start-recording").isEnabled)
    }

    @MainActor
    func testNativeSettingsContainsMeetingsAndReadAloudControls() {
        app = launch(scenario: "nativeApple")
        app.typeKey(",", modifierFlags: .command)

        assertExists("settings-root", timeout: 5)

        click(identifier: "settings-tab-shortcuts", fallbackLabel: "Shortcuts")
        let shortcutKey = element("settings-shortcut-1-key")
        XCTAssertTrue(shortcutKey.waitForExistence(timeout: 3))
        XCTAssertEqual(shortcutKey.label, "Shortcut 1 key")
        XCTAssertFalse(String(describing: shortcutKey.value).isEmpty)

        click(identifier: "settings-tab-audio", fallbackLabel: "Audio")
        assertExists("settings-pane-audio")

        click(identifier: "settings-audio-section-meetings", fallbackLabel: "Meetings")
        XCTAssertTrue(
            app.descendants(matching: .any)["Create Summary After Recording"]
                .firstMatch
                .waitForExistence(timeout: 3),
            "Meetings settings did not expose the summary control"
        )

        click(identifier: "settings-audio-section-readAloud", fallbackLabel: "Read Aloud")
        XCTAssertTrue(
            app.descendants(matching: .any)["Meeting Safety"]
                .firstMatch
                .waitForExistence(timeout: 3),
            "Read Aloud settings did not expose meeting-safety guidance"
        )
    }

    @MainActor
    func testSidebarSettingsOpensTheDedicatedSettingsWindow() {
        app = launch()

        let mainWindow = app.windows
            .matching(identifier: "com.arcusis.zerm.mainWindow")
            .firstMatch
        let settingsButton = mainWindow.descendants(matching: .any)
            .matching(identifier: "sidebar-settings")
            .firstMatch
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 3))
        settingsButton.click()

        XCTAssertTrue(element("settings-root").waitForExistence(timeout: 5))
        XCTAssertFalse(
            mainWindow.descendants(matching: .any)
                .matching(identifier: "settings-root")
                .firstMatch
                .exists,
            "Settings must not be embedded beside the primary app sidebar"
        )
        XCTAssertTrue(
            mainWindow.descendants(matching: .any)
                .matching(identifier: "destination-dashboard")
                .firstMatch
                .exists,
            "Opening Settings should preserve the current workflow in the main window"
        )
    }

    @MainActor
    func testPersistentMeetingStatusSurvivesNavigationWithAnimationsDisabledAndCanStop() {
        app = launch(scenario: "activeMeeting", disablesAnimations: true)

        let stop = element("global-stop-meeting")
        XCTAssertTrue(stop.waitForExistence(timeout: 3))
        openSidebarRoute("readAloudSpeak")
        XCTAssertTrue(stop.exists && stop.isHittable)
        stop.click()
        XCTAssertTrue(waitFor(stop, predicate: "exists == false"))
        assertMainWindowIsPresented()
    }

    @MainActor
    func testHebrewRightToLeftLaunchSmoke() {
        app = launch(scenario: "nativeApple", language: "he", rightToLeft: true)

        let sidebar = element("primary-sidebar")
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        openSidebarRoute("meetingsRecord")
        assertExists("meeting-prepare-title")
        XCTAssertTrue(app.descendants(matching: .any)["הכנת הפגישה"].exists)

        app.typeKey(",", modifierFlags: .command)
        assertExists("settings-root", timeout: 5)
        click(identifier: "settings-tab-shortcuts", fallbackLabel: "קיצורים")
        let shortcutKey = element("settings-shortcut-1-key")
        XCTAssertTrue(shortcutKey.waitForExistence(timeout: 3))
        XCTAssertEqual(shortcutKey.label, "המקש של קיצור דרך 1")
    }

    // MARK: - Harness

    @MainActor
    private func launch(
        scenario: String = "standard",
        language: String = "en",
        rightToLeft: Bool = false,
        disablesAnimations: Bool = false
    ) -> XCUIApplication {
        let application = XCUIApplication()
        let identifier = UUID().uuidString
        let isolatedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZermUITests-\(identifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)

        application.launchArguments = [
            "--zerm-ui-testing",
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", language == "he" ? "he_IL" : "en_US",
            "-ApplePersistenceIgnoreState", "YES",
            "-IsMenuBarOnly", "NO",
            "-autoUpdateCheck", "NO",
            "-PrewarmModelOnWake", "NO",
            "-selectedHotkey1", "none",
            "-selectedHotkey2", "none",
            "-readAloudHotkey", "none",
            "-isMiddleClickToggleEnabled", "NO"
        ]
        application.launchEnvironment = [
            "CFFIXED_USER_HOME": isolatedHome.path,
            "HOME": isolatedHome.path,
            "ZERM_UI_TEST_STORAGE_ROOT": isolatedHome.appendingPathComponent("Application Support", isDirectory: true).path,
            "ZERM_UI_TEST_DEFAULTS_SUITE": "com.arcusis.zerm.uitests.\(identifier)",
            "ZERM_UI_TEST_SCENARIO": scenario,
            "ZERM_UI_TEST_RTL": rightToLeft ? "1" : "0",
            "ZERM_UI_TEST_DISABLE_ANIMATIONS": disablesAnimations ? "1" : "0"
        ]
        application.launch()
        XCTAssertEqual(
            application.state,
            .runningForeground,
            "The explicit UI-test host must launch as a foreground macOS application"
        )
        application.typeKey("n", modifierFlags: .command)
        assertMainWindowIsPresented(in: application, timeout: 8)
        return application
    }

    @MainActor
    private func openSidebarRoute(_ route: String) {
        let link = element("sidebar-\(route)")
        XCTAssertTrue(link.waitForExistence(timeout: 3))
        link.click()
        XCTAssertTrue(element("destination-\(route)").waitForExistence(timeout: 3))
    }

    @MainActor
    private func choosePicker(identifier: String, option: String) {
        let picker = element(identifier)
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        picker.click()
        let menuItem = app.menuItems[option].firstMatch
        XCTAssertTrue(menuItem.waitForExistence(timeout: 2), "Missing picker option \(option)")
        menuItem.click()
    }

    @MainActor
    private func click(identifier: String, fallbackLabel: String) {
        let identified = element(identifier)
        if identified.waitForExistence(timeout: 1) {
            identified.click()
            return
        }
        let labelled = app.descendants(matching: .any)[fallbackLabel].firstMatch
        XCTAssertTrue(labelled.waitForExistence(timeout: 2), "Missing \(fallbackLabel)")
        labelled.click()
    }

    @MainActor
    private func assertExists(_ identifier: String, timeout: TimeInterval = 3) {
        XCTAssertTrue(element(identifier).waitForExistence(timeout: timeout), "Missing \(identifier)")
    }

    @MainActor
    private func assertMainWindowIsPresented(
        in application: XCUIApplication? = nil,
        timeout: TimeInterval = 3
    ) {
        let application = application ?? app!
        let mainWindow = application.windows
            .matching(identifier: "com.arcusis.zerm.mainWindow")
            .firstMatch
        XCTAssertTrue(
            mainWindow.waitForExistence(timeout: timeout),
            "The real Zerm main window was not presented"
        )

        let sidebar = mainWindow.descendants(matching: .any)
            .matching(identifier: "primary-sidebar")
            .firstMatch
        XCTAssertTrue(
            sidebar.waitForExistence(timeout: timeout),
            "The main window did not expose its primary sidebar"
        )
    }

    @MainActor
    private func element(_ identifier: String, in application: XCUIApplication? = nil) -> XCUIElement {
        (application ?? app).descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func waitFor(
        _ element: XCUIElement,
        predicate: String,
        timeout: TimeInterval = 3
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: predicate),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
