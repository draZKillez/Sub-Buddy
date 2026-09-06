import Foundation
import XCTest

final class LocalizationCoverageTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testWorkspaceNavigationIsTranslatedInEverySupportedInterfaceLanguage() throws {
        let requiredKeys: Set<String> = [
            "刷新模型列表", "正在刷新模型…", "推理强度", "关闭额外推理（速度优先）",
            "电影信息（可选）", "条（1–1000，默认 250）",
            "模型列表已刷新；不会自动更换当前模型或推理强度。",
            "当前模型或推理强度不在刷新后的支持列表中，请手动重新选择。",
            "模型列表刷新失败。请检查连接和登录状态；若仍无效，请更新 Sub Buddy 和 Codex 后重试。",
            "较高推理强度可能增加耗时和额度消耗，不保证译文一定更好。刷新列表无效时，建议更新 Sub Buddy 和 Codex。",
            "每块通过一次 stdin 整批提交；默认 Luna、关闭额外推理、250 条，更早保存首批结果。",
            "使用本机 Codex model/list；刷新无效时请更新 Sub Buddy 和 Codex。",
            "选择影片", "选择字幕", "翻译设置", "生成字幕", "完成",
            "运行环境和连接", "没有合适字幕？从英语音轨生成",
            "拖入一部影片或选择文件，应用只读取媒体信息。",
            "选择要翻译的字幕轨道；图片字幕会在本机 OCR。",
            "确认语言、翻译方式与输出格式，片名信息均可修改。",
            "检查输出摘要，然后开始生成；已完成进度会保存在本机。",
            "字幕已经生成，原始影片没有被替换。",
            "本地处理，不上传视频或登录凭据", "返回上一步", "继续：%@",
            "累计用时：%@ · 本阶段预计剩余：%@", "本阶段预计完成：%@",
            "整体粗略剩余：%@ · 整体粗略完成：%@", "累计用时：%@ · 整体粗略剩余：%@",
            "整体粗略完成：%@", "正在收集字幕数量和处理速度",
            "整体估算受文件大小与磁盘速度、字幕或 OCR 数量、分块数量、翻译模型及网络或服务负载、格式修复或重试影响；阶段切换后会持续校正。",
            "手动模式还取决于每份内容在外部工具中的翻译、复制和粘贴速度；完成首份后会按实际速度校正。"
        ]
        for locale in ["zh-Hans", "en", "es", "fr", "de", "ja", "ko", "pt", "ru", "ar"] {
            let file = repositoryRoot
                .appendingPathComponent("Localization")
                .appendingPathComponent("\(locale).lproj")
                .appendingPathComponent("Localizable.strings")
            let keys = try localizationKeys(in: file)
            XCTAssertTrue(
                requiredKeys.isSubset(of: keys),
                "\(locale) is missing: \(requiredKeys.subtracting(keys).sorted())"
            )
        }
    }

    func testEveryStaticChineseAppStringHasEnglishFallback() throws {
        let sourceDirectory = repositoryRoot.appendingPathComponent("Sources/MKVSubtitleTranslatorApp")
        let files = try FileManager.default.contentsOfDirectory(
            at: sourceDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        let englishKeys = try localizationKeys(
            in: repositoryRoot.appendingPathComponent("Localization/en.lproj/Localizable.strings")
        )
        let literalPattern = try NSRegularExpression(
            pattern: #""((?:[^"\\]|\\.)*[\u3400-\u9FFF](?:[^"\\]|\\.)*)""#
        )
        var missing: Set<String> = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            for match in literalPattern.matches(in: source, range: range) {
                guard let valueRange = Range(match.range(at: 1), in: source) else { continue }
                let value = String(source[valueRange])
                guard !value.contains(#"\("#) else { continue }
                if !englishKeys.contains(value) { missing.insert(value) }
            }
        }
        XCTAssertTrue(missing.isEmpty, "Missing English fallbacks: \(missing.sorted())")
    }

    func testLocalizedFormatPlaceholdersMatchTheirKeys() throws {
        for locale in ["zh-Hans", "en", "es", "fr", "de", "ja", "ko", "pt", "ru", "ar"] {
            let file = repositoryRoot
                .appendingPathComponent("Localization")
                .appendingPathComponent("\(locale).lproj")
                .appendingPathComponent("Localizable.strings")
            for (key, value) in try localizationEntries(in: file) {
                XCTAssertEqual(
                    formatPlaceholders(in: value).sorted(),
                    formatPlaceholders(in: key).sorted(),
                    "\(locale) has incompatible format placeholders for key: \(key)"
                )
            }
        }
    }

    func testBundleBrandNameIsLocalizedConsistently() throws {
        for locale in ["zh-Hans", "en", "es", "fr", "de", "ja", "ko", "pt", "ru", "ar"] {
            let file = repositoryRoot
                .appendingPathComponent("Localization")
                .appendingPathComponent("\(locale).lproj")
                .appendingPathComponent("InfoPlist.strings")
            let data = try Data(contentsOf: file)
            let entries = try XCTUnwrap(
                PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
            )
            XCTAssertEqual(entries["CFBundleDisplayName"], "Sub Buddy", locale)
            XCTAssertEqual(entries["CFBundleName"], "Sub Buddy", locale)
        }
    }

    private func localizationKeys(in file: URL) throws -> Set<String> {
        let contents = try String(contentsOf: file, encoding: .utf8)
        let expression = try NSRegularExpression(
            pattern: #"^"((?:[^"\\]|\\.)*)"\s*="#,
            options: [.anchorsMatchLines]
        )
        let range = NSRange(contents.startIndex..., in: contents)
        return Set(expression.matches(in: contents, range: range).compactMap { match in
            guard let keyRange = Range(match.range(at: 1), in: contents) else { return nil }
            return String(contents[keyRange])
        })
    }

    private func localizationEntries(in file: URL) throws -> [(String, String)] {
        let contents = try String(contentsOf: file, encoding: .utf8)
        let expression = try NSRegularExpression(
            pattern: #"^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;"#,
            options: [.anchorsMatchLines]
        )
        let range = NSRange(contents.startIndex..., in: contents)
        return expression.matches(in: contents, range: range).compactMap { match in
            guard let keyRange = Range(match.range(at: 1), in: contents),
                  let valueRange = Range(match.range(at: 2), in: contents) else { return nil }
            return (String(contents[keyRange]), String(contents[valueRange]))
        }
    }

    private func formatPlaceholders(in value: String) -> [String] {
        let expression = try! NSRegularExpression(
            pattern: #"(?<!%)%(?!%)(?:\d+\$)?[-+0 #']*(?:\d+|\*)?(?:\.\d+)?(?:hh|h|ll|l|L|z|j|t)?([@diuoxXfFeEgGaAcCsSp])"#
        )
        let range = NSRange(value.startIndex..., in: value)
        return expression.matches(in: value, range: range).compactMap { match in
            guard let conversionRange = Range(match.range(at: 1), in: value) else { return nil }
            return String(value[conversionRange])
        }
    }
}
