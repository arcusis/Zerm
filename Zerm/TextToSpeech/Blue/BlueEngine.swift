import Foundation
import os

private final class BlueORTHandle: @unchecked Sendable {
    let pointer: OpaquePointer

    init(directory: URL) throws {
        let names = ["duration_predictor.onnx", "text_encoder.onnx", "vector_estimator.onnx", "vocoder.onnx", "renikud/model.onnx"]
        let paths = names.map { directory.appendingPathComponent($0).path }
        let error = UnsafeMutablePointer<CChar>.allocate(capacity: 2048)
        error.initialize(repeating: 0, count: 2048)
        defer { error.deallocate() }
        var pathPointers: [UnsafePointer<CChar>?] = []
        func withPathPointers(_ index: Int) -> OpaquePointer? {
            guard index < paths.count else {
                return pathPointers.withUnsafeBufferPointer { buffer in
                    blue_ort_create(buffer.baseAddress, Int32(buffer.count), error, 2048)
                }
            }
            return paths[index].withCString { pointer in
                pathPointers.append(pointer)
                defer { pathPointers.removeLast() }
                return withPathPointers(index + 1)
            }
        }
        let created = withPathPointers(0)
        guard let created else { throw TTSError.notAvailable(String(cString: error)) }
        pointer = created
    }

    deinit { blue_ort_destroy(pointer) }
}

private enum BlueORTValue {
    case floats(String, [Float], [Int64])
    case integers(String, [Int64], [Int64])

    var name: String {
        switch self {
        case .floats(let name, _, _), .integers(let name, _, _): return name
        }
    }
}

actor BlueEngine {
    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "BlueEngine")
    private let modelDirectory: URL
    private let dataDirectory: URL
    private var handle: BlueORTHandle?
    private var metadata: [String: String] = [:]
    private var vocabulary: [String: Int] = [:]
    private var styleTTL: [Float] = []
    private var styleDP: [Float] = []

    init(modelDirectory: URL, dataDirectory: URL) {
        self.modelDirectory = modelDirectory
        self.dataDirectory = dataDirectory
    }

    func synthesize(text: String, language: String, speed: Double) async throws -> TTSAudio {
        let chunks = BlueTextFrontend.sentenceChunks(text)
        guard chunks.count > 1 else {
            return try await synthesizeChunk(text: text, language: language, speed: speed)
        }
        var combined = Data()
        var sampleRate = 44_100.0
        var channels = 1
        for chunk in chunks {
            try Task.checkCancellation()
            let audio = try await synthesizeChunk(text: chunk, language: language, speed: speed)
            sampleRate = audio.sampleRate
            channels = audio.channels
            combined.append(audio.pcm)
        }
        return TTSAudio(pcm: combined, sampleRate: sampleRate, channels: channels)
    }

    private func synthesizeChunk(text: String, language: String, speed: Double) async throws -> TTSAudio {
        try Task.checkCancellation()
        try loadIfNeeded()
        guard let handle else { throw TTSError.notAvailable(String(localized: "Blue ONNX runtime is unavailable.")) }
        let startedAt = ContinuousClock.now
        return try await withTaskCancellationHandler {
            let audio: TTSAudio
            do {
                audio = try synthesizeBlocking(text: text, language: language, speed: speed, handle: handle)
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
            let elapsed = startedAt.duration(to: .now).components
            let elapsedSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            let audioSeconds = Double(audio.pcm.count) / Double(audio.channels * 2) / audio.sampleRate
            let rtf = elapsedSeconds / max(audioSeconds, 0.001)
            let memoryMB = Double(blue_current_resident_memory_bytes()) / 1_048_576
            logger.info("Blue synthesis complete: elapsed=\(elapsedSeconds, privacy: .public)s audio=\(audioSeconds, privacy: .public)s rtf=\(rtf, privacy: .public) residentMB=\(memoryMB, privacy: .public)")
            return audio
        } onCancel: {
            blue_ort_cancel(handle.pointer)
        }
    }

    private func loadIfNeeded() throws {
        guard handle == nil else { return }
        let loaded = try BlueORTHandle(directory: modelDirectory)
        let vocabData = try Data(contentsOf: modelDirectory.appendingPathComponent("vocab.json"))
        let vocabRoot = try JSONSerialization.jsonObject(with: vocabData) as? [String: Any] ?? [:]
        vocabulary = vocabRoot["char_to_id"] as? [String: Int] ?? [:]
        let styleData = try Data(contentsOf: modelDirectory.appendingPathComponent("voices/female1.json"))
        let style = try JSONSerialization.jsonObject(with: styleData) as? [String: Any] ?? [:]
        styleTTL = Self.floatValues(style["style_ttl"])
        styleDP = Self.floatValues(style["style_dp"])
        for key in ["vocab", "consonant_vocab", "vowel_vocab", "letter_consonant_constraints", "geresh_map", "cls_token_id", "sep_token_id", "vowel_cond_consonant", "stress_cond_consonant", "stress_cond_vowel", "cascade_cond"] {
            if let value = Self.metadataValue(loaded.pointer, key: key) { metadata[key] = value }
        }
        handle = loaded
    }

    private func synthesizeBlocking(text: String, language: String, speed: Double, handle: BlueORTHandle) throws -> TTSAudio {
        try Task.checkCancellation()
        let runs = BlueTextFrontend.languageRuns(in: text)
        let phonemes = try runs.map { run in
            let value: String
            if run.language == "he" {
                value = try hebrewPhonemes(BlueTextFrontend.normalizeHebrewNumbers(run.text), handle: handle)
            } else {
                value = try englishPhonemes(run.text)
            }
            return "<\(run.language)>\(value)</\(run.language)>"
        }.joined(separator: " ")
        let ids = BlueTextFrontend.tokenIDs(for: phonemes, vocabulary: vocabulary)
        guard !ids.isEmpty else { throw TTSError.emptyAudio }
        logger.info("Blue text prepared: tokens=\(ids.count, privacy: .public) language=\(language, privacy: .public)")
        let tokenCount = Int64(ids.count)
        let textMask = Array(repeating: Float(1), count: ids.count)
        let duration = try run(handle, model: 0, inputs: [
            .integers("text_ids", ids, [1, tokenCount]),
            .floats("style_dp", styleDP, [1, 8, 16]),
            .floats("text_mask", textMask, [1, 1, tokenCount])
        ], outputNames: ["duration"])[0]
        let sampleCount = max(1, Int(Double(duration[0]) * 44_100 / max(speed, 0.01)))
        let latentCount = max(1, (sampleCount + 3_071) / 3_072)
        let tokenFrames = Int64(latentCount)
        let textEmb = try run(handle, model: 1, inputs: [
            .integers("text_ids", ids, [1, tokenCount]),
            .floats("style_ttl", styleTTL, [1, Int64(styleTTL.count / 256), 256]),
            .floats("text_mask", textMask, [1, 1, tokenCount])
        ], outputNames: ["text_emb"])[0]
        var latent = Self.gaussian(count: latentCount * 144)
        let latentMask = Array(repeating: Float(1), count: latentCount)
        for step in 0..<5 {
            try Task.checkCancellation()
            blue_ort_clear_cancel(handle.pointer)
            latent = try run(handle, model: 2, inputs: [
                .floats("noisy_latent", latent, [1, 144, tokenFrames]),
                .floats("text_emb", textEmb, [1, 256, tokenCount]),
                .floats("style_ttl", styleTTL, [1, Int64(styleTTL.count / 256), 256]),
                .floats("latent_mask", latentMask, [1, 1, tokenFrames]),
                .floats("text_mask", textMask, [1, 1, tokenCount]),
                .floats("current_step", [Float(step)], [1]),
                .floats("total_step", [5], [1]),
                .floats("cfg_scale", [4], [1])
            ], outputNames: ["denoised_latent"])[0]
        }
        var samples = try run(handle, model: 3, inputs: [
            .floats("latent", latent, [1, 144, tokenFrames])
        ], outputNames: ["waveform"])[0]
        if samples.count > 6_144 { samples = Array(samples.dropFirst(3_072).dropLast(3_072)) }
        guard !samples.isEmpty else { throw TTSError.emptyAudio }
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            var value = Int16(max(-1, min(1, sample)) * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        return TTSAudio(pcm: pcm, sampleRate: 44_100, channels: 1)
    }

    private func hebrewPhonemes(_ text: String, handle: BlueORTHandle) throws -> String {
        guard let vocabData = metadata["vocab"]?.data(using: .utf8),
              let vocab = try JSONSerialization.jsonObject(with: vocabData) as? [String: Int],
              let consonantsData = metadata["consonant_vocab"]?.data(using: .utf8),
              let consonants = try JSONSerialization.jsonObject(with: consonantsData) as? [String: String],
              let vowelsData = metadata["vowel_vocab"]?.data(using: .utf8),
              let vowels = try JSONSerialization.jsonObject(with: vowelsData) as? [String: String],
              let constraintsData = metadata["letter_consonant_constraints"]?.data(using: .utf8),
              let constraints = try JSONSerialization.jsonObject(with: constraintsData) as? [String: [Int]],
              let cls = Int(metadata["cls_token_id"] ?? ""),
              let sep = Int(metadata["sep_token_id"] ?? "") else {
            throw TTSError.notAvailable(String(localized: "Hebrew G2P metadata is missing."))
        }
        let normalized = text.decomposedStringWithCanonicalMapping.unicodeScalars
            .filter { !Self.isHebrewPoint($0.value) }.map(String.init).joined()
            .replacingOccurrences(of: "׳", with: "'").replacingOccurrences(of: "״", with: "\"")
        let scalars = Array(normalized.unicodeScalars)
        var ids: [Int64] = [Int64(cls)]
        ids += scalars.map { Int64(vocab[String($0)] ?? vocab["[UNK]"] ?? 0) }
        ids.append(Int64(sep))
        let attention = Array(repeating: Int64(1), count: ids.count)
        let output = try run(handle, model: 4, inputs: [
            .integers("input_ids", ids, [1, Int64(ids.count)]),
            .integers("attention_mask", attention, [1, Int64(attention.count)])
        ], outputNames: ["consonant_logits", "vowel_logits", "stress_logits"])
        let cLogits = output[0]
        let vLogits = output[1]
        let sLogits = output[2]
        let gereshData = (metadata["geresh_map"] ?? "{}").data(using: .utf8)!
        let geresh = (try? JSONSerialization.jsonObject(with: gereshData)) as? [String: String] ?? [:]
        guard let vowelWeights = Self.matrix(metadata["vowel_cond_consonant"], rows: 25, columns: 6),
              let stressConsonantWeights = Self.matrix(metadata["stress_cond_consonant"], rows: 25, columns: 2),
              let stressVowelWeights = Self.matrix(metadata["stress_cond_vowel"], rows: 6, columns: 2) else {
            return Self.greedyHebrewPhonemes(
                scalars: scalars,
                consonantLogits: cLogits,
                vowelLogits: vLogits,
                stressLogits: sLogits,
                constraints: constraints,
                consonants: consonants,
                vowels: vowels,
                geresh: geresh
            )
        }
        let consonantCount = 25
        let vowelCount = 6
        let stressCount = 2
        let softmaxConditioning = metadata["cascade_cond"] != "argmax"
        var energies = Array(repeating: Array(repeating: Array(repeating: -Double.greatestFiniteMagnitude, count: stressCount), count: vowelCount), count: consonantCount)
        var bestUnstressed = Array(repeating: -Double.greatestFiniteMagnitude, count: scalars.count)
        var bestStressed = bestUnstressed
        var bestUnstressedPair = Array(repeating: (0, 0), count: scalars.count)
        var bestStressedPair = bestUnstressedPair
        var consonantIDs: [Int] = []
        var vowelIDs: [Int] = []
        for (offset, scalar) in scalars.enumerated() {
            let char = String(scalar)
            guard (0x05D0...0x05EA).contains(scalar.value) else {
                consonantIDs.append(-1); vowelIDs.append(0); continue
            }
            let cOffset = (offset + 1) * consonantCount
            let vOffset = (offset + 1) * vowelCount
            let sOffset = (offset + 1) * stressCount
            let cValues = Array(cLogits[cOffset..<(cOffset + consonantCount)]).map(Double.init)
            let vValues = Array(vLogits[vOffset..<(vOffset + vowelCount)]).map(Double.init)
            let sValues = Array(sLogits[sOffset..<(sOffset + stressCount)]).map(Double.init)
            let condC = softmaxConditioning ? Self.softmax(cValues) : Self.oneHot(cValues)
            let condV = softmaxConditioning ? Self.softmax(vValues) : Self.oneHot(vValues)
            var baseV = Array(repeating: 0.0, count: vowelCount)
            for vowel in 0..<vowelCount {
                var conditioned = 0.0
                for consonant in 0..<consonantCount { conditioned += condC[consonant] * vowelWeights[consonant][vowel] }
                baseV[vowel] = vValues[vowel] - conditioned
            }
            var baseS = Array(repeating: 0.0, count: stressCount)
            for stress in 0..<stressCount {
                var conditionedConsonant = 0.0
                var conditionedVowel = 0.0
                for consonant in 0..<consonantCount { conditionedConsonant += condC[consonant] * stressConsonantWeights[consonant][stress] }
                for vowel in 0..<vowelCount { conditionedVowel += condV[vowel] * stressVowelWeights[vowel][stress] }
                baseS[stress] = sValues[stress] - conditionedConsonant - conditionedVowel
            }
            let logC = Self.logSoftmax(cValues)
            for consonant in 0..<consonantCount {
                for vowel in 0..<vowelCount { energies[consonant][vowel] = Array(repeating: -Double.greatestFiniteMagnitude, count: stressCount) }
            }
            let allowed = Set(constraints[char] ?? [])
            for consonant in 0..<consonantCount where allowed.contains(consonant) {
                var conditionalVowels = Array(repeating: 0.0, count: vowelCount)
                for vowel in 0..<vowelCount { conditionalVowels[vowel] = baseV[vowel] + vowelWeights[consonant][vowel] }
                let logV = Self.logSoftmax(conditionalVowels)
                for vowel in 0..<vowelCount {
                    let logS = Self.logSoftmax((0..<stressCount).map {
                        baseS[$0] + stressConsonantWeights[consonant][$0] + stressVowelWeights[vowel][$0]
                    })
                    for stress in 0..<stressCount where !(vowel == 0 && stress == 1) {
                        energies[consonant][vowel][stress] = logC[consonant] + logV[vowel] + logS[stress]
                    }
                }
            }
            var unmarked = -Double.greatestFiniteMagnitude
            var marked = unmarked
            for consonant in 0..<consonantCount {
                for vowel in 0..<vowelCount {
                    if energies[consonant][vowel][0] > unmarked {
                        unmarked = energies[consonant][vowel][0]
                        bestUnstressedPair[offset] = (consonant, vowel)
                    }
                    if energies[consonant][vowel][1] > marked {
                        marked = energies[consonant][vowel][1]
                        bestStressedPair[offset] = (consonant, vowel)
                    }
                }
            }
            bestUnstressed[offset] = unmarked
            bestStressed[offset] = marked
            consonantIDs.append(0)
            vowelIDs.append(0)
        }
        var stressed = Set<Int>()
        for word in Self.wordRanges(scalars) {
            let candidates = word.filter { (0x05D0...0x05EA).contains(scalars[$0].value) && bestStressed[$0] > -1e8 }
            if let index = candidates.max(by: { bestStressed[$0] - bestUnstressed[$0] < bestStressed[$1] - bestUnstressed[$1] }) {
                stressed.insert(index)
            }
        }
        for index in scalars.indices where consonantIDs[index] >= 0 {
            let pair = stressed.contains(index) ? bestStressedPair[index] : bestUnstressedPair[index]
            consonantIDs[index] = pair.0
            vowelIDs[index] = pair.1
        }
        return Self.renderHebrew(scalars, consonantIDs, vowelIDs, stressed, consonants, vowels, geresh)
    }

    private static func greedyHebrewPhonemes(
        scalars: [Unicode.Scalar], consonantLogits: [Float], vowelLogits: [Float], stressLogits: [Float],
        constraints: [String: [Int]], consonants: [String: String], vowels: [String: String], geresh: [String: String]
    ) -> String {
        let consonantCount = 25
        let vowelCount = 6
        var consonantIDs: [Int] = []
        var vowelIDs: [Int] = []
        for (offset, scalar) in scalars.enumerated() {
            let cOffset = (offset + 1) * consonantCount
            let vOffset = (offset + 1) * vowelCount
            let rawConsonant = (0..<consonantCount).max { consonantLogits[cOffset + $0] < consonantLogits[cOffset + $1] } ?? 0
            let allowed = constraints[String(scalar)]
            let consonant = allowed?.contains(rawConsonant) == false
                ? (allowed?.max { consonantLogits[cOffset + $0] < consonantLogits[cOffset + $1] } ?? rawConsonant)
                : rawConsonant
            let vowel = (0..<vowelCount).max { vowelLogits[vOffset + $0] < vowelLogits[vOffset + $1] } ?? 0
            if (0x05D0...0x05EA).contains(scalar.value) {
                consonantIDs.append(consonant)
                vowelIDs.append(vowel)
            } else {
                consonantIDs.append(-1)
                vowelIDs.append(vowel)
            }
        }
        var stressed = Set<Int>()
        for word in wordRanges(scalars) {
            let candidates = word.filter { vowelIDs[$0] > 0 }
            if let index = candidates.max(by: { lhs, rhs in
                let left = (lhs + 1) * 2
                let right = (rhs + 1) * 2
                return stressLogits[left + 1] - stressLogits[left] < stressLogits[right + 1] - stressLogits[right]
            }) { stressed.insert(index) }
        }
        return renderHebrew(scalars, consonantIDs, vowelIDs, stressed, consonants, vowels, geresh)
    }

    private static func renderHebrew(
        _ scalars: [Unicode.Scalar], _ consonantIDs: [Int], _ vowelIDs: [Int], _ stressed: Set<Int>,
        _ consonants: [String: String], _ vowels: [String: String], _ geresh: [String: String]
    ) -> String {
        var result = ""
        for index in scalars.indices {
            let scalar = scalars[index]
            guard consonantIDs[index] >= 0 else { result.unicodeScalars.append(scalar); continue }
            let char = String(scalar)
            var consonantID = consonantIDs[index]
            if index + 1 < scalars.count, scalars[index + 1] == "'", let alternate = geresh[char],
               let found = consonants.first(where: { $0.value == alternate }) {
                consonantID = Int(found.key) ?? consonantID
            }
            let consonant = consonants[String(consonantID)] ?? "∅"
            let vowel = vowels[String(vowelIDs[index])] ?? "∅"
            if consonant != "∅" { result += consonant }
            if stressed.contains(index), vowel != "∅" { result += "ˈ" }
            if vowel != "∅" { result += vowel }
        }
        return result
    }

    private func englishPhonemes(_ text: String) throws -> String {
        let dataPath = dataDirectory.path
        let pointer = text.withCString { textPointer in
            "en-us".withCString { voicePointer in
                dataPath.withCString { pathPointer in
                    blue_espeak_phonemize(textPointer, voicePointer, pathPointer)
                }
            }
        }
        guard let pointer else { throw TTSError.notAvailable(String(localized: "English pronunciation data failed to load.")) }
        defer { blue_ort_free_string(pointer) }
        return String(cString: pointer)
    }

    private func run(_ handle: BlueORTHandle, model: Int32, inputs: [BlueORTValue], outputNames: [String]) throws -> [[Float]] {
        var ortInputs = Array(repeating: BlueORTInput(), count: inputs.count)
        var outputPointers: [UnsafePointer<CChar>?] = []
        var outputs = Array(repeating: BlueORTOutput(), count: outputNames.count)
        let error = UnsafeMutablePointer<CChar>.allocate(capacity: 2048)
        error.initialize(repeating: 0, count: 2048)
        defer { error.deallocate(); outputs.withUnsafeMutableBufferPointer { buffer in for index in buffer.indices { blue_ort_free_output(buffer.baseAddress!.advanced(by: index)) } } }
        func output(_ index: Int) throws {
            if index == outputNames.count {
                let status = ortInputs.withUnsafeBufferPointer { inputBuffer in
                    outputPointers.withUnsafeBufferPointer { outputBuffer in
                        outputs.withUnsafeMutableBufferPointer { outputBufferMutable in
                            blue_ort_run(handle.pointer, model, inputBuffer.baseAddress, Int32(inputs.count), outputBuffer.baseAddress, Int32(outputNames.count), outputBufferMutable.baseAddress, error, 2048)
                        }
                    }
                }
                guard status != 0 else { throw TTSError.notAvailable(String(cString: error)) }
                return
            }
            try outputNames[index].withCString { name in
                outputPointers.append(name)
                defer { outputPointers.removeLast() }
                try output(index + 1)
            }
        }
        func input(_ index: Int) throws {
            guard index < inputs.count else { try output(0); return }
            try inputs[index].name.withCString { name in
                switch inputs[index] {
                case .floats(_, let values, let dims):
                    try values.withUnsafeBufferPointer { data in
                        ortInputs[index] = Self.makeInput(name, data.baseAddress, 1, dims)
                        try input(index + 1)
                    }
                case .integers(_, let values, let dims):
                    try values.withUnsafeBufferPointer { data in
                        ortInputs[index] = Self.makeInput(name, data.baseAddress, 7, dims)
                        try input(index + 1)
                    }
                }
            }
        }
        try input(0)
        return outputs.map { value in
            guard value.element_type == 1, let data = value.data else { return [] }
            return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: value.element_count))
        }
    }

    private static func makeInput(_ name: UnsafePointer<CChar>, _ data: UnsafeRawPointer?, _ type: Int32, _ dims: [Int64]) -> BlueORTInput {
        var shape: (Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64) = (0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &shape) { bytes in
            let values = bytes.bindMemory(to: Int64.self)
            for (index, dimension) in dims.enumerated() { values[index] = dimension }
        }
        return BlueORTInput(name: name, data: data, element_type: type, rank: Int32(dims.count), dimensions: shape)
    }

    private static func metadataValue(_ handle: OpaquePointer, key: String) -> String? {
        guard let pointer = key.withCString({ blue_ort_metadata(handle, 4, $0) }) else { return nil }
        defer { blue_ort_free_string(pointer) }
        return String(cString: pointer)
    }

    private static func floatValues(_ payload: Any?) -> [Float] {
        guard let root = payload as? [String: Any], let data = root["data"] else { return [] }
        func flatten(_ value: Any) -> [Float] {
            if let number = value as? NSNumber { return [number.floatValue] }
            return (value as? [Any] ?? []).flatMap(flatten)
        }
        return flatten(data)
    }

    private static func matrix(_ value: String?, rows: Int, columns: Int) -> [[Double]]? {
        guard let value, let data = value.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        let matrix = root.map { row in (row as? [NSNumber] ?? []).map(\.doubleValue) }
        guard matrix.count == rows, matrix.allSatisfy({ $0.count == columns }) else { return nil }
        return matrix
    }

    private static func softmax(_ values: [Double]) -> [Double] {
        let maximum = values.max() ?? 0
        let exponentials = values.map { exp($0 - maximum) }
        let total = exponentials.reduce(0, +)
        return exponentials.map { $0 / total }
    }

    private static func logSoftmax(_ values: [Double]) -> [Double] {
        let maximum = values.max() ?? 0
        let normalizer = maximum + log(values.reduce(0) { $0 + exp($1 - maximum) })
        return values.map { $0 - normalizer }
    }

    private static func oneHot(_ values: [Double]) -> [Double] {
        let best = values.indices.max { values[$0] < values[$1] } ?? 0
        return values.indices.map { $0 == best ? 1 : 0 }
    }

    private static func gaussian(count: Int) -> [Float] {
        (0..<count).map { _ in
            let first = max(Double.leastNonzeroMagnitude, Double.random(in: 0..<1))
            let second = Double.random(in: 0..<1)
            return Float(sqrt(-2 * log(first)) * cos(2 * .pi * second))
        }
    }

    private static func isHebrewPoint(_ value: UInt32) -> Bool {
        (0x0591...0x05BD).contains(value) || [0x05BF, 0x05C1, 0x05C2, 0x05C4, 0x05C5, 0x05C7].contains(value)
    }

    private static func wordRanges(_ scalars: [Unicode.Scalar]) -> [[Int]] {
        var result: [[Int]] = []
        var current: [Int] = []
        for index in scalars.indices {
            if CharacterSet.whitespacesAndNewlines.contains(scalars[index]) {
                if !current.isEmpty { result.append(current); current = [] }
            } else { current.append(index) }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
