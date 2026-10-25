import Foundation
import Security
import CryptoKit

/// A 160-bit recovery key in Crockford base32, shown as 8 groups of 4. It is used directly as the rclone crypt
/// password, so the printed sheet alone unlocks the storage on any Mac (or with rclone itself).
enum RecoveryKey {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func generate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 20)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "This Mac could not generate a random key."])
        }
        var symbols: [Character] = [], buffer = 0, bits = 0
        for byte in bytes {
            buffer = (buffer << 8) | Int(byte); bits += 8
            while bits >= 5 { bits -= 5; symbols.append(alphabet[(buffer >> bits) & 31]) }
            buffer &= (1 << bits) - 1
        }
        return grouped(symbols)
    }

    /// The canonical key for anything typed that looks like one: case, spaces and dashes are ignored, and the
    /// look-alikes O, I and L read as 0, 1 and 1. Returns nil for anything else (a passphrase).
    static func canonical(_ input: String) -> String? {
        let symbols = normalize(input)
        guard symbols.count == 32, symbols.allSatisfy(alphabet.contains) else { return nil }
        return grouped(symbols)
    }

    static func normalize(_ input: String) -> [Character] {
        input.uppercased().filter { $0 != " " && $0 != "-" }.map { c in
            switch c { case "O": "0"; case "I", "L": "1"; default: c }
        }
    }

    private static func grouped(_ symbols: [Character]) -> String {
        stride(from: 0, to: symbols.count, by: 4).map { String(symbols[$0..<min($0 + 4, symbols.count)]) }.joined(separator: "-")
    }
}

/// Random words for "Suggest Four Words", from the macOS system word list (nothing is downloaded).
enum PassphraseWords {
    /// About 48,000 four-to-seven letter words on a stock Mac: roughly 15.5 bits a word.
    static let list: [String] = {
        let text = (try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8)) ?? ""
        let words = text.split(separator: "\n").filter { (4...7).contains($0.count) && $0.allSatisfy { $0.isASCII && $0.isLowercase } }.map(String.init)
        return words.count >= 2048 ? words : fallback
    }()

    /// `SystemRandomNumberGenerator` is cryptographically secure on Apple platforms. A short fallback list gets
    /// more words so the phrase stays above 56 bits.
    static func suggest() -> String {
        let count = max(4, Int((56 / log2(Double(list.count))).rounded(.up)))
        return (0..<count).compactMap { _ in list.randomElement() }.joined(separator: " ")
    }

    private static let fallback = """
    acorn amber anchor apple arrow atlas autumn badge bamboo banjo barley basket beacon berry bison blanket bloom \
    border breeze bridge bronze bubble cabin cactus camel candle canyon carbon cargo castle cedar cello chalk cherry \
    cinder citrus clover cobalt comet copper coral cotton crater cricket crystal dagger daisy delta denim desert \
    dolphin dragon drift eagle echo ember falcon fern fiddle flint forest fossil galaxy garnet geyser ginger glacier \
    granite gravel harbor hazel helmet heron hollow honey island ivory jasper jungle kettle lagoon lantern lemon \
    lilac linen lotus magnet maple marble meadow meteor mint mosaic nectar nickel north oasis olive onyx orbit otter \
    paddle panda pepper pebble pilot pine planet plume prairie quartz quill rabbit raven reef ribbon river rocket \
    saffron salmon sapphire satin shadow silver spruce summit tango thistle thunder timber topaz tulip tundra velvet \
    violet walnut willow window winter yarrow zephyr
    """.split(whereSeparator: \.isWhitespace).map(String.init)
}

/// What an rclone crypt remote (standard name encryption, base32, directory names encrypted) puts on the server.
enum CryptPreview {
    /// Exact stored size: a 32-byte header plus 16 bytes per 64 KiB block.
    static func encryptedSize(_ size: Int64) -> Int64 {
        32 + size + 16 * ((size + 65_535) / 65_536)
    }

    /// A stand-in with the real length and alphabet of an encrypted name. It is not the real ciphertext, which
    /// depends on the key; the UI labels it as an illustration.
    static func illustrativeName(_ name: String) -> String {
        let padded = (name.utf8.count / 16 + 1) * 16
        let length = (padded * 8 + 4) / 5
        let alphabet = Array("0123456789abcdefghijklmnopqrstuv")
        var out = "", counter = 0
        while out.count < length {
            let digest = SHA256.hash(data: Data("\(counter):\(name)".utf8))
            for byte in digest where out.count < length { out.append(alphabet[Int(byte) & 31]) }
            counter += 1
        }
        return out
    }
}
