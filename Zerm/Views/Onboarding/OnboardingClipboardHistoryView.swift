import KeyboardShortcuts
import SwiftUI

struct OnboardingClipboardHistoryView: View {
    @Binding var hasCompletedOnboarding: Bool
    @AppStorage(ClipboardHistorySettings.Keys.enabled) private var isEnabled = true
    @State private var showTutorial = false

    var body: some View {
        ZStack {
            if showTutorial {
                OnboardingTutorialView(hasCompletedOnboarding: $hasCompletedOnboarding)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                OnboardingBackgroundView()
                VStack(spacing: 28) {
                    Image(systemName: "clipboard")
                        .font(.system(size: 54))
                        .foregroundStyle(Color.accentColor)
                    Text("Clipboard History")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                    Text("Keep copied items on this Mac, then find and paste them when needed.")
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                    Toggle("Enable Clipboard History", isOn: $isEnabled)
                        .toggleStyle(.switch)
                        .frame(maxWidth: 300)
                    HStack(spacing: 10) {
                        Text("Open history")
                        KeyboardShortcuts.Recorder(for: .openClipboardHistory)
                    }
                    .foregroundStyle(.white.opacity(0.8))
                    Button("Continue") { withAnimation { showTutorial = true } }
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(width: 200, height: 50)
                        .background(Color.accentColor)
                        .clipShape(Capsule())
                        .buttonStyle(ScaleButtonStyle())
                }
                .padding(32)
            }
        }
    }
}
