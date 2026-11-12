namespace Zerm.Core.Models;

public enum ModelProvider
{
    Whisper, SherpaOnnx, Groq, ElevenLabs, Deepgram, Mistral, Gemini, Soniox, Speechmatics, XAI, OpenAI, AssemblyAI, Gladia, Custom,
}

[Flags]
public enum ModelCapabilities { None = 0, Prompt = 1, Vocabulary = 2, LanguageHint = 4, Streaming = 8, Diarization = 16 }

public enum SherpaFamily { Transducer, NemoTransducer, Moonshine }

public sealed record TranscriptionModel
{
    public required string Name { get; init; }
    public required string DisplayName { get; init; }
    public string Description { get; init; } = "";
    public required ModelProvider Provider { get; init; }
    public IReadOnlyDictionary<string, string> SupportedLanguages { get; init; } = Languages.All;
    public ModelCapabilities Capabilities { get; init; }
    public bool IsHebrewOptimized { get; init; }
    public bool IsRecommended { get; init; }

    // Local models
    public string? DownloadUrl { get; init; }
    public string? Sha256 { get; init; }
    public long SizeBytes { get; init; }
    public double Accuracy { get; init; }
    public double Speed { get; init; }
    public double RamGb { get; init; }
    public SherpaFamily? SherpaFamily { get; init; }
    public string? License { get; init; }
    public string? Creator { get; init; }
    public string? SourceUrl { get; init; }

    // Custom (OpenAI-compatible) models
    public string? CustomEndpoint { get; init; }
    public string? CustomModelId { get; init; }

    public bool IsLocal => Provider is ModelProvider.Whisper or ModelProvider.SherpaOnnx;
    public bool IsMultilingual => SupportedLanguages.Count(kv => kv.Key != "auto") > 1;

    public string ProviderKey => Provider switch
    {
        ModelProvider.XAI => "xAI",
        ModelProvider.SherpaOnnx => "sherpa-onnx",
        _ => Provider.ToString(),
    };

    public bool SupportsLanguage(string? code) => code is null or "auto" or "" || SupportedLanguages.ContainsKey(code);

    /// <summary>The language to send, or null to let the model detect it (unsupported codes are never forced).</summary>
    public string? RequestLanguage(string? selected)
    {
        if (string.IsNullOrEmpty(selected) || selected == "auto") return null;
        if (!SupportedLanguages.ContainsKey(selected)) return null;
        return selected;
    }

    /// <summary>ivrit.ai models: anything other than English is transcribed as Hebrew.</summary>
    public string? TranscriptionLanguage(string? selected)
    {
        if (IsHebrewOptimized && Provider == ModelProvider.Whisper) return selected == "en" ? "en" : "he";
        return RequestLanguage(selected);
    }

    public string LocalPath => Provider switch
    {
        ModelProvider.Whisper => Path.Combine(AppPaths.WhisperModels, Name + ".bin"),
        ModelProvider.SherpaOnnx => Path.Combine(AppPaths.SherpaModels, Name),
        _ => "",
    };

    public bool IsDownloaded => Provider switch
    {
        ModelProvider.Whisper => File.Exists(LocalPath),
        ModelProvider.SherpaOnnx => Directory.Exists(LocalPath) && File.Exists(Path.Combine(LocalPath, "tokens.txt")),
        _ => false,
    };

    public DownloadSpec? Download => DownloadUrl == null
        ? null
        : Provider == ModelProvider.SherpaOnnx
            ? new DownloadSpec(DownloadUrl, Path.Combine(AppPaths.SherpaModels, Name + ".tar.bz2"), Sha256, SizeBytes, LocalPath)
            : new DownloadSpec(DownloadUrl, LocalPath, Sha256, SizeBytes);
}

/// <summary>Port of TranscriptionModelRegistry.swift for Windows (CoreML/Apple-only models replaced by ONNX builds).</summary>
public static class TranscriptionModelRegistry
{
    private const string WhisperCommit = "5359861c739e955e79d9a303bcbc70fb988958b1";
    private const long MB = 1024 * 1024;

    private static readonly IReadOnlyDictionary<string, string> EnglishOnly = new Dictionary<string, string> { ["en"] = "English" };

    private static readonly Dictionary<string, string> WhisperSha = new()
    {
        ["ggml-tiny"] = "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21",
        ["ggml-tiny.en"] = "921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f",
        ["ggml-base"] = "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe",
        ["ggml-base.en"] = "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002",
        ["ggml-small"] = "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b",
        ["ggml-small.en"] = "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d",
        ["ggml-medium"] = "6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208",
        ["ggml-medium.en"] = "cc37e93478338ec7700281a7ac30a10128929eb8f427dda2e865faa8f6da4356",
        ["ggml-large-v2"] = "9a423fe4d40c82774b6af34115b8b935f34152246eb19e80e376071d3f999487",
        ["ggml-large-v2-q5_0"] = "3a214837221e4530dbc1fe8d734f302af393eb30bd0ed046042ebf4baf70f6f2",
        ["ggml-large-v2-q8_0"] = "fef54e6d898246a65c8285bfa83bd1807e27fadf54d5d4e81754c47634737e8c",
        ["ggml-large-v3"] = "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2",
        ["ggml-large-v3-q5_0"] = "d75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1",
        ["ggml-large-v3-turbo-q8_0"] = "317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1",
        ["ggml-medium-q5_0"] = "19fea4b380c3a618ec4723c3eef2eb785ffba0d0538cf43f8f235e7b3b34220f",
        ["ggml-medium-q8_0"] = "42a1ffcbe4167d224232443396968db4d02d4e8e87e213d3ee2e03095dea6502",
        ["ggml-medium.en-q5_0"] = "76733e26ad8fe1c7a5bf7531a9d41917b2adc0f20f2e4f5531688a8c6cd88eb0",
        ["ggml-medium.en-q8_0"] = "43fa2cd084de5a04399a896a9a7a786064e221365c01700cea4666005218f11c",
        ["ggml-tiny-q8_0"] = "c2085835d3f50733e2ff6e4b41ae8a2b8d8110461e18821b09a15c40c42d1cca",
        ["ggml-tiny.en-q8_0"] = "5bc2b3860aa151a4c6e7bb095e1fcce7cf12c7b020ca08dcec0c6d018bb7dd94",
        ["ggml-base-q8_0"] = "c577b9a86e7e048a0b7eada054f4dd79a56bbfa911fbdacf900ac5b567cbb7d9",
        ["ggml-base.en-q8_0"] = "a4d4a0768075e13cfd7e19df3ae2dbc4a68d37d36a7dad45e8410c9a34f8c87e",
        ["ggml-small-q8_0"] = "49c8fb02b65e6049d5fa6c04f81f53b867b5ec9540406812c643f177317f779f",
        ["ggml-small.en-q8_0"] = "67a179f608ea6114bd3fdb9060e762b588a3fb3bd00c4387971be4d177958067",
        ["ggml-large-v3-turbo"] = "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
        ["ggml-large-v3-turbo-q5_0"] = "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
    };

    private static TranscriptionModel Whisper(string name, string display, long sizeMb, bool englishOnly, double acc, double speed, double ram,
        string? description = null, bool recommended = false)
    {
        var langs = englishOnly ? EnglishOnly : Languages.All;
        return new TranscriptionModel
        {
            Name = name,
            DisplayName = display,
            Description = description ?? (englishOnly ? "English-only Whisper model." : "Multilingual Whisper model (99 languages)."),
            Provider = ModelProvider.Whisper,
            SupportedLanguages = langs,
            Capabilities = ModelCapabilities.Prompt | ModelCapabilities.Vocabulary | (englishOnly ? 0 : ModelCapabilities.LanguageHint),
            DownloadUrl = $"https://huggingface.co/ggerganov/whisper.cpp/resolve/{WhisperCommit}/{name}.bin",
            Sha256 = WhisperSha.GetValueOrDefault(name),
            SizeBytes = sizeMb * MB,
            Accuracy = acc,
            Speed = speed,
            RamGb = ram,
            License = "MIT",
            Creator = "OpenAI (converted by ggml-org)",
            SourceUrl = "https://github.com/openai/whisper/blob/main/model-card.md",
            IsRecommended = recommended,
        };
    }

    private static readonly IReadOnlyDictionary<string, string> HebrewEnglish =
        new Dictionary<string, string> { ["auto"] = "Auto-detect", ["he"] = "Hebrew", ["en"] = "English" };

    public static readonly IReadOnlyList<TranscriptionModel> Local =
    [
        new TranscriptionModel
        {
            Name = "parakeet-tdt-0.6b-v3", DisplayName = "Parakeet V3",
            Description = "NVIDIA Parakeet TDT v3 (ONNX). Very fast on CPU, 25 European languages, detects the language automatically.",
            Provider = ModelProvider.SherpaOnnx, SherpaFamily = Models.SherpaFamily.NemoTransducer,
            SupportedLanguages = Languages.ForCodes(Languages.EuropeanParakeet),
            DownloadUrl = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2",
            Sha256 = "5793d0fd397c5778d2cf2126994d58e9d56b1be7c04d13c7a15bb1b4eafb16bf", SizeBytes = 487_170_055,
            Accuracy = 0.94, Speed = 0.95, RamGb = 1.0, License = "CC-BY-4.0", Creator = "NVIDIA (ONNX export by k2-fsa)",
            SourceUrl = "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3", IsRecommended = true,
        },
        new TranscriptionModel
        {
            Name = "parakeet-tdt-0.6b-v2", DisplayName = "Parakeet TDT v2",
            Description = "NVIDIA Parakeet TDT v2 (ONNX). English only, excellent accuracy and speed on CPU.",
            Provider = ModelProvider.SherpaOnnx, SherpaFamily = Models.SherpaFamily.NemoTransducer, SupportedLanguages = EnglishOnly,
            DownloadUrl = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8.tar.bz2",
            Sha256 = "157c157bc51155e03e37d2466522a3a737dd9c72bb25f36eb18912964161e1ad", SizeBytes = 482_468_385,
            Accuracy = 0.95, Speed = 0.95, RamGb = 1.0, License = "CC-BY-4.0", Creator = "NVIDIA (ONNX export by k2-fsa)",
            SourceUrl = "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2",
        },
        Whisper("ggml-large-v3-turbo", "Large v3 Turbo", 1600, false, .97, .75, 1.8, "Best multilingual accuracy, including Hebrew.", recommended: true),
        Whisper("ggml-large-v3-turbo-q5_0", "Large v3 Turbo Q5_0", 574, false, .95, .75, 1.0, "Quantized Large v3 Turbo — near-full accuracy at a third of the size."),
        Whisper("ggml-large-v3-turbo-q8_0", "Large v3 Turbo Q8_0", 874, false, .96, .75, 1.35),
        new TranscriptionModel
        {
            Name = "ivrit-large-v3-turbo", DisplayName = "ivrit.ai Large v3 Turbo",
            Description = "Whisper fine-tuned for Hebrew by ivrit.ai. Hebrew and English.",
            Provider = ModelProvider.Whisper, SupportedLanguages = HebrewEnglish, IsHebrewOptimized = true, IsRecommended = true,
            Capabilities = ModelCapabilities.Prompt | ModelCapabilities.Vocabulary | ModelCapabilities.LanguageHint,
            DownloadUrl = "https://huggingface.co/ivrit-ai/whisper-large-v3-turbo-ggml/resolve/2130c78e4a9cb4914cc4df91a1c3031407789705/ggml-model.bin",
            Sha256 = "c8090411113357097bfafc2b8e228ec1639fa7f5fe4ecb5d054ac0ccef8641b1", SizeBytes = 1600 * MB,
            Accuracy = .96, Speed = .75, RamGb = 1.8, License = "Apache-2.0", Creator = "ivrit.ai",
            SourceUrl = "https://huggingface.co/ivrit-ai/whisper-large-v3-turbo-ggml",
        },
        new TranscriptionModel
        {
            Name = "ivrit-large-v3", DisplayName = "ivrit.ai Large v3",
            Description = "Highest-accuracy Hebrew model from ivrit.ai. Slower; needs about 3 GB of RAM.",
            Provider = ModelProvider.Whisper, SupportedLanguages = HebrewEnglish, IsHebrewOptimized = true,
            Capabilities = ModelCapabilities.Prompt | ModelCapabilities.Vocabulary | ModelCapabilities.LanguageHint,
            DownloadUrl = "https://huggingface.co/ivrit-ai/whisper-large-v3-ggml/resolve/9ead614052ce13dfe5f8d0f6cd3e36787a9cf60c/ggml-model.bin",
            Sha256 = "09e66ec67b2e00c6933afab6684cbf78fe023e8ad153c1848f62000e4335a07f", SizeBytes = 3100 * MB,
            Accuracy = .97, Speed = .5, RamGb = 3.1, License = "Apache-2.0", Creator = "ivrit.ai",
            SourceUrl = "https://huggingface.co/ivrit-ai/whisper-large-v3-ggml",
        },
        Whisper("ggml-large-v3", "Whisper Large v3", 3100, false, .94, .55, 1.95),
        Whisper("ggml-large-v3-q5_0", "Whisper Large v3 Q5_0", 1100, false, .92, .65, 1.15),
        Whisper("ggml-large-v2", "Whisper Large v2", 3100, false, .92, .55, 1.95),
        Whisper("ggml-large-v2-q5_0", "Whisper Large v2 Q5_0", 1100, false, .90, .65, 1.15),
        Whisper("ggml-large-v2-q8_0", "Whisper Large v2 Q8_0", 1700, false, .91, .6, 1.5),
        Whisper("ggml-medium", "Whisper Medium", 1500, false, .87, .7, 1.2),
        Whisper("ggml-medium-q5_0", "Whisper Medium Q5_0", 539, false, .85, .75, .95),
        Whisper("ggml-medium-q8_0", "Whisper Medium Q8_0", 823, false, .86, .72, 1.15),
        Whisper("ggml-medium.en", "Whisper Medium English", 1500, true, .89, .7, 1.2),
        Whisper("ggml-medium.en-q5_0", "Whisper Medium English Q5_0", 539, true, .87, .75, .95),
        Whisper("ggml-medium.en-q8_0", "Whisper Medium English Q8_0", 823, true, .88, .72, 1.15),
        Whisper("ggml-small", "Whisper Small", 466, false, .78, .85, .7),
        Whisper("ggml-small-q8_0", "Whisper Small Q8_0", 264, false, .77, .88, .55),
        Whisper("ggml-small.en", "Whisper Small English", 466, true, .80, .85, .7),
        Whisper("ggml-small.en-q8_0", "Whisper Small English Q8_0", 264, true, .79, .88, .55),
        Whisper("ggml-base", "Whisper Base", 142, false, .66, .95, .4),
        Whisper("ggml-base-q8_0", "Whisper Base Q8_0", 82, false, .65, .97, .3),
        Whisper("ggml-base.en", "Whisper Base English", 142, true, .68, .95, .4),
        Whisper("ggml-base.en-q8_0", "Whisper Base English Q8_0", 82, true, .67, .97, .3),
        Whisper("ggml-tiny", "Whisper Tiny", 75, false, .56, 1.0, .3),
        Whisper("ggml-tiny-q8_0", "Whisper Tiny Q8_0", 44, false, .55, 1.0, .25),
        Whisper("ggml-tiny.en", "Whisper Tiny English", 75, true, .58, 1.0, .3),
        Whisper("ggml-tiny.en-q8_0", "Whisper Tiny English Q8_0", 44, true, .57, 1.0, .25),
        Whisper("ggml-distil-large-v3", "Distil-Whisper Large v3", 1500, true, .91, .82, 1.1, "Distilled Large v3: English, faster.") with
        {
            DownloadUrl = "https://huggingface.co/distil-whisper/distil-large-v3-ggml/resolve/0d78dd96ed9fc152325f63b53788fec3b43de031/ggml-distil-large-v3.bin",
            Sha256 = "2883a11b90fb10ed592d826edeaee7d2929bf1ab985109fe9e1e7b4d2b69a298",
            Creator = "Hugging Face (distil-whisper)",
            SourceUrl = "https://huggingface.co/distil-whisper/distil-large-v3",
        },
        new TranscriptionModel
        {
            Name = "sherpa-moonshine-tiny-en", DisplayName = "Moonshine Tiny EN", Description = "Tiny, very fast English model.",
            Provider = ModelProvider.SherpaOnnx, SherpaFamily = Models.SherpaFamily.Moonshine, SupportedLanguages = EnglishOnly,
            DownloadUrl = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-moonshine-tiny-en-int8.tar.bz2",
            Sha256 = "d5fe6ec4334fef36255b2a4010412cad4c007e33103fec62fb5d17cad88086f2", SizeBytes = 103 * MB,
            Accuracy = .7, Speed = 1.0, RamGb = .3, License = "MIT", Creator = "Useful Sensors",
        },
        new TranscriptionModel
        {
            Name = "sherpa-moonshine-base-en", DisplayName = "Moonshine Base EN", Description = "Small, fast English model.",
            Provider = ModelProvider.SherpaOnnx, SherpaFamily = Models.SherpaFamily.Moonshine, SupportedLanguages = EnglishOnly,
            DownloadUrl = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-moonshine-base-en-int8.tar.bz2",
            Sha256 = "21870cecaa2e44e4e2bf63e02d1072bed183ccd10284871353bd9d24dad14e5e", SizeBytes = 239 * MB,
            Accuracy = .78, Speed = .95, RamGb = .5, License = "MIT", Creator = "Useful Sensors",
        },
        new TranscriptionModel
        {
            Name = "sherpa-zipformer-ru-vosk-int8", DisplayName = "Zipformer Russian", Description = "Compact Russian model (Vosk).",
            Provider = ModelProvider.SherpaOnnx, SherpaFamily = Models.SherpaFamily.Transducer,
            SupportedLanguages = new Dictionary<string, string> { ["auto"] = "Auto-detect", ["ru"] = "Russian" },
            DownloadUrl = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-zipformer-ru-int8-2025-04-20.tar.bz2",
            Sha256 = "d6a651569aacc9a177259fa54705dd76acae23f6a4d62ea6797bd220d4b57163", SizeBytes = 58 * MB,
            Accuracy = .85, Speed = .95, RamGb = .3, License = "Apache-2.0", Creator = "Alpha Cephei (Vosk)",
        },
    ];

    private static readonly ModelCapabilities PVL = ModelCapabilities.Prompt | ModelCapabilities.Vocabulary | ModelCapabilities.LanguageHint;
    private static readonly ModelCapabilities VLD = ModelCapabilities.Vocabulary | ModelCapabilities.LanguageHint | ModelCapabilities.Diarization;

    public static readonly IReadOnlyList<TranscriptionModel> Cloud =
    [
        new() { Name = "whisper-large-v3-turbo", DisplayName = "Whisper Large v3 Turbo (Groq)", Provider = ModelProvider.Groq, Capabilities = PVL, IsRecommended = true,
                Description = "Whisper Large v3 Turbo on Groq — extremely fast." },
        new() { Name = "whisper-large-v3", DisplayName = "Whisper Large v3 (Groq)", Provider = ModelProvider.Groq, Capabilities = PVL, Description = "Whisper Large v3 on Groq." },
        new() { Name = "gpt-transcribe", DisplayName = "GPT Transcribe (OpenAI)", Provider = ModelProvider.OpenAI, Capabilities = PVL, Description = "OpenAI's transcription model." },
        new() { Name = "scribe_v2", DisplayName = "Scribe V2 (ElevenLabs)", Provider = ModelProvider.ElevenLabs, Capabilities = VLD | ModelCapabilities.Streaming, Description = "ElevenLabs Scribe." },
        new() { Name = "nova-3", DisplayName = "Nova 3 (Deepgram)", Provider = ModelProvider.Deepgram, Capabilities = VLD | ModelCapabilities.Streaming, Description = "Deepgram Nova 3, multilingual." },
        new() { Name = "nova-3-medical", DisplayName = "Nova 3 Medical (Deepgram)", Provider = ModelProvider.Deepgram, Capabilities = ModelCapabilities.Vocabulary | ModelCapabilities.Diarization,
                SupportedLanguages = Languages.ForCodes(["en", "en-US", "en-AU", "en-CA", "en-GB", "en-IE", "en-IN", "en-NZ"], false), Description = "Deepgram Nova 3 tuned for medical vocabulary." },
        new() { Name = "voxtral-mini-2602", DisplayName = "Voxtral Mini Transcribe 2 (Mistral)", Provider = ModelProvider.Mistral, Capabilities = VLD,
                SupportedLanguages = Languages.ForCodes(["ar", "de", "en", "es", "fr", "hi", "it", "ja", "ko", "nl", "pt", "ru", "zh"]), Description = "Mistral Voxtral transcription." },
        new() { Name = "grok-stt", DisplayName = "Grok (xAI)", Provider = ModelProvider.XAI, Capabilities = VLD | ModelCapabilities.Streaming,
                SupportedLanguages = Languages.ForCodes(["ar", "cs", "da", "nl", "en", "fil", "fr", "de", "hi", "id", "it", "ja", "ko", "mk", "ms", "fa", "pl", "pt", "ro", "ru", "es", "sv", "th", "tr", "vi"]),
                Description = "xAI speech-to-text." },
        new() { Name = "stt-async-v5", DisplayName = "Soniox V5", Provider = ModelProvider.Soniox, Capabilities = PVL | ModelCapabilities.Diarization, IsHebrewOptimized = true,
                Description = "Soniox asynchronous transcription; strong Hebrew." },
        new() { Name = "universal-3-5-pro", DisplayName = "Universal 3.5 Pro (AssemblyAI)", Provider = ModelProvider.AssemblyAI, Capabilities = VLD, IsHebrewOptimized = true, IsRecommended = true,
                Description = "AssemblyAI's flagship model." },
        new() { Name = "universal-2", DisplayName = "Universal 2 (AssemblyAI)", Provider = ModelProvider.AssemblyAI, Capabilities = VLD, Description = "AssemblyAI Universal 2." },
        new() { Name = "solaria-1", DisplayName = "Solaria (Gladia)", Provider = ModelProvider.Gladia, Capabilities = ModelCapabilities.LanguageHint | ModelCapabilities.Diarization,
                Description = "Gladia Solaria." },
        new() { Name = "gemini-2.5-flash", DisplayName = "Gemini 2.5 Flash (Gemini)", Provider = ModelProvider.Gemini, Capabilities = VLD, IsHebrewOptimized = true,
                Description = "Transcription with Google Gemini." },
        new() { Name = "speechmatics-enhanced", DisplayName = "Speechmatics", Provider = ModelProvider.Speechmatics, Capabilities = VLD, Description = "Speechmatics batch transcription (enhanced)." },
    ];

    public static IEnumerable<TranscriptionModel> All(IEnumerable<TranscriptionModel>? custom = null) =>
        Local.Concat(Cloud).Concat(custom ?? []);

    public static TranscriptionModel? Find(string? name, IEnumerable<TranscriptionModel>? custom = null) =>
        All(custom).FirstOrDefault(m => m.Name == name);

    /// <summary>Saved names of retired cloud models are remapped (RetiredCloudTranscriptionMigration.swift).</summary>
    public static string MigrateName(string name) => name switch
    {
        "gpt-4o-transcribe" or "gpt-4o-mini-transcribe" => "gpt-transcribe",
        "voxtral-mini-latest" => "voxtral-mini-2602",
        _ => name,
    };

    public static TranscriptionModel CustomModel(Guid id, string displayName, string endpoint, string modelId, bool multilingual = true) => new()
    {
        Name = $"custom-{id}",
        DisplayName = displayName,
        Provider = ModelProvider.Custom,
        Capabilities = ModelCapabilities.Prompt | ModelCapabilities.Vocabulary | ModelCapabilities.LanguageHint,
        SupportedLanguages = multilingual ? Languages.All : EnglishOnly,
        CustomEndpoint = endpoint,
        CustomModelId = modelId,
        Description = endpoint,
    };
}
