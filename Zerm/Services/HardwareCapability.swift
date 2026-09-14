import Foundation

/// Rates this Mac's ability to run local models and judges whether a given model
/// is a good fit, a stretch, or too heavy to install at all.
enum HardwareCapability {

    enum Tier {
        /// Intel Macs and Apple Silicon with 8 GB RAM.
        case limited
        /// Apple Silicon with 16 GB RAM.
        case capable
        /// Apple Silicon with 24 GB RAM or more.
        case powerful
    }

    static let physicalMemoryGB: Double =
        Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824

    static let chipName: String = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var chars = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &chars, &size, nil, 0)
        let name = String(cString: chars)
        return name.isEmpty ? SystemArchitecture.current : name
    }()

    /// What recommendations are derived from. Deliberately no chip names: RAM and architecture
    /// describe every generation, including ones released after this build.
    struct Profile: Equatable {
        let isAppleSilicon: Bool
        let physicalMemoryGB: Double
        /// macOS 26 or later, where Apple Speech (SpeechAnalyzer) exists.
        let hasAppleSpeech: Bool

        static let current: Profile = {
            let hasAppleSpeech: Bool
            if #available(macOS 26, *) { hasAppleSpeech = true } else { hasAppleSpeech = false }
            return Profile(
                isAppleSilicon: SystemArchitecture.isAppleSilicon,
                physicalMemoryGB: HardwareCapability.physicalMemoryGB,
                hasAppleSpeech: hasAppleSpeech
            )
        }()
    }

    static let tier: Tier = tier(for: .current)

    static func tier(for profile: Profile) -> Tier {
        guard profile.isAppleSilicon else { return .limited }
        switch profile.physicalMemoryGB {
        case ..<12: return .limited
        case ..<24: return .capable
        default: return .powerful
        }
    }

    /// Human-readable summary, e.g. "Apple M1 · 8 GB RAM".
    static var summary: String {
        String(localized: "\(chipName) · \(Int(physicalMemoryGB.rounded())) GB RAM")
    }

    /// Performance cores on Apple Silicon (`hw.perflevel0.physicalcpu`); physical cores
    /// elsewhere. Spilling inference threads onto efficiency cores or hyperthreads slows
    /// the P-core work down and costs battery.
    static let performanceCoreCount: Int = {
        for key in ["hw.perflevel0.physicalcpu", "hw.physicalcpu"] {
            var count: Int32 = 0
            var size = MemoryLayout<Int32>.size
            if sysctlbyname(key, &count, &size, nil, 0) == 0, count > 0 {
                return Int(count)
            }
        }
        return ProcessInfo.processInfo.processorCount
    }()

    /// Thread count for CPU-side inference: stay on the performance cores, and back off
    /// to half when macOS reports thermal pressure or Low Power Mode.
    static var inferenceThreadCount: Int {
        let base = max(1, min(8, performanceCoreCount))
        let process = ProcessInfo.processInfo
        if process.isLowPowerModeEnabled || process.thermalState == .serious || process.thermalState == .critical {
            return max(1, base / 2)
        }
        return base
    }

    // MARK: - Per-model fit

    enum ModelFit {
        /// Runs comfortably on this Mac.
        case good
        /// Will run, but may be slow and starve other apps of memory — warn before install.
        case heavy(reason: String)
        /// Needs more memory than this Mac can spare — installation is blocked.
        case tooHeavy(reason: String)

        var blocksInstall: Bool {
            if case .tooHeavy = self { return true }
            return false
        }
    }

    /// Judges a model by the peak RAM it needs while running, against the memory this
    /// Mac can realistically spare (the OS and other apps need the rest).
    static func fit(forEstimatedRAMGB needed: Double) -> ModelFit {
        fit(forEstimatedRAMGB: needed, physicalMemoryGB: physicalMemoryGB)
    }

    /// Testable core: thresholds are fractions of installed RAM.
    static func fit(forEstimatedRAMGB needed: Double, physicalMemoryGB total: Double) -> ModelFit {
        let neededText = String(format: "%.1f", needed)
        if needed > total * 0.70 {
            return .tooHeavy(reason: String(localized: "Needs ~\(neededText) GB of memory — more than this Mac (\(Int(total.rounded())) GB) can spare while macOS is running."))
        }
        if needed > total * 0.45 {
            return .heavy(reason: String(localized: "Needs ~\(neededText) GB of memory — will run, but expect slowdowns on this Mac (\(Int(total.rounded())) GB)."))
        }
        return .good
    }

    // MARK: - Transcription recommendations

    enum RecommendationNeed: CaseIterable {
        case english
        case multilingual
        case hebrew
    }

    static func canRun(_ model: any LocalTranscriptionModel, on profile: Profile) -> Bool {
        switch model.runtime {
        case .whisperCpp: return true
        case .fluidAudio: return profile.isAppleSilicon
        case .appleSpeech: return profile.isAppleSilicon && profile.hasAppleSpeech
        }
    }

    /// Memory a recommended speech model may take without crowding the on-device LLM (about
    /// 4 GB on every Apple Silicon Mac) and the user's other apps.
    static func comfortableSpeechModelMemoryGB(for profile: Profile) -> Double {
        switch tier(for: profile) {
        case .limited: return 1.0
        case .capable: return 4.0
        case .powerful: return profile.physicalMemoryGB * 0.35
        }
    }

    /// The best local model for one language need that this Mac runs comfortably, derived from
    /// catalog metadata. Within the comfortable memory budget the most accurate model wins
    /// (then the faster, then the lighter); when nothing fits the budget, the lightest model
    /// that still fits this Mac does.
    static func recommendedLocalModel(
        for need: RecommendationNeed,
        among models: [any TranscriptionModel],
        profile: Profile = .current
    ) -> (any LocalTranscriptionModel)? {
        let runnable = models
            .compactMap { $0 as? any LocalTranscriptionModel }
            .filter { model in
                guard canRun(model, on: profile) else { return false }
                if case .good = fit(forEstimatedRAMGB: model.estimatedRAMGB, physicalMemoryGB: profile.physicalMemoryGB) {
                    return true
                }
                return false
            }

        let candidates: [any LocalTranscriptionModel]
        switch need {
        case .english:
            // Intel Macs have no English-only engine; the general multilingual models cover English.
            let englishOnly = runnable.filter { $0.languageGroup == .englishOnly }
            candidates = englishOnly.isEmpty ? runnable.filter { !$0.isHebrewOptimized } : englishOnly
        case .multilingual:
            candidates = runnable.filter { $0.languageGroup == .multilingual && !$0.isHebrewOptimized }
        case .hebrew:
            candidates = runnable.filter(\.isHebrewOptimized)
        }

        let budget = comfortableSpeechModelMemoryGB(for: profile)
        let comfortable = candidates.filter { $0.estimatedRAMGB <= budget }
        guard !comfortable.isEmpty else {
            return candidates.min { $0.estimatedRAMGB < $1.estimatedRAMGB }
        }
        return comfortable.max { lhs, rhs in
            if lhs.accuracy != rhs.accuracy { return lhs.accuracy < rhs.accuracy }
            if lhs.speed != rhs.speed { return lhs.speed < rhs.speed }
            return lhs.estimatedRAMGB > rhs.estimatedRAMGB
        }
    }

    /// The on-device LLM recommendation deliberately does not scale with installed RAM. Zerm's
    /// rewrite and narration tasks do not justify reserving more unified memory simply because a
    /// Mac has it. Larger models remain explicit opt-ins.
    static var recommendedLocalLLMFileName: String {
        recommendedLocalLLMFileName(
            physicalMemoryGB: physicalMemoryGB,
            isAppleSilicon: !SystemArchitecture.isIntelMac
        )
    }

    static func recommendedLocalLLMFileName(
        physicalMemoryGB _: Double,
        isAppleSilicon: Bool
    ) -> String {
        guard isAppleSilicon else { return "gemma-3-1b-it-Q4_K_M.gguf" }
        return "gemma-4-E2B_q4_0-it.gguf"
    }

    /// Instant + Refine default. Independent of RAM: Gemma 4 E2B is the cleanup model on every
    /// Apple Silicon Mac, because it is the only one that preserves mixed-script dictation.
    static var recommendedEnhancementLocalLLMFileName: String {
        recommendedLocalLLMFileName
    }

    /// Zerm caps the default context at 8K even on high-memory Macs. Its focused rewrite and
    /// narration jobs do not need a 16K/32K KV cache, and unified memory belongs to the user's
    /// other applications as well as Zerm's STT and TTS runtimes.
    static var localLLMContextSize: Int {
        localLLMContextSize(physicalMemoryGB: physicalMemoryGB)
    }

    static func localLLMContextSize(physicalMemoryGB memory: Double) -> Int {
        switch memory {
        case ..<12: return 4_096
        default: return 8_192
        }
    }
}

// MARK: - Model RAM estimates

extension WhisperModel {
    /// Rough peak working-set while transcribing: the catalog's relative `ramUsage`
    /// (0.3 tiny … 1.8 large-turbo) scaled to gigabytes.
    var estimatedRAMGB: Double { ramUsage * 2.0 }

    var hardwareFit: HardwareCapability.ModelFit {
        HardwareCapability.fit(forEstimatedRAMGB: estimatedRAMGB)
    }
}

extension FluidAudioModel {
    var estimatedRAMGB: Double { ramUsage * 2.0 }

    var hardwareFit: HardwareCapability.ModelFit {
        HardwareCapability.fit(forEstimatedRAMGB: estimatedRAMGB)
    }
}

extension LocalLLMPackage {
    var hardwareFit: HardwareCapability.ModelFit {
        HardwareCapability.fit(forEstimatedRAMGB: estimatedRAMGB)
    }
}
