// AWS Signature Version 4 signing (non-S3 services) with CryptoKit.
import CryptoKit
import Foundation

public struct AWSCredentials: Sendable, Equatable {
    public var accessKeyId: String
    public var secretAccessKey: String
    public var sessionToken: String?
    public var expiration: Date?
    public init(accessKeyId: String, secretAccessKey: String, sessionToken: String? = nil, expiration: Date? = nil) {
        self.accessKeyId = accessKeyId; self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken; self.expiration = expiration
    }
}

enum SigV4 {
    /// RFC 3986 unreserved characters; everything else is percent-encoded.
    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")

    static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    static func hex(_ d: some Sequence<UInt8>) -> String { d.map { String(format: "%02x", $0) }.joined() }
    static func sha256(_ data: Data) -> String { hex(SHA256.hash(data: data)) }
    static func hmac(_ key: Data, _ msg: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(msg.utf8), using: SymmetricKey(data: key)))
    }

    /// Signs `request` in place. `encodedPath` is the request path exactly as
    /// sent (segments already percent-encoded once); `query` is unencoded.
    static func sign(request: inout URLRequest, method: String, host: String, encodedPath: String,
                     query: [(String, String)], body: Data, service: String, region: String,
                     credentials: AWSCredentials, date: Date = Date()) {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = fmt.string(from: date)
        let day = String(amzDate.prefix(8))
        let payloadHash = sha256(body)

        var headers: [String: String] = ["host": host, "x-amz-date": amzDate]
        if let t = credentials.sessionToken { headers["x-amz-security-token"] = t }
        if let ct = request.value(forHTTPHeaderField: "Content-Type") { headers["content-type"] = ct }

        // Non-S3: each path segment is URI-encoded twice in the canonical request.
        let canonicalPath = encodedPath.split(separator: "/", omittingEmptySubsequences: false)
            .map { encode(String($0)) }.joined(separator: "/")
        let encodedPairs: [(String, String)] = query.map { (encode($0.0), encode($0.1)) }
        let sortedPairs = encodedPairs.sorted { (a: (String, String), b: (String, String)) -> Bool in
            a.0 == b.0 ? a.1 < b.1 : a.0 < b.0
        }
        let canonicalQuery = sortedPairs.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
        let signedNames = headers.keys.sorted()
        let canonicalHeaders = signedNames.map { "\($0):\(headers[$0]!.trimmingCharacters(in: .whitespaces))\n" }.joined()
        let signedHeaders = signedNames.joined(separator: ";")
        let canonical = [method, canonicalPath.isEmpty ? "/" : canonicalPath, canonicalQuery,
                         canonicalHeaders, signedHeaders, payloadHash].joined(separator: "\n")

        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let toSign = ["AWS4-HMAC-SHA256", amzDate, scope, sha256(Data(canonical.utf8))].joined(separator: "\n")
        var key = hmac(Data("AWS4\(credentials.secretAccessKey)".utf8), day)
        key = hmac(key, region); key = hmac(key, service); key = hmac(key, "aws4_request")
        let signature = hex(hmac(key, toSign))

        request.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")
        if let t = credentials.sessionToken { request.setValue(t, forHTTPHeaderField: "X-Amz-Security-Token") }
        request.setValue("AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyId)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
                         forHTTPHeaderField: "Authorization")
    }
}
