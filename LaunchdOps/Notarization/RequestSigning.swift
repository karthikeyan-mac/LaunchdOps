import CryptoKit
import Foundation

/// App Store Connect API token: a JWT signed with ES256. Team keys name the issuer (`iss`); individual keys use
/// `sub: user` instead.
enum AppStoreConnectToken {
  /// Apple accepts tokens that live at most 20 minutes.
  static let lifetime: TimeInterval = 15 * 60

  static func make(credentials: NotaryCredentials, now: Date = Date()) throws -> String {
    let key = try P256.Signing.PrivateKey(pemRepresentation: credentials.privateKeyPEM)
    let header: [String: String] = [
      "alg": "ES256", "kid": credentials.keyID.trimmingCharacters(in: .whitespacesAndNewlines), "typ": "JWT",
    ]
    // A minute early, so a Mac clock that runs slightly fast still produces a valid token.
    let issuedAt = Int(now.timeIntervalSince1970) - 60
    var payload: [String: Any] = [
      "iat": issuedAt,
      "exp": issuedAt + Int(lifetime),
      "aud": "appstoreconnect-v1",
    ]
    switch credentials.kind {
    case .team: payload["iss"] = credentials.issuerID.trimmingCharacters(in: .whitespacesAndNewlines)
    case .individual: payload["sub"] = "user"
    }
    let encoder: (Any) throws -> String = {
      try base64URL(JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .withoutEscapingSlashes]))
    }
    let signingInput = "\(try encoder(header)).\(try encoder(payload))"
    let signature = try key.signature(for: Data(signingInput.utf8))
    return "\(signingInput).\(base64URL(signature.rawRepresentation))"
  }

  static func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

/// AWS Signature Version 4 for the single S3 upload the notary service asks for.
struct AWSSignatureV4: Sendable {
  var accessKeyID: String
  var secretAccessKey: String
  var sessionToken: String?
  var region: String
  var service = "s3"

  /// Returns the headers to send, including `Authorization`. `headers` must not contain `host`.
  func signedHeaders(
    method: String,
    host: String,
    path: String,
    headers: [String: String] = [:],
    payloadHash: String,
    date: Date
  ) -> [String: String] {
    let amzDate = Self.timestamp(date, format: "yyyyMMdd'T'HHmmss'Z'")
    let day = Self.timestamp(date, format: "yyyyMMdd")

    var all = headers
    all["host"] = host
    all["x-amz-date"] = amzDate
    all["x-amz-content-sha256"] = payloadHash
    if let sessionToken { all["x-amz-security-token"] = sessionToken }

    let names = all.keys.map { $0.lowercased() }.sorted()
    let lowered = Dictionary(uniqueKeysWithValues: all.map { ($0.key.lowercased(), $0.value) })
    let canonicalHeaders = names.map {
      "\($0):\(lowered[$0, default: ""].trimmingCharacters(in: .whitespacesAndNewlines))\n"
    }
    .joined()
    let signedHeaderNames = names.joined(separator: ";")
    let canonicalRequest = [method, path, "", canonicalHeaders, signedHeaderNames, payloadHash]
      .joined(separator: "\n")

    let scope = "\(day)/\(region)/\(service)/aws4_request"
    let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope, Self.hex(SHA256.hash(data: Data(canonicalRequest.utf8)))]
      .joined(separator: "\n")

    var key = SymmetricKey(data: Data("AWS4\(secretAccessKey)".utf8))
    for part in [day, region, service, "aws4_request"] {
      key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
    }
    let signature = Self.hex(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key))

    var result = all
    result.removeValue(forKey: "host")
    result["Authorization"] =
      "AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(scope), SignedHeaders=\(signedHeaderNames), Signature=\(signature)"
    return result
  }

  /// URI-encodes an S3 object key, keeping `/` between segments.
  static func encodedPath(forKey key: String) -> String {
    // RFC 3986 unreserved characters, ASCII only; everything else is percent-encoded.
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
    let segments = key.split(separator: "/", omittingEmptySubsequences: false).map { segment in
      String(segment).addingPercentEncoding(withAllowedCharacters: allowed) ?? String(segment)
    }
    return "/" + segments.joined(separator: "/")
  }

  static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
    bytes.map { String(format: "%02x", $0) }.joined()
  }

  private static func timestamp(_ date: Date, format: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = format
    return formatter.string(from: date)
  }
}
