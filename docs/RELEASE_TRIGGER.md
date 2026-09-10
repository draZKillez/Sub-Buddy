# Explicit release trigger / 显式发布入口

## Public release notes / 对外更新说明

Keep release notes brief and bilingual (Chinese and English). Describe user-facing improvements in plain language, such as improved translation stability, clearer interactions, or new features. Do not include internal test counts, build/validation reports, debugging details, or implementation jargon. Report those details separately to the maintainer. Disclose user-impacting limitations when necessary, in plain language.

对外更新日志保持简短、中英双语，只写用户能理解的功能改进，例如提升翻译稳定性、改善交互或更新功能。不要放测试数量、构建与验证报告、排查过程和技术术语，这些单独向维护者汇报；确实影响用户使用的限制仍需用通俗语言说明。

## Publishing / 发布流程

The existing GitHub Actions release workflow can be run manually with a version and increasing build number. Alternatively, update `Packaging/ReleaseVersion.json` on `main` in the same commit as the release changes. Only changes to that file trigger a push release; ordinary code edits do not.

现有发布工作流仍支持手动填写版本号和递增构建号。也可以在提交正式版本代码时，一并修改 `main` 分支上的 `Packaging/ReleaseVersion.json`。只有修改该文件才会触发推送发布，普通代码修改不会触发。

The workflow refuses reused version tags and non-increasing Sparkle build numbers, runs tests, builds the Universal DMG, signs the appcast using the existing `SPARKLE_PRIVATE_KEY` secret, and releases the exact tested commit. It never overwrites an existing release. If a run fails, inspect its logs before retrying; never delete a published version to reuse its number.

流程会拒绝复用版本标签或未递增的构建号，运行测试、构建 Universal DMG、使用已有 `SPARKLE_PRIVATE_KEY` 签名更新清单，并发布本次测试的确切提交。不会覆盖旧版本；失败后请先查看日志，不要删除已发布版本来复用版本号。
