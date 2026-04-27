import Foundation
import AppKit
import SwiftData
import ApplicationServices
import NaturalLanguage
import os

final class AutoLearnVocabularyService {
    static let shared = AutoLearnVocabularyService()
    private init() {}

    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "AutoLearnVocabulary")

    // Active monitoring state
    private var pastedText: String = ""
    private var lastKnownText: String = ""
    private var modelContext: ModelContext?
    private var timeoutTimer: DispatchSourceTimer?
    private var axObserver: AXObserver?
    private var workspaceObserver: NSObjectProtocol?
    private var isActive = false

    // Pending state — set during paste, activated after recorder dismisses
    private var pendingElement: AXUIElement?
    private var pendingText: String = ""
    private var pendingContext: ModelContext?

    // Must be called before paste fires, while the target text field still has focus
    func captureFocusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success else { return nil }
        return (focusedElement as! AXUIElement)
    }

    // Step 1: Called during paste — stores state but does NOT start observers yet
    func prepareMonitoring(pastedText: String, element: AXUIElement, modelContext: ModelContext) {
        pendingElement = element
        pendingText = pastedText
        pendingContext = modelContext
    }

    // Step 2: Called after recorder dismisses — now safe to start observing
    func beginMonitoring() {
        guard UserDefaults.standard.object(forKey: "autoLearnVocabulary") as? Bool ?? true else { return }
        guard let element = pendingElement, let context = pendingContext else { return }
        let pasted = pendingText
        pendingElement = nil
        pendingContext = nil
        pendingText = ""

        startMonitoring(pastedText: pasted, element: element, modelContext: context)
    }

    private func startMonitoring(pastedText: String, element: AXUIElement, modelContext: ModelContext) {
        stopMonitoring()

        self.pastedText = pastedText
        self.lastKnownText = pastedText
        self.modelContext = modelContext
        self.isActive = true

        setupValueChangeObserver(for: element)
        setupAppSwitchObserver()
        startTimeoutTimer()
    }

    func stopMonitoring() {
        isActive = false

        timeoutTimer?.cancel()
        timeoutTimer = nil

        if let obs = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
            axObserver = nil
        }

        if let obs = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            workspaceObserver = nil
        }

        modelContext = nil
    }

    // Watch the specific element for value changes — cache latest text on every keystroke
    private func setupValueChangeObserver(for element: AXUIElement) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else {
            logger.notice("⚠️ Could not get PID from element — skipping value observer")
            return
        }

        var observer: AXObserver?
        let callback: AXObserverCallback = { _, changedElement, _, refcon in
            guard let refcon else { return }
            let service = Unmanaged<AutoLearnVocabularyService>.fromOpaque(refcon).takeUnretainedValue()
            guard service.isActive else { return }
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(changedElement, kAXValueAttribute as CFString, &value) == .success,
               let text = value as? String {
                service.lastKnownText = text
            }
        }

        guard AXObserverCreate(pid, callback, &observer) == .success, let obs = observer else { return }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(obs, element, kAXValueChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        axObserver = obs
    }

    // Finalize immediately when user switches to a different app
    private func setupAppSwitchObserver() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isActive else { return }
            self.finalize()
        }
    }

    private func startTimeoutTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 30)
        timer.setEventHandler { [weak self] in
            guard let self, self.isActive else { return }
            self.finalize()
        }
        timer.resume()
        timeoutTimer = timer
    }

    // Called on main queue — from app switch or timeout
    private func finalize() {
        guard isActive else { return }
        isActive = false

        timeoutTimer?.cancel()
        timeoutTimer = nil

        if let obs = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
            axObserver = nil
        }

        if let obs = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            workspaceObserver = nil
        }

        guard let context = modelContext else { return }
        modelContext = nil

        let currentText = lastKnownText
        let baseline = pastedText

        guard currentText != baseline else { return }

        let allSubstitutions = WordDiffEngine.findSingleWordSubstitutions(original: baseline, edited: currentText)
        guard !allSubstitutions.isEmpty else { return }

        // Only consider corrections to words that were part of the pasted transcript
        let pastedTokens = Set(pastedText.components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters).lowercased() }
            .filter { !$0.isEmpty })

        let substitutions = allSubstitutions.filter { pastedTokens.contains($0.original.lowercased()) }
        guard !substitutions.isEmpty else { return }

        guard isSupportedLanguage(currentText) else { return }

        let namedEntities = namedEntitiesIn(currentText)

        var wordsToAdd = [String]()
        for (_, replWord) in substitutions {
            guard let correctedRange = currentText.range(of: replWord, options: .caseInsensitive) else { continue }
            let correctedPosition = currentText.distance(from: currentText.startIndex, to: correctedRange.lowerBound)

            let candidates = namedEntities.filter { entity in
                entity.name.components(separatedBy: .whitespaces)
                    .map { $0.lowercased() }
                    .contains(replWord.lowercased())
            }
            if let closest = candidates.min(by: { abs($0.position - correctedPosition) < abs($1.position - correctedPosition) }) {
                wordsToAdd.append(closest.name)
            }
        }

        let uniqueWordsToAdd = Array(NSOrderedSet(array: wordsToAdd)) as! [String]
        guard !uniqueWordsToAdd.isEmpty else { return }

        let descriptor = FetchDescriptor<VocabularyWord>()
        let existing = (try? context.fetch(descriptor)) ?? []
        let existingWords = Set(existing.map { $0.word.lowercased() })

        var addedWords: [VocabularyWord] = []

        for word in uniqueWordsToAdd {
            guard !existingWords.contains(word.lowercased()) else {
                logger.notice("⚠️ \"\(word, privacy: .public)\" already in Vocabulary — skipping")
                continue
            }

            let newWord = VocabularyWord(word: word)
            context.insert(newWord)
            addedWords.append(newWord)
            logger.notice("✅ Added \"\(word, privacy: .public)\" to Vocabulary")
        }

        guard !addedWords.isEmpty else { return }
        try? context.save()

        let title: String
        if addedWords.count == 1 {
            title = "Added \"\(addedWords[0].word)\" to Vocabulary"
        } else {
            title = "Added \(addedWords.count) words to Vocabulary"
        }

        Task { @MainActor in
            NotificationManager.shared.showNotification(
                title: title,
                type: .success,
                duration: 4.0,
                actionButton: ("Undo", {
                    for word in addedWords {
                        context.delete(word)
                    }
                    try? context.save()
                })
            )
        }
    }

    private static let nerSupportedLanguages: Set<NLLanguage> = [
        .english, .german, .french, .spanish, .italian, .portuguese, .russian, .turkish
    ]

    private func isSupportedLanguage(_ text: String) -> Bool {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage else { return false }
        return Self.nerSupportedLanguages.contains(language)
    }

    private func namedEntitiesIn(_ text: String) -> [(name: String, position: Int)] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text

        var entities = [(name: String, position: Int)]()
        let entityTags: Set<NLTag> = [.personalName, .placeName, .organizationName]

        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .nameType,
            options: [.omitWhitespace, .omitPunctuation, .joinNames]
        ) { tag, range in
            if let tag, entityTags.contains(tag) {
                let position = text.distance(from: text.startIndex, to: range.lowerBound)
                entities.append((name: String(text[range]), position: position))
            }
            return true
        }
        return entities
    }
}
