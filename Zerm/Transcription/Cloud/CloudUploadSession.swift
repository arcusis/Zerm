import Foundation

/// Uploads audio payloads over a connection that stays on TCP.
///
/// `URLSession.shared` caches the `Alt-Svc` advertisement that Cloudflare-fronted
/// transcription APIs send, so subsequent connections silently upgrade to HTTP/3.
/// Several VPN clients (GlobalProtect among them) forward small QUIC packets but
/// drop full-size datagrams, which blackholes a multi-megabyte audio upload until
/// the request times out with `-1001`. The retry then succeeds, because the failed
/// attempt is what knocks the connection back down to TCP.
///
/// An ephemeral session carries no Alt-Svc cache, so every upload starts on TCP.
/// The cost is one extra TLS handshake, around 0.1 s.
enum CloudUploadSession {

    /// Performs a one-shot upload on a fresh ephemeral session.
    static func upload(_ request: URLRequest, body: Data) async throws -> (Data, URLResponse) {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        return try await session.upload(for: request, from: body)
    }
}
