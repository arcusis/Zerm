import Foundation

/// Canonical technical terms shipped with the Coding enhancement profile.
///
/// This is deliberately separate from the user's Vocabulary database: the built-in list can be
/// improved in app updates, while personal/customer terminology remains local user data. The list
/// is activated only for the Coding profile so ordinary prose is not biased toward developer
/// jargon.
enum TechnicalTerminology {
    static let canonicalTerms: [String] = [
        "API", "CLI", "SDK", "IDE", "HTTP", "HTTPS", "JSON", "YAML", "XML",
        "SQL", "NoSQL", "OAuth", "SSH", "TLS", "TCP", "UDP", "URL", "UUID",
        "Codex", "Claude", "Claude Code", "Gemini", "OpenAI", "Anthropic",
        "Git", "GitHub", "GitLab", "Docker", "Kubernetes", "kubectl", "Terraform",
        "DigitalOcean", "doctl", "Cloudflare", "AWS", "Azure", "Google Cloud",
        "Xcode", "Swift", "SwiftUI", "AppKit", "Core Audio", "AVFoundation",
        "macOS", "iOS", "Linux", "Homebrew", "Node.js", "npm", "pnpm",
        "Python", "NumPy", "PyTorch", "PostgreSQL", "Redis", "GraphQL", "REST",
        "gRPC", "webhook", "codec", "FFmpeg"
    ]

    static func isCodingPrompt(_ promptID: UUID?) -> Bool {
        promptID == PredefinedPrompts.codingPromptId
    }

    static var selectedPromptID: UUID? {
        guard let value = UserDefaults.standard.string(forKey: "selectedPromptId") else {
            return nil
        }
        return UUID(uuidString: value)
    }

    static func terms(for promptID: UUID?) -> [String] {
        isCodingPrompt(promptID) ? canonicalTerms : []
    }

    static let phoneticGuidance = """
    Resolve technical names from pronunciation and context, but never guess blindly:
    - "code X" or "codecs" means Codex only when the surrounding text refers to OpenAI's coding agent; preserve codec/codecs for audio or video formats.
    - "cloud code" means Claude Code only when the surrounding text refers to Anthropic's coding tool; preserve cloud in infrastructure contexts.
    - "digital ocean" is DigitalOcean; "digital ocean C L I" is DigitalOcean CLI; its command-line tool is doctl.
    - Spoken initialisms stay initialisms: C L I → CLI, A P I → API, S D K → SDK, S S H → SSH, and T L S → TLS.
    - Preserve canonical product casing such as GitHub, GitLab, Cloudflare, Kubernetes, kubectl, PostgreSQL, Node.js, macOS, SwiftUI, AppKit, and FFmpeg.
    """
}
