# Third-party notices

## FFmpeg 8.1.2

Sub Buddy distributes a deliberately reduced FFmpeg 8.1.2 build for local Matroska and subtitle processing.

- Upstream: <https://ffmpeg.org/>
- License: GNU Lesser General Public License, version 2.1 or later
- Source archive: `Vendor/Downloads/ffmpeg-8.1.2.tar.xz`
- SHA-256: `464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c`
- macOS reproducible build: `scripts/build_ffmpeg_macos.sh`
- iOS reproducible build: `scripts/build_ffmpeg_ios.sh`

The builds disable GPL and nonfree components, network protocols, external codec libraries and unnecessary media features. Full FFmpeg license text, build configuration and source-relinking notes are copied into each packaged app.

FFmpeg is a trademark of Fabrice Bellard, originator of the FFmpeg project. This project is not affiliated with or endorsed by the FFmpeg project.

## whisper.cpp 1.9.2

- Upstream: <https://github.com/ggml-org/whisper.cpp>
- License: MIT
- Purpose: fully local English speech recognition
- Official framework archive: `Vendor/Downloads/whisper-v1.9.2-xcframework.zip`
- SHA-256: `af74fed13ea7f2d5ca2a39d9f58ec177713fafd7cab63aef4e27b79f3ceca80b`

Whisper model files are not included in the App. A user may explicitly download a selected converted model from the official whisper.cpp Hugging Face repository; the App validates its expected size and published SHA-1 before installation.

## Sparkle 2.9.6

- Upstream: <https://github.com/sparkle-project/Sparkle>
- License: MIT with bundled third-party notices
- Purpose: signed application updates from GitHub Releases
- Official release archive: `Vendor/Downloads/Sparkle-2.9.6.tar.xz`
- SHA-256: `52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192`

The full upstream Sparkle license and its included third-party notices are copied into the packaged App.

## Project license

No license is granted for Sub Buddy's own source code until the repository owner adds a root `LICENSE` file. Choose a project license before inviting outside reuse or contributions.
