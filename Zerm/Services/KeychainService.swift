import Foundation
import Security
import os

/// Securely stores and retrieves API keys.
///
/// Shipped (Release) builds use the macOS Keychain with data protection. Local *developer*
/// builds (`#if DEBUG`) fall back to UserDefaults because unsigned/ad-hoc dev binaries don't
/// keep a stable code-signing identity across rebuilds, which makes Keychain items unreliable.
/// The fallback is gated on `DEBUG` — never on the release flag — so shipped builds always use
/// the Keychain. On first launch of a Keychain build, any keys left in the old plaintext
/// UserDefaults store by a previous release are migrated into the Keychain and then purged.
final class KeychainService {
    static let shared = KeychainService()

    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "KeychainService")
    private let service = "com.arcusis.zerm"

    /// Prefix used by the DEBUG UserDefaults store and by the legacy plaintext store that
    /// shipped Release builds used before keys moved to the Keychain.
    private let localPrefix = "LocalKeychain_"

    #if DEBUG
    private let defaults = UserDefaults.standard
    #endif

    private init() {
        #if !DEBUG
        migrateLegacyPlaintextKeysIfNeeded()
        #endif
    }

    // MARK: - Public API

    /// Saves a string value to Keychain.
    @discardableResult
    func save(_ value: String, forKey key: String, syncable: Bool = true) -> Bool {
        guard let data = value.data(using: .utf8) else {
            logger.error("Failed to convert value to data for key: \(key, privacy: .public)")
            return false
        }
        return save(data: data, forKey: key, syncable: syncable)
    }

    /// Saves data to Keychain.
    @discardableResult
    func save(data: Data, forKey key: String, syncable: Bool = true) -> Bool {
        #if DEBUG
        defaults.set(data, forKey: localPrefix + key)
        return true
        #else
        // First, try to delete any existing item to avoid duplicates
        delete(forKey: key, syncable: syncable)

        var query = baseQuery(forKey: key, syncable: syncable)
        query[kSecValueData as String] = data

        let status = SecItemAdd(query as CFDictionary, nil)

        if status == errSecSuccess {
            logger.info("Successfully saved keychain item for key: \(key, privacy: .public)")
            return true
        } else {
            logger.error("Failed to save keychain item for key: \(key, privacy: .public), status: \(status, privacy: .public)")
            return false
        }
        #endif
    }

    /// Retrieves a string value from Keychain.
    func getString(forKey key: String, syncable: Bool = true) -> String? {
        guard let data = getData(forKey: key, syncable: syncable) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Retrieves data from Keychain.
    func getData(forKey key: String, syncable: Bool = true) -> Data? {
        #if DEBUG
        return defaults.data(forKey: localPrefix + key)
        #else
        var query = baseQuery(forKey: key, syncable: syncable)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess {
            return result as? Data
        } else if status != errSecItemNotFound {
            logger.error("Failed to retrieve keychain item for key: \(key, privacy: .public), status: \(status, privacy: .public)")
        }

        return nil
        #endif
    }

    /// Deletes an item from Keychain.
    @discardableResult
    func delete(forKey key: String, syncable: Bool = true) -> Bool {
        #if DEBUG
        defaults.removeObject(forKey: localPrefix + key)
        return true
        #else
        let query = baseQuery(forKey: key, syncable: syncable)
        let status = SecItemDelete(query as CFDictionary)

        if status == errSecSuccess || status == errSecItemNotFound {
            if status == errSecSuccess {
                logger.info("Successfully deleted keychain item for key: \(key, privacy: .public)")
            }
            return true
        } else {
            logger.error("Failed to delete keychain item for key: \(key, privacy: .public), status: \(status, privacy: .public)")
            return false
        }
        #endif
    }

    /// Checks if a key exists in Keychain.
    func exists(forKey key: String, syncable: Bool = true) -> Bool {
        #if DEBUG
        return defaults.data(forKey: localPrefix + key) != nil
        #else
        var query = baseQuery(forKey: key, syncable: syncable)
        query[kSecReturnData as String] = kCFBooleanFalse

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
        #endif
    }

    // MARK: - Private Helpers

    #if !DEBUG
    /// Creates base Keychain query dictionary.
    ///
    /// Uses the traditional login Keychain (not the data-protection Keychain) so it works for
    /// a Developer-ID, non-sandboxed app without a `keychain-access-groups` entitlement. The
    /// app reads back its own items without a prompt because it created them. `syncable` is
    /// accepted for source compatibility but intentionally unused: iCloud Keychain sync
    /// requires the data-protection Keychain, which our entitlements don't grant, and shipped
    /// builds never synced keys.
    private func baseQuery(forKey key: String, syncable: Bool) -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            // Only readable while the device is unlocked; excluded from unencrypted backups.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
    }

    /// One-time move of API keys that a prior Release build wrote in plaintext to
    /// `~/Library/Preferences` (UserDefaults `LocalKeychain_*`) into the Keychain, then
    /// deletes the plaintext copies. Idempotent via a persisted flag.
    private func migrateLegacyPlaintextKeysIfNeeded() {
        let migrationFlagKey = "KeychainPlaintextMigration_v1_done"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationFlagKey) else { return }

        var migrated = 0
        for (defaultsKey, value) in defaults.dictionaryRepresentation() where defaultsKey.hasPrefix(localPrefix) {
            let realKey = String(defaultsKey.dropFirst(localPrefix.count))
            // Values were stored as Data; skip anything unexpected but still purge it.
            if let data = value as? Data, !exists(forKey: realKey) {
                if save(data: data, forKey: realKey, syncable: true) {
                    migrated += 1
                }
            }
            defaults.removeObject(forKey: defaultsKey)
        }

        defaults.set(true, forKey: migrationFlagKey)
        if migrated > 0 {
            logger.notice("Migrated \(migrated, privacy: .public) API key(s) from plaintext storage into the Keychain")
        }
    }
    #endif
}
