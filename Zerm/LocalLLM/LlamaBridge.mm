#import "LlamaBridge.h"
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wquoted-include-in-framework-header"
#pragma clang diagnostic ignored "-Wdocumentation"
#import <llama/llama.h>
#pragma clang diagnostic pop
#import <os/log.h>

#include <algorithm>
#include <string>
#include <vector>

namespace {
/// Reasoning-block markers shared by the Qwen3 family. `kReasoningPrefill` reproduces exactly
/// what the model's own chat template emits for `enable_thinking=false`.
const std::string kReasoningOpen = "<think>";
const std::string kReasoningClose = "</think>";
const std::string kReasoningPrefill = "<think>\n\n</think>\n\n";
}

@implementation LlamaBridge {
    std::string _modelPath;
    llama_model   * _model;
    llama_context * _ctx;
    const llama_vocab * _vocab;
    llama_sampler * _sampler;
    int _contextSize;
    int _threadCount;
    BOOL _disablesThinking;
    /// Prompt tokens still resident in the KV cache from the previous request, so an identical
    /// system prefix is not recomputed on every dictation. See `generateWithSystem:`.
    std::vector<llama_token> _cachedPrompt;
}

@synthesize disablesThinking = _disablesThinking;

- (instancetype)initWithModelPath:(NSString *)modelPath
                       contextSize:(int)contextSize
                       threadCount:(int)threadCount {
    return [self initWithModelPath:modelPath
                       contextSize:contextSize
                       threadCount:threadCount
                  disablesThinking:NO];
}

- (instancetype)initWithModelPath:(NSString *)modelPath
                       contextSize:(int)contextSize
                       threadCount:(int)threadCount
                  disablesThinking:(BOOL)disablesThinking {
    if ((self = [super init])) {
        _modelPath = std::string(modelPath.UTF8String);
        _model = nullptr;
        _ctx = nullptr;
        _vocab = nullptr;
        _sampler = nullptr;
        _contextSize = std::max(2048, contextSize);
        _threadCount = std::max(1, threadCount);
        _disablesThinking = disablesThinking;
    }
    return self;
}

- (void)dealloc {
    if (_sampler) llama_sampler_free(_sampler);
    if (_ctx)     llama_free(_ctx);
    if (_model)   llama_model_free(_model);
}

- (BOOL)load {
    if (_model) return YES;

    // llama.cpp's global backend must be initialized exactly once per process.
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Disable Metal residency sets: their collection is freed by a C++ static destructor at
        // process exit, which races with its own background init and aborts (ggml_metal_rsets_free).
        // GPU acceleration is unaffected — this only turns off a memory-residency optimization.
        setenv("GGML_METAL_NO_RESIDENCY", "1", 1);
        llama_backend_init();
    });

    llama_model_params mparams = llama_model_default_params();
    mparams.n_gpu_layers = 999;   // offload everything to Metal; falls back gracefully

    _model = llama_model_load_from_file(_modelPath.c_str(), mparams);
    if (!_model) return NO;
    _vocab = llama_model_get_vocab(_model);

    llama_context_params cparams = llama_context_default_params();
    const int modelContext = llama_model_n_ctx_train(_model);
    cparams.n_ctx = (uint32_t)(modelContext > 0
        ? std::min(_contextSize, modelContext)
        : _contextSize);
    cparams.n_threads = _threadCount;
    cparams.n_threads_batch = _threadCount;

    _ctx = llama_init_from_model(_model, cparams);
    if (!_ctx) {
        llama_model_free(_model);
        _model = nullptr; _vocab = nullptr;
        return NO;
    }

    // Low-temperature chain so the rewrite stays faithful to the source text.
    _sampler = llama_sampler_chain_init(llama_sampler_chain_default_params());
    llama_sampler_chain_add(_sampler, llama_sampler_init_top_k(40));
    llama_sampler_chain_add(_sampler, llama_sampler_init_top_p(0.95f, 1));
    llama_sampler_chain_add(_sampler, llama_sampler_init_temp(0.3f));
    // Penalize loops/stutter so long rewrites don't repeat a phrase forever.
    llama_sampler_chain_add(_sampler, llama_sampler_init_penalties(
        /*last_n*/ 64, /*repeat*/ 1.15f, /*freq*/ 0.0f, /*present*/ 0.0f));
    llama_sampler_chain_add(_sampler, llama_sampler_init_dist(LLAMA_DEFAULT_SEED));
    return YES;
}

- (void)setThreadCount:(int)threadCount {
    _threadCount = std::max(1, threadCount);
    if (_ctx) llama_set_n_threads(_ctx, _threadCount, _threadCount);
}

- (nullable NSString *)generateWithSystem:(NSString *)system
                                     user:(NSString *)user
                             maxNewTokens:(int)maxNewTokens
                              isCancelled:(BOOL (^)(void))isCancelled {
    if (![self load]) return nil;

    llama_sampler_reset(_sampler);

    std::string systemStr = system.UTF8String ? system.UTF8String : "";
    std::string userStr = user.UTF8String ? user.UTF8String : "";
    std::string prompt = [self buildPromptWithSystem:systemStr user:userStr];
    if (_disablesThinking) {
        // Qwen3's own template turns reasoning off by pre-filling an empty block into the
        // assistant turn (`enable_thinking=false`). `llama_chat_apply_template` is a pattern
        // matcher, not a Jinja evaluator, and has no such parameter — so the prefill is
        // appended here. The `/no_think` soft switch cannot substitute: the model still opens
        // a `<think>` block, which is what has to be avoided.
        prompt += kReasoningPrefill;
    }

    std::vector<llama_token> tokens = [self tokenize:prompt addSpecial:true];
    if (tokens.empty()) return nil;

    // Reserve the requested response inside the actual per-sequence context. The previous
    // implementation retained nCtx - 128 prompt tokens regardless of maxNewTokens, so a long
    // transcript plus a 512-token rewrite eventually exceeded the KV cache. llama.cpp treats
    // that contract violation as a process-level abort rather than a recoverable error.
    const int nCtx = std::min((int)llama_n_ctx(_ctx), (int)llama_n_ctx_seq(_ctx));
    if (nCtx < 256) return nil;

    const int safetyTokens = 64;
    const int minimumPromptTokens = 128;
    const int outputBudget = std::max(
        1,
        std::min(maxNewTokens, nCtx - safetyTokens - minimumPromptTokens)
    );
    const int promptBudget = nCtx - safetyTokens - outputBudget;

    // On overflow, keep the system/instructions prefix and the newest user text. Never evict
    // the instructions while keeping only the transcript tail (that makes the model continue
    // the source text instead of rewriting it).
    if ((int)tokens.size() > promptBudget) {
        std::vector<llama_token> systemTokens = [self tokenize:systemStr addSpecial:false];
        int keepPrefix = std::min((int)systemTokens.size() + 32, promptBudget / 3);
        keepPrefix = std::max(keepPrefix, 64);
        int keepSuffix = promptBudget - keepPrefix;
        if (keepSuffix < 64) {
            keepPrefix = promptBudget / 4;
            keepSuffix = promptBudget - keepPrefix;
        }
        std::vector<llama_token> trimmed;
        trimmed.reserve(promptBudget);
        trimmed.insert(trimmed.end(), tokens.begin(), tokens.begin() + keepPrefix);
        trimmed.insert(trimmed.end(), tokens.end() - keepSuffix, tokens.end());
        tokens.swap(trimmed);
    }

    // llama_decode also has an independent logical batch limit (commonly 2K even for a 4K
    // context). Passing the whole retained prompt in one call was the direct cause of the
    // reported ggml_abort. Prefill sequentially in legal batches, and fail closed on any
    // decoder error so Swift can fall back to the original transcript.
    const int nBatch = (int)llama_n_batch(_ctx);
    if (nBatch <= 0) return nil;

    // Reuse the KV cache for the prompt prefix this request shares with the last one.
    //
    // The system prompt is identical on every dictation — roughly 850 tokens of instructions —
    // and clearing the whole cache each time meant re-prefilling all of it before a single new
    // token could be sampled. Measured on Gemma 4 E2B over a 22-case dictation set, that
    // prefill was 65% of end-to-end latency: 0.452 s with the real prompt against 0.157 s with
    // a 58-character one.
    //
    // Only the tail after the shared prefix is evicted and recomputed. At least one token is
    // always decoded, because the sampler needs logits from a fresh `llama_decode`.
    llama_memory_t memory = llama_get_memory(_ctx);
    size_t reusable = 0;
    const size_t maxReusable = tokens.size() - 1;
    while (reusable < maxReusable && reusable < _cachedPrompt.size()
           && _cachedPrompt[reusable] == tokens[reusable]) {
        reusable++;
    }
    if (reusable == 0) {
        llama_memory_clear(memory, true);
    } else {
        // Drops the previous request's uncommon tail *and* its generated tokens, which sit
        // after the prompt in the same sequence.
        llama_memory_seq_rm(memory, 0, (llama_pos)reusable, -1);
    }
    _cachedPrompt.clear();

    for (int offset = (int)reusable; offset < (int)tokens.size(); offset += nBatch) {
        if (isCancelled && isCancelled()) return @"";
        const int chunkCount = std::min(nBatch, (int)tokens.size() - offset);
        llama_batch batch = llama_batch_get_one(tokens.data() + offset, (int32_t)chunkCount);
        const int32_t decodeResult = llama_decode(_ctx, batch);
        if (decodeResult != 0) {
            os_log_error(OS_LOG_DEFAULT,
                         "Zerm local model rejected prompt batch (result=%{public}d, tokens=%{public}d)",
                         decodeResult, chunkCount);
            llama_memory_clear(memory, true);
            return nil;
        }
    }
    // Only now is the cache known to match these tokens exactly.
    _cachedPrompt = tokens;

    std::string out;
    int generated = 0;
    int decoded = 0;
    bool inReasoning = false;
    bool reasoningResolved = false;
    int reasoningTokens = 0;
    // Skipped reasoning still occupies the KV cache even though it never reaches the user, so
    // the hard ceiling is the real headroom left after the prompt — not `outputBudget`, which
    // only counts tokens kept as answer. Overrunning the cache is a process-level abort in
    // llama.cpp, not a recoverable error.
    const int headroom = std::max(1, nCtx - (int)tokens.size() - 8);
    // Within that ceiling, reasoning is budgeted separately so it cannot quietly eat the
    // answer's allowance. A block that never closes means no answer is coming, so the request
    // fails closed and Swift keeps the raw transcript.
    const int reasoningBudget = std::min(headroom, std::max(512, outputBudget * 4));

    while (generated < outputBudget && decoded < headroom) {
        if (isCancelled && isCancelled()) break;

        llama_token id = llama_sampler_sample(_sampler, _ctx, -1);
        if (llama_vocab_is_eog(_vocab, id)) break;

        decoded++;
        out += [self pieceFor:id];

        // A hybrid-reasoning model (Qwen3) opens its turn with `<think>` whenever the prefill
        // above did not take. Reasoning is not an answer and it is not a stop delimiter: it is
        // skipped, and the answer that follows `</think>` is kept. Treating `<think>` as a stop
        // truncated the buffer at offset 0 and returned an empty string for every single
        // request, which is what shipped in 2.8.3.
        if (!reasoningResolved) {
            size_t closePos = out.find(kReasoningClose);
            if (closePos != std::string::npos) {
                out.erase(0, closePos + kReasoningClose.size());
                inReasoning = false;
                reasoningResolved = true;
                generated = 0;
            } else if (inReasoning || out.find(kReasoningOpen) != std::string::npos) {
                inReasoning = true;
                if (++reasoningTokens > reasoningBudget) {
                    os_log_error(OS_LOG_DEFAULT,
                                 "Zerm local model never closed its reasoning block (tokens=%{public}d)",
                                 reasoningTokens);
                    return nil;
                }
            }
        }

        if (!inReasoning) {
            // Some small/quantized models emit chat-template delimiters as literal text instead
            // of special token IDs. Stop at the earliest one. Gemma 4 can emit the closing
            // `</start_of_turn>` spelling, which previously leaked into the user's pasted text.
            size_t firstStop = std::string::npos;
            for (const char *stop : {
                     "<end_of_turn>", "</end_of_turn>",
                     "<start_of_turn>", "</start_of_turn>",
                     "<eos>", "</eos>", "<|im_end|>", "<|endoftext|>"}) {
                size_t pos = out.find(stop);
                if (pos != std::string::npos) firstStop = std::min(firstStop, pos);
            }
            if (firstStop != std::string::npos) {
                out.erase(firstStop);
                break;
            }

            generated++;
            if (generated >= outputBudget) break;
        }

        llama_batch batch = llama_batch_get_one(&id, 1);
        const int32_t decodeResult = llama_decode(_ctx, batch);
        if (decodeResult != 0) {
            os_log_error(OS_LOG_DEFAULT,
                         "Zerm local model rejected generated token (result=%{public}d)",
                         decodeResult);
            // The cache can no longer be trusted to match `_cachedPrompt`; start clean next time.
            llama_memory_clear(llama_get_memory(_ctx), true);
            _cachedPrompt.clear();
            return nil;
        }
    }

    NSString *result = [NSString stringWithUTF8String:out.c_str()];
    return [result stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

// MARK: - Helpers

/// Builds the prompt with separate system + user roles when the model template supports it.
- (std::string)buildPromptWithSystem:(const std::string &)system user:(const std::string &)user {
    const char * tmpl = llama_model_chat_template(_model, nullptr);
    if (tmpl != nullptr) {
        llama_chat_message msgs[2];
        int msgCount = 0;
        if (!system.empty()) {
            msgs[msgCount].role = "system";
            msgs[msgCount].content = system.c_str();
            msgCount++;
        }
        msgs[msgCount].role = "user";
        msgs[msgCount].content = user.c_str();
        msgCount++;

        int32_t needed = llama_chat_apply_template(tmpl, msgs, msgCount, true, nullptr, 0);
        if (needed > 0) {
            std::vector<char> buf(needed);
            int32_t n = llama_chat_apply_template(tmpl, msgs, msgCount, true, buf.data(), (int32_t)buf.size());
            if (n > 0) return std::string(buf.data(), n);
        }
        // Some templates reject "system" — fall back to fused user turn.
        std::string fused = system.empty() ? user : (system + "\n\n" + user);
        llama_chat_message msg;
        msg.role = "user";
        msg.content = fused.c_str();
        needed = llama_chat_apply_template(tmpl, &msg, 1, true, nullptr, 0);
        if (needed > 0) {
            std::vector<char> buf(needed);
            int32_t n = llama_chat_apply_template(tmpl, &msg, 1, true, buf.data(), (int32_t)buf.size());
            if (n > 0) return std::string(buf.data(), n);
        }
    }
    std::string fused = system.empty() ? user : (system + "\n\n" + user);
    return "<start_of_turn>user\n" + fused + "<end_of_turn>\n<start_of_turn>model\n";
}

- (std::vector<llama_token>)tokenize:(const std::string &)text addSpecial:(bool)addSpecial {
    int32_t byteCount = (int32_t)text.size();
    int32_t capacity = byteCount + 16;
    std::vector<llama_token> tokens(capacity);
    int32_t n = llama_tokenize(_vocab, text.c_str(), byteCount,
                               tokens.data(), capacity, addSpecial, true);
    if (n < 0) return {};
    tokens.resize(n);
    return tokens;
}

- (std::string)pieceFor:(llama_token)token {
    char buf[64];
    int32_t n = llama_token_to_piece(_vocab, token, buf, (int32_t)sizeof(buf), 0, false);
    if (n < 0) {
        std::vector<char> big(-n);
        n = llama_token_to_piece(_vocab, token, big.data(), (int32_t)big.size(), 0, false);
        if (n < 0) return "";
        return std::string(big.data(), n);
    }
    return std::string(buf, n);
}

@end
