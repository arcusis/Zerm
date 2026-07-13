import SwiftUI

/// Compact update status card pinned to the bottom of the main sidebar.
struct SidebarUpdateBanner: View {
    @ObservedObject var updater: UpdaterViewModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if updater.updateAvailable {
                availableCard
            } else if let error = updater.lastErrorMessage, !error.isEmpty {
                errorCard(error)
            } else if updater.isChecking {
                checkingCard
            } else {
                idleFooter
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .padding(.top, 4)
    }

    // MARK: - States

    private var availableCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Update available")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(versionLine)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                }

                Spacer(minLength: 0)

                Button {
                    updater.dismissUpdateBanner()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(5)
                        .background(Circle().fill(.white.opacity(0.18)))
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }

            Button {
                updater.installPendingUpdate()
            } label: {
                Text("Install update")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.95))
                    )
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.accentColor, Color.accentColor.opacity(0.82)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
        )
        .shadow(color: Color.accentColor.opacity(0.25), radius: 8, y: 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Update available: \(versionLine)")
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Update check failed")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
            }
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(3)

            Button("Try again") {
                updater.checkForUpdates()
            }
            .font(.system(size: 12, weight: .medium))
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!updater.canCheckForUpdates)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground(tint: Color.orange.opacity(0.12)))
    }

    private var checkingCard: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(updater.statusText ?? "Checking for updates…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(cardBackground(tint: Color.primary.opacity(0.04)))
    }

    private var idleFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("v\(updater.currentVersion)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if let status = updater.statusText {
                    Text(status)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                updater.checkForUpdates()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Check for Updates")
                        .font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(!updater.canCheckForUpdates && !updater.isChecking)
            .opacity(updater.canCheckForUpdates || updater.isChecking ? 1 : 0.5)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    // MARK: - Helpers

    private var versionLine: String {
        let next = updater.availableVersion ?? "?"
        return "\(updater.currentVersion) → \(next)"
    }

    private func cardBackground(tint: Color) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(tint)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08), lineWidth: 0.5)
            )
    }
}
