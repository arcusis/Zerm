import SwiftUI
import AVFoundation

/// Live mic level meter for onboarding / Audio Input settings ("Test my mic").
struct MicTestView: View {
    @StateObject private var deviceManager = AudioDeviceManager.shared
    @State private var isTesting = false
    @State private var level: Float = 0
    @State private var peak: Float = 0
    @State private var meterTask: Task<Void, Never>?
    @State private var testRecorder: CoreAudioRecorder?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Test Microphone")
                Spacer()
                Button {
                    if isTesting {
                        stopTest()
                    } else {
                        startTest()
                    }
                } label: {
                    Text(isTesting ? LocalizedStringKey("Stop") : LocalizedStringKey("Test my mic"))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.15))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(levelColor)
                        .frame(width: max(4, geo.size.width * CGFloat(level)))
                }
            }
            .frame(height: 10)

            if isTesting {
                Text(String.localizedStringWithFormat(
                    String(localized: "Level %.0f dB  ·  Peak %.0f dB"),
                    levelDb,
                    peakDb
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Speak while testing to confirm your mic is picking up audio.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear { stopTest() }
    }

    private var levelDb: Float { level * -1 * 0 + (level > 0 ? (level * 60 - 60) : -60) }
    private var peakDb: Float { peak * 60 - 60 }

    private var levelColor: Color {
        if level > 0.7 { return .green }
        if level > 0.3 { return .accentColor }
        return .orange
    }

    private func startTest() {
        stopTest()
        isTesting = true
        let deviceID = deviceManager.getCurrentDevice()
        guard deviceID != 0 else {
            NotificationManager.shared.showNotification(
                title: String(localized: "No microphone selected"),
                type: .error
            )
            isTesting = false
            return
        }

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("zerm-mic-test.wav")
        let recorder = CoreAudioRecorder()
        do {
            try recorder.startRecording(toOutputFile: temp, deviceID: deviceID)
            testRecorder = recorder
            meterTask = Task { @MainActor in
                while !Task.isCancelled, isTesting {
                    let avg = recorder.averagePower
                    let pk = recorder.peakPower
                    // Map dB (-60…0) to 0…1
                    level = max(0, min(1, (avg + 60) / 60))
                    peak = max(0, min(1, (pk + 60) / 60))
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
        } catch {
            isTesting = false
            NotificationManager.shared.showNotification(
                title: String.localizedStringWithFormat(
                    String(localized: "Mic test failed: %@"),
                    error.localizedDescription
                ),
                type: .error
            )
        }
    }

    private func stopTest() {
        meterTask?.cancel()
        meterTask = nil
        testRecorder?.stopRecording()
        testRecorder = nil
        isTesting = false
        level = 0
        peak = 0
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("zerm-mic-test.wav")
        try? FileManager.default.removeItem(at: temp)
    }
}
