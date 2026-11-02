import Foundation

enum BomWriterError: LocalizedError {
  case tooManyEntries(Int)

  var errorDescription: String? {
    switch self {
    case .tooManyEntries(let count):
      "The package would list \(count) files and folders; the most LaunchdOps can write is \(BomWriter.maximumEntries). "
        + "Use Build Script output for larger payloads."
    }
  }
}

/// Writes the bill of materials (`Bom`) that Installer records as the package receipt.
///
/// The format is not documented by Apple. This writer produces the structure `lsbom(8)` and
/// `pkgutil --payload-files` read: a "BOMStore" header, numbered blocks, named variables
/// (BomInfo, Paths, HLIndex, VIndex, Size64) and a block index. All integers are big-endian.
/// Every path fits in one leaf of the Paths tree, which caps the entry count.
enum BomWriter {
  static let maximumEntries = 500

  private static let headerSize = 512
  private static let pathsBlockSize = 4096
  private static let smallTreeBlockSize = 128

  static func bom(_ entries: [PackageEntry]) throws -> Data {
    guard entries.count <= maximumEntries else { throw BomWriterError.tooManyEntries(entries.count) }
    var store = BlockStore()

    // BomInfo: version, path count, one empty info entry.
    var info = Data()
    info.appendBigEndian(UInt32(1))
    info.appendBigEndian(UInt32(entries.count))
    info.appendBigEndian(UInt32(1))
    info.append(Data(count: 16))
    let infoIndex = store.add(info)

    // Paths: one leaf holding (PathInfo1, File) block pairs in path order.
    var identifiers: [String: UInt32] = [:]
    var pairs: [(info: UInt32, file: UInt32)] = []
    for (offset, entry) in entries.enumerated() {
      let identifier = UInt32(offset + 1)
      identifiers[entry.path] = identifier

      var info2 = Data()
      info2.append(entry.isDirectory ? 2 : 1)  // type: 1 file, 2 directory
      info2.append(1)
      info2.appendBigEndian(UInt16(3))  // architecture, as in Apple-built receipts for plain files
      info2.appendBigEndian(UInt16(entry.mode))
      info2.appendBigEndian(UInt32(entry.uid))
      info2.appendBigEndian(UInt32(entry.gid))
      info2.appendBigEndian(UInt32(PackagePayload.modificationTime))
      info2.appendBigEndian(UInt32(truncatingIfNeeded: entry.contents.count))
      info2.append(1)
      info2.appendBigEndian(entry.isDirectory ? UInt32(0) : POSIXChecksum.cksum(entry.contents))
      info2.appendBigEndian(UInt32(0))  // link name length
      let info2Index = store.add(info2)

      var info1 = Data()
      info1.appendBigEndian(identifier)
      info1.appendBigEndian(info2Index)
      let info1Index = store.add(info1)

      let parentPath = entry.path.split(separator: "/").dropLast().joined(separator: "/")
      let parent = entry.path.isEmpty ? 0 : identifiers[parentPath] ?? 0
      let name = entry.path.isEmpty ? "." : String(entry.path.split(separator: "/").last ?? "")
      var file = Data()
      file.appendBigEndian(parent)
      file.append(Data(name.utf8))
      file.append(0)
      let fileIndex = store.add(file)

      pairs.append((info1Index, fileIndex))
    }
    let pathsLeaf = store.add(leaf(pairs, size: pathsBlockSize))
    let pathsIndex = store.add(tree(child: pathsLeaf, blockSize: pathsBlockSize, pathCount: entries.count))

    let hardLinksIndex = store.add(tree(child: store.add(leaf([], size: pathsBlockSize)), blockSize: pathsBlockSize))

    let vTree = store.add(tree(child: store.add(leaf([], size: smallTreeBlockSize)), blockSize: smallTreeBlockSize))
    var vIndex = Data()
    vIndex.appendBigEndian(UInt32(1))
    vIndex.appendBigEndian(vTree)
    vIndex.appendBigEndian(UInt32(0))
    vIndex.append(0)
    let vIndexIndex = store.add(vIndex)

    let size64Index = store.add(
      tree(child: store.add(leaf([], size: smallTreeBlockSize)), blockSize: smallTreeBlockSize)
    )

    let variables: [(String, UInt32)] = [
      ("BomInfo", infoIndex),
      ("Paths", pathsIndex),
      ("HLIndex", hardLinksIndex),
      ("VIndex", vIndexIndex),
      ("Size64", size64Index),
    ]
    return store.serialize(variables: variables, headerSize: headerSize)
  }

  private static func tree(child: UInt32, blockSize: Int, pathCount: Int = 0) -> Data {
    var data = Data("tree".utf8)
    data.appendBigEndian(UInt32(1))
    data.appendBigEndian(child)
    data.appendBigEndian(UInt32(blockSize))
    data.appendBigEndian(UInt32(pathCount))
    data.append(0)
    return data
  }

  private static func leaf(_ pairs: [(info: UInt32, file: UInt32)], size: Int) -> Data {
    var data = Data()
    data.appendBigEndian(UInt16(1))  // leaf
    data.appendBigEndian(UInt16(pairs.count))
    data.appendBigEndian(UInt32(0))  // forward
    data.appendBigEndian(UInt32(0))  // backward
    for pair in pairs {
      data.appendBigEndian(pair.info)
      data.appendBigEndian(pair.file)
    }
    if data.count < size {
      data.append(Data(count: size - data.count))
    }
    return data
  }

  private struct BlockStore {
    private var blocks: [Data] = []

    /// Returns the block's index; index 0 is reserved for the null block.
    mutating func add(_ data: Data) -> UInt32 {
      blocks.append(data)
      return UInt32(blocks.count)
    }

    func serialize(variables: [(String, UInt32)], headerSize: Int) -> Data {
      var body = Data()
      var pointers: [(address: UInt32, length: UInt32)] = [(0, 0)]
      for block in blocks {
        pointers.append((UInt32(headerSize + body.count), UInt32(block.count)))
        body.append(block)
      }

      var vars = Data()
      vars.appendBigEndian(UInt32(variables.count))
      for (name, index) in variables {
        vars.appendBigEndian(index)
        vars.append(UInt8(name.utf8.count))
        vars.append(Data(name.utf8))
      }

      var index = Data()
      index.appendBigEndian(UInt32(pointers.count))
      for pointer in pointers {
        index.appendBigEndian(pointer.address)
        index.appendBigEndian(pointer.length)
      }
      index.appendBigEndian(UInt32(2))  // free list: two empty entries
      index.append(Data(count: 16))

      let varsOffset = headerSize + body.count
      let indexOffset = varsOffset + vars.count

      var header = Data("BOMStore".utf8)
      header.appendBigEndian(UInt32(1))
      header.appendBigEndian(UInt32(blocks.count))
      header.appendBigEndian(UInt32(indexOffset))
      header.appendBigEndian(UInt32(index.count))
      header.appendBigEndian(UInt32(varsOffset))
      header.appendBigEndian(UInt32(vars.count))
      header.append(Data(count: headerSize - header.count))

      return header + body + vars + index
    }
  }
}

/// The checksum `cksum(1)` prints: CRC-32 (polynomial 0x04C11DB7, not reflected) over the data and its length.
enum POSIXChecksum {
  private static let table: [UInt32] = (0..<256).map { index in
    var value = UInt32(index) << 24
    for _ in 0..<8 {
      value = value & 0x8000_0000 != 0 ? (value << 1) ^ 0x04C1_1DB7 : value << 1
    }
    return value
  }

  static func cksum(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0
    func update(_ byte: UInt8) {
      crc = (crc << 8) ^ table[Int(((crc >> 24) ^ UInt32(byte)) & 0xFF)]
    }
    for byte in data {
      update(byte)
    }
    var length = data.count
    while length > 0 {
      update(UInt8(length & 0xFF))
      length >>= 8
    }
    return ~crc
  }
}
