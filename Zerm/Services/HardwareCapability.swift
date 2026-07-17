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

    static let tier: Tier = {
        if SystemArchitecture.isIntelMac { return .limited }
        switch physicalMemoryGB {
        case ..<12: return .limited
        case ..<24: return .capable
        default: return .powerful
        }
    }()

    /// Human-readable summary, e.g. "Apple M1 · 8 GB RAM".
    static var summary: String {
        "\(chipName) · \(Int(physicalMemoryGB.rounded())) GB RAM"
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
            return .tooHeavy(reason: "Needs ~\(neededText) GB of memory — more than this Mac (\(Int(total.rounded())) GB) can spare while macOS is running.")
        }
        if needed > total * 0.45 {
            return .heavy(reason: "Needs ~\(neededText) GB of memory — will run, but expect slowdowns on this Mac (\(Int(total.rounded())) GB).")
        }
        return .good
    }

    /// Transcription model names recommended for this Mac, in display order.
    static var recommendedTranscriptionModelNames: [String] {
        switch tier {
        case .limited:
            return ["ggml-base.en", "parakeet-tdt-0.6b-v2", "whisper-large-v3-turbo"]
        case .capable, .powerful:
            return ["ggml-base.en", "parakeet-tdt-0.6b-v2", "ggml-large-v3-turbo-q5_0", "whisper-large-v3-turbo"]
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
