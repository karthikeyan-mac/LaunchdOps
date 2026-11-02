import CryptoKit
import Foundation
import Synchronization
import Testing

@testable import LaunchdOps

struct AppStoreConnectTokenTests {
  @Test func tokenHasExpectedClaimsAndVerifies() throws {
    let key = P256.Signing.PrivateKey()
    let credentials = NotaryCredentials(
      issuerID: "57246542-96fe-1a63-e053-0824d011072a",
      keyID: "2X9R4HXF34",
      privateKeyPEM: key.pemRepresentation
    )
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let token = try AppStoreConnectToken.make(credentials: credentials, now: now)
    let parts = token.split(separator: ".").map(String.init)
    try #require(parts.count == 3)

    func decode(_ part: String) throws -> [String: Any] {
      var base64 = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
      base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
      let data = try #require(Data(base64Encoded: base64))
      return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    let header = try decode(parts[0])
    let payload = try decode(parts[1])
    #expect(header["alg"] as? String == "ES256")
    #expect(header["kid"] as? String == "2X9R4HXF34")
    #expect(payload["iss"] as? String == "57246542-96fe-1a63-e053-0824d011072a")
    #expect(payload["aud"] as? String == "appstoreconnect-v1")
    // Issued a minute early to tolerate a fast clock; still valid for 15 minutes from issue.
    #expect(payload["iat"] as? Int == 1_799_999_940)
    #expect(payload["exp"] as? Int == 1_800_000_840)

    var signatureBase64 = parts[2].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    signatureBase64 += String(repeating: "=", count: (4 - signatureBase64.count % 4) % 4)
    let signature = try P256.Signing.ECDSASignature(
      rawRepresentation: try #require(Data(base64Encoded: signatureBase64)))
    #expect(key.publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))
  }

  @Test func individualKeyTokenUsesSubjectInsteadOfIssuer() throws {
    let key = P256.Signing.PrivateKey()
    let credentials = NotaryCredentials(
      kind: .individual, issuerID: "", keyID: "2X9R4HXF34", privateKeyPEM: key.pemRepresentation)
    let token = try AppStoreConnectToken.make(credentials: credentials, now: Date(timeIntervalSince1970: 1_800_000_000))
    var base64 = String(token.split(separator: ".")[1]).replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    let payloadData = try #require(Data(base64Encoded: base64))
    let payload = try #require(try JSONSerialization.jsonObject(with: payloadData) as? [String: Any])
    #expect(payload["sub"] as? String == "user")
    #expect(payload["iss"] == nil)
    #expect(payload["aud"] as? String == "appstoreconnect-v1")
  }

  @Test func individualKeyNeedsNoIssuerAndOldKeysDecodeAsTeam() throws {
    let pem = P256.Signing.PrivateKey().pemRepresentation
    #expect(throws: Never.self) {
      try NotaryCredentials(kind: .individual, issuerID: "", keyID: "ABCDE12345", privateKeyPEM: pem).validate()
    }
    let saved = try JSONSerialization.data(withJSONObject: [
      "issuerID": UUID().uuidString, "keyID": "ABCDE12345", "privateKeyPEM": pem,
    ])
    #expect(try JSONDecoder().decode(NotaryCredentials.self, from: saved).kind == .team)
  }

  @Test func credentialValidation() {
    let key = P256.Signing.PrivateKey().pemRepresentation
    let valid = NotaryCredentials(issuerID: UUID().uuidString, keyID: "ABCDE12345", privateKeyPEM: key)
    #expect(throws: Never.self) { try valid.validate() }
    #expect(throws: NotaryCredentials.ValidationError.issuerID) {
      try NotaryCredentials(issuerID: "team", keyID: "ABCDE12345", privateKeyPEM: key).validate()
    }
    #expect(throws: NotaryCredentials.ValidationError.keyID) {
      try NotaryCredentials(issuerID: UUID().uuidString, keyID: "abc", privateKeyPEM: key).validate()
    }
    #expect(throws: NotaryCredentials.ValidationError.privateKey) {
      try NotaryCredentials(issuerID: UUID().uuidString, keyID: "ABCDE12345", privateKeyPEM: "not a key").validate()
    }
  }
}

struct AWSSignatureTests {
  /// "GET Object" example from the AWS Signature Version 4 documentation for S3.
  @Test func matchesPublishedExample() throws {
    let signer = AWSSignatureV4(
      accessKeyID: "AKIAIOSFODNN7EXAMPLE",
      secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
      sessionToken: nil,
      region: "us-east-1"
    )
    let headers = signer.signedHeaders(
      method: "GET",
      host: "examplebucket.s3.amazonaws.com",
      path: "/test.txt",
      headers: ["Range": "bytes=0-9"],
      payloadHash: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
      date: Date(timeIntervalSince1970: 1_369_353_600)  // 2013-05-24T00:00:00Z
    )
    #expect(
      headers["Authorization"]
        == "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, "
        + "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, "
        + "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
    )
    #expect(headers["x-amz-date"] == "20130524T000000Z")
  }

  @Test func encodesObjectKeys() {
    #expect(AWSSignatureV4.encodedPath(forKey: "a b/c+d.pkg") == "/a%20b/c%2Bd.pkg")
  }

  @Test func readsRegionFromS3Error() {
    let body = Data("<Error><Code>AuthorizationHeaderMalformed</Code><Region>us-east-1</Region></Error>".utf8)
    #expect(NotaryClient.expectedRegion(inS3Error: body) == "us-east-1")
    #expect(NotaryClient.expectedRegion(inS3Error: Data("<Error/>".utf8)) == nil)
  }
}

/// Serves fixed responses for the notary flow so the client runs without the network.
private final class NotaryStub: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let url = request.url?.absoluteString ?? ""
    let (status, body) = Self.response(
      method: request.httpMethod ?? "GET",
      url: url,
      authorization: request.value(forHTTPHeaderField: "Authorization") ?? ""
    )
    if let url = request.url,
      let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
    {
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }
    client?.urlProtocol(self, didLoad: Data(body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  private static func response(method: String, url: String, authorization: String) -> (Int, String) {
    switch (method, url) {
    case ("POST", "https://appstoreconnect.apple.com/notary/v2/submissions"):
      guard authorization.hasPrefix("Bearer ") else { return (401, "{}") }
      return (
        200,
        #"{"data":{"id":"sub-1","type":"newSubmissions","attributes":{"awsAccessKeyId":"AK","awsSecretAccessKey":"SK","awsSessionToken":"TOKEN","bucket":"notary-bucket","object":"prod/sub-1.pkg"}}}"#
      )
    case ("PUT", "https://notary-bucket.s3.us-west-2.amazonaws.com/prod/sub-1.pkg"):
      return authorization.hasPrefix("AWS4-HMAC-SHA256 Credential=AK/") ? (200, "") : (403, "")
    case ("GET", "https://appstoreconnect.apple.com/notary/v2/submissions/sub-1"):
      return (200, #"{"data":{"id":"sub-1","attributes":{"status":"Invalid","name":"x.pkg"}}}"#)
    case ("GET", "https://appstoreconnect.apple.com/notary/v2/submissions/sub-1/logs"):
      return (200, #"{"data":{"id":"sub-1","attributes":{"developerLogUrl":"https://logs.example.test/sub-1.json"}}}"#)
    case ("GET", "https://logs.example.test/sub-1.json"):
      return (
        200,
        #"{"status":"Invalid","statusSummary":"Archive contains critical validation errors","issues":[{"severity":"error","path":"x.pkg","message":"The signature is invalid."}]}"#
      )
    default:
      return (404, "")
    }
  }
}

struct NotaryClientTests {
  @Test func runsTheWholeFlowAndReadsTheLog() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [NotaryStub.self]
    let credentials = NotaryCredentials(
      issuerID: UUID().uuidString,
      keyID: "ABCDE12345",
      privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation
    )
    let client = NotaryClient(
      credentials: credentials,
      session: URLSession(configuration: configuration),
      pollInterval: .zero
    )
    let result = try await client.notarize(Data("package".utf8), name: "x.pkg") { _ in }
    #expect(result.submissionID == "sub-1")
    #expect(result.status == .invalid)
    #expect(result.summary == "Archive contains critical validation errors")
    #expect(result.issues == ["x.pkg: The signature is invalid."])
  }
}

/// Scenario stubs: each serves a fixed set of routes, with counters where a route answers differently over time.
private enum Scenario {
  static let submission =
    #"{"data":{"id":"sub-2","type":"newSubmissions","attributes":{"awsAccessKeyId":"AK","awsSecretAccessKey":"SK","awsSessionToken":"TOKEN","bucket":"notary-bucket","object":"prod/sub-2.pkg"}}}"#
  static let statusURL = "https://appstoreconnect.apple.com/notary/v2/submissions/sub-2"
  static let submissionsURL = "https://appstoreconnect.apple.com/notary/v2/submissions"
  static let westUpload = "https://notary-bucket.s3.us-west-2.amazonaws.com/prod/sub-2.pkg"
  static let eastUpload = "https://notary-bucket.s3.us-east-1.amazonaws.com/prod/sub-2.pkg"

  static func status(_ value: String) -> String {
    #"{"data":{"id":"sub-2","attributes":{"status":"\#(value)"}}}"#
  }
}

private class ScenarioStub: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}

  class func respond(method: String, url: String) -> (Int, String) { (404, "") }

  override func startLoading() {
    let (status, body) = Self.respond(method: request.httpMethod ?? "GET", url: request.url?.absoluteString ?? "")
    if let url = request.url,
      let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
    {
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }
    client?.urlProtocol(self, didLoad: Data(body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
}

/// First status check fails with 503 (retried), then "In Progress", then "Accepted"; no log available.
private final class AcceptedAfterWaitStub: ScenarioStub {
  static let statusCalls = Mutex(0)

  override class func respond(method: String, url: String) -> (Int, String) {
    switch (method, url) {
    case ("POST", Scenario.submissionsURL): return (200, Scenario.submission)
    case ("PUT", Scenario.westUpload): return (200, "")
    case ("GET", Scenario.statusURL):
      let call = statusCalls.withLock { value in
        value += 1
        return value
      }
      switch call {
      case 1: return (503, "")
      case 2: return (200, Scenario.status("In Progress"))
      default: return (200, Scenario.status("Accepted"))
      }
    default: return (404, "")
    }
  }
}

private final class UnauthorizedStub: ScenarioStub {
  override class func respond(method: String, url: String) -> (Int, String) { (401, "{}") }
}

/// The first upload goes to the wrong region; S3 names the right one.
private final class RegionRetryStub: ScenarioStub {
  override class func respond(method: String, url: String) -> (Int, String) {
    switch (method, url) {
    case ("POST", Scenario.submissionsURL): return (200, Scenario.submission)
    case ("PUT", Scenario.westUpload):
      return (400, "<Error><Code>AuthorizationHeaderMalformed</Code><Region>us-east-1</Region></Error>")
    case ("PUT", Scenario.eastUpload): return (200, "")
    case ("GET", Scenario.statusURL): return (200, Scenario.status("Accepted"))
    default: return (404, "")
    }
  }
}

private final class UploadFailsStub: ScenarioStub {
  override class func respond(method: String, url: String) -> (Int, String) {
    switch (method, url) {
    case ("POST", Scenario.submissionsURL): return (200, Scenario.submission)
    case ("PUT", _): return (500, "")
    default: return (404, "")
    }
  }
}

private final class NeverFinishesStub: ScenarioStub {
  override class func respond(method: String, url: String) -> (Int, String) {
    switch (method, url) {
    case ("POST", Scenario.submissionsURL): return (200, Scenario.submission)
    case ("PUT", Scenario.westUpload): return (200, "")
    case ("GET", Scenario.statusURL): return (200, Scenario.status("In Progress"))
    default: return (404, "")
    }
  }
}

struct NotaryScenarioTests {
  private func client(_ stub: AnyClass, pollInterval: Duration = .zero) -> NotaryClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [stub]
    return NotaryClient(
      credentials: NotaryCredentials(
        issuerID: UUID().uuidString,
        keyID: "ABCDE12345",
        privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation
      ),
      session: URLSession(configuration: configuration),
      pollInterval: pollInterval,
      retryDelay: .zero
    )
  }

  @Test func acceptedAfterWaitingAndARetry() async throws {
    let result = try await client(AcceptedAfterWaitStub.self).notarize(Data("p".utf8), name: "x.pkg") { _ in }
    #expect(result.status == .accepted)
    #expect(result.summary == "Accepted")
    #expect(AcceptedAfterWaitStub.statusCalls.withLock { $0 } == 3)
  }

  @Test func wrongKeyIsUnauthorized() async {
    await #expect(throws: NotaryError.unauthorized) {
      try await client(UnauthorizedStub.self).notarize(Data("p".utf8), name: "x.pkg") { _ in }
    }
  }

  @Test func uploadRetriesInTheRegionS3Names() async throws {
    let result = try await client(RegionRetryStub.self).notarize(Data("p".utf8), name: "x.pkg") { _ in }
    #expect(result.status == .accepted)
  }

  @Test func failedUploadIsReported() async {
    await #expect(throws: NotaryError.upload("Storage returned HTTP 500.")) {
      try await client(UploadFailsStub.self).notarize(Data("p".utf8), name: "x.pkg") { _ in }
    }
  }

  @Test func cancellingWhileWaitingStops() async throws {
    let client = client(NeverFinishesStub.self, pollInterval: .seconds(30))
    let task = Task { try await client.notarize(Data("p".utf8), name: "x.pkg") { _ in } }
    try await Task.sleep(for: .milliseconds(300))
    task.cancel()
    let result = await task.result
    guard case .failure(let error) = result else {
      Issue.record("Expected cancellation")
      return
    }
    #expect(isCancellation(error))
  }
}

struct NotarizationProgressTests {
  @Test func eachPhaseHighlightsItsStep() {
    var activity = NotarizationActivity(packageName: "Backup-1.0.pkg", startedAt: .now, phase: .uploading)
    #expect(activity.currentStep == .upload)
    activity.phase = .waiting(submissionID: "2efe2717-52ef-43a5-96dc-0797e4ca1041")
    #expect(activity.currentStep == .appleCheck)
    #expect(activity.shortStatus == "Waiting for Apple…")
    activity.phase = .stapling
    #expect(activity.currentStep == .staple)
  }
}
