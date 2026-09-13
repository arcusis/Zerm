import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

enum ModelFilter: CaseIterable, Identifiable {
    case recommended
    case local
    case cloud
    case custom

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .recommended: return "Recommended"
        case .local: return "Local"
        case .cloud: return "Cloud"
        case .custom: return "Custom"
        }
    }
}

enum LocalModelFilter: CaseIterable, Identifiable {
    case all
    case englishOnly
    case multilingual
    case hebrew

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .all: return "All"
        case .englishOnly: return "English only"
        case .multilingual: return "Multilingual"
        case .hebrew: return "Great in Hebrew"
        }
    }
}

struct ModelManagementView: View {
    @EnvironmentObject private var whisperModelManager: WhisperModelManager
    @EnvironmentObject private var fluidAudioModelManager: FluidAudioModelManager
    @EnvironmentObject private var transcriptionModelManager: TranscriptionModelManager
    @State private var customModelToEdit: CustomCloudModel?
    @StateObject private var aiService = AIService()
    @StateObject private var customModelManager = CustomCloudModelManager.shared
    @EnvironmentObject private var enhancementService: AIEnhancementService
    @Environment(\.modelContext) private var modelContext
    @StateObject private var whisperPrompt = WhisperPrompt()
    @ObservedObject private var warmupCoordinator = WhisperModelWarmupCoordinator.shared

    @State private var selectedFilter: ModelFilter = .recommended
    @State private var selectedLocalFilter: LocalModelFilter = .all
    /// `nil` shows every cloud provider.
    @State private var selectedCloudProvider: ModelProvider?
    @State private var isShowingSettings = false
    @State private var appleSpeechSupportsHebrew = AppleSpeechLanguageSupport.supportsHebrew
    @State private var replacementNotice = UserDefaults.standard.dictionary(
        forKey: RetiredLocalTranscriptionModelMigration.replacementNoticeKey
    ) as? [String: String]

    private let settingsPanelWidth: CGFloat = 400

    // State for the unified alert
    @State private var isShowingDeleteAlert = false
    @State private var alertTitle: LocalizedStringKey = ""
    @State private var alertMessage: LocalizedStringKey = ""
    @State private var deleteActionClosure: () -> Void = {}

    private func closeSettings() {
        withAnimation(.smooth(duration: 0.3)) {
            isShowingSettings = false
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if SystemArchitecture.isIntelMac {
                    intelMacWarningBanner
                } else if HardwareCapability.tier == .limited {
                    limitedMemoryBanner
                }

                if let replacementNotice {
                    replacementNoticeBanner(replacementNotice)
                }

                defaultModelSection
                languageSelectionSection
                availableModelsSection
            }
            .padding(40)
        }
        .frame(minWidth: 600, minHeight: 500)
        .background(Color(NSColor.controlBackgroundColor))
        .slidingPanel(isPresented: $isShowingSettings, width: settingsPanelWidth) {
            settingsPanelContent
        }
        .alert(isPresented: $isShowingDeleteAlert) {
            Alert(
                title: Text(alertTitle),
                message: Text(alertMessage),
                primaryButton: .destructive(Text("Delete"), action: deleteActionClosure),
                secondaryButton: .cancel()
            )
        }
        .task {
            appleSpeechSupportsHebrew = await AppleSpeechLanguageSupport.refresh()
        }
    }

    private var settingsPanelContent: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Text("Model Settings")
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)

                Spacer()

                Button(action: { closeSettings() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(6)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(Color(NSColor.windowBackgroundColor))
            .overlay(
                Divider().opacity(0.5), alignment: .bottom
            )

            // Content
            ModelSettingsView(whisperPrompt: whisperPrompt)
        }
    }

    // MARK: - Default model

    private var defaultModelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text("Default Model")
                    .font(.headline)
                    .foregroundColor(.secondary)
                InfoTip(
                    String(localized: "The model that transcribes your speech unless a Power Mode says otherwise. Choose a different one with Set as Default on any card below."),
                    doc: .models
                )
            }
            if let current = transcriptionModelManager.currentTranscriptionModel {
                Text(verbatim: current.displayName)
                    .font(.title2)
                    .fontWeight(.bold)
                if isDownloadRequired(current) {
                    downloadRequiredRow(for: current)
                }
            } else {
                Text("No model selected")
                    .font(.title2)
                    .fontWeight(.bold)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground(isSelected: false))
        .cornerRadius(10)
    }

    /// A selected local model whose files are missing (never downloaded, replaced by a migration,
    /// or deleted from disk) fails every dictation, so it is called out here.
    private func isDownloadRequired(_ model: any TranscriptionModel) -> Bool {
        switch model.provider {
        case .whisper:
            return !whisperModelManager.availableModels.contains { $0.name == model.name }
        case .fluidAudio:
            return !fluidAudioModelManager.isFluidAudioModelDownloaded(named: model.name)
        default:
            return false
        }
    }

    private func isDownloading(_ model: any TranscriptionModel) -> Bool {
        if let fluidAudioModel = model as? FluidAudioModel {
            return fluidAudioModelManager.isFluidAudioModelDownloading(fluidAudioModel)
        }
        return whisperModelManager.downloadProgress[model.name + "_main"] != nil
            || whisperModelManager.downloadProgress[model.name + "_coreml"] != nil
    }

    private func downloadRequiredRow(for model: any TranscriptionModel) -> some View {
        HStack(spacing: 10) {
            Label("Download required — this model is not on this Mac yet, so dictation won't work until it is downloaded.", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            Button(action: { download(model) }) {
                Text(isDownloading(model) ? "Downloading..." : "Download")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isDownloading(model))
        }
    }

    private func download(_ model: any TranscriptionModel) {
        if let whisperModel = model as? WhisperModel {
            Task { await whisperModelManager.downloadModel(whisperModel) }
        } else if let fluidAudioModel = model as? FluidAudioModel {
            Task { await fluidAudioModelManager.downloadFluidAudioModel(fluidAudioModel) }
        }
    }

    private func replacementNoticeBanner(_ notice: [String: String]) -> some View {
        let retired = RetiredLocalTranscriptionModelMigration.retiredDisplayNames[
            notice[RetiredLocalTranscriptionModelMigration.noticeRetiredNameKey] ?? ""
        ] ?? notice[RetiredLocalTranscriptionModelMigration.noticeRetiredNameKey] ?? ""
        let replacementName = notice[RetiredLocalTranscriptionModelMigration.noticeReplacementNameKey]
        let replacement = transcriptionModelManager.allAvailableModels
            .first { $0.name == replacementName }?.displayName ?? replacementName ?? ""

        return HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.accentColor)

            Text("\(retired) is no longer offered, so your default model is now \(replacement).")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            Button(action: {
                UserDefaults.standard.removeObject(forKey: RetiredLocalTranscriptionModelMigration.replacementNoticeKey)
                withAnimation(.smooth(duration: 0.3)) {
                    replacementNotice = nil
                }
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.08))
        .cornerRadius(8)
    }

    private var languageSelectionSection: some View {
        LanguageSelectionView(transcriptionModelManager: transcriptionModelManager, displayMode: .full, whisperPrompt: whisperPrompt)
    }

    // MARK: - Model lists

    private var availableModelsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                // Modern compact pill switcher
                HStack(spacing: 12) {
                    ForEach(ModelFilter.allCases) { filter in
                        Button(action: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                selectedFilter = filter
                                isShowingSettings = false
                            }
                        }) {
                            Text(filter.title)
                                .font(.system(size: 14, weight: selectedFilter == filter ? .semibold : .medium))
                                .foregroundColor(selectedFilter == filter ? .primary : .primary.opacity(0.7))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(
                                    CardBackground(isSelected: selectedFilter == filter, cornerRadius: 22)
                                )
                        }
                        .buttonStyle(PlainButtonStyle())
                    }

                    InfoTip(
                        String(localized: "Recommended picks the best English, multilingual and Hebrew models this Mac runs comfortably. Local models run on this Mac with no network and no per-word cost. Cloud models are usually more accurate but send your audio to a provider and need an API key. Custom is for your own OpenAI-compatible endpoint."),
                        doc: .models
                    )
                }

                Spacer()

                Button(action: {
                    withAnimation(.smooth(duration: 0.3)) {
                        isShowingSettings.toggle()
                    }
                }) {
                    // A bare gear glyph gave no clue what it opened; the label does.
                    HStack(spacing: 5) {
                        Image(systemName: "gear")
                        Text("Settings")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isShowingSettings ? .accentColor : .primary.opacity(0.7))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        CardBackground(isSelected: isShowingSettings, cornerRadius: 22)
                    )
                }
                .buttonStyle(PlainButtonStyle())
                .help("Output format, formatting, VAD and filler words")
                .accessibilityLabel("Model settings")
            }
            .padding(.bottom, 12)

            switch selectedFilter {
            case .recommended:
                recommendedList
            case .local:
                localFilterChips
                modelCards(localModels)
                importLocalModelCard
            case .cloud:
                cloudProviderChips
                modelCards(filteredCloudModels)
            case .custom:
                modelCards(transcriptionModelManager.allAvailableModels.filter { $0.provider == .custom })
                customModelSection
            }
        }
        .padding()
    }

    private func modelCards(_ models: [any TranscriptionModel]) -> some View {
        VStack(spacing: 12) {
            ForEach(models, id: \.id) { model in
                modelCard(model)
            }
        }
    }

    private func modelCard(_ model: any TranscriptionModel) -> some View {
        let isWarming = (model as? WhisperModel).map { whisperModel in
            warmupCoordinator.isWarming(modelNamed: whisperModel.name)
        } ?? false

        return ModelCardView(
            model: model,
            fluidAudioModelManager: fluidAudioModelManager,
            transcriptionModelManager: transcriptionModelManager,
            isDownloaded: whisperModelManager.availableModels.contains { $0.name == model.name },
            isCurrent: transcriptionModelManager.currentTranscriptionModel?.name == model.name,
            downloadProgress: whisperModelManager.downloadProgress,
            modelURL: whisperModelManager.availableModels.first { $0.name == model.name }?.url,
            isWarming: isWarming,
            downloadError: whisperModelManager.downloadErrors[model.name],
            deleteAction: {
                if let customModel = model as? CustomCloudModel {
                    alertTitle = "Delete Custom Model"
                    alertMessage = "Are you sure you want to delete the custom model '\(customModel.displayName)'?"
                    deleteActionClosure = {
                        customModelManager.removeCustomModel(withId: customModel.id)
                        transcriptionModelManager.refreshAllAvailableModels()
                    }
                    isShowingDeleteAlert = true
                } else if let downloadedModel = whisperModelManager.availableModels.first(where: { $0.name == model.name }) {
                    alertTitle = "Delete Model"
                    alertMessage = "Are you sure you want to delete the model '\(downloadedModel.name)'?"
                    deleteActionClosure = {
                        Task {
                            await whisperModelManager.deleteModel(downloadedModel)
                        }
                    }
                    isShowingDeleteAlert = true
                }
            },
            setDefaultAction: {
                Task {
                    transcriptionModelManager.setDefaultTranscriptionModel(model)
                }
            },
            downloadAction: {
                if let whisperModel = model as? WhisperModel {
                    Task { await whisperModelManager.downloadModel(whisperModel) }
                }
            },
            editAction: model.provider == .custom ? { customModel in
                customModelToEdit = customModel
            } : nil
        )
    }

    // MARK: Recommended

    private var recommendedList: some View {
        let models = transcriptionModelManager.allAvailableModels
        let cloudPicks = cloudModels.filter { model in
            model.isRecommended && transcriptionModelManager.usableModels.contains { $0.name == model.name }
        }

        return VStack(alignment: .leading, spacing: 20) {
            Text("Picked for this Mac: \(HardwareCapability.summary)")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            ForEach(HardwareCapability.RecommendationNeed.allCases, id: \.self) { need in
                if let model = HardwareCapability.recommendedLocalModel(for: need, among: models) {
                    recommendationGroup(title(for: need)) {
                        modelCard(model)
                    }
                }
            }

            if !cloudPicks.isEmpty {
                recommendationGroup("Cloud") {
                    modelCards(cloudPicks)
                }
            }
        }
    }

    private func title(for need: HardwareCapability.RecommendationNeed) -> LocalizedStringKey {
        switch need {
        case .english: return "Best for English"
        case .multilingual: return "Best for many languages"
        case .hebrew: return "Best for Hebrew"
        }
    }

    private func recommendationGroup<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
            content()
        }
    }

    // MARK: Local

    private var localModels: [any TranscriptionModel] {
        transcriptionModelManager.allAvailableModels.filter { model in
            guard model.provider == .whisper || model.provider == .nativeApple || model.provider == .fluidAudio else {
                return false
            }
            switch selectedLocalFilter {
            case .all: return true
            case .englishOnly: return model.languageGroup == .englishOnly
            case .multilingual: return model.languageGroup == .multilingual
            case .hebrew: return isGreatInHebrew(model)
            }
        }
    }

    /// Apple Speech joins the Hebrew list only when this Mac's Speech framework reports Hebrew.
    private func isGreatInHebrew(_ model: any TranscriptionModel) -> Bool {
        model.isHebrewOptimized || (model.provider == .nativeApple && appleSpeechSupportsHebrew)
    }

    private var localFilterChips: some View {
        HStack(spacing: 8) {
            ForEach(LocalModelFilter.allCases) { filter in
                filterChip(filter.title, isSelected: selectedLocalFilter == filter) {
                    selectedLocalFilter = filter
                }
            }
        }
    }

    private var importLocalModelCard: some View {
        HStack(spacing: 8) {
            Button(action: { presentImportPanel() }) {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down")
                    Text("Import Local Model…")
                        .font(.system(size: 12, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(16)
                .background(CardBackground(isSelected: false))
                .cornerRadius(10)
            }
            .buttonStyle(.plain)

            InfoTip(
                String(localized: "Add a custom fine-tuned whisper model to use with Zerm. Select the downloaded .bin file."),
                learnMoreURL: Links.docString(.customLocalWhisperModels)
            )
            .help("Read more about custom local models")
        }
    }

    // MARK: Cloud

    private var cloudModels: [any TranscriptionModel] {
        transcriptionModelManager.allAvailableModels.filter { CloudProviderRegistry.provider(for: $0.provider) != nil }
    }

    private var filteredCloudModels: [any TranscriptionModel] {
        guard let selectedCloudProvider else { return cloudModels }
        return cloudModels.filter { $0.provider == selectedCloudProvider }
    }

    private var cloudProviderChips: some View {
        let providers = CloudProviderRegistry.allProviders.map(\.modelProvider)

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip("All providers", isSelected: selectedCloudProvider == nil) {
                    selectedCloudProvider = nil
                }
                ForEach(providers, id: \.self) { provider in
                    filterChip(verbatim: provider.rawValue, isSelected: selectedCloudProvider == provider) {
                        selectedCloudProvider = provider
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: Custom

    private var customModelSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                Text("Only OpenAI-compatible transcription APIs are supported.")
                    .font(.system(size: 12))
            }
            .foregroundColor(.secondary)
            .padding(.bottom, 4)

            AddCustomModelCardView(
                customModelManager: customModelManager,
                onModelAdded: {
                    // Refresh the models when a new custom model is added
                    transcriptionModelManager.refreshAllAvailableModels()
                    customModelToEdit = nil // Clear editing state
                },
                editingModel: customModelToEdit
            )
        }
    }

    // MARK: - Filter chips

    private func filterChip(_ title: LocalizedStringKey, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { action() } }) {
            chipLabel(Text(title), isSelected: isSelected)
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func filterChip(verbatim title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { action() } }) {
            chipLabel(Text(verbatim: title), isSelected: isSelected)
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func chipLabel(_ text: Text, isSelected: Bool) -> some View {
        text
            .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
            .foregroundColor(isSelected ? .primary : .primary.opacity(0.7))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(CardBackground(isSelected: isSelected, cornerRadius: 16))
    }

    // MARK: - Banners

    private var intelMacWarningBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.orange)

            Text("Local models don't work reliably on Intel Macs")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary.opacity(0.85))

            Spacer()

            Button(action: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    selectedFilter = .cloud
                }
            }) {
                HStack(spacing: 4) {
                    Text("Use Cloud")
                        .font(.system(size: 12, weight: .semibold))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundColor(.orange)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.12))
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.08))
        .cornerRadius(8)
    }

    private var limitedMemoryBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "memorychip")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.orange)

            Text("\(HardwareCapability.summary) — recommendations are tuned for this Mac; models that need more memory are marked or unavailable")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary.opacity(0.85))

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.08))
        .cornerRadius(8)
    }

    // MARK: - Import Panel
    private func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "bin")!]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.resolvesAliases = true
        panel.title = String(localized: "Select a Whisper ggml .bin model")
        if panel.runModal() == .OK, let url = panel.url {
            Task { @MainActor in
                await whisperModelManager.importWhisperModel(from: url)
            }
        }
    }
}
