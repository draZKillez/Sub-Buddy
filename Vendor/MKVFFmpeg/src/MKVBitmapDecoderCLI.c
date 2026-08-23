#include "MKVFFmpeg.h"

#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <stdatomic.h>
#include <unistd.h>

typedef struct {
    const char *input;
    int32_t stream_index;
    const char *output;
    MKVFFOperationState *state;
    char *error;
    int32_t status;
    atomic_int done;
} DecodeJob;

static void *decode(void *opaque) {
    DecodeJob *job = (DecodeJob *)opaque;
    job->status = mkvff_decode_bitmap_subtitle(
        job->input, job->stream_index, job->output, job->state, &job->error
    );
    atomic_store_explicit(&job->done, 1, memory_order_release);
    return NULL;
}

int main(int argc, char **argv) {
    if (argc != 4) {
        fprintf(stderr, "usage: mkvbitmapdecode INPUT STREAM_INDEX OUTPUT\n");
        return 64;
    }
    char *end = NULL;
    long index = strtol(argv[2], &end, 10);
    if (!end || *end != '\0' || index < 0 || index > INT32_MAX) {
        fprintf(stderr, "invalid stream index\n");
        return 64;
    }
    MKVFFOperationState *state = mkvff_operation_state_create();
    if (!state) {
        fprintf(stderr, "cannot create operation state\n");
        return 70;
    }
    DecodeJob job = {
        .input = argv[1], .stream_index = (int32_t)index, .output = argv[3],
        .state = state, .error = NULL, .status = 1
    };
    atomic_init(&job.done, 0);
    pthread_t thread;
    if (pthread_create(&thread, NULL, decode, &job) != 0) {
        fprintf(stderr, "cannot start decoder\n");
        mkvff_operation_state_free(state);
        return 70;
    }
    while (!atomic_load_explicit(&job.done, memory_order_acquire)) {
        printf("progress=%.6f\n", mkvff_operation_state_progress(state));
        fflush(stdout);
        usleep(200000);
    }
    pthread_join(thread, NULL);
    printf("progress=%.6f\n", mkvff_operation_state_progress(state));
    fflush(stdout);
    if (job.status != 0) fprintf(stderr, "%s\n", job.error ? job.error : "VobSub decode failed");
    if (job.error) mkvff_string_free(job.error);
    mkvff_operation_state_free(state);
    return job.status == 0 ? 0 : 1;
}
