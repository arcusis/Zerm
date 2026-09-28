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

enum ClipboardHistoryError: Error {
    case invalidKey
    case encryptionFailed
    case keychainUnavailable
    case corruptStore
    case missingPayload
}
