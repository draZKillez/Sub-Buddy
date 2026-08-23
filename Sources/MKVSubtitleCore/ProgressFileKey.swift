import Foundation

enum ProgressFileKey {
    static func name(prefix: String, identity: String, suffix: String) -> String {
        let readable = prefix.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? String($0) : "_"
        }.joined()
        return "\(String(readable.prefix(64)))-\(fnv1a64(identity)).\(suffix)"
    }

    private static func fnv1a64(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}
