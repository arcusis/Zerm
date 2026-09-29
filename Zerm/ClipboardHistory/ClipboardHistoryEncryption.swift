import CryptoKit
import Foundation

struct ClipboardHistoryEncryption {
    let key: SymmetricKey

    init(keyData: Data) throws {
        guard keyData.count == 32 else { throw ClipboardHistoryError.invalidKey }
        key = SymmetricKey(data: keyData)
    }

    func seal(_ data: Data) throws -> Data {
        guard let sealed = try AES.GCM.seal(data, using: key).combined else {
            throw ClipboardHistoryError.encryptionFailed
        }
        return sealed
    }

    func open(_ data: Data) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key)
    }
}

enum ClipboardHistoryError: LocalizedError {
    case invalidKey
    case encryptionFailed
    case keychainUnavailable
    case corruptStore
    case missingPayload
    case archiveOperationFailed
    case invalidArchivePassword
    case unsupportedArchiveVersion
    case corruptArchive
    case targetUnavailable
    case pasteCommandFailed

    var errorDescription: String? {
        switch self {
        case .targetUnavailable: String(localized: "The destination app is unavailable. Reopen history from the app you want to paste into.")
        case .pasteCommandFailed: String(localized: "Paste could not be sent. Check Accessibility permission, or copy the item and paste manually.")
        case .missingPayload: String(localized: "The clipboard item could not be loaded. Choose another item or reopen history.")
        case .keychainUnavailable, .invalidKey: String(localized: "Clipboard history could not access its encryption key.")
        case .invalidArchivePassword: String(localized: "The archive password is incorrect.")
        case .unsupportedArchiveVersion: String(localized: "This clipboard archive requires a newer version of Zerm.")
        case .corruptStore, .corruptArchive, .encryptionFailed, .archiveOperationFailed: String(localized: "Clipboard history could not read or save its data.")
        }
    }
}
