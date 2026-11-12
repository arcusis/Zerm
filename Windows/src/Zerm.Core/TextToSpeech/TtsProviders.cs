using System.Runtime.InteropServices.WindowsRuntime;
using System.Text.Json.Nodes;
using SherpaOnnx;
using NAudio.Wave;
using Zerm.Core.Models;
using Zerm.Core.Net;
using Zerm.Core.Settings;

namespace Zerm.Core.TextToSpeech;

public sealed record TtsVoice(string Id, string Name, string Language = "en", string? Detail = null)
{
    public override string ToString() => Detail == null ? Name : $"{Name} — {Detail}";
}

public sealed record PcmAudio(float[] Samples, int SampleRate);

public interface ITtsProvider
{
    string Name { get; }
    bool RequiresApiKey { get; }
    bool IsMultilingual { get; }
    IReadOnlyList<TtsVoice> Voices { get; }
    Task<PcmAudio> SynthesizeAsync(string text, string voiceId, double speed, CancellationToken ct);
}

public static class Pcm
{
    public static float[] FromS16Le(byte[] bytes, int offset = 0)
    {
        var count = (bytes.Length - offset) / 2;
        var samples = new float[count];
        for (var i = 0; i < count; i++)
            samples[i] = (short)(bytes[offset + i * 2] | (bytes[offset + i * 2 + 1] << 8)) / 32768f;
        return samples;
    }

    /// <summary>Returns (samples, rate) from a RIFF WAV byte array (data chunk only).</summary>
    public static PcmAudio FromWav(byte[] wav)
    {
        using var ms = new MemoryStream(wav);
        using var reader = new NAudio.Wave.WaveFileReader(ms);
        var provider = reader.ToSampleProvider();
        var channels = reader.WaveFormat.Channels;
        var list = new List<float>((int)(reader.SampleCount));
        var buffer = new float[reader.WaveFormat.SampleRate * channels];
        int read;
        while ((read = provider.Read(buffer.AsSpan())) > 0)
        {
            for (var i = 0; i < read; i += channels)
            {
                float sum = 0;
                for (var c = 0; c < channels; c++) sum += buffer[i + c];
                list.Add(sum / channels);
            }
        }
        return new PcmAudio([.. list], reader.WaveFormat.SampleRate);
    }
}

/// <summary>Windows OneCore / SAPI voices through WinRT (no download, works offline; includes Hebrew when installed).</summary>
public sealed class WindowsVoicesProvider : ITtsProvider
{
    public string Name => "Windows";
    public bool RequiresApiKey => false;
    public bool IsMultilingual => true;

    public IReadOnlyList<TtsVoice> Voices
    {
        get
        {
            try
            {
                var current = System.Globalization.CultureInfo.CurrentUICulture.TwoLetterISOLanguageName;
                return Windows.Media.SpeechSynthesis.SpeechSynthesizer.AllVoices
                    .Select(v => new TtsVoice(v.Id, v.DisplayName, v.Language.Split('-')[0], v.Language))
                    .OrderBy(v => v.Language == current ? 0 : v.Language == "he" ? 1 : v.Language == "en" ? 2 : 3)
                    .ThenBy(v => v.Name)
                    .ToList();
            }
            catch (Exception ex)
            {
                Log.Error("Could not list Windows voices", ex);
                return [];
            }
        }
    }

    public async Task<PcmAudio> SynthesizeAsync(string text, string voiceId, double speed, CancellationToken ct)
    {
        using var synth = new Windows.Media.SpeechSynthesis.SpeechSynthesizer();
        var voice = Windows.Media.SpeechSynthesis.SpeechSynthesizer.AllVoices.FirstOrDefault(v => v.Id == voiceId)
                    ?? Windows.Media.SpeechSynthesis.SpeechSynthesizer.DefaultVoice;
        if (voice != null) synth.Voice = voice;
        synth.Options.SpeakingRate = Math.Clamp(speed, 0.5, 6.0);
        using var stream = await synth.SynthesizeTextToStreamAsync(text).AsTask(ct);
        var bytes = new byte[stream.Size];
        await stream.ReadAsync(bytes.AsBuffer(), (uint)stream.Size, Windows.Storage.Streams.InputStreamOptions.None).AsTask(ct);
        return Pcm.FromWav(bytes);
    }
}

/// <summary>Kokoro v0.19 through sherpa-onnx (English, offline, ~330 MB).</summary>
public sealed class KokoroProvider : ITtsProvider, IDisposable
{
    public const string ArchiveUrl = "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-en-v0_19.tar.bz2";
    public const string ArchiveSha256 = "912804855a04745fa77a30be545b3f9a5d15c4d66db00b88cbcd4921df605ac7";
    public const long ArchiveSize = 319_625_534;

    private OfflineTts? _tts;
    private readonly object _gate = new();

    public string Name => "Kokoro";
    public bool RequiresApiKey => false;
    public bool IsMultilingual => false;

    public static string ModelDir => Path.Combine(AppPaths.TtsModels, "kokoro-en-v0_19");
    public static bool IsDownloaded => File.Exists(Path.Combine(ModelDir, "model.onnx")) && File.Exists(Path.Combine(ModelDir, "voices.bin"));
    public static DownloadSpec Download => new(ArchiveUrl, Path.Combine(AppPaths.TtsModels, "kokoro-en-v0_19.tar.bz2"), ArchiveSha256, ArchiveSize, ModelDir);

    public IReadOnlyList<TtsVoice> Voices { get; } =
    [
        new("1", "Bella", "en", "American, female"),
        new("3", "Sarah", "en", "American, female"),
        new("4", "Sky", "en", "American, female"),
        new("5", "Adam", "en", "American, male"),
        new("6", "Michael", "en", "American, male"),
        new("7", "Emma", "en", "British, female"),
        new("8", "Isabella", "en", "British, female"),
        new("9", "George", "en", "British, male"),
        new("10", "Lewis", "en", "British, male"),
    ];

    private OfflineTts Engine()
    {
        lock (_gate)
        {
            if (_tts != null) return _tts;
            if (!IsDownloaded) throw new TtsUnavailableException("Download the Kokoro voice model in Read Aloud settings.");
            var config = new OfflineTtsConfig();
            config.Model.Kokoro.Model = Path.Combine(ModelDir, "model.onnx");
            config.Model.Kokoro.Voices = Path.Combine(ModelDir, "voices.bin");
            config.Model.Kokoro.Tokens = Path.Combine(ModelDir, "tokens.txt");
            config.Model.Kokoro.DataDir = Path.Combine(ModelDir, "espeak-ng-data");
            config.Model.Kokoro.LengthScale = 1.0f;
            config.Model.NumThreads = PowerThrottling.InferenceThreads;
            config.Model.Provider = "cpu";
            config.MaxNumSentences = 1;
            _tts = new OfflineTts(config);
            return _tts;
        }
    }

    public Task<PcmAudio> SynthesizeAsync(string text, string voiceId, double speed, CancellationToken ct) => Task.Run(() =>
    {
        ct.ThrowIfCancellationRequested();
        var engine = Engine();
        var sid = int.TryParse(voiceId, out var v) ? v : 1;
        lock (_gate)
        {
            var audio = engine.Generate(text, (float)Math.Clamp(speed, 0.5, 2.0), sid);
            return new PcmAudio(audio.Samples, audio.SampleRate);
        }
    }, ct);

    public void Dispose() => _tts?.Dispose();
}

/// <summary>Cloud TTS providers (TTSProvider implementations in TextToSpeech/Providers). All return 24 kHz PCM.</summary>
public sealed class CloudTtsProvider(string name, Func<string?> apiKey) : ITtsProvider
{
    public string Name { get; } = name;
    public bool RequiresApiKey => true;
    public bool IsMultilingual => Name is not ("Deepgram");

    public IReadOnlyList<TtsVoice> Voices => Name switch
    {
        "Deepgram" =>
        [
            new("aura-2-thalia-en", "Thalia", "en", "clear, confident"), new("aura-2-andromeda-en", "Andromeda", "en", "casual, expressive"),
            new("aura-2-helena-en", "Helena", "en", "caring, warm"), new("aura-2-apollo-en", "Apollo", "en", "confident, comfortable"),
            new("aura-2-arcas-en", "Arcas", "en", "natural, smooth"), new("aura-2-aries-en", "Aries", "en", "warm, energetic"),
            new("aura-2-orion-en", "Orion", "en", "approachable, calm"), new("aura-2-luna-en", "Luna", "en", "friendly, natural"),
        ],
        "ElevenLabs" =>
        [
            new("21m00Tcm4TlvDq8ikWAM", "Rachel"), new("EXAVITQu4vr4xnSDxMaL", "Bella"), new("AZnzlk1XvdvUeBnXmlld", "Domi"),
            new("XB0fDUnXU5powFXDhCwa", "Charlotte"), new("pNInz6obpgDQGcFmaJgB", "Adam"), new("ErXwobaYiN019PkySvjV", "Antoni"),
            new("TxGEqnHWrfWFTfGW9XjX", "Josh"), new("VR6AewLTigWG4xSOukaG", "Arnold"),
        ],
        "Gemini" => new[] { "Kore", "Puck", "Charon", "Aoede", "Fenrir", "Leda", "Orus", "Zephyr", "Callirrhoe", "Enceladus" }
            .Select(v => new TtsVoice(v, v)).ToList(),
        "OpenAI" => new[] { "alloy", "ash", "ballad", "coral", "echo", "fable", "nova", "onyx", "sage", "shimmer", "verse", "marin", "cedar" }
            .Select(v => new TtsVoice(v, char.ToUpper(v[0]) + v[1..])).ToList(),
        "Cartesia" =>
        [
            new("f786b574-daa5-4673-aa0c-cbe3e8534c02", "Katie"), new("db6b0ed5-d5d3-463d-ae85-518a07d3c2b4", "Skylar"),
            new("a5136bf9-224c-4d76-b823-52bd5efcffcc", "Jameson"), new("62ae83ad-4f6a-430b-af41-a9bede9286ca", "Gemma (UK)"),
            new("ef191366-f52f-447a-a398-ed8c0f2943a1", "Archie (UK)"),
        ],
        "Inworld" => new[] { "Ashley", "Dennis", "Mark", "Olivia", "Sarah", "Theodore", "Elizabeth", "Edward", "Hades", "Pixie" }
            .Select(v => new TtsVoice(v, v)).ToList(),
        _ => [],
    };

    public async Task<PcmAudio> SynthesizeAsync(string text, string voiceId, double speed, CancellationToken ct)
    {
        var key = apiKey() ?? throw new TtsUnavailableException($"Add an API key for {Name} in Read Aloud settings");
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(TimeSpan.FromSeconds(30));
        var token = cts.Token;
        switch (Name)
        {
            case "Deepgram":
            {
                var req = Http.Json(HttpMethod.Post, $"https://api.deepgram.com/v1/speak?model={voiceId}&encoding=linear16&sample_rate=24000&container=none",
                    new { text }).Header("Authorization", "Token " + key);
                return new PcmAudio(Pcm.FromS16Le(await Http.SendForBytesAsync(req, token)), 24000);
            }
            case "ElevenLabs":
            {
                var req = Http.Json(HttpMethod.Post, $"https://api.elevenlabs.io/v1/text-to-speech/{voiceId}?output_format=pcm_24000",
                    new { text, model_id = "eleven_v3" }).Header("xi-api-key", key);
                return new PcmAudio(Pcm.FromS16Le(await Http.SendForBytesAsync(req, token)), 24000);
            }
            case "OpenAI":
            {
                var req = Http.Json(HttpMethod.Post, "https://api.openai.com/v1/audio/speech",
                    new { model = "gpt-4o-mini-tts", input = text, voice = voiceId, response_format = "pcm", speed = Math.Clamp(speed, 0.25, 4) }).Bearer(key);
                return new PcmAudio(Pcm.FromS16Le(await Http.SendForBytesAsync(req, token)), 24000);
            }
            case "Gemini":
            {
                var body = new JsonObject
                {
                    ["contents"] = new JsonArray(new JsonObject { ["parts"] = new JsonArray(new JsonObject { ["text"] = text }) }),
                    ["generationConfig"] = new JsonObject
                    {
                        ["responseModalities"] = new JsonArray("AUDIO"),
                        ["speechConfig"] = new JsonObject { ["voiceConfig"] = new JsonObject { ["prebuiltVoiceConfig"] = new JsonObject { ["voiceName"] = voiceId } } },
                    },
                };
                var req = Http.Json(HttpMethod.Post, "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-tts:generateContent", body)
                    .Header("x-goog-api-key", key);
                var json = await Http.SendForJsonAsync(req, token);
                var data = json["candidates"]?[0]?["content"]?["parts"]?[0]?["inlineData"]?["data"]?.GetValue<string>()
                           ?? throw new ApiException(null, "Gemini returned no audio");
                return new PcmAudio(Pcm.FromS16Le(Convert.FromBase64String(data)), 24000);
            }
            case "Cartesia":
            {
                var body = new JsonObject
                {
                    ["model_id"] = "sonic-3.5",
                    ["transcript"] = text,
                    ["voice"] = new JsonObject { ["mode"] = "id", ["id"] = voiceId },
                    ["output_format"] = new JsonObject { ["container"] = "raw", ["encoding"] = "pcm_s16le", ["sample_rate"] = 24000 },
                };
                var req = Http.Json(HttpMethod.Post, "https://api.cartesia.ai/tts/bytes", body)
                    .Header("X-API-Key", key).Header("Cartesia-Version", "2025-04-16");
                return new PcmAudio(Pcm.FromS16Le(await Http.SendForBytesAsync(req, token)), 24000);
            }
            case "Inworld":
            {
                var body = new JsonObject
                {
                    ["text"] = text,
                    ["voiceId"] = voiceId,
                    ["modelId"] = "inworld-tts-1.5-mini",
                    ["audioConfig"] = new JsonObject { ["audioEncoding"] = "LINEAR16", ["sampleRateHertz"] = 24000 },
                };
                var req = Http.Json(HttpMethod.Post, "https://api.inworld.ai/tts/v1/voice", body).Header("Authorization", "Basic " + key);
                var json = await Http.SendForJsonAsync(req, token);
                var wav = Convert.FromBase64String(json["audioContent"]?.GetValue<string>() ?? throw new ApiException(null, "Inworld returned no audio"));
                return wav.Length > 12 && wav[0] == 'R' && wav[1] == 'I' ? Pcm.FromWav(wav) : new PcmAudio(Pcm.FromS16Le(wav), 24000);
            }
            default:
                throw new NotSupportedException(Name);
        }
    }
}

public static class TtsProviders
{
    public static readonly IReadOnlyList<string> Names = ["Windows", "Kokoro", "Deepgram", "Inworld", "ElevenLabs", "Gemini", "OpenAI", "Cartesia"];

    public static bool IsCloud(string name) => name is not ("Windows" or "Kokoro");

    /// <summary>Key id used by <see cref="SecretStore"/> for a TTS provider.</summary>
    public static string KeyProvider(string name) => name;
}
