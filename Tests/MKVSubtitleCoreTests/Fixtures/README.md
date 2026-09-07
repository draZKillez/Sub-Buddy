# Synthetic container fixtures

Generated locally with FFmpeg from a solid blue 160×90 video and `timing.srt`; no third-party film footage or dialogue. `timed.mp4` has H.264 B-frames and mov_text captions; `edited.mov` shifts the subtitle input by two seconds; `timed.webm` has VP9 and WebVTT; `no-subtitles.mp4` is video-only. Tests also copy the MP4 bytes to an uppercase `.M4V` path containing spaces, Unicode and `$`.

Expected intervals are 1.234–2.789 and 3.050–4.100 seconds, plus two seconds for `edited.mov`. These exercise real bundled demuxers/decoders; mocks alone would not detect missing compile-time FFmpeg components. The release workflow builds the stripped-down tools before running these tests.
