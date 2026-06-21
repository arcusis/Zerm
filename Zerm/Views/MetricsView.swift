import SwiftUI
import SwiftData
import Charts
import KeyboardShortcuts

struct MetricsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var hotkeyManager: HotkeyManager
    
    var body: some View {
        VStack {
            MetricsContent(
                modelContext: modelContext,
                licenseState: .licensed
            )
        }
        .background(Color(.controlBackgroundColor))
    }
}
