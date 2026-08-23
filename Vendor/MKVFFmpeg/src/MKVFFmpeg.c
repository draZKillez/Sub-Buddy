#include "MKVFFmpeg.h"

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avstring.h>
#include <libavutil/dict.h>
#include <libavutil/error.h>
#include <libavutil/mem.h>
#include <libavutil/rational.h>

#include <stdatomic.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MKVFF_BITMAP_MAX_DIMENSION 8192
#define MKVFF_BITMAP_MAX_PIXELS 16777216
#define MKVFF_BITMAP_MAX_TOTAL_BYTES ((uint64_t)512 * 1024 * 1024)

struct MKVFFOperationState {
    atomic_int cancelled;
    _Atomic double progress;
};

static void mkvff_set_error(char **target, const char *prefix, int code) {
    if (!target) return;
    char detail[AV_ERROR_MAX_STRING_SIZE] = {0};
    if (code < 0) av_strerror(code, detail, sizeof(detail));
    const char *separator = code < 0 ? "：" : "";
    size_t size = strlen(prefix) + strlen(separator) + strlen(detail) + 1;
    *target = av_malloc(size);
    if (*target) snprintf(*target, size, "%s%s%s", prefix, separator, detail);
}

static void mkvff_copy_metadata(char *target, size_t capacity, AVDictionary *metadata, const char *key) {
    const AVDictionaryEntry *entry = av_dict_get(metadata, key, NULL, 0);
    av_strlcpy(target, entry && entry->value ? entry->value : "", capacity);
}

static int mkvff_is_text_codec(enum AVCodecID codec_id) {
    return codec_id == AV_CODEC_ID_SUBRIP ||
           codec_id == AV_CODEC_ID_ASS ||
           codec_id == AV_CODEC_ID_SSA ||
           codec_id == AV_CODEC_ID_WEBVTT ||
           codec_id == AV_CODEC_ID_TEXT;
}

const char *mkvff_version(void) {
    return av_version_info();
}

int32_t mkvff_inspect(const char *input_path, MKVFFMediaInfo **media_info, char **error_message) {
    if (media_info) *media_info = NULL;
    if (error_message) *error_message = NULL;
    if (!input_path || !media_info) {
        mkvff_set_error(error_message, "检查参数无效", 0);
        return AVERROR(EINVAL);
    }

    AVFormatContext *format = NULL;
    int result = avformat_open_input(&format, input_path, NULL, NULL);
    if (result < 0) {
        mkvff_set_error(error_message, "无法打开 MKV", result);
        return result;
    }
    result = avformat_find_stream_info(format, NULL);
    if (result < 0) {
        mkvff_set_error(error_message, "无法读取 MKV 轨道信息", result);
        avformat_close_input(&format);
        return result;
    }

    int32_t subtitle_count = 0;
    for (unsigned int i = 0; i < format->nb_streams; ++i) {
        if (format->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_SUBTITLE) subtitle_count++;
    }

    MKVFFMediaInfo *info = av_mallocz(sizeof(*info));
    if (!info) {
        avformat_close_input(&format);
        mkvff_set_error(error_message, "内存不足", AVERROR(ENOMEM));
        return AVERROR(ENOMEM);
    }
    if (subtitle_count > 0) {
        info->subtitle_tracks = av_calloc((size_t)subtitle_count, sizeof(*info->subtitle_tracks));
        if (!info->subtitle_tracks) {
            av_free(info);
            avformat_close_input(&format);
            mkvff_set_error(error_message, "内存不足", AVERROR(ENOMEM));
            return AVERROR(ENOMEM);
        }
    }
    info->subtitle_track_count = subtitle_count;
    info->duration_seconds = format->duration == AV_NOPTS_VALUE ? 0 : (double)format->duration / AV_TIME_BASE;
    mkvff_copy_metadata(info->container_title, sizeof(info->container_title), format->metadata, "title");

    int32_t output_index = 0;
    for (unsigned int i = 0; i < format->nb_streams; ++i) {
        AVStream *stream = format->streams[i];
        AVCodecParameters *parameters = stream->codecpar;
        if (parameters->codec_type != AVMEDIA_TYPE_SUBTITLE) continue;
        MKVFFSubtitleTrack *track = &info->subtitle_tracks[output_index++];
        track->stream_index = (int32_t)i;
        av_strlcpy(track->codec, avcodec_get_name(parameters->codec_id), sizeof(track->codec));
        mkvff_copy_metadata(track->language, sizeof(track->language), stream->metadata, "language");
        if (!track->language[0]) av_strlcpy(track->language, "und", sizeof(track->language));
        mkvff_copy_metadata(track->title, sizeof(track->title), stream->metadata, "title");
        track->is_default = (stream->disposition & AV_DISPOSITION_DEFAULT) != 0;
        track->is_forced = (stream->disposition & AV_DISPOSITION_FORCED) != 0;
        track->is_hearing_impaired = (stream->disposition & AV_DISPOSITION_HEARING_IMPAIRED) != 0;
        track->is_text = mkvff_is_text_codec(parameters->codec_id);
        track->is_pgs = parameters->codec_id == AV_CODEC_ID_HDMV_PGS_SUBTITLE;
    }

    avformat_close_input(&format);
    *media_info = info;
    return 0;
}

void mkvff_media_info_free(MKVFFMediaInfo *media_info) {
    if (!media_info) return;
    av_free(media_info->subtitle_tracks);
    av_free(media_info);
}

MKVFFOperationState *mkvff_operation_state_create(void) {
    MKVFFOperationState *state = calloc(1, sizeof(*state));
    if (state) {
        atomic_init(&state->cancelled, 0);
        atomic_init(&state->progress, 0.0);
    }
    return state;
}

void mkvff_operation_state_cancel(MKVFFOperationState *state) {
    if (state) atomic_store_explicit(&state->cancelled, 1, memory_order_relaxed);
}

double mkvff_operation_state_progress(const MKVFFOperationState *state) {
    return state ? atomic_load_explicit(&state->progress, memory_order_relaxed) : 0.0;
}

void mkvff_operation_state_free(MKVFFOperationState *state) {
    free(state);
}

static int mkvff_cancelled(const MKVFFOperationState *state) {
    return state && atomic_load_explicit(&state->cancelled, memory_order_relaxed);
}

static int mkvff_interrupt(void *opaque) {
    return mkvff_cancelled((const MKVFFOperationState *)opaque);
}

static void mkvff_configure_interrupt(AVFormatContext *format, MKVFFOperationState *state) {
    if (!format) return;
    format->interrupt_callback.callback = mkvff_interrupt;
    format->interrupt_callback.opaque = state;
}

static void mkvff_update_progress(MKVFFOperationState *state, int64_t timestamp, AVStream *stream, int64_t duration) {
    if (!state || timestamp == AV_NOPTS_VALUE || duration <= 0) return;
    int64_t microseconds = av_rescale_q(timestamp, stream->time_base, AV_TIME_BASE_Q);
    double value = (double)microseconds / (double)duration;
    if (value < 0) value = 0;
    if (value > 0.99) value = 0.99;
    atomic_store_explicit(&state->progress, value, memory_order_relaxed);
}

static void mkvff_format_srt_timestamp(char *buffer, size_t capacity, int64_t milliseconds) {
    if (milliseconds < 0) milliseconds = 0;
    int64_t hours = milliseconds / 3600000;
    int64_t minutes = (milliseconds / 60000) % 60;
    int64_t seconds = (milliseconds / 1000) % 60;
    int64_t millis = milliseconds % 1000;
    snprintf(buffer, capacity, "%02lld:%02lld:%02lld,%03lld",
             (long long)hours, (long long)minutes, (long long)seconds, (long long)millis);
}

static const uint8_t *mkvff_ass_text(const uint8_t *data, int size, int *text_size) {
    int commas = 0;
    for (int i = 0; i < size; ++i) {
        if (data[i] == ',') {
            commas++;
            if (commas == 8) {
                *text_size = size - i - 1;
                return data + i + 1;
            }
        }
    }
    *text_size = size;
    return data;
}

static int mkvff_write_srt_cue(FILE *output, int cue_id, int64_t start_ms, int64_t end_ms,
                               const uint8_t *data, int size, enum AVCodecID codec_id) {
    if (!data || size <= 0) return 0;
    int text_size = size;
    const uint8_t *text = data;
    if (codec_id == AV_CODEC_ID_ASS || codec_id == AV_CODEC_ID_SSA) {
        text = mkvff_ass_text(data, size, &text_size);
    }
    while (text_size > 0 && (text[text_size - 1] == '\0' || text[text_size - 1] == '\r' || text[text_size - 1] == '\n')) text_size--;
    if (text_size <= 0) return 0;
    if (end_ms <= start_ms) end_ms = start_ms + 5000;
    char start[32], end[32];
    mkvff_format_srt_timestamp(start, sizeof(start), start_ms);
    mkvff_format_srt_timestamp(end, sizeof(end), end_ms);
    if (fprintf(output, "%d\n%s --> %s\n", cue_id, start, end) < 0) return AVERROR(EIO);
    if (fwrite(text, 1, (size_t)text_size, output) != (size_t)text_size) return AVERROR(EIO);
    if (fwrite("\n\n", 1, 2, output) != 2) return AVERROR(EIO);
    return 1;
}

static int mkvff_write_sup_packet(FILE *output, const AVPacket *packet, AVStream *stream) {
    int64_t raw_timestamp = packet->pts != AV_NOPTS_VALUE ? packet->pts : packet->dts;
    if (raw_timestamp == AV_NOPTS_VALUE) raw_timestamp = 0;
    uint32_t pts = (uint32_t)av_rescale_q(raw_timestamp, stream->time_base, (AVRational){1, 90000});
    const uint8_t *data = packet->data;
    int offset = 0;
    while (offset + 3 <= packet->size) {
        int payload_size = ((int)data[offset + 1] << 8) | data[offset + 2];
        int segment_size = payload_size + 3;
        if (offset + segment_size > packet->size) return AVERROR_INVALIDDATA;
        uint8_t header[10] = {
            'P', 'G',
            (uint8_t)(pts >> 24), (uint8_t)(pts >> 16), (uint8_t)(pts >> 8), (uint8_t)pts,
            (uint8_t)(pts >> 24), (uint8_t)(pts >> 16), (uint8_t)(pts >> 8), (uint8_t)pts
        };
        if (fwrite(header, 1, sizeof(header), output) != sizeof(header)) return AVERROR(EIO);
        if (fwrite(data + offset, 1, (size_t)segment_size, output) != (size_t)segment_size) return AVERROR(EIO);
        offset += segment_size;
    }
    return offset == packet->size ? 0 : AVERROR_INVALIDDATA;
}

int32_t mkvff_extract_subtitle(const char *input_path, int32_t stream_index, const char *output_path,
                               MKVFFOperationState *state, char **error_message) {
    if (error_message) *error_message = NULL;
    if (!input_path || !output_path || !state) {
        mkvff_set_error(error_message, "提取参数无效", 0);
        return AVERROR(EINVAL);
    }
    AVFormatContext *format = NULL;
    FILE *output = NULL;
    AVPacket *packet = NULL;
    uint8_t *pending_data = NULL;
    int pending_size = 0;
    int64_t pending_start = 0;
    int64_t pending_end = 0;
    int cue_id = 1;
    int result = avformat_open_input(&format, input_path, NULL, NULL);
    if (result < 0) {
        mkvff_set_error(error_message, "无法打开 MKV", result);
        goto cleanup;
    }
    result = avformat_find_stream_info(format, NULL);
    if (result < 0) {
        mkvff_set_error(error_message, "无法读取 MKV 轨道信息", result);
        goto cleanup;
    }
    if (stream_index < 0 || (unsigned int)stream_index >= format->nb_streams) {
        result = AVERROR_STREAM_NOT_FOUND;
        mkvff_set_error(error_message, "所选字幕轨道不存在", result);
        goto cleanup;
    }
    AVStream *stream = format->streams[stream_index];
    enum AVCodecID codec_id = stream->codecpar->codec_id;
    int is_text = mkvff_is_text_codec(codec_id);
    int is_pgs = codec_id == AV_CODEC_ID_HDMV_PGS_SUBTITLE;
    if (!is_text && !is_pgs) {
        result = AVERROR_DECODER_NOT_FOUND;
        mkvff_set_error(error_message, "当前字幕编码不支持提取", result);
        goto cleanup;
    }
    /*
     * Tell the Matroska demuxer to discard every unselected stream before it
     * creates AVPackets for them. This avoids copying multi-gigabyte video and
     * audio packet payloads through the app merely to reach a tiny subtitle
     * stream. The demuxer can skip those blocks at the I/O layer instead.
     */
    for (unsigned int i = 0; i < format->nb_streams; ++i) {
        if ((int32_t)i != stream_index) format->streams[i]->discard = AVDISCARD_ALL;
    }
    output = fopen(output_path, "wb");
    if (!output) {
        result = AVERROR(errno);
        mkvff_set_error(error_message, "无法创建字幕输出", result);
        goto cleanup;
    }
    packet = av_packet_alloc();
    if (!packet) {
        result = AVERROR(ENOMEM);
        mkvff_set_error(error_message, "内存不足", result);
        goto cleanup;
    }

    while ((result = av_read_frame(format, packet)) >= 0) {
        if (mkvff_cancelled(state)) {
            result = AVERROR_EXIT;
            mkvff_set_error(error_message, "任务已取消", result);
            av_packet_unref(packet);
            goto cleanup;
        }
        if (packet->stream_index != stream_index) {
            av_packet_unref(packet);
            continue;
        }
        int64_t timestamp = packet->pts != AV_NOPTS_VALUE ? packet->pts : packet->dts;
        int64_t start_ms = timestamp == AV_NOPTS_VALUE ? 0 : av_rescale_q(timestamp, stream->time_base, (AVRational){1, 1000});
        int64_t duration_ms = packet->duration > 0 ? av_rescale_q(packet->duration, stream->time_base, (AVRational){1, 1000}) : 0;
        mkvff_update_progress(state, timestamp, stream, format->duration);

        if (is_pgs) {
            result = mkvff_write_sup_packet(output, packet, stream);
            av_packet_unref(packet);
            if (result < 0) {
                mkvff_set_error(error_message, "PGS 数据包格式无效", result);
                goto cleanup;
            }
            continue;
        }

        if (pending_data) {
            int64_t effective_end = pending_end > pending_start ? pending_end : start_ms;
            int written = mkvff_write_srt_cue(output, cue_id, pending_start, effective_end,
                                               pending_data, pending_size, codec_id);
            av_freep(&pending_data);
            if (written < 0) {
                result = written;
                mkvff_set_error(error_message, "写入 SRT 失败", result);
                av_packet_unref(packet);
                goto cleanup;
            }
            if (written > 0) cue_id++;
        }
        pending_data = av_memdup(packet->data, (size_t)packet->size);
        if (!pending_data) {
            result = AVERROR(ENOMEM);
            mkvff_set_error(error_message, "内存不足", result);
            av_packet_unref(packet);
            goto cleanup;
        }
        pending_size = packet->size;
        pending_start = start_ms;
        pending_end = duration_ms > 0 ? start_ms + duration_ms : 0;
        av_packet_unref(packet);
    }
    if (result == AVERROR_EOF) result = 0;
    if (result < 0) {
        mkvff_set_error(error_message, "读取 MKV 字幕失败", result);
        goto cleanup;
    }
    if (is_text && pending_data) {
        int written = mkvff_write_srt_cue(output, cue_id, pending_start, pending_end,
                                           pending_data, pending_size, codec_id);
        if (written < 0) {
            result = written;
            mkvff_set_error(error_message, "写入 SRT 失败", result);
            goto cleanup;
        }
    }
    atomic_store_explicit(&state->progress, 1.0, memory_order_relaxed);

cleanup:
    av_freep(&pending_data);
    av_packet_free(&packet);
    if (output && fclose(output) != 0 && result >= 0) result = AVERROR(EIO);
    avformat_close_input(&format);
    if (result < 0) remove(output_path);
    return result;
}

void mkvff_string_free(char *value) {
    av_free(value);
}

static int mkvff_write_u32_le(FILE *output, uint32_t value) {
    uint8_t bytes[4] = {
        (uint8_t)value, (uint8_t)(value >> 8),
        (uint8_t)(value >> 16), (uint8_t)(value >> 24)
    };
    return fwrite(bytes, 1, sizeof(bytes), output) == sizeof(bytes) ? 0 : AVERROR(EIO);
}

static int mkvff_write_i64_le(FILE *output, int64_t value) {
    uint64_t raw = (uint64_t)value;
    uint8_t bytes[8];
    for (int i = 0; i < 8; ++i) bytes[i] = (uint8_t)(raw >> (i * 8));
    return fwrite(bytes, 1, sizeof(bytes), output) == sizeof(bytes) ? 0 : AVERROR(EIO);
}

static int mkvff_write_bitmap_cue(FILE *output, const AVSubtitle *subtitle,
                                  int64_t packet_start_ms, int64_t packet_duration_ms,
                                  uint64_t *total_bytes) {
    int min_x = INT_MAX, min_y = INT_MAX, max_x = 0, max_y = 0;
    int bitmap_count = 0;
    for (unsigned int i = 0; i < subtitle->num_rects; ++i) {
        const AVSubtitleRect *rect = subtitle->rects[i];
        if (!rect || rect->type != SUBTITLE_BITMAP || !rect->data[0] || !rect->data[1] ||
            rect->w <= 0 || rect->h <= 0 || rect->linesize[0] < rect->w ||
            rect->x < 0 || rect->y < 0) continue;
        if (rect->w > MKVFF_BITMAP_MAX_DIMENSION || rect->h > MKVFF_BITMAP_MAX_DIMENSION ||
            rect->x > INT_MAX - rect->w || rect->y > INT_MAX - rect->h) return AVERROR_INVALIDDATA;
        if (rect->x < min_x) min_x = rect->x;
        if (rect->y < min_y) min_y = rect->y;
        if (rect->x + rect->w > max_x) max_x = rect->x + rect->w;
        if (rect->y + rect->h > max_y) max_y = rect->y + rect->h;
        bitmap_count++;
    }
    if (!bitmap_count) return 0;
    int width = max_x - min_x;
    int height = max_y - min_y;
    if (width <= 0 || height <= 0 || width > MKVFF_BITMAP_MAX_DIMENSION ||
        height > MKVFF_BITMAP_MAX_DIMENSION || width > MKVFF_BITMAP_MAX_PIXELS / height) {
        return AVERROR_INVALIDDATA;
    }
    size_t pixel_count = (size_t)width * (size_t)height;
    if (pixel_count > SIZE_MAX / 4) return AVERROR(ENOMEM);
    size_t byte_count = pixel_count * 4;
    if (*total_bytes > MKVFF_BITMAP_MAX_TOTAL_BYTES - byte_count) return AVERROR(ENOMEM);
    uint8_t *rgba = av_mallocz(byte_count);
    if (!rgba) return AVERROR(ENOMEM);

    for (unsigned int i = 0; i < subtitle->num_rects; ++i) {
        const AVSubtitleRect *rect = subtitle->rects[i];
        if (!rect || rect->type != SUBTITLE_BITMAP || !rect->data[0] || !rect->data[1] ||
            rect->w <= 0 || rect->h <= 0 || rect->linesize[0] < rect->w) continue;
        const uint32_t *palette = (const uint32_t *)rect->data[1];
        for (int y = 0; y < rect->h; ++y) {
            const uint8_t *indices = rect->data[0] + (size_t)y * (size_t)rect->linesize[0];
            for (int x = 0; x < rect->w; ++x) {
                uint32_t color = palette[indices[x]];
                uint8_t alpha = (uint8_t)(color >> 24);
                if (!alpha) continue;
                size_t target = ((size_t)(rect->y - min_y + y) * (size_t)width +
                                 (size_t)(rect->x - min_x + x)) * 4;
                rgba[target] = (uint8_t)(color >> 16);
                rgba[target + 1] = (uint8_t)(color >> 8);
                rgba[target + 2] = (uint8_t)color;
                rgba[target + 3] = alpha;
            }
        }
    }

    int64_t start_ms = packet_start_ms + (int64_t)subtitle->start_display_time;
    int64_t end_ms = packet_start_ms + (int64_t)subtitle->end_display_time;
    if ((end_ms <= start_ms || end_ms - start_ms > 120000) &&
        packet_duration_ms > 0 && packet_duration_ms <= 120000) {
        end_ms = packet_start_ms + packet_duration_ms;
    }
    if (end_ms - start_ms > 120000) end_ms = start_ms + 5000;
    if (end_ms <= start_ms) end_ms = start_ms + 5000;
    int result = mkvff_write_i64_le(output, start_ms);
    if (result >= 0) result = mkvff_write_i64_le(output, end_ms);
    if (result >= 0) result = mkvff_write_u32_le(output, (uint32_t)width);
    if (result >= 0) result = mkvff_write_u32_le(output, (uint32_t)height);
    if (result >= 0) result = mkvff_write_u32_le(output, (uint32_t)byte_count);
    if (result >= 0 && fwrite(rgba, 1, byte_count, output) != byte_count) result = AVERROR(EIO);
    av_free(rgba);
    if (result >= 0) *total_bytes += byte_count;
    return result < 0 ? result : 1;
}

int32_t mkvff_decode_bitmap_subtitle(const char *input_path, int32_t stream_index,
                                     const char *output_path, MKVFFOperationState *state,
                                     char **error_message) {
    if (error_message) *error_message = NULL;
    if (!input_path || !output_path || !state) {
        mkvff_set_error(error_message, "位图字幕解码参数无效", 0);
        return AVERROR(EINVAL);
    }
    AVFormatContext *format = avformat_alloc_context();
    AVCodecContext *decoder_context = NULL;
    const AVCodec *decoder = NULL;
    AVPacket *packet = NULL;
    FILE *output = NULL;
    uint32_t cue_count = 0;
    uint64_t total_bytes = 0;
    int result = 0;
    if (!format) {
        mkvff_set_error(error_message, "内存不足", AVERROR(ENOMEM));
        return AVERROR(ENOMEM);
    }
    mkvff_configure_interrupt(format, state);
    result = avformat_open_input(&format, input_path, NULL, NULL);
    if (result < 0) { mkvff_set_error(error_message, "无法打开 MKV", result); goto cleanup_bitmap; }
    result = avformat_find_stream_info(format, NULL);
    if (result < 0) { mkvff_set_error(error_message, "无法读取 MKV 轨道信息", result); goto cleanup_bitmap; }
    if (stream_index < 0 || (unsigned int)stream_index >= format->nb_streams) {
        result = AVERROR_STREAM_NOT_FOUND;
        mkvff_set_error(error_message, "所选字幕轨道不存在", result);
        goto cleanup_bitmap;
    }
    AVStream *stream = format->streams[stream_index];
    if (stream->codecpar->codec_id != AV_CODEC_ID_DVD_SUBTITLE) {
        result = AVERROR_DECODER_NOT_FOUND;
        mkvff_set_error(error_message, "该轨道不是 VobSub/DVD 图片字幕", result);
        goto cleanup_bitmap;
    }
    decoder = avcodec_find_decoder(stream->codecpar->codec_id);
    if (!decoder) {
        result = AVERROR_DECODER_NOT_FOUND;
        mkvff_set_error(error_message, "内嵌 FFmpeg 缺少 VobSub 解码器", result);
        goto cleanup_bitmap;
    }
    decoder_context = avcodec_alloc_context3(decoder);
    if (!decoder_context) { result = AVERROR(ENOMEM); mkvff_set_error(error_message, "内存不足", result); goto cleanup_bitmap; }
    result = avcodec_parameters_to_context(decoder_context, stream->codecpar);
    if (result < 0) { mkvff_set_error(error_message, "无法初始化 VobSub 解码器", result); goto cleanup_bitmap; }
    result = avcodec_open2(decoder_context, decoder, NULL);
    if (result < 0) { mkvff_set_error(error_message, "无法启动 VobSub 解码器", result); goto cleanup_bitmap; }
    for (unsigned int i = 0; i < format->nb_streams; ++i) {
        if ((int32_t)i != stream_index) format->streams[i]->discard = AVDISCARD_ALL;
    }
    output = fopen(output_path, "wb+");
    if (!output) { result = AVERROR(errno); mkvff_set_error(error_message, "无法创建位图字幕输出", result); goto cleanup_bitmap; }
    if (fwrite("MKVBM01\0", 1, 8, output) != 8 || mkvff_write_u32_le(output, 0) < 0) {
        result = AVERROR(EIO); mkvff_set_error(error_message, "无法写入位图字幕输出", result); goto cleanup_bitmap;
    }
    packet = av_packet_alloc();
    if (!packet) { result = AVERROR(ENOMEM); mkvff_set_error(error_message, "内存不足", result); goto cleanup_bitmap; }
    while ((result = av_read_frame(format, packet)) >= 0) {
        if (mkvff_cancelled(state)) {
            result = AVERROR_EXIT; mkvff_set_error(error_message, "任务已取消", result);
            av_packet_unref(packet); goto cleanup_bitmap;
        }
        if (packet->stream_index == stream_index) {
            AVSubtitle subtitle = {0};
            int got_subtitle = 0;
            int consumed = avcodec_decode_subtitle2(decoder_context, &subtitle, &got_subtitle, packet);
            if (consumed < 0) {
                avsubtitle_free(&subtitle);
                result = consumed; mkvff_set_error(error_message, "VobSub 数据包解码失败", result);
                av_packet_unref(packet); goto cleanup_bitmap;
            }
            if (got_subtitle) {
                int64_t timestamp = packet->pts != AV_NOPTS_VALUE ? packet->pts : packet->dts;
                int64_t start_ms = timestamp == AV_NOPTS_VALUE ? 0 :
                    av_rescale_q(timestamp, stream->time_base, (AVRational){1, 1000});
                int64_t duration_ms = packet->duration > 0 ?
                    av_rescale_q(packet->duration, stream->time_base, (AVRational){1, 1000}) : 0;
                int written = mkvff_write_bitmap_cue(output, &subtitle, start_ms, duration_ms, &total_bytes);
                avsubtitle_free(&subtitle);
                if (written < 0) {
                    result = written;
                    mkvff_set_error(error_message, written == AVERROR(ENOMEM) ?
                                    "VobSub 解码图片超过安全内存上限" : "VobSub 图片数据无效", result);
                    av_packet_unref(packet); goto cleanup_bitmap;
                }
                if (written > 0) cue_count++;
                mkvff_update_progress(state, timestamp, stream, format->duration);
            }
        }
        av_packet_unref(packet);
    }
    if (result == AVERROR_EOF) result = 0;
    if (result < 0) { mkvff_set_error(error_message, "读取 VobSub 字幕失败", result); goto cleanup_bitmap; }
    if (!cue_count) { result = AVERROR_INVALIDDATA; mkvff_set_error(error_message, "VobSub 轨道中没有可识别的字幕图片", result); goto cleanup_bitmap; }
    if (fseek(output, 8, SEEK_SET) != 0 || mkvff_write_u32_le(output, cue_count) < 0) {
        result = AVERROR(EIO); mkvff_set_error(error_message, "无法完成位图字幕输出", result); goto cleanup_bitmap;
    }
    atomic_store_explicit(&state->progress, 1.0, memory_order_relaxed);

cleanup_bitmap:
    av_packet_free(&packet);
    avcodec_free_context(&decoder_context);
    if (output && fclose(output) != 0 && result >= 0) result = AVERROR(EIO);
    avformat_close_input(&format);
    if (result < 0) remove(output_path);
    return result;
}
