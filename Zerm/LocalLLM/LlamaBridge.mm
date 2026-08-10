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

@implementation LlamaBridge {
    std::string _modelPath;
    llama_model   * _model;
    llama_context * _ctx;
    const llama_vocab * _vocab;
    llama_sampler * _sampler;
}

- (instancetype)initWithModelPath:(NSString *)modelPath {
    if ((self = [super init])) {
        _modelPath = std::string(modelPath.UTF8String);
        _model = nullptr;
        _ctx = nullptr;
        _vocab = nullptr;
        _sampler = nullptr;
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
    cparams.n_ctx = 4096;
    int threads = (int)NSProcessInfo.processInfo.activeProcessorCount - 2;
    if (threads < 2) threads = 2;
    if (threads > 8) threads = 8;
    cparams.n_threads = threads;
    cparams.n_threads_batch = threads;

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

- (nullable NSString *)generateWithSystem:(NSString *)system
                                     user:(NSString *)user
                             maxNewTokens:(int)maxNewTokens
                              isCancelled:(BOOL (^)(void))isCancelled {
    if (![self load]) return nil;

    // Fresh state for every request (we reuse one context).
    llama_memory_clear(llama_get_memory(_ctx), true);
    llama_sampler_reset(_sampler);

    std::string systemStr = system.UTF8String ? system.UTF8String : "";
    std::string userStr = user.UTF8String ? user.UTF8String : "";
    std::string prompt = [self buildPromptWithSystem:systemStr user:userStr];

    std::vector<llama_token> tokens = [self tokenize:prompt addSpecial:true];
    if (tokens.empty()) return nil;

    // On overflow, keep the system/instructions prefix and drop the oldest
    // middle of the user transcript — never evict instructions while keeping
    // only the transcript tail (that makes the model continue the text).
    const int nCtx = (int)llama_n_ctx(_ctx);
    const int budget = nCtx - 128;
    if ((int)tokens.size() > budget) {
        std::vector<llama_token> systemTokens = [self tokenize:systemStr addSpecial:false];
        int keepPrefix = std::min((int)systemTokens.size() + 32, budget / 3);
        keepPrefix = std::max(keepPrefix, 64);
        int keepSuffix = budget - keepPrefix;
        if (keepSuffix < 64) {
            keepPrefix = budget / 4;
            keepSuffix = budget - keepPrefix;
        }
        std::vector<llama_token> trimmed;
        trimmed.reserve(budget);
        trimmed.insert(trimmed.end(), tokens.begin(), tokens.begin() + keepPrefix);
        trimmed.insert(trimmed.end(), tokens.end() - keepSuffix, tokens.end());
        tokens.swap(trimmed);
    }

    std::string out;
    int generated = 0;
    std::vector<llama_token> current = tokens;

    while (generated < maxNewTokens) {
        if (isCancelled && isCancelled()) break;

        llama_batch batch = llama_batch_get_one(current.data(), (int32_t)current.size());
        if (llama_decode(_ctx, batch) != 0) break;

        llama_token id = llama_sampler_sample(_sampler, _ctx, -1);
        if (llama_vocab_is_eog(_vocab, id)) break;

        out += [self pieceFor:id];

        // Some small/quantized models emit the turn delimiter as literal text instead of the
        // special token — stop there so "<end_of_turn>" is never spoken.
        bool hitStop = false;
        for (const char *stop : {"<end_of_turn>", "<start_of_turn>", "<eos>"}) {
            size_t pos = out.find(stop);
            if (pos != std::string::npos) { out.erase(pos); hitStop = true; break; }
        }
        if (hitStop) break;

        generated++;
        current.assign(1, id);
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
