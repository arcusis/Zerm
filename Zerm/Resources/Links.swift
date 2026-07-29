import Foundation

/// Every outbound URL the app opens, in one place.
///
/// Until this existed each link was an inline string literal spread across seventeen
/// call sites, which is how the whole app ended up pointing at a domain that was never
/// registered. Adding a page means adding a `Doc` case; CI fails the build if the
/// matching page has not been published.
enum Links {
    /// The published site. GitHub Pages, served from `docs/` on the Production branch.
    static let site = URL(string: "https://arcusis.github.io/Zerm/")!

    static let repository = URL(string: "https://github.com/arcusis/Zerm")!

    static let issues = URL(string: "https://github.com/arcusis/Zerm/issues")!

    /// Landing page listing every documentation page.
    static let docs = URL(string: "docs/", relativeTo: site)!.absoluteURL

    /// A published documentation page.
    ///
    /// The raw value is the slug, which is also the generated file name:
    /// `docs/docs/<slug>.html`. Raw values are spelled out rather than left implicit
    /// so the CI guard can read the list straight out of this file.
    enum Doc: String, CaseIterable {
        case announcements = "announcements"
        case audioInput = "audio-input"
        case commonIssues = "common-issues"
        case contextualAwareness = "contextual-awareness"
        case customLocalWhisperModels = "custom-local-whisper-models"
        case dictation = "dictation"
        case dictionary = "dictionary"
        case enhancement = "enhancement"
        case enhancementShortcuts = "enhancement-shortcuts"
        case models = "models"
        case outputModes = "output-modes"
        case permissions = "permissions"
        case powerMode = "power-mode"
        case privacyRetention = "privacy-retention"
        case readAloud = "read-aloud"
        case shortcuts = "shortcuts"
    }

    static func doc(_ page: Doc) -> URL {
        URL(string: "\(page.rawValue).html", relativeTo: docs)!.absoluteURL
    }

    /// String form, for the call sites that take one — `InfoTip(_:learnMoreURL:)` and
    /// the support email body.
    static func docString(_ page: Doc) -> String {
        doc(page).absoluteString
    }
}
