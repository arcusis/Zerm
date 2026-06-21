#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Thin Objective-C wrapper around llama.cpp. This exists purely to keep the llama/ggml C
/// headers out of Swift: whisper.cpp also vendors `ggml`, and importing both ggml-bearing
/// Clang modules into Swift triggers a redefinition clash. By confining `#import <llama/llama.h>`
/// to one Objective-C++ translation unit, Swift only ever sees this Foundation-only interface.
@interface LlamaBridge : NSObject

- (instancetype)initWithModelPath:(NSString *)modelPath;

/// Loads the model, context, and sampler. Idempotent. Returns NO on failure.
- (BOOL)load;

/// Runs one instruction-style generation (system + user → assistant text).
/// `isCancelled` is polled between tokens; return YES to stop early. Returns nil on failure.
- (nullable NSString *)generateWithSystem:(NSString *)system
                                     user:(NSString *)user
                             maxNewTokens:(int)maxNewTokens
                              isCancelled:(BOOL (^_Nullable)(void))isCancelled;

@end

NS_ASSUME_NONNULL_END
