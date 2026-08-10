import SwiftUI

/// Every past recording, as its own screen.
///
/// A full-width list rather than a second sidebar: the Recording tab already sits inside the app's
/// navigation sidebar, and nesting a split view inside it left both columns too narrow to read.
struct MeetingLibraryView: View {
    @EnvironmentObject private var controller: MeetingRecordingController
    @ObservedObject var store: MeetingRecordingStore
    let onOpen: (MeetingRecordingStore.Item) -> Void
    let onImport: () -> Void

    @State private var searchText = ""
    @State private var filteredItems: [MeetingRecordingStore.Item] = []
    @State private var pendingDeletion: MeetingRecordingStore.Item?
    @State private var processingItemID: String?
    @State private var processingError: String?

    private var searchRequest: SearchRequest {
        SearchRequest(query: searchText, itemIDs: store.items.map(\.id))
    }

    var body: some View {
        VStack(spacing: 0) {
            if !store.items.isEmpty {
                searchBar
                Divider()
            }

            if store.items.isEmpty {
                emptyLibrary
            } else if filteredItems.isEmpty {
                noMatches
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert(
            "Move this recording to the Trash?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
        ) {
            Button("Move to Trash", role: .destructive) {
                if let item = pendingDeletion { store.delete(item) }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("The audio, transcript and summary all go with it.")
        }
        .task(id: searchRequest) {
            do {
                try await Task.sleep(for: .milliseconds(180))
            } catch {
                return
            }
            updateSearchResults()
        }
        .alert(
            "Could Not Process Recording",
            isPresented: Binding(
                get: { processingError != nil },
                set: { if !$0 { processingError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { processingError = nil }
        } message: {
            Text(processingError ?? String(localized: "Unknown processing error"))
        }
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
                TextField("Search recordings and transcripts...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear meeting search")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.secondary.opacity(0.08)))
            .frame(maxWidth: .infinity)

            Text("meeting_recording_count \(store.items.count)")
                .font(.caption)
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(filteredItems) { item in
                    row(item)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
    }

    private func row(_ item: MeetingRecordingStore.Item) -> some View {
        HStack(spacing: 8) {
            Button {
                onOpen(item)
            } label: {
                HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                    Image(systemName: "waveform")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.accentColor)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    HStack(spacing: 10) {
                        Label(MeetingRecordingView.clock(item.duration), systemImage: "clock")
                        if item.speakerCount > 0 {
                            Label("\(item.speakerCount)", systemImage: "person.2.fill")
                        }
                        Text(ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file))
                        if item.wasInterrupted {
                            Label("recovered", systemImage: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                        }
                    }
                        .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()

                    if let transcript = item.transcript, !transcript.isEmpty {
                        Text(transcript)
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if item.summary != nil {
                    Label("Summary", systemImage: "sparkles")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.secondary.opacity(0.10)))
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
            }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .metricsCardSurface(cornerRadius: 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens this meeting for playback and review")

            if requiresProcessing(item) {
                Button {
                    process(item)
                } label: {
                    if processingItemID == item.id {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label(processTitle(item), systemImage: "waveform.badge.magnifyingglass")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!canProcess || processingItemID != nil)
                .accessibilityIdentifier("process-meeting-\(item.id)")
            }
        }
        .contextMenu {
            Button(processTitle(item)) {
                process(item)
            }
            .disabled(!canProcess || processingItemID != nil)

            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.folder])
            }
            Button("Move to Trash", role: .destructive) {
                pendingDeletion = item
            }
        }
    }

    // MARK: - Empty states

    private var emptyLibrary: some View {
        VStack(spacing: 16) {
            Spacer()
            CompactHeroSection(
                icon: "rectangle.stack",
                title: String(localized: "No recordings yet"),
                description: String(localized: "Meetings you record show up here with their audio, transcript and summary. You can also bring in audio you already have."),
                maxDescriptionWidth: 420
            )
            Button("Import Recordings…", action: onImport)
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMatches: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("No recording matches “\(searchText)”.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            Button("Clear search") { searchText = "" }
                .buttonStyle(.link)
                .font(.callout)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func updateSearchResults() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            filteredItems = store.items
            return
        }

        filteredItems = store.items.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || ($0.transcript?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var canProcess: Bool {
        switch controller.lifecycle.phase {
        case .idle, .ready, .partial, .failed:
            return true
        case .preflighting, .capturing, .stopping, .processing:
            return false
        }
    }

    private func requiresProcessing(_ item: MeetingRecordingStore.Item) -> Bool {
        item.transcript?.isEmpty != false || item.wasInterrupted || !item.issues.isEmpty
    }

    private func processTitle(_ item: MeetingRecordingStore.Item) -> LocalizedStringKey {
        item.transcript?.isEmpty == false ? "Retry Processing" : "Process"
    }

    private func process(_ item: MeetingRecordingStore.Item) {
        guard canProcess, processingItemID == nil else { return }
        processingItemID = item.id
        Task {
            await controller.process(item)
            processingError = controller.errorMessage
            store.reload()
            updateSearchResults()
            processingItemID = nil
        }
    }
}

private struct SearchRequest: Hashable {
    let query: String
    let itemIDs: [String]
}
