import Foundation

enum SecureFileReader {
  enum ReadError: LocalizedError {
    case notAFile
    case tooLarge(Int)

    var errorDescription: String? {
      switch self {
      case .notAFile:
        "Only regular files can be added."
      case .tooLarge(let limit):
        "The file is larger than \(limit.formatted(.byteCount(style: .file)))."
      }
    }
  }

  static func read(_ url: URL, limit: Int = PayloadFile.maximumSize) throws -> Data {
    let didAccess = url.startAccessingSecurityScopedResource()
    defer {
      if didAccess { url.stopAccessingSecurityScopedResource() }
    }
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true else { throw ReadError.notAFile }
    if let size = values.fileSize, size > limit { throw ReadError.tooLarge(limit) }
    return try Data(contentsOf: url, options: .mappedIfSafe)
  }

  static func isExecutable(_ url: URL) -> Bool {
    let didAccess = url.startAccessingSecurityScopedResource()
    defer {
      if didAccess { url.stopAccessingSecurityScopedResource() }
    }
    return FileManager.default.isExecutableFile(atPath: url.path(percentEncoded: false))
  }
}
