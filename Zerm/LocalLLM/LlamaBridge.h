#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Thin Objective-C wrapper around llama.cpp. This exists purely to keep the llama/ggml C
/// headers out of Swift: whisper.cpp also vendors `ggml`, and importing both ggml-bearing
/// Clang modules into Swift triggers a redefinition clash. By confining `#import <llama/llama.h>`
/// to one Objective-C++ translation unit, Swift only ever sees this Foundation-only interface.
@interface LlamaBridge : NSObject

- (instancetype)initWithModelPath:(NSString *)modelPath
                       contextSize:(int)contextSize
                       threadCount:(int)threadCount;

- (instancetype)initWithModelPath:(NSString *)modelPath
                       contextSize:(int)contextSize
                       threadCount:(int)threadCount
                  disablesThinking:(BOOL)disablesThinking;

/// Adjusts CPU-side inference work without reloading model weights.
- (void)setThreadCount:(int)threadCount;

/// Loads the model, context, and sampler. Idempotent. Returns NO on failure.
- (BOOL)load;

/// Suppresses a hybrid-reasoning model's chain of thought by pre-filling an empty
/// `<think></think>` block into the assistant turn. Set for Qwen3-family packages.
@property (nonatomic, readonly) BOOL disablesThinking;

/// Runs one instruction-style generation (system + user → assistant text).
/// `isCancelled` is polled between tokens; return YES to stop early. Returns nil on failure.
- (nullable NSString *)generateWithSystem:(NSString *)system
                                     user:(NSString *)user
                             maxNewTokens:(int)maxNewTokens
                              isCancelled:(BOOL (^_Nullable)(void))isCancelled;

@end

NS_ASSUME_NONNULL_END
