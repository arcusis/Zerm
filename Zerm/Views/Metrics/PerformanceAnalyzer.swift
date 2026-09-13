import Foundation

enum PanelMode {
    case info
    case analysis
}

struct PerformanceAnalyzer {
    struct AnalysisResult {
        let totalTranscripts: Int
        let totalWithTranscriptionData: Int
        let totalAudioDuration: TimeInterval
        let totalEnhancedFiles: Int
        let transcriptionModels: [ModelStat]
        let enhancementModels: [ModelStat]
    }

    struct ModelStat: Identifiable {
        let id = UUID()
        let name: String
        let fileCount: Int
        let totalProcessingTime: TimeInterval
        let avgProcessingTime: TimeInterval
        let avgAudioDuration: TimeInterval
        let speedFactor: Double
    }

    static func analyze(transcriptions: [Transcription]) -> AnalysisResult {
        let totalTranscripts = transcriptions.count
        let totalWithTranscriptionData = transcriptions.filter { $0.transcriptionDuration != nil }.count
        let totalAudioDuration = transcriptions.reduce(0) { $0 + $1.duration }
        let totalEnhancedFiles = transcriptions.filter { $0.enhancedText != nil && $0.enhancementDuration != nil }.count

        let transcriptionStats = processStats(
            for: transcriptions,
            modelNameKeyPath: \.transcriptionModelName,
            durationKeyPath: \.transcriptionDuration,
            includesSpeedFactor: true
        )

        let enhancementStats = processStats(
            for: transcriptions,
            modelNameKeyPath: \.aiEnhancementModelName,
            durationKeyPath: \.enhancementDuration
        )

        return AnalysisResult(
            totalTranscripts: totalTranscripts,
            totalWithTranscriptionData: totalWithTranscriptionData,
            totalAudioDuration: totalAudioDuration,
            totalEnhancedFiles: totalEnhancedFiles,
            transcriptionModels: transcriptionStats,
            enhancementModels: enhancementStats
        )
    }

    static func processStats(for transcriptions: [Transcription],
                             modelNameKeyPath: KeyPath<Transcription, String?>,
                             durationKeyPath: KeyPath<Transcription, TimeInterval?>,
                             // Speed factor is audio-seconds per processing-second, which is
                             // only meaningful for transcription. Enhancement time has no
                             // audio duration to divide by, so its stats leave this off.
                             includesSpeedFactor: Bool = false) -> [ModelStat] {

        let relevantTranscriptions = transcriptions.filter {
            $0[keyPath: modelNameKeyPath] != nil && $0[keyPath: durationKeyPath] != nil
        }

        let groupedByModel = Dictionary(grouping: relevantTranscriptions) {
            $0[keyPath: modelNameKeyPath] ?? "Unknown"
        }

        return groupedByModel.map { modelName, items in
            let fileCount = items.count
            let totalProcessingTime = items.reduce(0) { $0 + ($1[keyPath: durationKeyPath] ?? 0) }
            let avgProcessingTime = totalProcessingTime / Double(fileCount)

            let totalAudioDuration = items.reduce(0) { $0 + $1.duration }
            let avgAudioDuration = totalAudioDuration / Double(fileCount)

            var speedFactor = 0.0
            if includesSpeedFactor, totalProcessingTime > 0 {
                speedFactor = totalAudioDuration / totalProcessingTime
            }

            return ModelStat(
                name: modelName,
                fileCount: fileCount,
                totalProcessingTime: totalProcessingTime,
                avgProcessingTime: avgProcessingTime,
                avgAudioDuration: avgAudioDuration,
                speedFactor: speedFactor
            )
        }.sorted { $0.avgProcessingTime < $1.avgProcessingTime }
    }

    static func getMacModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &machine, &size, nil, 0)
        return String(cString: machine)
    }

    static func getCPUInfo() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    static func getMemoryInfo() -> String {
        let totalMemory = ProcessInfo.processInfo.physicalMemory
        return ByteCountFormatter.string(fromByteCount: Int64(totalMemory), countStyle: .memory)
    }
}
