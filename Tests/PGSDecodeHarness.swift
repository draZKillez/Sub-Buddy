import Foundation

@main
enum PGSDecodeHarness {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let cues = try PGSSubtitleDecoder().decode(data)
        print("bytes=\(data.count) cues=\(cues.count)")
        if let first = cues.first, let last = cues.last {
            print("first=\(first.startMilliseconds)-\(first.endMilliseconds) \(first.width)x\(first.height)")
            print("last=\(last.startMilliseconds)-\(last.endMilliseconds) \(last.width)x\(last.height)")
        }
    }
}
