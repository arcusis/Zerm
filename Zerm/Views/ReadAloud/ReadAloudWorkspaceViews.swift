import AppKit
import SwiftUI

struct ReadAloudSpeakView: View {
    @EnvironmentObject private var controller: TTSController
    @ObservedObject private var localLLM = LocalLLMModelManager.shared
    @AppStorage(TTSSettings.Keys.readingMode) private var modeRaw = ReadAloudMode.retell.rawValue

    private var mode: ReadAloudMode {
        ReadAloudMode(rawValue: modeRaw) ?? .retell
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Speak Selected Content")
                        .font(.largeTitle.bold())
                    Text("Select text in any application. Zerm analyzes the complete selection, prepares the version you requested, and then reads it aloud.")
                        .foregroundStyle(.secondary)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        Picker("Reading mode", selection: $modeRaw) {
                            ForEach(ReadAloudMode.allCases) { mode in
                                Text(mode.title).tag(mode.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("read-aloud-mode-picker")

                        Text(mode.subtitle)
                            .foregroundStyle(.secondary)

                        if mode.usesLocalAI {
                            LabeledContent("Local AI model", value: localLLM.currentPackage.displayName)
                            if !localLLM.isInstalled {
                                Label(
                                    String.localizedStringWithFormat(
                                        String(localized: "Download this model in Models & Voices before using %@."),
                                        mode.title
                                    ),
                                    systemImage: "exclamationmark.triangle.fill"
                                )
                                .foregroundStyle(.orange)
                            }
                        }

                        Button {
                            controller.toggle()
                        } label: {
                            Label(
                                controller.isSpeaking ? "Stop Read Aloud" : "Read Selected Text",
                                systemImage: controller.isSpeaking ? "stop.fill" : "speaker.wave.2.fill"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(mode.usesLocalAI && !localLLM.isInstalled && !controller.isSpeaking)
                        .accessibilityIdentifier("read-aloud-primary-action")
                    }
                    .padding(8)
                }

                if let prepared = controller.lastPreparedText, !prepared.isEmpty {
                    GroupBox("Last Prepared Version") {
                        Text(prepared)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
        }
    }
}

struct ReadAloudHistoryView: View {
    @ObservedObject private var store = ReadAloudHistoryStore.shared
    @State private var searchText = ""
    @State private var itemToDelete: ReadAloudHistoryItem?

    private var filteredItems: [ReadAloudHistoryItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.items }
        return store.items.filter {
            $0.sourceText.localizedCaseInsensitiveContains(query)
                || $0.spokenText.localizedCaseInsensitiveContains(query)
                || $0.mode.title.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Read Aloud History")
                    .font(.largeTitle.bold())
                Spacer()
                if !store.items.isEmpty {
                    Button("Clear History", role: .destructive) { store.clear() }
                }
            }
            .padding(24)

            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search source or spoken text", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 24)
            .padding(.bottom, 16)

            if filteredItems.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "No Read Aloud History" : "No Results",
                    systemImage: "speaker.wave.2",
                    description: Text(searchText.isEmpty
                        ? "Completed readings will appear here with the original and prepared text."
                        : "Try another search term.")
                )
            } else {
                List(filteredItems) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label(item.mode.title, systemImage: "speaker.wave.2")
                                .font(.headline)
                            Spacer()
                            Text(item.createdAt, format: .dateTime.month().day().hour().minute())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(item.spokenText)
                            .lineLimit(4)
                            .textSelection(.enabled)
                        HStack {
                            Text(item.providerName)
                            Text("•")
                            Text(item.voiceName)
                            if let model = item.localModelName {
                                Text("•")
                                Text(model)
                            }
                            Spacer()
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(item.spokenText, forType: .string)
                            }
                            Button(role: .destructive) { itemToDelete = item } label: {
                                Image(systemName: "trash")
                            }
                            .accessibilityLabel("Delete history item")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .confirmationDialog(
            "Delete this Read Aloud history item?",
            isPresented: Binding(
                get: { itemToDelete != nil },
                set: { if !$0 { itemToDelete = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let itemToDelete { store.delete(itemToDelete) }
                itemToDelete = nil
            }
            Button("Cancel", role: .cancel) { itemToDelete = nil }
        }
    }
}
