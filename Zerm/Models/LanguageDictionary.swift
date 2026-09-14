import Foundation

enum LanguageDictionary {

    static func forProvider(isMultilingual: Bool, provider: ModelProvider = .whisper) -> [String: String] {
        if !isMultilingual {
            return ["en": "English"]
        }

        if let cloudProvider = CloudProviderRegistry.provider(for: provider) {
            guard let codes = cloudProvider.languageCodes else {
                return all
            }
            var filtered = forCodes(codes)
            if cloudProvider.includesAutoDetect { filtered["auto"] = "Auto-detect" }
            return filtered
        }

        switch provider {
        case .nativeApple:
            let codes = ["ar", "de", "en", "es", "fr", "it", "ja", "ko", "pt", "yue", "zh"]
            return all.filter { codes.contains($0.key) }

        case .fluidAudio:
            // Parakeet V3 detects among its 25 European languages on its own; Zerm sends it no
            // language hint, so the UI shows these as detected, not as a selectable choice.
            let codes = [
                "bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fr", "hr", "hu", "it",
                "lt", "lv", "mt", "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "uk"
            ]
            var languages = all.filter { codes.contains($0.key) }
            languages["auto"] = "Auto-detect"
            return languages

        default:
            return all
        }
    }

    /// A language's name in the app's language, e.g. "עברית" for `he`. The English names below
    /// are the fallback for codes macOS has no name for.
    static func displayName(for code: String) -> String {
        if code == "auto" { return String(localized: "Auto-detect") }
        if let name = Locale.current.localizedString(forIdentifier: code), name != code { return name }
        return all[code] ?? regional[code] ?? code
    }

    /// Names for the given codes, including regional variants that only some providers accept.
    static func forCodes(_ codes: [String]) -> [String: String] {
        var languages: [String: String] = [:]
        for code in codes {
            languages[code] = all[code] ?? regional[code]
        }
        return languages
    }

    /// Regional variants offered by providers with locale-specific models (Deepgram Nova-3).
    /// Kept apart from `all` so Whisper's language list stays one entry per language.
    static let regional: [String: String] = [
        "af-ZA": "Afrikaans (South Africa)",
        "ar-AE": "Arabic (United Arab Emirates)",
        "ar-DZ": "Arabic (Algeria)",
        "ar-EG": "Arabic (Egypt)",
        "ar-IQ": "Arabic (Iraq)",
        "ar-IR": "Arabic (Iran)",
        "ar-JO": "Arabic (Jordan)",
        "ar-KW": "Arabic (Kuwait)",
        "ar-LB": "Arabic (Lebanon)",
        "ar-MA": "Arabic (Morocco)",
        "ar-PS": "Arabic (Palestine)",
        "ar-QA": "Arabic (Qatar)",
        "ar-SA": "Arabic (Saudi Arabia)",
        "ar-SD": "Arabic (Sudan)",
        "ar-SY": "Arabic (Syria)",
        "ar-TD": "Arabic (Chad)",
        "ar-TN": "Arabic (Tunisia)",
        "as-IN": "Assamese (India)",
        "cs-CZ": "Czech (Czechia)",
        "da-DK": "Danish (Denmark)",
        "de-CH": "German (Switzerland)",
        "en-AU": "English (Australia)",
        "en-CA": "English (Canada)",
        "en-GB": "English (United Kingdom)",
        "en-IE": "English (Ireland)",
        "en-IN": "English (India)",
        "en-NZ": "English (New Zealand)",
        "en-US": "English (United States)",
        "es-419": "Spanish (Latin America)",
        "fr-CA": "French (Canada)",
        "gu-IN": "Gujarati (India)",
        "ka-GE": "Georgian (Georgia)",
        "kk-KZ": "Kazakh (Kazakhstan)",
        "ko-KR": "Korean (South Korea)",
        "nl-BE": "Flemish (Belgium)",
        "pa-IN": "Punjabi (India)",
        "ps-AF": "Pashto (Afghanistan)",
        "pt-BR": "Portuguese (Brazil)",
        "pt-PT": "Portuguese (Portugal)",
        "sv-SE": "Swedish (Sweden)",
        "th-TH": "Thai (Thailand)",
        "tr-TR": "Turkish (Türkiye)",
        "zh-CN": "Chinese (Simplified, China)",
        "zh-HK": "Chinese (Cantonese, Hong Kong)",
        "zh-Hans": "Chinese (Simplified script)",
        "zh-Hant": "Chinese (Traditional script)",
        "zh-TW": "Chinese (Traditional, Taiwan)"
    ]

    // Apple Native Speech languages in BCP-47 format
    // Based on actual supported locales from SpeechTranscriber.supportedLocales
    static let appleNative: [String: String] = [
        "en-US": "English (United States)",
        "en-GB": "English (United Kingdom)",
        "en-CA": "English (Canada)",
        "en-AU": "English (Australia)",
        "en-IN": "English (India)",
        "en-IE": "English (Ireland)",
        "en-NZ": "English (New Zealand)",
        "en-ZA": "English (South Africa)",
        "en-SA": "English (Saudi Arabia)",
        "en-AE": "English (UAE)",
        "en-SG": "English (Singapore)",
        "en-PH": "English (Philippines)",
        "en-ID": "English (Indonesia)",
        "es-ES": "Spanish (Spain)",
        "es-MX": "Spanish (Mexico)",
        "es-US": "Spanish (United States)",
        "es-CO": "Spanish (Colombia)",
        "es-CL": "Spanish (Chile)",
        "es-419": "Spanish (Latin America)",
        "fr-FR": "French (France)",
        "fr-CA": "French (Canada)",
        "fr-BE": "French (Belgium)",
        "fr-CH": "French (Switzerland)",
        "de-DE": "German (Germany)",
        "de-AT": "German (Austria)",
        "de-CH": "German (Switzerland)",
        "zh-CN": "Chinese Simplified (China)",
        "zh-TW": "Chinese Traditional (Taiwan)",
        "zh-HK": "Chinese Traditional (Hong Kong)",
        "ja-JP": "Japanese (Japan)",
        "ko-KR": "Korean (South Korea)",
        "yue-CN": "Cantonese (China)",
        "pt-BR": "Portuguese (Brazil)",
        "pt-PT": "Portuguese (Portugal)",
        "it-IT": "Italian (Italy)",
        "it-CH": "Italian (Switzerland)",
        "ar-SA": "Arabic (Saudi Arabia)"
    ]

    static let all: [String: String] = [
        "auto": "Auto-detect",
        "af": "Afrikaans",
        "am": "Amharic",
        "ar": "Arabic",
        "as": "Assamese",
        "az": "Azerbaijani",
        "ba": "Bashkir",
        "be": "Belarusian",
        "bg": "Bulgarian",
        "bn": "Bengali",
        "bo": "Tibetan",
        "br": "Breton",
        "bs": "Bosnian",
        "ca": "Catalan",
        "cs": "Czech",
        "cy": "Welsh",
        "da": "Danish",
        "de": "German",
        "el": "Greek",
        "en": "English",
        "es": "Spanish",
        "et": "Estonian",
        "eu": "Basque",
        "fa": "Persian",
        "fi": "Finnish",
        "fil": "Filipino",
        "fo": "Faroese",
        "fr": "French",
        "ga": "Irish",
        "gl": "Galician",
        "gu": "Gujarati",
        "ha": "Hausa",
        "haw": "Hawaiian",
        "he": "Hebrew",
        "hi": "Hindi",
        "hr": "Croatian",
        "ht": "Haitian Creole",
        "hu": "Hungarian",
        "hy": "Armenian",
        "id": "Indonesian",
        "ig": "Igbo",
        "is": "Icelandic",
        "it": "Italian",
        "ja": "Japanese",
        "jw": "Javanese",
        "ka": "Georgian",
        "kk": "Kazakh",
        "km": "Khmer",
        "kn": "Kannada",
        "ko": "Korean",
        "ku": "Kurdish",
        "ky": "Kyrgyz",
        "la": "Latin",
        "lb": "Luxembourgish",
        "ln": "Lingala",
        "lo": "Lao",
        "lt": "Lithuanian",
        "lv": "Latvian",
        "mg": "Malagasy",
        "mi": "Maori",
        "mk": "Macedonian",
        "ml": "Malayalam",
        "mn": "Mongolian",
        "mr": "Marathi",
        "ms": "Malay",
        "mt": "Maltese",
        "my": "Myanmar",
        "ne": "Nepali",
        "nl": "Dutch",
        "nn": "Norwegian Nynorsk",
        "no": "Norwegian",
        "oc": "Occitan",
        "or": "Odia",
        "pa": "Punjabi",
        "pl": "Polish",
        "ps": "Pashto",
        "pt": "Portuguese",
        "ro": "Romanian",
        "ru": "Russian",
        "sa": "Sanskrit",
        "sd": "Sindhi",
        "si": "Sinhala",
        "sk": "Slovak",
        "sl": "Slovenian",
        "sn": "Shona",
        "so": "Somali",
        "sq": "Albanian",
        "sr": "Serbian",
        "su": "Sundanese",
        "sv": "Swedish",
        "sw": "Swahili",
        "ta": "Tamil",
        "te": "Telugu",
        "tg": "Tajik",
        "th": "Thai",
        "tk": "Turkmen",
        "tl": "Tagalog",
        "tr": "Turkish",
        "tt": "Tatar",
        "uk": "Ukrainian",
        "ur": "Urdu",
        "uz": "Uzbek",
        "vi": "Vietnamese",
        "wo": "Wolof",
        "xh": "Xhosa",
        "yi": "Yiddish",
        "yo": "Yoruba",
        "yue": "Cantonese",
        "zh": "Chinese",
        "zu": "Zulu"
    ]
}
