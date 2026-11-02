import Compression
import Foundation

enum PackageCompressionError: LocalizedError {
  case compressionFailed

  var errorDescription: String? {
    "A package file could not be compressed."
  }
}

/// gzip (RFC 1952) and zlib (RFC 1950) wrappers around the Compression framework's raw DEFLATE.
enum PackageCompression {
  static func deflate(_ data: Data) throws -> Data {
    if data.isEmpty {
      // An empty final stored block; compression_encode_buffer returns 0 for empty input.
      return Data([0x03, 0x00])
    }
    let capacity = data.count + data.count / 100 + 4096
    var output = Data(count: capacity)
    let written = output.withUnsafeMutableBytes { destination -> Int in
      data.withUnsafeBytes { source -> Int in
        guard
          let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
          let sourceBase = source.bindMemory(to: UInt8.self).baseAddress
        else { return 0 }
        return compression_encode_buffer(destinationBase, capacity, sourceBase, data.count, nil, COMPRESSION_ZLIB)
      }
    }
    guard written > 0 else { throw PackageCompressionError.compressionFailed }
    output.count = written
    return output
  }

  static func gzip(_ data: Data) throws -> Data {
    // Fixed header: no file name, modification time 0, "unknown" OS, so output is deterministic.
    var output = Data([0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF])
    output.append(try deflate(data))
    output.appendLittleEndian(CRC32.checksum(data))
    output.appendLittleEndian(UInt32(truncatingIfNeeded: data.count))
    return output
  }

  static func zlib(_ data: Data) throws -> Data {
    var output = Data([0x78, 0x9C])
    output.append(try deflate(data))
    output.appendBigEndian(adler32(data))
    return output
  }

  static func adler32(_ data: Data) -> UInt32 {
    var a: UInt32 = 1
    var b: UInt32 = 0
    for byte in data {
      a = (a + UInt32(byte)) % 65521
      b = (b + a) % 65521
    }
    return (b << 16) | a
  }
}

extension Data {
  mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
    Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
  }

  mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
    Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
  }
}
