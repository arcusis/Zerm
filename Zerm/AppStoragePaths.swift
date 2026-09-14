import Foundation

/// Filesystem locations owned by this build of Zerm.
///
/// Every location is keyed by the bundle identifier, so a development build
/// (`com.arcusis.zerm.dev`, see `make dev-app`) runs beside the installed app without
/// reading, migrating or deleting its stores, models, recordings or logs. The release
/// build keeps exactly the paths it has always used.
enum AppStoragePaths {
    static let productionBundleIdentifier = "com.arcusis.zerm"

    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? productionBundleIdentifier
    }

    static var isProductionBundle: Bool {
        bundleIdentifier == productionBundleIdentifier
    }

    private static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// `Application Support/com.arcusis.zerm`: SwiftData stores, models, recordings, logs.
    static var root: URL {
        applicationSupport.appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    /// `Application Support/Zerm`: the older folder that holds custom sounds.
    static var legacyRoot: URL {
        let name = isProductionBundle ? "Zerm" : "Zerm (\(bundleIdentifier))"
        return applicationSupport.appendingPathComponent(name, isDirectory: true)
    }
}
