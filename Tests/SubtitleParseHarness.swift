import Foundation

@main
enum SubtitleParseHarness {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { return }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let document = try SubtitleParser().parse(contentsOf: url, format: .srt)
        print("cues=\(document.cues.count) first=\(document.cues.first?.id ?? -1) last=\(document.cues.last?.id ?? -1)")
        print(document.cues.first?.text ?? "")
        print(document.cues.last?.text ?? "")
    }
}
