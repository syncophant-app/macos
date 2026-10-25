import Security

public enum PasswordGenerator {
    /// Meets Storage Box's uppercase, lowercase, digit, special-character and length requirements.
    public static func make() throws -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789-_.+")
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CoreKitError.connection("The system could not generate a random password.")
        }
        var chars = bytes.map { alphabet[Int($0) % alphabet.count] }
        chars[0] = "A"; chars[1] = "z"; chars[2] = "7"; chars[3] = "+"
        chars.shuffle()
        return String(chars)
    }
}
