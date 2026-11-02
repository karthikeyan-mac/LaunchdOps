import CryptoKit
import Foundation

enum NotaryError: LocalizedError, Equatable {
  case notSignedIn
  case unauthorized
  case http(status: Int, detail: String)
  case network(String)
  case unexpectedResponse
  case upload(String)
  case timedOut(submissionID: String)
  case unknownStatus(String, submissionID: String)
  /// A failure after Apple received the package; Apple may still finish checking it.
  case afterUpload(submissionID: String, reason: String)

  var errorDescription: String? {
    switch self {
    case .notSignedIn:
      "Notarization is not set up. In LaunchdOps ▸ Settings ▸ Signing, turn on Sign the Package and Notarize "
        + "After Export, then set up the Notarization Key."
    case .unauthorized:
      "Apple did not accept the App Store Connect API key. Check the issuer ID, key ID and key file under "
        + "Settings ▸ Notarization Key, and that the key has the Developer role or higher."
    case .http(let status, let detail):
      "Apple’s notary service returned an error (HTTP \(status)). \(detail) Try again later."
    case .network(let detail):
      "The connection to Apple failed (\(detail)). Check your internet connection and try again."
    case .unexpectedResponse:
      "Apple’s notary service sent a response LaunchdOps could not read. Try again later."
    case .upload(let detail):
      "The package could not be uploaded to Apple. \(detail) Check your internet connection and try again."
    case .timedOut(let id):
      "Apple has not finished checking the package after an hour. Check later with "
        + "xcrun notarytool info \(id) and your notarytool credentials."
    case .unknownStatus(let status, let id):
      "Apple reported the status “\(status)” for submission \(id). Check it with xcrun notarytool info \(id)."
    case .afterUpload(let id, let reason):
      "\(reason) Apple received the package and may still finish checking it: submission \(id). Check later "
        + "with xcrun notarytool info \(id)."
    }
  }
}

/// The outcome of a finished notarization.
struct NotaryResult: Equatable, Sendable {
  enum Status: String, Sendable {
    case accepted = "Accepted"
    case invalid = "Invalid"
    case rejected = "Rejected"
  }

  var submissionID: String
  var status: Status
  var summary: String
  var issues: [String]
}

/// Talks to Apple's notary service (Notary API v2): create a submission, upload the file to the storage
/// Apple returns (an S3 bucket), wait for the result and read the log from the link Apple returns.
/// These are the only hosts contacted.
struct NotaryClient: Sendable {
  enum Phase: Equatable, Sendable {
    case uploading
    case waiting(submissionID: String)
    /// Set by the caller after Apple accepts, while the ticket is stapled.
    case stapling
  }

  static let baseURL = URL(string: "https://appstoreconnect.apple.com/notary/v2/")
  static let defaultUploadRegion = "us-west-2"

  /// No cache and no cookies, so every status check reaches Apple.
  static let defaultSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    return URLSession(configuration: configuration)
  }()

  var credentials: NotaryCredentials
  var session: URLSession = NotaryClient.defaultSession
  var pollInterval: Duration = .seconds(20)
  var retryDelay: Duration = .seconds(5)
  var timeout: Duration = .seconds(3600)

  func notarize(
    _ package: Data,
    name: String,
    progress: @escaping @Sendable (Phase) async -> Void
  ) async throws -> NotaryResult {
    await progress(.uploading)
    let started = ContinuousClock.now
    let submission = try await createSubmission(name: name, sha256: AWSSignatureV4.hex(SHA256.hash(data: package)))
    Log.notarization.notice("Submitted \(name, privacy: .public) as \(submission.id, privacy: .public)")
    try await upload(package, to: submission)
    Log.notarization.info("Uploaded \(package.count) bytes in \(Log.milliseconds(since: started)) ms")
    await progress(.waiting(submissionID: submission.id))

    do {
      let clock = ContinuousClock()
      let deadline = clock.now + timeout
      var status = try await withRetry { try await submissionStatus(submission.id) }
      while status == "In Progress" {
        guard clock.now < deadline else { throw NotaryError.timedOut(submissionID: submission.id) }
        try await Task.sleep(for: pollInterval)
        status = try await withRetry { try await submissionStatus(submission.id) }
      }
      guard let resultStatus = NotaryResult.Status(rawValue: status) else {
        Log.notarization.error("Unknown status \(status, privacy: .public) for \(submission.id, privacy: .public)")
        throw NotaryError.unknownStatus(status, submissionID: submission.id)
      }
      let seconds = Log.milliseconds(since: started) / 1000
      Log.notarization.notice(
        "\(submission.id, privacy: .public) finished: \(status, privacy: .public) after \(seconds) s"
      )
      // The log only adds detail; the status above is the result, so a missing log is not an error.
      let log = try? await developerLog(submission.id)
      return NotaryResult(
        submissionID: submission.id,
        status: resultStatus,
        summary: log?.statusSummary ?? status,
        issues: (log?.issues ?? []).map { issue in
          [issue.path, issue.message].compactMap { $0 }.joined(separator: ": ")
        }
      )
    } catch let error as NotaryError {
      switch error {
      case .timedOut, .unknownStatus: throw error
      default: throw NotaryError.afterUpload(submissionID: submission.id, reason: error.localizedDescription)
      }
    }
  }

  /// Retries temporary failures (network errors, HTTP 429 and 5xx) up to three times with a growing delay.
  private func withRetry<T: Sendable>(_ operation: () async throws -> T) async throws -> T {
    var attempt = 0
    while true {
      do {
        return try await operation()
      } catch let error as NotaryError where attempt < 3 && error.isTemporary {
        attempt += 1
        Log.notarization.info("Retrying (\(attempt) of 3): \(error.localizedDescription, privacy: .public)")
        try await Task.sleep(for: retryDelay * attempt)
      }
    }
  }

  // MARK: - Requests

  struct Submission: Equatable, Sendable {
    var id: String
    var accessKeyID: String
    var secretAccessKey: String
    var sessionToken: String
    var bucket: String
    var object: String
  }

  private struct SubmissionResponse: Decodable {
    struct Payload: Decodable {
      struct Attributes: Decodable {
        let awsAccessKeyId: String
        let awsSecretAccessKey: String
        let awsSessionToken: String
        let bucket: String
        let object: String
      }
      let id: String
      let attributes: Attributes
    }
    let data: Payload
  }

  private struct StatusResponse: Decodable {
    struct Payload: Decodable {
      struct Attributes: Decodable { let status: String }
      let attributes: Attributes
    }
    let data: Payload
  }

  private struct LogURLResponse: Decodable {
    struct Payload: Decodable {
      struct Attributes: Decodable { let developerLogUrl: String }
      let attributes: Attributes
    }
    let data: Payload
  }

  struct DeveloperLog: Decodable, Sendable {
    struct Issue: Decodable, Sendable {
      let severity: String?
      let path: String?
      let message: String?
    }
    let status: String?
    let statusSummary: String?
    let issues: [Issue]?
  }

  private struct ErrorResponse: Decodable {
    struct Item: Decodable {
      let title: String?
      let detail: String?
    }
    let errors: [Item]
  }

  func createSubmission(name: String, sha256: String) async throws -> Submission {
    let body = try JSONSerialization.data(withJSONObject: ["submissionName": name, "sha256": sha256])
    let data = try await apiRequest("submissions", method: "POST", body: body)
    let response = try decode(SubmissionResponse.self, from: data)
    let attributes = response.data.attributes
    return Submission(
      id: response.data.id,
      accessKeyID: attributes.awsAccessKeyId,
      secretAccessKey: attributes.awsSecretAccessKey,
      sessionToken: attributes.awsSessionToken,
      bucket: attributes.bucket,
      object: attributes.object
    )
  }

  func upload(_ package: Data, to submission: Submission) async throws {
    let payloadHash = AWSSignatureV4.hex(SHA256.hash(data: package))
    var region = Self.defaultUploadRegion
    for attempt in 0..<2 {
      let host = "\(submission.bucket).s3.\(region).amazonaws.com"
      let path = AWSSignatureV4.encodedPath(forKey: submission.object)
      guard let url = URL(string: "https://\(host)\(path)") else {
        throw NotaryError.upload("The upload address is invalid.")
      }
      let signer = AWSSignatureV4(
        accessKeyID: submission.accessKeyID,
        secretAccessKey: submission.secretAccessKey,
        sessionToken: submission.sessionToken,
        region: region
      )
      var request = URLRequest(url: url)
      request.httpMethod = "PUT"
      let headers = signer.signedHeaders(
        method: "PUT",
        host: host,
        path: path,
        headers: ["content-type": "application/octet-stream"],
        payloadHash: payloadHash,
        date: Date()
      )
      for (name, value) in headers {
        request.setValue(value, forHTTPHeaderField: name)
      }
      let (data, response) = try await send { try await session.upload(for: request, from: package) }
      let http = response as? HTTPURLResponse
      let status = http?.statusCode ?? 0
      if (200..<300).contains(status) { return }
      // S3 names the right region when the request went to the wrong one; retry there once.
      let expected = Self.expectedRegion(inS3Error: data) ?? http?.value(forHTTPHeaderField: "x-amz-bucket-region")
      if attempt == 0, let expected, expected != region {
        region = expected
        continue
      }
      throw NotaryError.upload("Storage returned HTTP \(status).")
    }
  }

  func submissionStatus(_ id: String) async throws -> String {
    let data = try await apiRequest("submissions/\(id)", method: "GET")
    return try decode(StatusResponse.self, from: data).data.attributes.status
  }

  func developerLog(_ id: String) async throws -> DeveloperLog {
    let data = try await apiRequest("submissions/\(id)/logs", method: "GET")
    let response = try decode(LogURLResponse.self, from: data)
    guard let url = URL(string: response.data.attributes.developerLogUrl), url.scheme == "https" else {
      throw NotaryError.unexpectedResponse
    }
    let (logData, _) = try await send { try await session.data(from: url) }
    return try decode(DeveloperLog.self, from: logData)
  }

  private func apiRequest(_ path: String, method: String, body: Data? = nil) async throws -> Data {
    guard let url = URL(string: path, relativeTo: Self.baseURL) else { throw NotaryError.unexpectedResponse }
    var request = URLRequest(url: url)
    request.httpMethod = method
    let token = try AppStoreConnectToken.make(credentials: credentials)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    if let body {
      request.httpBody = body
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let (data, response) = try await send { try await session.data(for: request) }
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    switch status {
    case 200..<300:
      return data
    case 401, 403:
      throw NotaryError.unauthorized
    default:
      // Apple's error text is optional detail for the message.
      let item = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.errors.first
      throw NotaryError.http(status: status, detail: item.flatMap { $0.detail ?? $0.title } ?? "")
    }
  }

  /// Runs a URLSession call, turning network failures into `NotaryError.network`. A cancelled task keeps
  /// throwing its cancellation so callers can stop quietly.
  private func send(_ call: () async throws -> (Data, URLResponse)) async throws -> (Data, URLResponse) {
    do {
      return try await call()
    } catch let error as URLError where error.code != .cancelled {
      throw NotaryError.network(error.localizedDescription)
    }
  }

  /// Decodes a response, reporting a readable error instead of a decoding error.
  private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      throw NotaryError.unexpectedResponse
    }
  }

  static func expectedRegion(inS3Error data: Data) -> String? {
    let text = String(decoding: data, as: UTF8.self)
    guard let match = text.firstMatch(of: /<Region>([a-z0-9-]+)<\/Region>/) else { return nil }
    return String(match.output.1)
  }
}

extension NotaryError {
  var isTemporary: Bool {
    switch self {
    case .network: true
    case .http(let status, _): status == 429 || (500..<600).contains(status)
    default: false
    }
  }
}

/// Whether an error means the user cancelled, which URLSession reports as `URLError.cancelled`.
func isCancellation(_ error: Error) -> Bool {
  error is CancellationError || (error as? URLError)?.code == .cancelled
}
