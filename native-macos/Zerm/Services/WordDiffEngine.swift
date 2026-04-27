import Foundation

enum WordDiffEngine {
    // Find word substitutions between original and edited text using LCS alignment
    static func findSingleWordSubstitutions(original: String, edited: String) -> [(original: String, replacement: String)] {
        let origTokens = tokenize(original)
        let editTokens = tokenize(edited)
        guard !origTokens.isEmpty, !editTokens.isEmpty else { return [] }

        let lcsIndices = lcsIndexPairs(origTokens, editTokens)

        var results = [(original: String, replacement: String)]()
        var oi = 0
        var ei = 0

        // Collect changed segments between each LCS anchor
        for (anchorO, anchorE) in lcsIndices {
            let origSegment = Array(origTokens[oi..<anchorO])
            let editSegment = Array(editTokens[ei..<anchorE])
            results.append(contentsOf: pairSegments(origSegment, editSegment))
            oi = anchorO + 1
            ei = anchorE + 1
        }

        // Trailing tokens after the last anchor
        let origTail = Array(origTokens[oi...])
        let editTail = Array(editTokens[ei...])
        results.append(contentsOf: pairSegments(origTail, editTail))

        return results
    }

    // Pair tokens from a changed segment into substitutions
    private static func pairSegments(_ orig: [String], _ edit: [String]) -> [(original: String, replacement: String)] {
        if orig.isEmpty || edit.isEmpty { return [] }

        // Equal length: pair 1:1, skip case-only matches
        if orig.count == edit.count {
            return zip(orig, edit).compactMap { a, b in
                a.lowercased() == b.lowercased() ? nil : (a, b)
            }
        }

        // Unequal length: merge/split — pair each original with each new replacement
        var results = [(original: String, replacement: String)]()
        for editWord in edit {
            let isCaseOnly = orig.contains(where: { $0.lowercased() == editWord.lowercased() })
            if !isCaseOnly {
                for origWord in orig {
                    results.append((origWord, editWord))
                }
            }
        }
        return results
    }

    // Compute LCS index pairs using case-insensitive comparison
    private static func lcsIndexPairs(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        let m = a.count
        let n = b.count

        var dp = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)
        for i in 1...m {
            for j in 1...n {
                if a[i - 1].lowercased() == b[j - 1].lowercased() {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }

        // Backtrack to find matched index pairs
        var pairs = [(Int, Int)]()
        var i = m, j = n
        while i > 0 && j > 0 {
            if a[i - 1].lowercased() == b[j - 1].lowercased() {
                pairs.append((i - 1, j - 1))
                i -= 1
                j -= 1
            } else if dp[i - 1][j] > dp[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }

        return pairs.reversed()
    }

    private static func tokenize(_ text: String) -> [String] {
        text.components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }
}
