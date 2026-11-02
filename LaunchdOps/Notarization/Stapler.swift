import CryptoKit
import Foundation

enum StapleError: LocalizedError, Equatable {
  case notAPackage
  case unsupportedChecksum
  case ticketNotFound
  case network(String)
  case service(String)
  case unexpectedResponse
  case read(String)
  case changedWhileStapling
  case write(String)

  var errorDescription: String? {
    switch self {
    case .notAPackage:
      "The file is not a flat installer package. Choose a .pkg file."
    case .unsupportedChecksum:
      "The package uses a checksum LaunchdOps cannot staple. Staple it with xcrun stapler staple."
    case .ticketNotFound:
      "Apple has no notarization ticket for this package. Notarize it first, or wait a minute if it was just "
        + "accepted, then try again."
    case .network(let detail):
      "Apple’s ticket service could not be reached: \(detail) Check your internet connection and try again."
    case .service(let detail):
      "Apple’s ticket service returned an error (\(detail)). Try again later."
    case .unexpectedResponse:
      "Apple’s ticket service sent a response LaunchdOps could not read. Try again later."
    case .read(let detail):
      "LaunchdOps could not read the package: \(detail) Choose the .pkg file again."
    case .changedWhileStapling:
      "The package changed while LaunchdOps was stapling it. Staple it again."
    case .write(let detail):
      "The ticket could not be added to the package: \(detail)"
    }
  }
}

/// Staples a notarization ticket to a flat installer package, producing the same bytes as
/// `xcrun stapler staple`.
///
/// Apple does not document this format. It was worked out on 2026-09-27 from `stapler staple -v` output and a
/// byte comparison with a package stapled by `xcrun stapler`: the ticket comes from Apple's ticket service (CloudKit database
/// `com.apple.gk.ticket-delivery`), looked up by `2/1/<hex SHA-1 of the xar table of contents>`, and is
/// appended to the unchanged package between two 16-byte trailers: `"t8lr"`, version (UInt16), type
/// (UInt16: 1 start, 2 ticket), length (UInt64), all little-endian. If it ever stops working, the fallback is
/// `xcrun stapler staple`.
enum Stapler {
  static let lookupURL = URL(
    string: "https://api.apple-cloudkit.com/database/1/com.apple.gk.ticket-delivery/production/public/records/lookup"
  )

  private static let trailerMagic = Data("t8lr".utf8)
  private static let trailerSize = 16
  private static let xarHeaderMinimum = 28
  private static let sha1Length = 20

  // MARK: - Package format

  /// The xar table-of-contents checksum, which Apple uses to find the package's ticket. Every length is
  /// checked against the file size before use, and the stored checksum must match the table of contents.
  static func tableOfContentsChecksum(_ package: Data) throws(StapleError) -> Data {
    guard package.count >= xarHeaderMinimum, package.prefix(4) == Data("xar!".utf8),
      let headerSize = Int(exactly: unsigned(package, at: 4, width: 2, bigEndian: true)),
      let tocLength = Int(exactly: unsigned(package, at: 8, width: 8, bigEndian: true)),
      headerSize >= xarHeaderMinimum, headerSize <= package.count,
      tocLength <= package.count - headerSize,
      package.count - headerSize - tocLength >= sha1Length
    else { throw .notAPackage }
    guard unsigned(package, at: 24, width: 4, bigEndian: true) == 1 else { throw .unsupportedChecksum }  // 1 = SHA-1

    let tocStart = package.startIndex + headerSize
    let checksumStart = tocStart + tocLength
    let stored = package.subdata(in: checksumStart..<checksumStart + sha1Length)
    guard Data(Insecure.SHA1.hash(data: package[tocStart..<checksumStart])) == stored else { throw .notAPackage }
    return stored
  }

  static func recordName(for package: Data) throws(StapleError) -> String {
    "2/1/" + (try tableOfContentsChecksum(package)).map { String(format: "%02x", $0) }.joined()
  }

  /// The package without any stapled ticket. Anything else at the end, such as a partial trailer left by an
  /// interrupted write, is kept; Gatekeeper reads the ticket from the end, so it does no harm.
  static func unstapled(_ package: Data) -> Data {
    guard let length = stapledTicketLength(package) else { return package }
    return package.prefix(package.count - (trailerSize + length + trailerSize))
  }

  static func stapled(_ package: Data, ticket: Data) -> Data {
    unstapled(package) + stapleTail(ticket: ticket)
  }

  /// What stapling appends: start trailer, ticket, ticket trailer.
  static func stapleTail(ticket: Data) -> Data {
    trailer(type: 1, length: 0) + ticket + trailer(type: 2, length: ticket.count)
  }

  /// The ticket length when the package ends with a stapled ticket and its start marker.
  static func stapledTicketLength(_ package: Data) -> Int? {
    guard package.count >= trailerSize * 2 else { return nil }
    let end = package.suffix(trailerSize)
    guard end.prefix(4) == trailerMagic, unsigned(end, at: 6, width: 2, bigEndian: false) == 2,
      let length = Int(exactly: unsigned(end, at: 8, width: 8, bigEndian: false)),
      length > 0, length <= package.count - 2 * trailerSize
    else { return nil }
    let startOffset = package.count - trailerSize - length - trailerSize
    let start = package.subdata(in: package.startIndex + startOffset..<package.startIndex + startOffset + trailerSize)
    guard start.prefix(4) == trailerMagic, unsigned(start, at: 6, width: 2, bigEndian: false) == 1 else { return nil }
    return length
  }

  private static func trailer(type: UInt16, length: Int) -> Data {
    var data = trailerMagic
    data.appendLittleEndian(UInt16(1))
    data.appendLittleEndian(type)
    data.appendLittleEndian(UInt64(length))
    return data
  }

  private static func unsigned(_ data: Data, at offset: Int, width: Int, bigEndian: Bool) -> UInt64 {
    let start = data.startIndex + offset
    let bytes = data[start..<start + width]
    return (bigEndian ? Array(bytes) : bytes.reversed()).reduce(0) { ($0 << 8) | UInt64($1) }
  }

  // MARK: - Ticket service

  private struct LookupResponse: Decodable {
    struct Record: Decodable {
      struct Fields: Decodable {
        struct Ticket: Decodable { let value: String }
        let signedTicket: Ticket?
      }
      let fields: Fields?
      let serverErrorCode: String?
    }
    let records: [Record]
  }

  static func fetchTicket(recordName: String, session: URLSession = NotaryClient.defaultSession) async throws -> Data {
    guard let url = lookupURL else { throw StapleError.unexpectedResponse }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["records": [["recordName": recordName]]])

    let (data, response): (Data, URLResponse)
    do {
      (data, response) = try await session.data(for: request)
    } catch let error as URLError where error.code != .cancelled {
      throw StapleError.network(error.localizedDescription)
    }
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else { throw StapleError.service("HTTP \(status)") }

    let lookup: LookupResponse
    do {
      lookup = try JSONDecoder().decode(LookupResponse.self, from: data)
    } catch {
      throw StapleError.unexpectedResponse
    }
    guard let record = lookup.records.first else { throw StapleError.unexpectedResponse }
    if let code = record.serverErrorCode {
      throw code == "NOT_FOUND" ? StapleError.ticketNotFound : StapleError.service(code)
    }
    guard let value = record.fields?.signedTicket?.value, let ticket = Data(base64Encoded: value), !ticket.isEmpty
    else { throw StapleError.unexpectedResponse }
    return ticket
  }

  // MARK: - Files

  /// Fetches the ticket for the package at `url` and staples it in place, replacing any earlier ticket.
  /// Only the end of the file is rewritten, and only if the file is unchanged since it was read.
  static func staple(fileAt url: URL, session: URLSession = NotaryClient.defaultSession) async throws {
    let didAccess = url.startAccessingSecurityScopedResource()
    defer {
      if didAccess { url.stopAccessingSecurityScopedResource() }
    }

    // Read everything needed before the network call; the file is not touched again until writing.
    let original: Data
    do {
      guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
        throw StapleError.notAPackage
      }
      original = try Data(contentsOf: url)  // Not mapped: the same file is truncated below.
    } catch let error as StapleError {
      throw error
    } catch {
      throw StapleError.read(error.localizedDescription)
    }
    let base = unstapled(original)
    let record = try recordName(for: base)
    let keep = UInt64(base.count)

    Log.stapling.info("Looking up the ticket for \(url.lastPathComponent, privacy: .public)")
    let ticket = try await fetchTicket(recordName: record, session: session)

    do {
      let handle = try FileHandle(forUpdating: url)
      defer { try? handle.close() }  // Closing after a completed, synchronized write cannot lose data.
      guard try handle.seekToEnd() == UInt64(original.count) else { throw StapleError.changedWhileStapling }
      try handle.seek(toOffset: 0)
      guard let head = try handle.read(upToCount: min(base.count, 64 * 1024)), base.starts(with: head) else {
        throw StapleError.changedWhileStapling
      }
      try handle.truncate(atOffset: keep)
      try handle.seek(toOffset: keep)
      try handle.write(contentsOf: stapleTail(ticket: ticket))
      try handle.synchronize()
      Log.stapling.notice("Stapled a \(ticket.count)-byte ticket to \(url.lastPathComponent, privacy: .public)")
    } catch let error as StapleError {
      throw error
    } catch {
      throw StapleError.write(error.localizedDescription)
    }
  }
}
