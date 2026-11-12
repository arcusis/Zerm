// Language tables ported from LanguageDictionary.swift and WhisperPrompt.swift.
namespace Zerm.Core.Models;

public static class Languages
{
    /// <summary>"auto" plus every Whisper language code with its English name.</summary>
    public static readonly IReadOnlyDictionary<string, string> All = new Dictionary<string, string>
    {
        ["auto"] = "Auto-detect",
        ["af"] = "Afrikaans",
        ["am"] = "Amharic",
        ["ar"] = "Arabic",
        ["as"] = "Assamese",
        ["az"] = "Azerbaijani",
        ["ba"] = "Bashkir",
        ["be"] = "Belarusian",
        ["bg"] = "Bulgarian",
        ["bn"] = "Bengali",
        ["bo"] = "Tibetan",
        ["br"] = "Breton",
        ["bs"] = "Bosnian",
        ["ca"] = "Catalan",
        ["cs"] = "Czech",
        ["cy"] = "Welsh",
        ["da"] = "Danish",
        ["de"] = "German",
        ["el"] = "Greek",
        ["en"] = "English",
        ["es"] = "Spanish",
        ["et"] = "Estonian",
        ["eu"] = "Basque",
        ["fa"] = "Persian",
        ["fi"] = "Finnish",
        ["fil"] = "Filipino",
        ["fo"] = "Faroese",
        ["fr"] = "French",
        ["ga"] = "Irish",
        ["gl"] = "Galician",
        ["gu"] = "Gujarati",
        ["ha"] = "Hausa",
        ["haw"] = "Hawaiian",
        ["he"] = "Hebrew",
        ["hi"] = "Hindi",
        ["hr"] = "Croatian",
        ["ht"] = "Haitian Creole",
        ["hu"] = "Hungarian",
        ["hy"] = "Armenian",
        ["id"] = "Indonesian",
        ["ig"] = "Igbo",
        ["is"] = "Icelandic",
        ["it"] = "Italian",
        ["ja"] = "Japanese",
        ["jw"] = "Javanese",
        ["ka"] = "Georgian",
        ["kk"] = "Kazakh",
        ["km"] = "Khmer",
        ["kn"] = "Kannada",
        ["ko"] = "Korean",
        ["ku"] = "Kurdish",
        ["ky"] = "Kyrgyz",
        ["la"] = "Latin",
        ["lb"] = "Luxembourgish",
        ["ln"] = "Lingala",
        ["lo"] = "Lao",
        ["lt"] = "Lithuanian",
        ["lv"] = "Latvian",
        ["mg"] = "Malagasy",
        ["mi"] = "Maori",
        ["mk"] = "Macedonian",
        ["ml"] = "Malayalam",
        ["mn"] = "Mongolian",
        ["mr"] = "Marathi",
        ["ms"] = "Malay",
        ["mt"] = "Maltese",
        ["my"] = "Myanmar",
        ["ne"] = "Nepali",
        ["nl"] = "Dutch",
        ["nn"] = "Norwegian Nynorsk",
        ["no"] = "Norwegian",
        ["oc"] = "Occitan",
        ["or"] = "Odia",
        ["pa"] = "Punjabi",
        ["pl"] = "Polish",
        ["ps"] = "Pashto",
        ["pt"] = "Portuguese",
        ["ro"] = "Romanian",
        ["ru"] = "Russian",
        ["sa"] = "Sanskrit",
        ["sd"] = "Sindhi",
        ["si"] = "Sinhala",
        ["sk"] = "Slovak",
        ["sl"] = "Slovenian",
        ["sn"] = "Shona",
        ["so"] = "Somali",
        ["sq"] = "Albanian",
        ["sr"] = "Serbian",
        ["su"] = "Sundanese",
        ["sv"] = "Swedish",
        ["sw"] = "Swahili",
        ["ta"] = "Tamil",
        ["te"] = "Telugu",
        ["tg"] = "Tajik",
        ["th"] = "Thai",
        ["tk"] = "Turkmen",
        ["tl"] = "Tagalog",
        ["tr"] = "Turkish",
        ["tt"] = "Tatar",
        ["uk"] = "Ukrainian",
        ["ur"] = "Urdu",
        ["uz"] = "Uzbek",
        ["vi"] = "Vietnamese",
        ["wo"] = "Wolof",
        ["xh"] = "Xhosa",
        ["yi"] = "Yiddish",
        ["yo"] = "Yoruba",
        ["yue"] = "Cantonese",
        ["zh"] = "Chinese",
        ["zu"] = "Zulu",
    };

    /// <summary>Parakeet v3 (25 European languages).</summary>
    public static readonly IReadOnlyList<string> EuropeanParakeet =
        ["bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fr", "hr", "hu", "it", "lt", "lv", "mt", "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "uk"];

    /// <summary>Built-in Whisper style prompts per language (used as the initial prompt).</summary>
    public static readonly IReadOnlyDictionary<string, string> WhisperStylePrompts = new Dictionary<string, string>
    {
        ["en"] = "Hello, how are you doing? Nice to meet you. One, two, three — let me know.",
        ["hi"] = "नमस्ते, कैसे हैं आप? आपसे मिलकर अच्छा लगा।",
        ["bn"] = "নমস্কার, কেমন আছেন? আপনার সাথে দেখা হয়ে ভালো লাগলো।",
        ["ja"] = "こんにちは、お元気ですか？お会いできて嬉しいです。",
        ["ko"] = "안녕하세요, 잘 지내시나요? 만나서 반갑습니다.",
        ["zh"] = "你好，最近好吗？见到你很高兴。",
        ["th"] = "สวัสดีครับ/ค่ะ, สบายดีไหม? ยินดีที่ได้พบคุณ",
        ["vi"] = "Xin chào, bạn khỏe không? Rất vui được gặp bạn.",
        ["yue"] = "你好，最近點呀？見到你好開心。",
        ["es"] = "¡Hola, ¿cómo estás? Encantado de conocerte.",
        ["fr"] = "Bonjour, comment allez-vous? Ravi de vous rencontrer.",
        ["de"] = "Hallo, wie geht es dir? Schön dich kennenzulernen.",
        ["it"] = "Ciao, come stai? Piacere di conoscerti.",
        ["pt"] = "Olá, como você está? Prazer em conhecê-lo.",
        ["ru"] = "Здравствуйте, как ваши дела? Приятно познакомиться.",
        ["pl"] = "Cześć, jak się masz? Miło cię poznać.",
        ["nl"] = "Hallo, hoe gaat het? Aangenaam kennis te maken.",
        ["tr"] = "Merhaba, nasılsın? Tanıştığımıza memnun oldum.",
        ["ar"] = "مرحباً، كيف حالك؟ سعيد بلقائك.",
        ["fa"] = "سلام، حال شما چطور است؟ از آشنایی با شما خوشوقتم.",
        ["he"] = "שלום, מה שלומך? נעים להכיר.",
        ["ta"] = "வணக்கம், எப்படி இருக்கிறீர்கள்? உங்களை சந்தித்ததில் மகிழ்ச்சி.",
        ["te"] = "నమస్కారం, ఎలా ఉన్నారు? కలవడం చాలా సంతోషం.",
        ["ml"] = "നമസ്കാരം, സുഖമാണോ? കണ്ടതിൽ സന്തോഷം.",
        ["kn"] = "ನಮಸ್ಕಾರ, ಹೇಗಿದ್ದೀರಾ? ನಿಮ್ಮನ್ನು ಭೇಟಿಯಾಗಿ ಸಂತೋಷವಾಗಿದೆ.",
        ["ur"] = "السلام علیکم، کیسے ہیں آپ؟ آپ سے مل کر خوشی ہوئی۔",
        ["default"] = "",
    };

    public static string DisplayName(string code)
    {
        if (code == "auto" || string.IsNullOrEmpty(code)) return "Auto-detect";
        try
        {
            var native = new System.Globalization.CultureInfo(code).NativeName;
            if (!string.IsNullOrWhiteSpace(native) && !native.StartsWith("Unknown")) return All.TryGetValue(code, out var en) ? $"{en} ({native})" : native;
        }
        catch (System.Globalization.CultureNotFoundException) { }
        return All.TryGetValue(code, out var name) ? name : code;
    }

    public static IReadOnlyDictionary<string, string> ForCodes(IEnumerable<string> codes, bool includeAuto = true)
    {
        var d = new Dictionary<string, string>();
        if (includeAuto) d["auto"] = "Auto-detect";
        foreach (var c in codes) d[c] = All.TryGetValue(c, out var n) ? n : c;
        return d;
    }
}
