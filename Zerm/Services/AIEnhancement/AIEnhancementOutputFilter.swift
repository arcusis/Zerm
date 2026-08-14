import Foundation

struct AIEnhancementOutputFilter {
    /// Tokens used by common instruct/chat templates. These are model protocol, never user
    /// content. Small quantized models occasionally emit them as ordinary text instead of the
    /// special token ID, so every provider output is sanitized at the product boundary.
    private static let controlTokenPattern = #"(?i)(?:<\s*/?\s*(?:start_of_turn|end_of_turn|eos|bos)\s*>|<\|(?:im_start|im_end|endoftext|assistant|user|system)\|>|\[/?INST\])"#

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

        if let regex = try? NSRegularExpression(pattern: controlTokenPattern) {
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
