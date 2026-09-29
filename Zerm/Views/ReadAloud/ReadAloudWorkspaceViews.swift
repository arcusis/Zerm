import AppKit
import SwiftUI

struct ReadAloudSpeakView: View {
    @EnvironmentObject private var controller: TTSController
    @ObservedObject private var localLLM = LocalLLMModelManager.shared
    @AppStorage(TTSSettings.Keys.readingMode) private var modeRaw = ReadAloudMode.exact.rawValue

    private var mode: ReadAloudMode {
        ReadAloudMode(rawValue: modeRaw) ?? .exact
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
                                Text(verbatim: mode.title).tag(mode.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("read-aloud-mode-picker")

                        Text(verbatim: mode.subtitle)
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
                        Text(verbatim: prepared)
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
    @ObservedObject private var store: ReadAloudHistoryStore
    @State private var searchText = ""
    @State private var sortOrder: HistorySortOrder = .newestFirst
    @State private var selectedMode: ReadAloudMode?
    @State private var itemToDelete: ReadAloudHistoryItem?
    @State private var showClearConfirmation = false

    init(store: ReadAloudHistoryStore = .shared) {
        _store = ObservedObject(wrappedValue: store)
    }

    private var filteredItems: [ReadAloudHistoryItem] {
        ReadAloudHistoryPresentation.visibleItems(
            from: store.items,
            query: searchText,
            mode: selectedMode,
            sortOrder: sortOrder
        )
    }

    private var hasActiveHistoryFilters: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedMode != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Read Aloud History")
                    .font(.title2.bold())
                Spacer()
                Text("history_result_count \(filteredItems.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Menu {
                    Picker("Sort by", selection: $sortOrder) {
                        ForEach(HistorySortOrder.allCases) { order in
                            Text(order.title).tag(order)
                        }
                    }

                    Menu("Filter by Mode") {
                        Button("All Modes") { selectedMode = nil }
                        ForEach(ReadAloudMode.allCases) { mode in
                            Button {
                                selectedMode = mode
                            } label: {
                                if selectedMode == mode {
                                    Label(mode.title, systemImage: "checkmark")
                                } else {
                                    Text(verbatim: mode.title)
                                }
                            }
                        }
                    }

                    if !store.items.isEmpty {
                        Divider()
                        Button("Clear History", role: .destructive) {
                            showClearConfirmation = true
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 16))
                }
                .menuStyle(.borderlessButton)
                .help("Sort, Filter, or Clear History")
                .accessibilityLabel("Sort, Filter, or Clear History")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            HStack(spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search source or spoken text", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(10)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

                if selectedMode != nil {
                    Button {
                        selectedMode = nil
                    } label: {
                        Label("Filter", systemImage: "line.3.horizontal.decrease.circle.fill")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .help("Clear mode filter")
                    .accessibilityLabel("Clear mode filter")
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)

            if filteredItems.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "speaker.wave.2")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text(hasActiveHistoryFilters ? "No Results" : "No Read Aloud History")
                        .font(.headline)
                    Text(hasActiveHistoryFilters
                        ? "Try another search term."
                        : "Completed readings will appear here with the original and prepared text.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if hasActiveHistoryFilters {
                        Button("Clear Filters") {
                            searchText = ""
                            selectedMode = nil
                        }
                        .buttonStyle(.link)
                    } else {
                        Button("Go to Speak") {
                            NotificationCenter.default.post(
                                name: .navigateToDestination,
                                object: nil,
                                userInfo: ["route": AppRoute.readAloudSpeak]
                            )
                        }
                        .buttonStyle(.link)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredItems) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Label(item.mode.title, systemImage: "speaker.wave.2")
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                Text(item.createdAt, format: .dateTime.month().day().hour().minute())
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text(verbatim: item.spokenText)
                                .lineLimit(2)
                                .font(.system(size: 13, weight: .medium))
                                .textSelection(.enabled)
                            Text("Source: \(item.sourceText)")
                                .lineLimit(1)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 5) {
                                Text(verbatim: item.providerName)
                                Text(verbatim: "•")
                                Text(verbatim: item.voiceName)
                                if let model = item.localModelName {
                                    Text(verbatim: "•")
                                    Text(verbatim: model)
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
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.plain)
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .confirmationDialog(
            "Clear all Read Aloud history?",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) { store.clear() }
            Button("Cancel", role: .cancel) {}
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
