# Subtitle batch benchmark

## 2026-09-05–06 实测结论 / Results

**产品默认选择 250，优先更早保存首批结果。** 在这份短对白样本和当前模型上，500 只比 250/350
快约 2%–3%，不是数量翻倍、速度翻倍。250 更早返回首批结果；500 少一次请求，
减少重复输入。不能把这次结果外推为所有影片、语言或模型的最优值。

Product decision: default to 250 for earlier saved results, while keeping the batch size editable.

Same 495-cue English SDH source (16,093 body characters), `gpt-5.6-luna`,
reasoning `none`, sequential requests, 50-cue context on either side where
available. Times exclude video extraction, OCR, compilation and time between
experiments. Quota-interrupted attempts are excluded, not counted as fast runs.

| Batch limit | First complete run | Repeat | First saved result | Model requests per successful run |
| --- | ---: | ---: | ---: | ---: |
| 250 | 301.93 s | 300.44 s | 153–154 s | 2 |
| 350 | 300.78 s | 301.20 s | 208–209 s | 2 |
| 500 (actual core: 495) | 293.27 s | 294.19 s* | 293–294 s | 1 |

*500's repeat time is the recorded model-call time. That experiment initially
failed SRT export round-trip due to the trailing-newline bug described below.
After the writer fix, its saved 495 translations were exported and verified
offline with identical IDs/timestamps, without retranslation. It is not a second
uninterrupted end-to-end timing. The 250 repeat was run after quota recovered the
next day; service load/time-of-day and caching are not controlled. Treat the small
speed difference as preliminary, not statistically established superiority.*

No model-format recovery was needed in these six completed generations after
the slash-encoding fix. First-run input usage was about 37,165 / 37,162 / 22,174
tokens for 250 / 350 / 500 respectively; output usage was approximately 16,000
tokens in every case. Input counts include CLI context and cached tokens and are
**not** a direct estimate of money or account quota saved.

### Language checks

Same first 48 cues, one request per language, same prompt contract:

| English → | Elapsed | Source/ID valid | Export timeline | HTML/ASS tag differences |
| --- | ---: | ---: | --- | ---: |
| Spanish | 35.96 s | 48/48 | unchanged | 0 |
| Japanese | 38.52 s | 48/48 | unchanged | 0 |
| Arabic | 39.72 s | 48/48 | unchanged | 0 |

No retries. Local Natural Language recognition identified the expected target
language in each aggregate output. Sample inspection confirmed Japanese script,
Spanish punctuation, Arabic script, and retained subtitle tags; no Unicode bidi
override controls were present. These are smoke tests, **not** exhaustive human
translation-quality evaluations or batch-size comparisons for those languages.
All 100 source/target prompt combinations are covered separately by unit tests.

### Remaining format limitations

Source/ID validation does not prove every translated word belongs to the right
cue or that every formatting instruction was obeyed. On the full Chinese runs,
raw newline counts differed from the source in 71/66 cues (250), 81/84 (350),
and 27/23 (500). One cue in the 350 repeat lost its italic tags; the other five
runs had no HTML/ASS tag differences. The Spanish/Japanese/Arabic smoke tests had
1/2/0 newline-count differences. Timelines were not shifted by these layout
differences. The new writer prevents blank lines from breaking the container
format, but does **not** reconstruct missing line breaks or styling, and the
current validator does not automatically reject these layout differences.

### Local evidence (ignored by Git)

- `.build/batch-benchmark-20260905-clean-slashes/`: first three runs and 500 repeat;
  `zh-Hans-500-r2-safe-export.srt` is the verified offline replay.
- `.build/batch-benchmark-20260905-confirm/`: 350 repeat plus excluded interrupted 250 attempt.
- `.build/batch-benchmark-20260906-final250/`: completed 250 repeat.
- `.build/batch-benchmark-20260906-multilingual/`: three language smoke tests.

No original video/subtitle was overwritten. No test subtitle or raw model
response is included in Git; only this aggregate report and the test harness are
part of the working-tree changes. No release or default-batch-size change was made.

## Method

This opt-in integration benchmark uses the same `CodexBridge`, prompt builder,
source-echo validator and bounded recovery engine as the app. It uses the user's
existing official Codex login. It never reads authentication files and has no API
key path. Running it consumes account quota; ordinary tests and CI skip it.

## Reproduce

Supply an extracted SRT you are allowed to process and a new output directory:

```sh
SUB_BUDDY_BENCH_SOURCE="/absolute/path/source.srt" \
SUB_BUDDY_BENCH_OUTPUT="/absolute/path/new-benchmark-directory" \
SUB_BUDDY_CODEX_EXECUTABLE="/absolute/path/codex" \
SUB_BUDDY_BENCH_SIZES="250,350,500" \
SUB_BUDDY_BENCH_REPEATS="2" \
SUB_BUDDY_BENCH_LANGUAGES="zh-Hans" \
swift test --filter TranslationBatchBenchmarkTests
```

The default model is the app's `gpt-5.6-luna`, with its production reasoning and
sandbox settings. `SUB_BUDDY_BENCH_MODEL` explicitly overrides it; there is no
fallback model. `SUB_BUDDY_BENCH_CUE_LIMIT` optionally selects the first N cues for
a small language smoke test. Supported target codes are `en`, `zh-Hans`, `es`,
`fr`, `de`, `ja`, `ko`, `pt`, `ru`, `ar`.

Experiments run **sequentially**, never competing with each other for throughput.
The second repetition reverses batch-size order. Every experiment starts with
an empty glossary and no saved translations. The glossary then carries across
chunks exactly as in production. Input fingerprint, model, prompt hashes,
characters, first validated-result time, total time, actual requests, repair
rounds, completed cues, token usage (when CLI reports it) and failures are recorded.
Final model messages are saved locally for diagnosing rejected entries, not the
CLI's authentication state or raw diagnostic logs. Exported SRT IDs and timelines
are round-trip checked. Film extraction and UI rendering are not timed.

Reports and translated subtitles are written locally, not committed or uploaded.
Use a new directory per run: existing final report files are never overwritten.

## Interpreting results

- Compare **complete-dataset elapsed time including recovery**, not just the
  first request or seconds per batch. Batch sizes are upper limits: a 495-cue
  source at limit 500 has one 495-cue request, not a padded 500-cue request.
- Two repetitions provide a small controlled comparison, not statistical proof.
  Backend load, network and prompt caching remain confounders; this does not
  measure uncached service latency in isolation.
- ID/source validation detects many structural errors, not every semantic
  mistranslation or sentence shift. Read sample outputs as well.
- A few target-language smoke tests do not establish the best batch size for
  all language pairs, models, or long-dialogue movies.
- Keep source echo, tags, line breaks, glossary and language rules identical
  across batch-size variants; do not trade correctness for a faster benchmark.

## Multilingual prompt contract

Automatic JSON and manual SRT prompts share a language policy with explicit
source and target codes, independent of the app's UI language. A user-entered
reference title is identifying context, not an instruction to use its language.
The policy specifies native writing systems, consistent names/register,
translated SDH descriptions, preserved markup and cue boundaries, and logical
Arabic text order. The app, not the model, assembles bilingual subtitles.

Unit tests cover all 100 source/target combinations. These are prompt-contract
tests, not claims about translation quality for every pair.

## Issue found during the 2026-09-05 pilot

On a 495-cue English SDH source, a 250-cue request returned six incorrect source
echoes. Every one contained an unnecessary literal backslash before `/`: five
HTML closing tags and one slash-separated name. The single-name cue still failed
after the two allowed repair rounds. The input encoder had legally escaped `/`
as `\/`; the model sometimes double-escaped it instead of preserving its decoded
value. This is not evidence that the original subtitle itself was invalid.

The prompt encoder now emits unescaped slashes and deterministic key ordering,
and reuses one encoder per cue list. Strict source correspondence is unchanged;
genuine backslashes and newlines still round-trip. A dedicated regression test
covers HTML, slash-separated names, filesystem-style text and literal `\/`.
Pilot timings before this fix must not be pooled with the corrected-prompt runs.

A second issue surfaced during the 500-limit repeat: a valid JSON response had a
trailing newline in one cue's translation. The old writer added its own separator,
producing three consecutive newlines, and the strict SRT parser could not read
the next cue. SRT/VTT export now drops whitespace-only body lines and normalizes
CRLF/CR, leaving all nonempty text lines, tags, cue IDs and timing intact. Empty
bodies fail explicitly. ASS output is not subject to this block-format rule.
The saved model response is replay-tested offline, without another model call.
