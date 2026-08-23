#ifndef AI_VIEWING_COMPANION_WHISPER_BRIDGE_H
#define AI_VIEWING_COMPANION_WHISPER_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AVCWhisperContext AVCWhisperContext;

typedef void (*AVCWhisperProgressCallback)(int progress, void * user_data);
typedef void (*AVCWhisperSegmentCallback)(
    int64_t start_milliseconds,
    int64_t end_milliseconds,
    const char * text,
    void * user_data
);

AVCWhisperContext * avc_whisper_create(const char * model_path, bool use_gpu, int thread_count);
void avc_whisper_destroy(AVCWhisperContext * context);
void avc_whisper_cancel(AVCWhisperContext * context);

// Returns 0 on success, 2 when cancelled, and a negative value on failure.
int avc_whisper_transcribe(
    AVCWhisperContext * context,
    const float * samples,
    int sample_count,
    const char * initial_prompt,
    AVCWhisperProgressCallback progress_callback,
    AVCWhisperSegmentCallback segment_callback,
    void * user_data
);

#ifdef __cplusplus
}
#endif

#endif
