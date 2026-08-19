import Foundation

struct AIEnhancementOutputFilter {
    /// Tokens used by common instruct/chat templates. These are model protocol, never user
    /// content. Small quantized models occasionally emit them as ordinary text instead of the
    /// special token ID, so every provider output is sanitized at the product boundary.
    private static let controlTokenPattern = #"(?i)(?:<\s*/?\s*(?:start_of_turn|end_of_turn|eos|bos)\s*>|<\|(?:im_start|im_end|endoftext|assistant|user|system)\|>|\[/?INST\])"#

    /// Section delimiters the enhancement prompt wraps around its own inputs. They are prompt
    /// scaffolding, never something the user said. Qwen3 echoes the `<TRANSCRIPT>` pair back
    /// around its answer, which pastes literal markup into the user's document; Gemma never
    /// did, which is why this only surfaced when the default model changed.
    private static let promptSectionTagPattern = #"(?i)</?\s*(?:TRANSCRIPT|SYSTEM_INSTRUCTIONS|CLIPBOARD_CONTEXT|CURRENT_WINDOW_CONTEXT|CURRENTLY_SELECTED_TEXT|CUSTOM_VOCABULARY|BUILT_IN_TECHNICAL_VOCABULARY)\s*>"#

    static func filter(_ text: String) -> String {
        var processedText = text
        let patterns = [
            #"(?s)<thinking>(.*?)</thinking>"#,
            #"(?s)<think>(.*?)</think>"#,
            #"(?s)<reasoning>(.*?)</reasoning>"#
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(processedText.startIndex..., in: processedText)
                processedText = regex.stringByReplacingMatches(in: processedText, options: [], range: range, withTemplate: "")
            }
        }

        // A reasoning block that ran out of budget never gets its closing tag, so the patterns
        // above leave the raw chain-of-thought in place and it reaches the user's cursor as if
        // it were the rewrite. An unterminated block has no answer after it by definition:
        // drop it, and let the caller fall back to the transcript.
        for opener in ["<thinking>", "<think>", "<reasoning>"] {
            if let range = processedText.range(of: opener, options: .caseInsensitive) {
                processedText.removeSubrange(range.lowerBound..<processedText.endIndex)
            }
        }

        for pattern in [promptSectionTagPattern, controlTokenPattern] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(processedText.startIndex..., in: processedText)
            processedText = regex.stringByReplacingMatches(
                in: processedText,
                options: [],
                range: range,
                withTemplate: ""
            )
        }

        return processedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
