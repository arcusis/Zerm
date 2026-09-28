import Foundation

struct ModelProvenance: Equatable, Sendable {
    let creator: String
    let sourceURL: URL
    let downloadHost: String
    let licenseName: String
    let licenseSPDX: String?
    let licenseURL: URL
    let attribution: String
    let conversionCredit: String?
    let checksumSHA256: String?
}
