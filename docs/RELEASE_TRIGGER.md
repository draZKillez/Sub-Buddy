# Explicit release trigger / 显式发布入口

The existing GitHub Actions release workflow can be run manually with a version and increasing build number. Alternatively, update `Packaging/ReleaseVersion.json` on `main` in the same commit as the release changes. Only changes to that file trigger a push release; ordinary code edits do not.

现有发布工作流仍支持手动填写版本号和递增构建号。也可以在提交正式版本代码时，一并修改 `main` 分支上的 `Packaging/ReleaseVersion.json`。只有修改该文件才会触发推送发布，普通代码修改不会触发。

The workflow refuses reused version tags and non-increasing Sparkle build numbers, runs tests, builds the Universal DMG, signs the appcast using the existing `SPARKLE_PRIVATE_KEY` secret, and releases the exact tested commit. It never overwrites an existing release. If a run fails, inspect its logs before retrying; never delete a published version to reuse its number.

流程会拒绝复用版本标签或未递增的构建号，运行测试、构建 Universal DMG、使用已有 `SPARKLE_PRIVATE_KEY` 签名更新清单，并发布本次测试的确切提交。不会覆盖旧版本；失败后请先查看日志，不要删除已发布版本来复用版本号。
