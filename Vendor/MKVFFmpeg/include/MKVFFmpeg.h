#ifndef MKVFFMPEG_H
#define MKVFFMPEG_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(__GNUC__)
#define MKVFF_EXPORT __attribute__((visibility("default")))
#else
#define MKVFF_EXPORT
#endif

#define MKVFF_MAX_CODEC 64
#define MKVFF_MAX_LANGUAGE 32
#define MKVFF_MAX_TITLE 512

typedef struct {
    int32_t stream_index;
    char codec[MKVFF_MAX_CODEC];
    char language[MKVFF_MAX_LANGUAGE];
    char title[MKVFF_MAX_TITLE];
    int32_t is_default;
    int32_t is_forced;
    int32_t is_hearing_impaired;
    int32_t is_text;
    int32_t is_pgs;
} MKVFFSubtitleTrack;

typedef struct {
    double duration_seconds;
    char container_title[MKVFF_MAX_TITLE];
    int32_t subtitle_track_count;
    MKVFFSubtitleTrack *subtitle_tracks;
} MKVFFMediaInfo;

typedef struct MKVFFOperationState MKVFFOperationState;

MKVFF_EXPORT const char *mkvff_version(void);

MKVFF_EXPORT int32_t mkvff_inspect(
    const char *input_path,
    MKVFFMediaInfo **media_info,
    char **error_message
);

/* Same inspection with an interrupt callback for responsive UI cancellation. */
MKVFF_EXPORT int32_t mkvff_inspect_cancellable(
    const char *input_path,
    MKVFFMediaInfo **media_info,
    MKVFFOperationState *state,
    char **error_message
);

MKVFF_EXPORT void mkvff_media_info_free(MKVFFMediaInfo *media_info);

MKVFF_EXPORT MKVFFOperationState *mkvff_operation_state_create(void);
MKVFF_EXPORT void mkvff_operation_state_cancel(MKVFFOperationState *state);
MKVFF_EXPORT double mkvff_operation_state_progress(const MKVFFOperationState *state);
MKVFF_EXPORT void mkvff_operation_state_free(MKVFFOperationState *state);

/*
 * Text tracks are normalized to UTF-8 SRT. PGS tracks are written as a
 * standard SUP stream so the Swift PGS decoder can preserve packet timing.
 */
MKVFF_EXPORT int32_t mkvff_extract_subtitle(
    const char *input_path,
    int32_t stream_index,
    const char *output_path,
    MKVFFOperationState *state,
    char **error_message
);

/*
 * Decodes a DVD/VobSub subtitle track into the private MKVBM01 bitmap
 * archive consumed by the Swift Apple Vision OCR service. The archive keeps
 * one cropped RGBA image and its original millisecond time range per cue.
 */
MKVFF_EXPORT int32_t mkvff_decode_bitmap_subtitle(
    const char *input_path,
    int32_t stream_index,
    const char *output_path,
    MKVFFOperationState *state,
    char **error_message
);

MKVFF_EXPORT void mkvff_string_free(char *value);

#ifdef __cplusplus
}
#endif

#endif
