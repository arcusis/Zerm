import Testing
@testable import Zerm

struct HardwareCapabilityTests {

    @Test func smallModelFitsOn8GB() {
        let fit = HardwareCapability.fit(forEstimatedRAMGB: 1.5, physicalMemoryGB: 8)
        guard case .good = fit else {
            Issue.record("Expected .good, got \(fit)")
            return
        }
    }

    @Test func midModelWarnsOn8GB() {
        // Gemma 4 E2B (~4 GB peak) should warn but stay installable on 8 GB.
        let fit = HardwareCapability.fit(forEstimatedRAMGB: 4.0, physicalMemoryGB: 8)
        guard case .heavy = fit else {
            Issue.record("Expected .heavy, got \(fit)")
            return
        }
        #expect(!fit.blocksInstall)
    }

    @Test func largeModelBlockedOn8GB() {
        // Gemma 4 12B (~9 GB peak) must be blocked on 8 GB.
        let fit = HardwareCapability.fit(forEstimatedRAMGB: 9.0, physicalMemoryGB: 8)
        #expect(fit.blocksInstall)
    }

    @Test func largeModelWarnsOn16GB() {
        let fit = HardwareCapability.fit(forEstimatedRAMGB: 9.0, physicalMemoryGB: 16)
        guard case .heavy = fit else {
            Issue.record("Expected .heavy, got \(fit)")
            return
        }
    }

    @Test func hugeModelBlockedOn16GBButAllowedOn32GB() {
        // Gemma 3 27B (~19 GB peak).
        #expect(HardwareCapability.fit(forEstimatedRAMGB: 19.0, physicalMemoryGB: 16).blocksInstall)
        #expect(!HardwareCapability.fit(forEstimatedRAMGB: 19.0, physicalMemoryGB: 32).blocksInstall)
    }

    @MainActor
    @Test func everyLLMPackageHasARAMEstimate() {
        for package in LocalLLMModelManager.packages {
            #expect(package.estimatedRAMGB > 0)
        }
    }

    @Test func inferenceThreadCountIsSane() {
        let threads = HardwareCapability.inferenceThreadCount
        #expect(threads >= 1)
        #expect(threads <= 8)
        #expect(HardwareCapability.performanceCoreCount >= 1)
    }

    @Test @MainActor func enhancementDefaultIsQwen17() {
        #expect(HardwareCapability.recommendedEnhancementLocalLLMFileName == "Qwen3-1.7B-Q4_K_M.gguf")
        #expect(LocalLLMModelManager.enhancementDefaultPackage.fileName == "Qwen3-1.7B-Q4_K_M.gguf")
        #expect(LocalLLMModelManager.enhancementDefaultPackage.disablesThinking)
        #expect(LocalLLMModelManager.enhancementDefaultPackage.estimatedRAMGB < 3)
        #expect(LocalLLMModelManager.packages.contains(where: { $0.fileName == "Qwen3-0.6B-Q4_K_M.gguf" }))
        #expect(LocalLLMModelManager.packages.contains(where: { $0.fileName == "Qwen3-4B-Q4_K_M.gguf" }))
    }

    @Test @MainActor func enhancementCatalogExcludesGemmaChatModels() {
        let enhancement = LocalLLMModelManager.packages(for: .enhancement)
        #expect(enhancement.contains(where: { $0.fileName == "Qwen3-1.7B-Q4_K_M.gguf" }))
        #expect(!enhancement.contains(where: { $0.fileName.hasPrefix("gemma-4") }))
        let reading = LocalLLMModelManager.packages(for: .reading)
        #expect(reading.contains(where: { $0.fileName == "gemma-4-E2B_q4_0-it.gguf" }))
        #expect(!reading.contains(where: { $0.fileName == "Qwen3-0.6B-Q4_K_M.gguf" }))
    }

    @Test func localLLMRecommendationKeepsAppleSiliconOnTheEfficientDefault() {
        #expect(HardwareCapability.recommendedLocalLLMFileName(
            physicalMemoryGB: 8,
            isAppleSilicon: true
        ) == "gemma-4-E2B_q4_0-it.gguf")
        #expect(HardwareCapability.recommendedLocalLLMFileName(
            physicalMemoryGB: 16,
            isAppleSilicon: true
        ) == "gemma-4-E2B_q4_0-it.gguf")
        #expect(HardwareCapability.recommendedLocalLLMFileName(
            physicalMemoryGB: 64,
            isAppleSilicon: true
        ) == "gemma-4-E2B_q4_0-it.gguf")
        #expect(HardwareCapability.recommendedLocalLLMFileName(
            physicalMemoryGB: 64,
            isAppleSilicon: false
        ) == "gemma-3-1b-it-Q4_K_M.gguf")
    }

    @Test func localLLMContextLeavesRoomForOtherOnDeviceModels() {
        #expect(HardwareCapability.localLLMContextSize(physicalMemoryGB: 8) == 4_096)
        #expect(HardwareCapability.localLLMContextSize(physicalMemoryGB: 16) == 8_192)
        #expect(HardwareCapability.localLLMContextSize(physicalMemoryGB: 32) == 8_192)
        #expect(HardwareCapability.localLLMContextSize(physicalMemoryGB: 64) == 8_192)
    }
}
