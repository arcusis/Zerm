using System.Text;
using LLama;
using LLama.Common;
using LLama.Sampling;
using Zerm.Core.Enhancement;
using Zerm.Core.Models;

namespace Zerm.Core.LocalLlm;

public sealed record LocalLlmPackage(
    string Id,
    string FileName,
    string DisplayName,
    string Description,
    long SizeBytes,
    string Url,
    string Sha256,
    bool ForEnhancement,
    bool ForReading,
    string License);

/// <summary>GGUF catalog (LocalLLMModelManager.swift). Pinned revisions and SHA-256 checksums.</summary>
public static class LocalLlmCatalog
{
    public static readonly IReadOnlyList<LocalLlmPackage> Packages =
    [
        new("gemma-4-e2b", "gemma-4-E2B_q4_0-it.gguf", "Gemma 4 E2B", "Default. Fast, multilingual, good at clean-up.", 3_349_516_256,
            "https://huggingface.co/google/gemma-4-E2B-it-qat-q4_0-gguf/resolve/675cff42a74c774d6cb76f76d8eacb49b48c9b93/gemma-4-E2B_q4_0-it.gguf",
            "fa401b55b07ee70a54c6dae3903c783a6e65064312529ea57175cb5f8dec6634", true, true, "Gemma Terms of Use"),
        new("qwen3-4b-instruct", "Qwen3-4B-Instruct-2507-Q4_K_M.gguf", "Qwen3 4B Instruct", "Strong instruction following.", 2_497_280_000,
            "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/a06e946bb6b655725eafa393f4a9745d460374c9/Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
            "3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597", true, false, "Apache-2.0"),
        new("gemma-3-1b", "gemma-3-1b-it-Q4_K_M.gguf", "Gemma 3 1B", "Smallest and fastest; best for Read Aloud on slow PCs.", 806_058_240,
            "https://huggingface.co/unsloth/gemma-3-1b-it-GGUF/resolve/f0b45be0aac41bd6a100a4b5734cad5f67255bfb/gemma-3-1b-it-Q4_K_M.gguf",
            "8270790f3ab69fdfe860b7b64008d9a19986d8df7e407bb018184caa08798ebd", false, true, "Gemma Terms of Use"),
        new("gemma-4-e4b", "gemma-4-E4B-it-Q4_K_M.gguf", "Gemma 4 E4B", "Higher quality reading; needs more RAM.", 5_340_000_000,
            "https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/bfc15c382204943c3a8fff0c750b94ae2364d7a3/gemma-4-E4B-it-Q4_K_M.gguf",
            "85a896a047553e842f25297ee5b031d64ff30147d9c4af17b1e4b394cd1fab87", true, true, "Gemma Terms of Use"),
    ];

    public const string DefaultId = "gemma-4-e2b";

    public static string Directory => System.IO.Directory.CreateDirectory(Path.Combine(AppPaths.Root, "LLMModels")).FullName;
    public static string PathFor(LocalLlmPackage p) => Path.Combine(Directory, p.FileName);
    public static bool IsDownloaded(LocalLlmPackage p) => File.Exists(PathFor(p));
    public static LocalLlmPackage? Find(string? id) => Packages.FirstOrDefault(p => p.Id == id);

    public static DownloadSpec Spec(LocalLlmPackage p) => new(p.Url, PathFor(p), p.Sha256, p.SizeBytes);

    /// <summary>The user's pick if downloaded → default → any downloaded enhancement-capable model.</summary>
    public static LocalLlmPackage? ResolveForEnhancement(string? preferredId) =>
        new[] { Find(preferredId), Find(DefaultId) }.Concat(Packages.Where(p => p.ForEnhancement))
            .FirstOrDefault(p => p != null && p.ForEnhancement && IsDownloaded(p));

    /// <summary>Super Enhancement uses the strongest downloaded local model: Gemma 4 E4B → Qwen3 4B → Gemma 4 E2B.</summary>
    public static readonly string[] SuperPreference = ["gemma-4-e4b", "qwen3-4b-instruct", "gemma-4-e2b"];

    public static LocalLlmPackage? ResolveForSuper(string? preferredId = null)
    {
        var candidates = new[] { Find(preferredId) }.Concat(SuperPreference.Select(Find))
            .Where(p => p != null && p.ForEnhancement && IsDownloaded(p)).Cast<LocalLlmPackage>().Distinct().ToList();
        // Strongest model that fits entirely on the GPU right now; otherwise the strongest one (CPU).
        return candidates.FirstOrDefault(p => LocalLlmEngine.FitsOnGpu(PathFor(p))) ?? candidates.FirstOrDefault();
    }

    public static LocalLlmPackage? ResolveForReading(string? preferredId) =>
        new[] { Find(preferredId), Find(DefaultId) }.Concat(Packages.Where(p => p.ForReading))
            .FirstOrDefault(p => p != null && IsDownloaded(p));
}

/// <summary>
/// llama.cpp through LLamaSharp (CPU). One model stays loaded and is unloaded after 120 s idle.
/// Chat formatting is done here because llama.cpp's built-in matcher does not know every template.
/// </summary>
public sealed class LocalLlmEngine : ILocalLlm, IDisposable
{
    private readonly SemaphoreSlim _gate = new(1, 1);
    private LLamaWeights? _weights;
    private ModelParams? _params;
    private string? _loadedPath;
    private string _family = "chatml";
    private Timer? _idleTimer;

    static LocalLlmEngine()
    {
        // GPU (NVIDIA, AMD, Intel) through Vulkan when available; otherwise the CPU build.
        try
        {
            LLama.Native.NativeLibraryConfig.All
                .WithVulkan(Environment.GetEnvironmentVariable("ZERM_LLM_CPU") != "1")
                .WithAutoFallback(true)
                .WithLogCallback((level, message) =>
                {
                    if (level >= LLama.Native.LLamaLogLevel.Warning) Log.Debug("llama: " + message.TrimEnd());
                });
        }
        catch (Exception ex)
        {
            Log.Warn($"llama native library already configured: {ex.Message}");
        }
    }

    public bool IsModelAvailable(string? modelPath) => modelPath != null && File.Exists(modelPath);

    public async Task PrewarmAsync(string modelPath)
    {
        await _gate.WaitAsync();
        try { EnsureLoaded(modelPath); }
        finally { _gate.Release(); }
    }

    /// <summary>
    /// Loads the model and generates one token so GPU shaders are compiled before the first real request.
    /// The driver caches them per executable, so this is slow only the very first time.
    /// </summary>
    public async Task WarmUpAsync(string modelPath)
    {
        var sw = System.Diagnostics.Stopwatch.StartNew();
        await GenerateAsync(modelPath, "Reply with OK.", "OK?", 1, 0f, CancellationToken.None);
        Log.Info($"Local LLM warm-up took {sw.ElapsedMilliseconds} ms");
    }

    public async Task<string> GenerateAsync(string modelPath, string system, string user, int maxTokens, float temperature, CancellationToken ct)
    {
        await _gate.WaitAsync(ct);
        try
        {
            _idleTimer?.Change(Timeout.Infinite, Timeout.Infinite);
            EnsureLoaded(modelPath);
            var prompt = Format(_family, system, user);
            var executor = new StatelessExecutor(_weights!, _params!);
            var inference = new InferenceParams
            {
                MaxTokens = maxTokens,
                SamplingPipeline = new DefaultSamplingPipeline { Temperature = temperature, TopK = 40, TopP = 0.95f, RepeatPenalty = 1.1f },
                AntiPrompts = StopStrings(_family),
            };
            var sb = new StringBuilder();
            await foreach (var token in executor.InferAsync(prompt, inference, ct))
                sb.Append(token);
            // LLamaSharp stops yielding on cancellation without throwing; a cut-off answer must never
            // be treated as a complete rewrite.
            ct.ThrowIfCancellationRequested();
            var text = sb.ToString();
            foreach (var stop in StopStrings(_family))
                text = text.Replace(stop, "");
            return text.Trim();
        }
        finally
        {
            _idleTimer ??= new Timer(_ => Unload(), null, Timeout.Infinite, Timeout.Infinite);
            _idleTimer.Change(TimeSpan.FromSeconds(120), Timeout.InfiniteTimeSpan);
            _gate.Release();
        }
    }

    private void EnsureLoaded(string modelPath)
    {
        if (_loadedPath == modelPath && _weights != null) return;
        UnloadUnsafe();
        Log.Info($"Loading local LLM {Path.GetFileName(modelPath)}");
        _params = new ModelParams(modelPath)
        {
            ContextSize = 4096,
            GpuLayerCount = GpuLayersFor(modelPath),
            Threads = PowerThrottling.InferenceThreads,
        };
        try
        {
            _weights = LLamaWeights.LoadFromFile(_params);
        }
        catch (Exception ex)
        {
            // Not enough video memory (or a broken driver): run on the CPU instead.
            Log.Warn($"GPU load failed ({ex.Message}); loading on CPU");
            _params.GpuLayerCount = 0;
            _weights = LLamaWeights.LoadFromFile(_params);
        }
        _loadedPath = modelPath;
        GpuMemory.Invalidate();
        _weights.Metadata.TryGetValue("tokenizer.chat_template", out var template);
        _weights.Metadata.TryGetValue("general.architecture", out var arch);
        _family = DetectFamily(template ?? "", arch ?? "");
    }

    /// <summary>Estimated video memory a model needs: weights plus KV cache and compute buffers.</summary>
    public static long GpuBytesNeeded(string modelPath) => (long)(new FileInfo(modelPath).Length * 1.15) + 600L * 1024 * 1024;

    /// <summary>True when the model fits in free video memory (or the amount can't be measured).</summary>
    public static bool FitsOnGpu(string modelPath) =>
        GpuMemory.AvailableBytes() is not { } free || free >= GpuBytesNeeded(modelPath);

    /// <summary>
    /// All layers on the GPU, or none. A partial CPU/GPU split crashed llama.cpp with Gemma on Vulkan
    /// (GGML_ASSERT n_inputs &lt; GGML_SCHED_MAX_SPLIT_INPUTS — a native abort), so it is never used.
    /// </summary>
    public static int GpuLayersFor(string modelPath)
    {
        var free = GpuMemory.AvailableBytes();
        var need = GpuBytesNeeded(modelPath);
        var onGpu = free == null || free >= need;
        Log.Info($"Free VRAM {(free == null ? "unknown" : $"{free / (1024 * 1024)} MB")}, model needs ~{need / (1024 * 1024)} MB → {(onGpu ? "GPU" : "CPU")}");
        return onGpu ? 99 : 0;
    }

    public static string DetectFamily(string template, string arch)
    {
        if (template.Contains("<|turn>")) return "gemma4";
        if (template.Contains("<start_of_turn>") || arch.StartsWith("gemma")) return "gemma";
        if (template.Contains("<|start_header_id|>")) return "llama3";
        return "chatml";
    }

    public static string Format(string family, string system, string user) => family switch
    {
        "gemma4" => $"<|turn>system\n{system.Trim()}<turn|>\n<|turn>user\n{user.Trim()}<turn|>\n<|turn>model\n",
        // Gemma 2/3 templates have no system role: fuse it into the user turn.
        "gemma" => $"<start_of_turn>user\n{system.Trim()}\n\n{user.Trim()}<end_of_turn>\n<start_of_turn>model\n",
        "llama3" => $"<|start_header_id|>system<|end_header_id|>\n\n{system.Trim()}<|eot_id|><|start_header_id|>user<|end_header_id|>\n\n{user.Trim()}<|eot_id|><|start_header_id|>assistant<|end_header_id|>\n\n",
        // ChatML (Qwen); pre-fill an empty think block so thinking variants answer directly.
        _ => $"<|im_start|>system\n{system.Trim()}<|im_end|>\n<|im_start|>user\n{user.Trim()}<|im_end|>\n<|im_start|>assistant\n",
    };

    public static string[] StopStrings(string family) => family switch
    {
        "gemma4" => ["<turn|>", "<|turn>"],
        "gemma" => ["<end_of_turn>", "<start_of_turn>"],
        "llama3" => ["<|eot_id|>"],
        _ => ["<|im_end|>", "<|im_start|>"],
    };

    /// <summary>Frees the loaded model (e.g. before its file is deleted). Safe to call any time.</summary>
    public void UnloadNow()
    {
        _gate.Wait();
        try { UnloadUnsafe(); }
        finally { _gate.Release(); }
    }

    private void Unload()
    {
        if (!_gate.Wait(0)) return;
        try { UnloadUnsafe(); }
        finally { _gate.Release(); }
    }

    private void UnloadUnsafe()
    {
        if (_weights != null) Log.Info("Unloading local LLM");
        _weights?.Dispose();
        _weights = null;
        _loadedPath = null;
        GpuMemory.Invalidate();
    }

    public void Dispose()
    {
        _idleTimer?.Dispose();
        UnloadUnsafe();
    }
}
