import Foundation
import CryptoKit

struct S3Signing: Sendable {
    let accessKey: String
    let secretKey: String
    let region: String
    let sessionToken: String?

    private func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }
    private func host(_ url: URL) -> String {
        let c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        return c.host! + (c.port.map { ":\($0)" } ?? "")
    }
    static func query(_ items: [(String, String)]) -> String {
        let encoded: [(String, String)] = items.map { (HTTPStoreSupport.encode($0.0), HTTPStoreSupport.encode($0.1)) }
        let sorted = encoded.sorted { a, b in a.0 == b.0 ? a.1 < b.1 : a.0 < b.0 }
        return sorted.map { $0.0 + "=" + $0.1 }.joined(separator: "&")
    }
    private func signature(_ canonical: String, timestamp: String) -> String {
        let day = String(timestamp.prefix(8)), scope = "\(day)/\(region)/s3/aws4_request"
        func hmac(_ key: Data, _ value: String) -> Data { Data(HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: SymmetricKey(data: key))) }
        var key = hmac(Data(("AWS4" + secretKey).utf8), day)
        key = hmac(key, region); key = hmac(key, "s3"); key = hmac(key, "aws4_request")
        let hash = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        return hmac(key, "AWS4-HMAC-SHA256\n\(timestamp)\n\(scope)\n\(hash)").map { String(format: "%02x", $0) }.joined()
    }
    func sign(_ request: inout URLRequest, payloadHash: String, now: Date = Date()) {
        let timestamp = timestamp(now), day = String(timestamp.prefix(8)), url = request.url!
        request.setValue(host(url), forHTTPHeaderField: "Host")
        request.setValue(timestamp, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        if let sessionToken { request.setValue(sessionToken, forHTTPHeaderField: "x-amz-security-token") }
        let headers = (request.allHTTPHeaderFields ?? [:]).map { ($0.key.lowercased(), $0.value.split(whereSeparator: \.isWhitespace).joined(separator: " ")) }.sorted { $0.0 < $1.0 }
        let names = headers.map(\.0).joined(separator: ";")
        let c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let canonical = "\(request.httpMethod!)\n\(c.percentEncodedPath)\n\(c.percentEncodedQuery ?? "")\n" + headers.map { "\($0):\($1)\n" }.joined() + "\n\(names)\n\(payloadHash)"
        let signed = signature(canonical, timestamp: timestamp)
        request.setValue("AWS4-HMAC-SHA256 Credential=\(accessKey)/\(day)/\(region)/s3/aws4_request, SignedHeaders=\(names), Signature=\(signed)", forHTTPHeaderField: "Authorization")
    }

    func presignedGET(_ url: URL, expires: Int, now: Date = Date()) throws -> URL {
        guard (1...604800).contains(expires) else { throw CoreKitError.remote("S3 sharing expiry must be between one second and seven days.") }
        let timestamp = timestamp(now), scope = "\(timestamp.prefix(8))/\(region)/s3/aws4_request"
        var items = [("X-Amz-Algorithm", "AWS4-HMAC-SHA256"), ("X-Amz-Credential", "\(accessKey)/\(scope)"),
                     ("X-Amz-Date", timestamp), ("X-Amz-Expires", String(expires)), ("X-Amz-SignedHeaders", "host")]
        if let sessionToken { items.append(("X-Amz-Security-Token", sessionToken)) }
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let canonical = "GET\n\(c.percentEncodedPath)\n\(Self.query(items))\nhost:\(host(url))\n\nhost\nUNSIGNED-PAYLOAD"
        items.append(("X-Amz-Signature", signature(canonical, timestamp: timestamp)))
        c.percentEncodedQuery = Self.query(items)
        guard let url = c.url else { throw CoreKitError.remote("Cannot construct S3 sharing URL.") }
        return url
    }
}
