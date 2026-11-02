import Foundation

/// Reads just enough of a Mach-O file to tell whether it carries a code signature, and of which kind.
/// Layouts: <mach-o/loader.h>, <mach-o/fat.h> and the code signature blobs in xnu's `cs_blobs.h`.
/// Malformed data is reported as `notMachO` so a damaged file never produces a false warning.
enum MachOSignature: Equatable, Sendable {
  case notMachO
  /// `arm64` is true when the file has arm64 code, which Apple silicon runs only when it is signed.
  case unsigned(arm64: Bool)
  case adHoc
  case developerSigned(hardenedRuntime: Bool)

  static func inspect(_ data: Data) -> MachOSignature {
    let reader = ByteReader(data: data)
    guard let magic = reader.uint32(at: 0, bigEndian: true) else { return .notMachO }
    switch magic {
    case 0xCAFE_BABE: return fat(reader, archSize: 20, is64: false)
    case 0xCAFE_BABF: return fat(reader, archSize: 32, is64: true)
    default: return thin(reader, base: 0) ?? .notMachO
    }
  }

  /// Rank used to report the weakest slice of a universal binary.
  private var rank: Int {
    switch self {
    case .notMachO: 0
    case .unsigned(let arm64): arm64 ? 1 : 2
    case .adHoc: 3
    case .developerSigned(let hardened): hardened ? 5 : 4
    }
  }

  private static func fat(_ reader: ByteReader, archSize: Int, is64: Bool) -> MachOSignature {
    // Java class files share 0xCAFEBABE; their "count" is a class file version well above any slice count.
    guard let count = reader.uint32(at: 4, bigEndian: true), count > 0, count <= 32 else { return .notMachO }
    var weakest: MachOSignature?
    for index in 0..<Int(count) {
      let entry = 8 + index * archSize
      let offset: UInt64?
      if is64 {
        offset = reader.uint64(at: entry + 8, bigEndian: true)
      } else {
        offset = reader.uint32(at: entry + 8, bigEndian: true).map(UInt64.init)
      }
      guard let offset, offset <= UInt64(Int.max), let slice = thin(reader, base: Int(offset)) else {
        return .notMachO
      }
      if let current = weakest, current.rank <= slice.rank { continue }
      weakest = slice
    }
    return weakest ?? .notMachO
  }

  private static func thin(_ reader: ByteReader, base: Int) -> MachOSignature? {
    let headerSize: Int
    let bigEndian: Bool
    guard let magic = reader.uint32(at: base, bigEndian: false) else { return nil }
    switch magic {
    case 0xFEED_FACE: (headerSize, bigEndian) = (28, false)
    case 0xFEED_FACF: (headerSize, bigEndian) = (32, false)
    case 0xCEFA_EDFE: (headerSize, bigEndian) = (28, true)
    case 0xCFFA_EDFE: (headerSize, bigEndian) = (32, true)
    default: return nil
    }
    guard let cpuType = reader.uint32(at: base + 4, bigEndian: bigEndian),
      let commandCount = reader.uint32(at: base + 16, bigEndian: bigEndian),
      let commandsSize = reader.uint32(at: base + 20, bigEndian: bigEndian)
    else { return nil }
    // Load commands must fit in sizeofcmds, which bounds the loop however large ncmds claims to be.
    let end = base + headerSize + Int(commandsSize)
    var cursor = base + headerSize
    for _ in 0..<commandCount {
      guard cursor + 8 <= end,
        let command = reader.uint32(at: cursor, bigEndian: bigEndian),
        let size = reader.uint32(at: cursor + 4, bigEndian: bigEndian), size >= 8, cursor + Int(size) <= end
      else { return nil }
      if command == 0x1D {  // LC_CODE_SIGNATURE
        guard let offset = reader.uint32(at: cursor + 8, bigEndian: bigEndian) else { return nil }
        return signature(reader, at: base + Int(offset))
      }
      cursor += Int(size)
    }
    return .unsigned(arm64: cpuType == 0x0100_000C)  // CPU_TYPE_ARM64
  }

  /// The code signature super blob is always big-endian.
  private static func signature(_ reader: ByteReader, at start: Int) -> MachOSignature? {
    guard reader.uint32(at: start, bigEndian: true) == 0xFADE_0CC0,
      let count = reader.uint32(at: start + 8, bigEndian: true), count <= 64
    else { return nil }
    var flags: UInt32?
    var cmsLength: UInt32 = 0
    for index in 0..<Int(count) {
      let entry = start + 12 + index * 8
      guard let type = reader.uint32(at: entry, bigEndian: true),
        let offset = reader.uint32(at: entry + 4, bigEndian: true)
      else { return nil }
      let blob = start + Int(offset)
      switch type {
      case 0:  // CSSLOT_CODEDIRECTORY
        guard reader.uint32(at: blob, bigEndian: true) == 0xFADE_0C02 else { return nil }
        flags = reader.uint32(at: blob + 12, bigEndian: true)
      case 0x10000:  // CSSLOT_SIGNATURESLOT, a blob wrapper around the CMS signature
        guard reader.uint32(at: blob, bigEndian: true) == 0xFADE_0B01 else { return nil }
        cmsLength = reader.uint32(at: blob + 4, bigEndian: true) ?? 0
      default:
        continue
      }
    }
    guard let flags else { return nil }
    // An ad hoc signature has CS_ADHOC set and an empty (8-byte header only) or missing CMS blob.
    if flags & 0x2 != 0 || cmsLength <= 8 {
      return .adHoc
    }
    return .developerSigned(hardenedRuntime: flags & 0x1_0000 != 0)  // CS_RUNTIME
  }
}

private struct ByteReader {
  let data: Data

  func uint32(at offset: Int, bigEndian: Bool) -> UInt32? {
    bytes(at: offset, count: 4).map { value(of: $0, bigEndian: bigEndian) }.map(UInt32.init)
  }

  func uint64(at offset: Int, bigEndian: Bool) -> UInt64? {
    bytes(at: offset, count: 8).map { value(of: $0, bigEndian: bigEndian) }
  }

  private func bytes(at offset: Int, count: Int) -> [UInt8]? {
    guard offset >= 0, offset <= data.count - count else { return nil }
    let start = data.startIndex + offset
    return [UInt8](data[start..<start + count])
  }

  private func value(of bytes: [UInt8], bigEndian: Bool) -> UInt64 {
    let ordered = bigEndian ? bytes : bytes.reversed()
    return ordered.reduce(0) { $0 << 8 | UInt64($1) }
  }
}
