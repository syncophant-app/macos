import Foundation

@main
struct EncryptionSelfCheck {
    static func main() throws {
        let key = try RecoveryKey.generate()
        precondition(key.count == 39 && key.split(separator: "-").count == 8, "8 groups of 4")
        let other = try RecoveryKey.generate()
        precondition(key != other, "keys differ")
        precondition(RecoveryKey.canonical(key) == key)
        let typed = key.lowercased().replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "0", with: "o").replacingOccurrences(of: "1", with: "l")
        precondition(RecoveryKey.canonical(typed) == key, "look-alikes and case are forgiven")
        precondition(RecoveryKey.canonical("harbor velvet orbit lantern") == nil, "a passphrase is not a key")
        precondition(PassphraseWords.suggest().split(separator: " ").count >= 4)
        precondition(PassphraseWords.list.count > 2048, "system word list is used")
        precondition(CryptPreview.encryptedSize(0) == 32 && CryptPreview.encryptedSize(65_536) == 65_584 && CryptPreview.encryptedSize(65_537) == 65_601)
        precondition(CryptPreview.illustrativeName("a.txt").count == 26 && CryptPreview.illustrativeName(String(repeating: "x", count: 16)).count == 52)
        print("encryption self-check passed")
    }
}
