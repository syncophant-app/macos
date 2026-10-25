import CryptoKit
import Foundation

@main struct CryptIntegrationCheck {
    static func main() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let proof = environment["SYNCOPHANT_CRYPT_PROOF"],
              let helper = environment["SYNCOPHANT_CRYPT_HELPER"] else { fatalError("Missing crypt integration fixture paths.") }
        let base = try LocalRemoteStore(root: URL(fileURLWithPath: proof).appendingPathComponent("remote"))
        let store = try CryptStore(base: base, password: "syncophant-public-fixture-password",
                                  password2: "syncophant-public-fixture-salt", helperURL: URL(fileURLWithPath: helper))
        let size = Int64(environment["SYNCOPHANT_CRYPT_STREAM_BYTES"] ?? "8388645")!
        let chunk = Data((0..<(1024 * 1024)).map { UInt8($0 % 251) })
        if environment["SYNCOPHANT_CRYPT_PHASE"] == "verify" {
            let expected = try String(contentsOf: URL(fileURLWithPath: proof).appendingPathComponent("sha256"), encoding: .utf8)
            guard try await store.checksum(path: "/Archive/rclone-write.bin") == expected,
                  try await store.stat(path: "/Archive/rclone-write.bin").size == size else {
                fatalError("Independent rclone write did not decrypt correctly.")
            }
            print("Independent rclone -> CryptStore round trip passed.")
            return
        }
        try await store.createDirectory(path: "/Archive")
        try await store.prepareUpload(path: "/Archive/interop.bin")
        var offset: Int64 = 0, hash = SHA256()
        while offset < size {
            let bytes = Data(chunk.prefix(Int(min(Int64(chunk.count), size - offset))))
            try await store.write(path: "/Archive/interop.bin", offset: offset, data: bytes)
            hash.update(data: bytes)
            offset += Int64(bytes.count)
        }
        try await store.finishUpload(path: "/Archive/interop.bin")
        let expectedHash = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard try await store.checksum(path: "/Archive/interop.bin") == expectedHash,
              try await store.stat(path: "/Archive/interop.bin").size == size,
              try await store.read(path: "/Archive/interop.bin", offset: 65530, length: 33) == chunk.subdata(in: 65530..<65563) else {
            fatalError("CryptStore streaming/range/checksum validation failed.")
        }
        try Data(expectedHash.utf8).write(to: URL(fileURLWithPath: proof).appendingPathComponent("sha256"))
        print("CryptStore streamed \(size) bytes with bounded 1 MiB chunks and encrypted staging.")
    }
}
