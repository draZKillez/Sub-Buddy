#include "MKVFFmpeg.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <unistd.h>

typedef struct {
    MKVFFOperationState *operation;
    useconds_t delay;
} CancelContext;

static void *cancel_later(void *raw) {
    CancelContext *context = raw;
    usleep(context->delay);
    mkvff_operation_state_cancel(context->operation);
    return NULL;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s input.mkv [output]\n", argv[0]);
        return 64;
    }
    MKVFFMediaInfo *info = NULL;
    char *error = NULL;
    int status = mkvff_inspect(argv[1], &info, &error);
    if (status != 0) {
        fprintf(stderr, "%s\n", error ? error : "inspect failed");
        mkvff_string_free(error);
        return 1;
    }
    printf("ffmpeg=%s title=%s duration=%.3f subtitles=%d\n",
           mkvff_version(), info->container_title, info->duration_seconds, info->subtitle_track_count);
    int selected = -1;
    for (int i = 0; i < info->subtitle_track_count; ++i) {
        MKVFFSubtitleTrack *track = &info->subtitle_tracks[i];
        printf("stream=%d codec=%s lang=%s title=%s default=%d forced=%d sdh=%d text=%d pgs=%d\n",
               track->stream_index, track->codec, track->language, track->title,
               track->is_default, track->is_forced, track->is_hearing_impaired,
               track->is_text, track->is_pgs);
        if (selected < 0 && (!strcmp(track->language, "eng") || !strcmp(track->language, "en")) &&
            (track->is_text || track->is_pgs)) selected = track->stream_index;
    }
    if (argc >= 3 && selected >= 0) {
        MKVFFOperationState *operation = mkvff_operation_state_create();
        pthread_t cancellation_thread;
        CancelContext cancellation = { operation, 0 };
        int has_cancellation = 0;
        const char *cancel_ms = getenv("MKVFF_CANCEL_MS");
        if (cancel_ms && atoi(cancel_ms) > 0) {
            cancellation.delay = (useconds_t)atoi(cancel_ms) * 1000;
            has_cancellation = pthread_create(&cancellation_thread, NULL, cancel_later, &cancellation) == 0;
        }
        status = mkvff_extract_subtitle(argv[1], selected, argv[2], operation, &error);
        if (has_cancellation) pthread_join(cancellation_thread, NULL);
        printf("extract_stream=%d status=%d progress=%.3f output=%s\n",
               selected, status, mkvff_operation_state_progress(operation), argv[2]);
        mkvff_operation_state_free(operation);
        if (status != 0) fprintf(stderr, "%s\n", error ? error : "extract failed");
        mkvff_string_free(error);
    }
    mkvff_media_info_free(info);
    return status == 0 ? 0 : 2;
}
