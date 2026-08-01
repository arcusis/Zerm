import SwiftUI

/// Every past recording, as its own screen.
///
/// A full-width list rather than a second sidebar: the Recording tab already sits inside the app's
/// navigation sidebar, and nesting a split view inside it left both columns too narrow to read.
struct MeetingLibraryView: View {
    @ObservedObject var store: MeetingRecordingStore
    let onOpen: (MeetingRecordingStore.Item) -> Void
    let onImport: () -> Void

    @State private var searchText = ""
    @State private var pendingDeletion: MeetingRecordingStore.Item?

    private var filtered: [MeetingRecordingStore.Item] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return store.items }
        return store.items.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || ($0.transcript?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !store.items.isEmpty {
                searchBar
                Divider()
            }

            if store.items.isEmpty {
                emptyLibrary
            } else if filtered.isEmpty {
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
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.secondary.opacity(0.08)))
            .frame(maxWidth: .infinity)

            Text("\(store.items.count) recording\(store.items.count == 1 ? "" : "s")")
                .font(.system(size: 11))
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
                ForEach(filtered) { item in
                    row(item)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
    }

    private func row(_ item: MeetingRecordingStore.Item) -> some View {
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
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .monospacedDigit()

                    if let transcript = item.transcript, !transcript.isEmpty {
                        Text(transcript)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if item.summary != nil {
                    Label("Summary", systemImage: "sparkles")
                        .font(.system(size: 10, weight: .medium))
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
        .contextMenu {
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
                title: "No recordings yet",
                description: "Meetings you record show up here with their audio, transcript and summary. You can also bring in audio you already have.",
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
                .font(.system(size: 12))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
