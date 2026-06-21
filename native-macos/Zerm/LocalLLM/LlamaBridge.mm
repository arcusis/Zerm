#import "LlamaBridge.h"
#import <llama/llama.h>
#import <os/log.h>

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

    std::string combined = std::string(system.UTF8String) + "\n\n" + std::string(user.UTF8String);
    std::string prompt = [self buildPrompt:combined];

    std::vector<llama_token> tokens = [self tokenize:prompt addSpecial:true];
    if (tokens.empty()) return nil;

    const int nCtx = (int)llama_n_ctx(_ctx);
    if ((int)tokens.size() > nCtx - 128) {
        tokens.erase(tokens.begin(), tokens.end() - (nCtx - 128));   // keep most recent context
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

/// Builds the prompt using the model's own chat template (so any GGUF instruct model works),
/// folding the instructions into a single user turn. Falls back to the Gemma format.
- (std::string)buildPrompt:(const std::string &)content {
    const char * tmpl = llama_model_chat_template(_model, nullptr);
    if (tmpl != nullptr) {
        llama_chat_message msg;
        msg.role = "user";
        msg.content = content.c_str();
        int32_t needed = llama_chat_apply_template(tmpl, &msg, 1, true, nullptr, 0);
        if (needed > 0) {
            std::vector<char> buf(needed);
            int32_t n = llama_chat_apply_template(tmpl, &msg, 1, true, buf.data(), (int32_t)buf.size());
            if (n > 0) return std::string(buf.data(), n);
        }
    }
    return "<start_of_turn>user\n" + content + "<end_of_turn>\n<start_of_turn>model\n";
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
