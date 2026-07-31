import AVFoundation
import Foundation
import OSLog

/// Turns a live meeting's audio into a transcript while the meeting is still running.
///
/// Audio is cut into fixed windows and each window is transcribed as a file, rather than held
/// open on a streaming socket. Over a two-hour meeting that matters: sockets drop and have to be
/// re-established, cloud streaming meters by the minute, and a dropped connection loses the tail.
/// A window that fails to transcribe costs only itself, and the approach works with every model
/// Zerm supports — local Whisper, Parakeet or any cloud provider — through the one
/// `transcribe` closure.
///
/// Windows overlap slightly so a word spoken across a boundary is not sliced in half.
final class MeetingTranscriber: @unchecked Sendable {

    struct Segment: Identifiable, Equatable {
        let id = UUID()
        let start: TimeInterval
        let end: TimeInterval
        let text: String
    }

    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "MeetingTranscriber")

    private let format = SystemAudioTrackWriter.targetFormat
    private let sampleRate: Double = 16_000
    private let windowSeconds: Double
    private let overlapSeconds: Double
    private let transcribe: @Sendable (URL) async throws -> String

    private let queue = DispatchQueue(label: "com.arcusis.zerm.meeting-transcriber", qos: .utility)
    private var pending = Data()
    private var windowIndex = 0
    private var totalSamplesAppended = 0

    private let windowStream: AsyncStream<(index: Int, start: TimeInterval, url: URL)>
    private let windowContinuation: AsyncStream<(index: Int, start: TimeInterval, url: URL)>.Continuation
    private var worker: Task<Void, Never>?

    /// Emitted on the main actor as each window comes back, in order.
    var onSegment: ((Segment) -> Void)?

    init(
        windowSeconds: Double = 30,
        overlapSeconds: Double = 2,
        transcribe: @escaping @Sendable (URL) async throws -> String
    ) {
        self.windowSeconds = windowSeconds
        self.overlapSeconds = overlapSeconds
        self.transcribe = transcribe
        let (stream, continuation) = AsyncStream.makeStream(of: (index: Int, start: TimeInterval, url: URL).self)
        self.windowStream = stream
        self.windowContinuation = continuation
    }

    deinit {
        windowContinuation.finish()
        worker?.cancel()
    }

    // MARK: - Lifecycle

    func start() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            // Serial on purpose: a local model is the common case and running several passes at
            // once would contend for the same compute and reorder the transcript.
            for await window in self.windowStream {
                if Task.isCancelled { break }
                await self.process(window)
            }
        }
    }

    /// Flushes whatever is left and waits for every outstanding window to come back.
    func finish() async {
        queue.sync { cutWindows(force: true) }
        windowContinuation.finish()
        await worker?.value
        worker = nil
    }

    func cancel() {
        windowContinuation.finish()
        worker?.cancel()
        worker = nil
    }

    // MARK: - Ingest

    /// Safe to call from a Core Audio thread: it only appends bytes behind a queue.
    func append(_ data: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pending.append(data)
            self.totalSamplesAppended += data.count / MemoryLayout<Int16>.size
            self.cutWindows(force: false)
        }
    }

    /// Drains every window the buffer can yield, not just one.
    ///
    /// Cutting a single window per delivery is only adequate while audio arrives in chunks
    /// smaller than a window. A larger delivery — a burst after a stall, or any change to the
    /// upstream buffer size — would leave the remainder queued, and the transcript would fall
    /// further behind the meeting the longer it ran.
    private func cutWindows(force: Bool) {
        while cutWindow(force: force) {}
    }

    @discardableResult
    private func cutWindow(force: Bool) -> Bool {
        let bytesPerSample = MemoryLayout<Int16>.size
        let windowBytes = Int(windowSeconds * sampleRate) * bytesPerSample
        let overlapBytes = Int(overlapSeconds * sampleRate) * bytesPerSample

        guard pending.count >= windowBytes || (force && !pending.isEmpty) else { return false }

        let takeBytes = min(pending.count, max(windowBytes, 0))
        let slice = pending.prefix(takeBytes)

        let samplesBefore = totalSamplesAppended - pending.count / bytesPerSample
        let start = Double(samplesBefore) / sampleRate

        guard let url = writeWindow(Data(slice), index: windowIndex) else {
            pending.removeFirst(takeBytes)
            return true
        }

        windowContinuation.yield((index: windowIndex, start: start, url: url))
        windowIndex += 1

        // Keep the overlap so the next window starts slightly before this one ended.
        let drop = force ? takeBytes : max(0, takeBytes - overlapBytes)
        pending.removeFirst(min(drop, pending.count))
        return true
    }

    private func writeWindow(_ samples: Data, index: Int) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zerm-meeting-window-\(index)-\(UUID().uuidString.prefix(6)).wav")
        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: format.settings,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
            let frames = AVAudioFrameCount(samples.count / MemoryLayout<Int16>.size)
            guard frames > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
                  let channel = buffer.int16ChannelData else { return nil }
            buffer.frameLength = frames
            samples.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                memcpy(channel[0], base, samples.count)
            }
            try file.write(from: buffer)
            return url
        } catch {
            logger.error("Could not stage a transcription window: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Transcription

    private func process(_ window: (index: Int, start: TimeInterval, url: URL)) async {
        defer { try? FileManager.default.removeItem(at: window.url) }

        do {
            let text = try await transcribe(window.url)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            let duration = Self.duration(of: window.url) ?? windowSeconds
            let segment = Segment(start: window.start, end: window.start + duration, text: trimmed)
            await MainActor.run { [weak self] in
                self?.onSegment?(segment)
            }
        } catch {
            // One bad window must not end the transcript; the meeting is still being recorded
            // and the audio is on disk either way.
            logger.error("Window \(window.index, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func duration(of url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        return Double(file.length) / file.fileFormat.sampleRate
    }
}
