#ifndef ASR4ALL_ENGINE_H
#define ASR4ALL_ENGINE_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct Asr4allContext Asr4allContext;

/// Initializes an ASR4ALL ONNX bundle context from `bundle_dir` (containing `metadata.json` and `asr4all.onnx.data`).
/// Returns NULL on error and writes a human-readable message to `err_buf` if non-null.
Asr4allContext* asr4all_init(const char* bundle_dir, int n_threads, char* err_buf, size_t err_buf_len);

/// Frees all ONNX Runtime sessions, initializers, and mmap state associated with `ctx`.
void asr4all_free(Asr4allContext* ctx);

/// Requests immediate termination of any in-flight `asr4all_transcribe` call on `ctx`.
void asr4all_abort(Asr4allContext* ctx);

/// Clears a pending termination request before starting a new transcription.
void asr4all_reset_abort(Asr4allContext* ctx);

/// Runs streaming-offline transcription + PCEC (when `apply_pcec` is true) on 16 kHz mono float32 PCM samples.
/// `tier_name` may be NULL/empty to use the bundle's `default_tier`.
/// On success, returns 0 and allocates `*out_text` (caller must free with `asr4all_free_string`).
/// Returns -2 if aborted, -1 on error (with message in `err_buf`).
int asr4all_transcribe(
    Asr4allContext* ctx,
    const float* samples,
    size_t n_samples,
    const char* tier_name,
    bool apply_pcec,
    char** out_text,
    int* out_window_samples,
    char* err_buf,
    size_t err_buf_len
);

/// Frees a string returned by `asr4all_transcribe`.
void asr4all_free_string(char* str);

#ifdef __cplusplus
}
#endif

#endif /* ASR4ALL_ENGINE_H */
