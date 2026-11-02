import Foundation

/// One file or directory in a package payload, with its path relative to the install location.
struct PackageEntry: Hashable, Sendable {
  enum Kind: Hashable, Sendable {
    case directory
    case file(Data)
  }

  /// Path without a leading slash, for example `Library/LaunchDaemons/com.example.plist`. Empty for the root.
  var path: String
  var kind: Kind
  /// Permission bits only, for example `0o644`.
  var permissions: Int
  var uid = 0
  var gid = 0

  var isDirectory: Bool { kind == .directory }

  var contents: Data {
    if case .file(let data) = kind { return data }
    return Data()
  }

  /// `.`, `./Library`, … as pkgbuild names payload entries.
  var archiveName: String { path.isEmpty ? "." : "./\(path)" }

  /// Full mode including the file type bits.
  var mode: Int { (isDirectory ? 0o040000 : 0o100000) | permissions }
}

enum PackagePayloadError: LocalizedError, Equatable {
  case invalidPath(String)
  case duplicatePath(String)
  case fileAndFolder(String)

  var errorDescription: String? {
    switch self {
    case .invalidPath(let path):
      "The package path \(path) contains . or .. components. Fix the payload destination on the General tab."
    case .duplicatePath(let path):
      "Two files would install to \(path). Give each payload file a different name or destination."
    case .fileAndFolder(let path):
      "\(path) would be both a file and a folder in the package. Change the payload destination."
    }
  }
}

enum PackagePayload {
  /// Fixed modification time for every entry (2001-01-01 00:00:00 UTC), so exports are deterministic.
  static let modificationTime = 978_307_200

  /// Builds a sorted payload from absolute install paths, adding every parent directory as root:wheel 0755.
  /// Throws for paths `pkgbuild` could never produce, which Export can reach when the user exports anyway.
  static func entries(files: [(path: String, contents: Data, permissions: Int)]) throws -> [PackageEntry] {
    var byPath: [String: PackageEntry] = ["": PackageEntry(path: "", kind: .directory, permissions: 0o755)]
    for file in files {
      guard SafeInstallPath.problem(withAbsolutePath: file.path) == nil else {
        throw PackagePayloadError.invalidPath(file.path)
      }
      let components = file.path.split(separator: "/").map(String.init)
      guard !components.isEmpty else { continue }
      for depth in 1..<components.count {
        let directory = components[0..<depth].joined(separator: "/")
        switch byPath[directory]?.kind {
        case .file: throw PackagePayloadError.fileAndFolder("/" + directory)
        case .directory: continue
        case nil: byPath[directory] = PackageEntry(path: directory, kind: .directory, permissions: 0o755)
        }
      }
      let path = components.joined(separator: "/")
      switch byPath[path]?.kind {
      case .file: throw PackagePayloadError.duplicatePath("/" + path)
      case .directory: throw PackagePayloadError.fileAndFolder("/" + path)
      case nil: break
      }
      byPath[path] = PackageEntry(path: path, kind: .file(file.contents), permissions: file.permissions & 0o7777)
    }
    return byPath.values.sorted { $0.path < $1.path }
  }

  static func installKilobytes(_ entries: [PackageEntry]) -> Int {
    let bytes = entries.reduce(0) { $0 + $1.contents.count }
    return (bytes + 1023) / 1024
  }
}

/// Writes a POSIX.1 portable ("odc", magic 070707) cpio archive, the format installer payloads use.
enum CpioWriter {
  static func archive(_ entries: [PackageEntry]) -> Data {
    var output = Data()
    for (index, entry) in entries.enumerated() {
      appendHeader(
        to: &output,
        name: entry.archiveName,
        inode: index + 1,
        mode: entry.mode,
        uid: entry.uid,
        gid: entry.gid,
        links: entry.isDirectory ? 2 : 1,
        size: entry.contents.count
      )
      output.append(entry.contents)
    }
    appendHeader(to: &output, name: "TRAILER!!!", inode: 0, mode: 0, uid: 0, gid: 0, links: 1, size: 0)
    return output
  }

  private static func appendHeader(
    to output: inout Data,
    name: String,
    inode: Int,
    mode: Int,
    uid: Int,
    gid: Int,
    links: Int,
    size: Int
  ) {
    let nameBytes = Data(name.utf8) + [0]
    let fields = [
      "070707",
      octal(0, width: 6),  // device
      octal(inode, width: 6),
      octal(mode, width: 6),
      octal(uid, width: 6),
      octal(gid, width: 6),
      octal(links, width: 6),
      octal(0, width: 6),  // rdev
      octal(inode == 0 ? 0 : PackagePayload.modificationTime, width: 11),
      octal(nameBytes.count, width: 6),
      octal(size, width: 11),
    ]
    output.append(Data(fields.joined().utf8))
    output.append(nameBytes)
  }

  private static func octal(_ value: Int, width: Int) -> String {
    let digits = String(value, radix: 8)
    return String(repeating: "0", count: max(0, width - digits.count)) + digits
  }
}
