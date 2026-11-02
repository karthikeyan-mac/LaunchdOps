import Foundation
import Testing

@testable import LaunchdOps

/// Fixtures: a package LaunchdOps built, signed and notarized (unstapled.pkg), and the same file after
/// `xcrun stapler staple` (stapled.pkg), captured on 2026-09-27. They are real, root-installing packages:
/// never install them. They are only read by these tests. The fixture tests are skipped when the
/// fixture files are not in the checkout (the public repository leaves them out).
private final class FixtureToken {}

private enum Fixture {
  static var isAvailable: Bool {
    let bundle = Bundle(for: FixtureToken.self)
    return bundle.url(forResource: "unstapled", withExtension: "pkg", subdirectory: "Fixtures") != nil
      || bundle.url(forResource: "unstapled", withExtension: "pkg") != nil
  }

  static func data(_ name: String) throws -> Data {
    let bundle = Bundle(for: FixtureToken.self)
    let url = try #require(
      bundle.url(forResource: name, withExtension: "pkg", subdirectory: "Fixtures")
        ?? bundle.url(forResource: name, withExtension: "pkg")
    )
    return try Data(contentsOf: url)
  }

  static var ticket: Data {
    get throws {
      let stapled = try data("stapled")
      let unstapled = try data("unstapled")
      return stapled.subdata(in: unstapled.count + 16..<stapled.count - 16)
    }
  }
}

/// Answers the ticket lookup with the fixture's ticket, or NOT_FOUND for any other record.
private final class TicketStub: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}

  override func startLoading() {
    let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
    let asked = String(decoding: body, as: UTF8.self)
    let json: String
    if asked.contains("175dd04be37ff467bf24c03a3545222e087b9ad9"), let ticket = try? Fixture.ticket {
      json =
        #"{"records":[{"recordName":"2/1/175dd04be37ff467bf24c03a3545222e087b9ad9","recordType":"DeveloperIDTicket","fields":{"signedTicket":{"type":"BYTES","value":""#
        + ticket.base64EncodedString() + #""}}}]}"#
    } else {
      json = #"{"records":[{"recordName":"2/1/0","reason":"Record not found","serverErrorCode":"NOT_FOUND"}]}"#
    }
    if let url = request.url,
      let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
    {
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }
    client?.urlProtocol(self, didLoad: Data(json.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  private static func read(_ stream: InputStream) -> Data {
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      if count <= 0 { break }
      data.append(buffer, count: count)
    }
    return data
  }

  static var session: URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TicketStub.self]
    return URLSession(configuration: configuration)
  }
}

struct StaplerTests {
  @Test(.enabled(if: Fixture.isAvailable)) func recordNameIsTheTableOfContentsChecksum() throws {
    #expect(try Stapler.recordName(for: Fixture.data("unstapled")) == "2/1/175dd04be37ff467bf24c03a3545222e087b9ad9")
    // Stapling appends after the heap, so the stapled file has the same record name.
    #expect(try Stapler.recordName(for: Fixture.data("stapled")) == "2/1/175dd04be37ff467bf24c03a3545222e087b9ad9")
  }

  @Test(.enabled(if: Fixture.isAvailable)) func matchesStaplerOutputByteForByte() throws {
    let stapled = Stapler.stapled(try Fixture.data("unstapled"), ticket: try Fixture.ticket)
    #expect(stapled == (try Fixture.data("stapled")))
  }

  @Test(.enabled(if: Fixture.isAvailable)) func recognisesAndRemovesAStapledTicket() throws {
    let stapled = try Fixture.data("stapled")
    #expect(Stapler.stapledTicketLength(stapled) == 1653)
    #expect(Stapler.unstapled(stapled) == (try Fixture.data("unstapled")))
    #expect(Stapler.stapledTicketLength(try Fixture.data("unstapled")) == nil)
  }

  @Test(.enabled(if: Fixture.isAvailable)) func restaplingReplacesTheTicket() throws {
    let restapled = Stapler.stapled(try Fixture.data("stapled"), ticket: Data("new-ticket".utf8))
    let unstapled = try Fixture.data("unstapled")
    #expect(restapled.count == unstapled.count + 16 + 10 + 16)
    #expect(Stapler.unstapled(restapled) == unstapled)
  }

  @Test func rejectsFilesThatAreNotPackages() {
    #expect(throws: StapleError.notAPackage) { try Stapler.recordName(for: Data("not a package".utf8)) }
  }

  @Test(.enabled(if: Fixture.isAvailable)) func staplesAFileInPlace() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "LaunchdOpsTests-\(UUID().uuidString).pkg")
    defer { try? FileManager.default.removeItem(at: url) }
    try Fixture.data("unstapled").write(to: url)

    try await Stapler.staple(fileAt: url, session: TicketStub.session)
    #expect(try Data(contentsOf: url) == (try Fixture.data("stapled")))

    // Stapling again leaves the same bytes: the old ticket is replaced, not duplicated.
    try await Stapler.staple(fileAt: url, session: TicketStub.session)
    #expect(try Data(contentsOf: url) == (try Fixture.data("stapled")))
  }

  @Test(.enabled(if: Fixture.isAvailable)) func unknownPackageHasNoTicket() async throws {
    let package = FlatPackageBuilder.self
    let data = try package.package(package.input(for: Project()))
    await #expect(throws: StapleError.ticketNotFound) {
      try await Stapler.fetchTicket(recordName: try Stapler.recordName(for: data), session: TicketStub.session)
    }
  }

  @Test(.enabled(if: Fixture.isAvailable)) func hugeHeaderLengthsAreRejectedWithoutCrashing() throws {
    var package = try Fixture.data("unstapled")
    package.replaceSubrange(8..<16, with: Data(repeating: 0xFF, count: 8))
    #expect(throws: StapleError.notAPackage) { try Stapler.recordName(for: package) }
    package = try Fixture.data("unstapled")
    package.replaceSubrange(4..<6, with: Data([0xFF, 0xFF]))
    #expect(throws: StapleError.notAPackage) { try Stapler.recordName(for: package) }
  }

  @Test(.enabled(if: Fixture.isAvailable)) func hugeTrailerLengthIsIgnored() throws {
    var package = try Fixture.data("unstapled")
    package.append(Data("t8lr".utf8) + Data([1, 0, 2, 0]) + Data(repeating: 0xFF, count: 8))
    #expect(Stapler.stapledTicketLength(package) == nil)
    #expect(Stapler.unstapled(package) == package)
  }

  @Test(.enabled(if: Fixture.isAvailable)) func otherChecksumTypesAreNotStapled() throws {
    var package = try Fixture.data("unstapled")
    package[27] = 2
    #expect(throws: StapleError.unsupportedChecksum) { try Stapler.recordName(for: package) }
  }

  @Test(.enabled(if: Fixture.isAvailable)) func corruptTableOfContentsIsRejected() throws {
    var package = try Fixture.data("unstapled")
    package[40] ^= 0xFF
    #expect(throws: StapleError.notAPackage) { try Stapler.recordName(for: package) }
  }

  @Test(.enabled(if: Fixture.isAvailable)) func failedLookupLeavesTheFileUnchanged() async throws {
    let package = try FlatPackageBuilder.package(FlatPackageBuilder.input(for: Project()))
    let url = FileManager.default.temporaryDirectory.appending(path: "LaunchdOpsTests-\(UUID().uuidString).pkg")
    defer { try? FileManager.default.removeItem(at: url) }
    try package.write(to: url)
    await #expect(throws: StapleError.ticketNotFound) {
      try await Stapler.staple(fileAt: url, session: TicketStub.session)
    }
    #expect(try Data(contentsOf: url) == package)
  }

  @Test func folderIsNotAPackage() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "LaunchdOpsTests-\(UUID().uuidString).pkg")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    await #expect(throws: StapleError.notAPackage) {
      try await Stapler.staple(fileAt: url, session: TicketStub.session)
    }
  }

  @Test func serviceErrorsAreReportedDistinctly() async {
    await #expect(throws: StapleError.service("HTTP 500")) {
      try await Stapler.fetchTicket(recordName: "2/1/http500", session: ServiceErrorStub.session)
    }
    await #expect(throws: StapleError.service("THROTTLED")) {
      try await Stapler.fetchTicket(recordName: "2/1/throttled", session: ServiceErrorStub.session)
    }
    await #expect(throws: StapleError.unexpectedResponse) {
      try await Stapler.fetchTicket(recordName: "2/1/badticket", session: ServiceErrorStub.session)
    }
  }
}

/// Answers by the record name in the request: an HTTP 500, a CloudKit error code, or a ticket that is not base64.
private final class ServiceErrorStub: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}

  override func startLoading() {
    var body = request.httpBody ?? Data()
    if body.isEmpty, let stream = request.httpBodyStream {
      stream.open()
      var buffer = [UInt8](repeating: 0, count: 4096)
      while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        body.append(buffer, count: count)
      }
      stream.close()
    }
    let asked = String(decoding: body, as: UTF8.self)
    let (status, json): (Int, String)
    if asked.contains("http500") {
      (status, json) = (500, "")
    } else if asked.contains("throttled") {
      (status, json) = (200, #"{"records":[{"recordName":"2/1/throttled","serverErrorCode":"THROTTLED"}]}"#)
    } else {
      (status, json) = (
        200, #"{"records":[{"recordName":"2/1/badticket","fields":{"signedTicket":{"type":"BYTES","value":"%%%"}}}]}"#
      )
    }
    if let url = request.url,
      let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
    {
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }
    client?.urlProtocol(self, didLoad: Data(json.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  static var session: URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ServiceErrorStub.self]
    return URLSession(configuration: configuration)
  }
}
