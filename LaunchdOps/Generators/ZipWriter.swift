import Foundation

/// Writes an uncompressed ZIP archive with Unix permissions and fixed timestamps,
/// so identical inputs always produce identical bytes and SHA-256 hashes.
struct ZipWriter {
  struct Entry {
    var path: String
    var contents: Data
    var mode: Int
    var isDirectory: Bool { path.hasSuffix("/") }
  }

  private var entries: [Entry] = []

  mutating func addDirectory(_ path: String, mode: Int = 0o755) {
    let normalized = path.hasSuffix("/") ? path : path + "/"
    guard !entries.contains(where: { $0.path == normalized }) else { return }
    entries.append(Entry(path: normalized, contents: Data(), mode: mode))
  }

  mutating func addFile(_ path: String, contents: Data, mode: Int) {
    entries.append(Entry(path: path, contents: contents, mode: mode))
  }

  func archive() -> Data {
    var output = Data()
    var central = Data()
    let dosTime: UInt16 = 0
    let dosDate: UInt16 = (0 << 9) | (1 << 5) | 1

    for entry in entries {
      let name = Data(entry.path.utf8)
      let crc = CRC32.checksum(entry.contents)
      let size = UInt32(entry.contents.count)
      let offset = UInt32(output.count)
      let fileType = entry.isDirectory ? 0o040000 : 0o100000
      let externalAttributes = UInt32(fileType | (entry.mode & 0o7777)) << 16

      output.appendLE(UInt32(0x04034b50))
      output.appendLE(UInt16(10))
      output.appendLE(UInt16(0x0800))
      output.appendLE(UInt16(0))
      output.appendLE(dosTime)
      output.appendLE(dosDate)
      output.appendLE(crc)
      output.appendLE(size)
      output.appendLE(size)
      output.appendLE(UInt16(name.count))
      output.appendLE(UInt16(0))
      output.append(name)
      output.append(entry.contents)

      central.appendLE(UInt32(0x02014b50))
      // Version made by: Unix (3) so extractors honour the permission bits.
      central.appendLE(UInt16((3 << 8) | 20))
      central.appendLE(UInt16(10))
      central.appendLE(UInt16(0x0800))
      central.appendLE(UInt16(0))
      central.appendLE(dosTime)
      central.appendLE(dosDate)
      central.appendLE(crc)
      central.appendLE(size)
      central.appendLE(size)
      central.appendLE(UInt16(name.count))
      central.appendLE(UInt16(0))
      central.appendLE(UInt16(0))
      central.appendLE(UInt16(0))
      central.appendLE(UInt16(0))
      central.appendLE(externalAttributes)
      central.appendLE(offset)
      central.append(name)
    }

    let centralOffset = UInt32(output.count)
    output.append(central)
    output.appendLE(UInt32(0x06054b50))
    output.appendLE(UInt16(0))
    output.appendLE(UInt16(0))
    output.appendLE(UInt16(entries.count))
    output.appendLE(UInt16(entries.count))
    output.appendLE(UInt32(central.count))
    output.appendLE(centralOffset)
    output.appendLE(UInt16(0))
    return output
  }
}

enum CRC32 {
  private static let table: [UInt32] = (0..<256).map { index in
    var value = UInt32(index)
    for _ in 0..<8 {
      value = value & 1 == 1 ? 0xEDB88320 ^ (value >> 1) : value >> 1
    }
    return value
  }

  static func checksum(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFFFFFF
    for byte in data {
      crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
    }
    return crc ^ 0xFFFFFFFF
  }
}

private extension Data {
  mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
    Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
  }
}
