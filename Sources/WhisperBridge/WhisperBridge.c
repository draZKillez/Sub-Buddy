#include "WhisperBridge.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <whisper.h>

struct AVCWhisperContext {
    struct whisper_context * whisper;
    atomic_bool cancelled;
    int thread_count;
};

typedef struct {
    AVCWhisperContext * owner;
    AVCWhisperProgressCallback progress;
    AVCWhisperSegmentCallback segment;
    void * user_data;
} AVCWhisperCallbacks;

static bool avc_abort_callback(void * user_data) {
    AVCWhisperCallbacks * callbacks = (AVCWhisperCallbacks *) user_data;
    return callbacks == NULL || callbacks->owner == NULL || atomic_load(&callbacks->owner->cancelled);
}

static void avc_progress_callback(
    struct whisper_context * context,
    struct whisper_state * state,
    int progress,
    void * user_data
) {
    (void) context;
    (void) state;
    AVCWhisperCallbacks * callbacks = (AVCWhisperCallbacks *) user_data;
    if (callbacks != NULL && callbacks->progress != NULL) {
        callbacks->progress(progress, callbacks->user_data);
    }
}

static void avc_segment_callback(
    struct whisper_context * context,
    struct whisper_state * state,
    int new_segment_count,
    void * user_data
) {
    (void) state;
    AVCWhisperCallbacks * callbacks = (AVCWhisperCallbacks *) user_data;
    if (callbacks == NULL || callbacks->segment == NULL) {
        return;
    }
    const int total = whisper_full_n_segments(context);
    const int first = total > new_segment_count ? total - new_segment_count : 0;
    for (int index = first; index < total; index++) {
        callbacks->segment(
            whisper_full_get_segment_t0(context, index) * 10,
            whisper_full_get_segment_t1(context, index) * 10,
            whisper_full_get_segment_text(context, index),
            callbacks->user_data
        );
    }
}

AVCWhisperContext * avc_whisper_create(const char * model_path, bool use_gpu, int thread_count) {
    if (model_path == NULL) {
        return NULL;
    }
    AVCWhisperContext * result = (AVCWhisperContext *) calloc(1, sizeof(AVCWhisperContext));
    if (result == NULL) {
        return NULL;
    }
    atomic_init(&result->cancelled, false);
    result->thread_count = thread_count > 0 ? thread_count : 4;
    struct whisper_context_params parameters = whisper_context_default_params();
    parameters.use_gpu = use_gpu;
    parameters.flash_attn = true;
    result->whisper = whisper_init_from_file_with_params(model_path, parameters);
    if (result->whisper == NULL) {
        free(result);
        return NULL;
    }
    return result;
}

void avc_whisper_destroy(AVCWhisperContext * context) {
    if (context == NULL) {
        return;
    }
    whisper_free(context->whisper);
    free(context);
}

void avc_whisper_cancel(AVCWhisperContext * context) {
    if (context != NULL) {
        atomic_store(&context->cancelled, true);
    }
}

int avc_whisper_transcribe(
    AVCWhisperContext * context,
    const float * samples,
    int sample_count,
    const char * initial_prompt,
    AVCWhisperProgressCallback progress_callback,
    AVCWhisperSegmentCallback segment_callback,
    void * user_data
) {
    if (context == NULL || context->whisper == NULL || samples == NULL || sample_count <= 0) {
        return -1;
    }
    atomic_store(&context->cancelled, false);
    AVCWhisperCallbacks callbacks = {
        .owner = context,
        .progress = progress_callback,
        .segment = segment_callback,
        .user_data = user_data
    };
    struct whisper_full_params parameters = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    parameters.n_threads = context->thread_count;
    parameters.translate = false;
    parameters.no_context = true;
    parameters.no_timestamps = false;
    parameters.print_special = false;
    parameters.print_progress = false;
    parameters.print_realtime = false;
    parameters.print_timestamps = false;
    parameters.language = "en";
    parameters.detect_language = false;
    parameters.initial_prompt = initial_prompt;
    parameters.carry_initial_prompt = true;
    parameters.max_len = 84;
    parameters.split_on_word = true;
    parameters.suppress_blank = true;
    parameters.suppress_nst = true;
    parameters.no_speech_thold = 0.60f;
    parameters.progress_callback = avc_progress_callback;
    parameters.progress_callback_user_data = &callbacks;
    parameters.new_segment_callback = avc_segment_callback;
    parameters.new_segment_callback_user_data = &callbacks;
    parameters.abort_callback = avc_abort_callback;
    parameters.abort_callback_user_data = &callbacks;

    const int status = whisper_full(context->whisper, parameters, samples, sample_count);
    if (atomic_load(&context->cancelled)) {
        return 2;
    }
    return status == 0 ? 0 : -2;
}
