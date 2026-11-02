import Compression
import CryptoKit
import Foundation
import Synchronization
import Testing

@testable import LaunchdOps

/// Test-only readers for the formats LaunchdOps writes, so each writer is checked by parsing its output.
private enum Read {
  static func bigEndian<T: FixedWidthInteger>(_ data: Data, at offset: Int, as: T.Type = T.self) -> T {
    let start = data.startIndex + offset
    return data[start..<start + MemoryLayout<T>.size].reduce(T(0)) { ($0 << 8) | T($1) }
  }

  static func littleEndian32(_ data: Data, at offset: Int) -> UInt32 {
    let start = data.startIndex + offset
    return data[start..<start + 4].reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
  }

  static func inflate(_ deflated: Data, expectedSize: Int) -> Data {
    var output = Data(count: max(expectedSize, 1))
    let written = output.withUnsafeMutableBytes { destination in
      deflated.withUnsafeBytes { source in
        compression_decode_buffer(
          destination.bindMemory(to: UInt8.self).baseAddress!, destination.count,
          source.bindMemory(to: UInt8.self).baseAddress!, deflated.count,
          nil, COMPRESSION_ZLIB
        )
      }
    }
    output.count = written
    return output
  }

  static func gunzip(_ data: Data) -> Data {
    let size = Int(littleEndian32(data, at: data.count - 4))
    return inflate(data.subdata(in: 10..<data.count - 8), expectedSize: size)
  }

  /// cpio "odc" entry names and data sizes, excluding the trailer.
  static func cpioEntries(_ data: Data) -> [(name: String, mode: Int, size: Int)] {
    var entries: [(String, Int, Int)] = []
    var offset = 0
    while offset < data.count {
      let header = String(decoding: data[offset..<offset + 76], as: UTF8.self)
      #expect(header.hasPrefix("070707"))
      func field(_ start: Int, _ width: Int) -> Int {
        Int(header.dropFirst(start).prefix(width), radix: 8) ?? -1
      }
      let mode = field(18, 6)
      let nameSize = field(59, 6)
      let fileSize = field(65, 11)
      let name = String(decoding: data[offset + 76..<offset + 76 + nameSize - 1], as: UTF8.self)
      offset += 76 + nameSize + fileSize
      if name == "TRAILER!!!" { break }
      entries.append((name, mode, fileSize))
    }
    return entries
  }
}

struct PackageCompressionTests {
  @Test func gzipRoundTripsWithTrailer() throws {
    let text = Data(String(repeating: "launchd ", count: 500).utf8)
    let gzip = try PackageCompression.gzip(text)
    #expect(gzip.prefix(3) == Data([0x1F, 0x8B, 0x08]))
    #expect(Read.littleEndian32(gzip, at: gzip.count - 8) == CRC32.checksum(text))
    #expect(Read.gunzip(gzip) == text)
  }

  @Test func gzipOfEmptyDataIsValid() throws {
    let gzip = try PackageCompression.gzip(Data())
    #expect(Read.littleEndian32(gzip, at: gzip.count - 4) == 0)
    #expect(Read.gunzip(gzip).isEmpty)
  }

  @Test func adler32KnownValue() {
    #expect(PackageCompression.adler32(Data("Wikipedia".utf8)) == 0x11E6_0398)
  }

  @Test func posixChecksumMatchesCksum() {
    // Values printed by cksum(1) for the empty input and for "123456789".
    #expect(POSIXChecksum.cksum(Data()) == 4_294_967_295)
    #expect(POSIXChecksum.cksum(Data("123456789".utf8)) == 930_766_865)
  }
}

struct CpioWriterTests {
  @Test func writesEntriesAndTrailer() throws {
    let entries = try PackagePayload.entries(files: [
      ("/Library/LaunchDaemons/com.example.job.plist", Data("<plist/>".utf8), 0o644),
      ("/usr/local/libexec/run.sh", Data("#!/bin/zsh\n".utf8), 0o755),
    ])
    let parsed = Read.cpioEntries(CpioWriter.archive(entries))
    #expect(
      parsed.map(\.name) == [
        ".", "./Library", "./Library/LaunchDaemons", "./Library/LaunchDaemons/com.example.job.plist",
        "./usr", "./usr/local", "./usr/local/libexec", "./usr/local/libexec/run.sh",
      ]
    )
    #expect(parsed[3].mode == 0o100644)
    #expect(parsed[3].size == 8)
    #expect(parsed[7].mode == 0o100755)
    #expect(parsed[0].mode == 0o040755)
  }
}

struct BomWriterTests {
  private var entries: [PackageEntry] {
    get throws {
      try PackagePayload.entries(files: [
        ("/Library/LaunchDaemons/com.example.job.plist", Data("<plist/>".utf8), 0o644)
      ])
    }
  }

  @Test func headerVariablesAndIndexAreConsistent() throws {
    let entries = try entries
    let bom = try BomWriter.bom(entries)
    #expect(bom.prefix(8) == Data("BOMStore".utf8))
    let indexOffset = Int(Read.bigEndian(bom, at: 16, as: UInt32.self))
    let indexLength = Int(Read.bigEndian(bom, at: 20, as: UInt32.self))
    #expect(indexOffset + indexLength == bom.count)

    let varsOffset = Int(Read.bigEndian(bom, at: 24, as: UInt32.self))
    let count = Int(Read.bigEndian(bom, at: varsOffset, as: UInt32.self))
    var names: [String] = []
    var cursor = varsOffset + 4
    for _ in 0..<count {
      let length = Int(bom[cursor + 4])
      names.append(String(decoding: bom[cursor + 5..<cursor + 5 + length], as: UTF8.self))
      cursor += 5 + length
    }
    #expect(names == ["BomInfo", "Paths", "HLIndex", "VIndex", "Size64"])
  }

  @Test func pathsTreeListsEveryEntryWithParents() throws {
    let entries = try entries
    let bom = try BomWriter.bom(entries)
    let indexOffset = Int(Read.bigEndian(bom, at: 16, as: UInt32.self))
    func block(_ index: UInt32) -> Data {
      let pointer = indexOffset + 4 + Int(index) * 8
      let address = Int(Read.bigEndian(bom, at: pointer, as: UInt32.self))
      let length = Int(Read.bigEndian(bom, at: pointer + 4, as: UInt32.self))
      return bom.subdata(in: address..<address + length)
    }

    // Variable 1 is Paths: find its tree, then the single leaf.
    let varsOffset = Int(Read.bigEndian(bom, at: 24, as: UInt32.self))
    let pathsVar = varsOffset + 4 + 5 + "BomInfo".count
    let tree = block(Read.bigEndian(bom, at: pathsVar, as: UInt32.self))
    #expect(tree.prefix(4) == Data("tree".utf8))
    #expect(Int(Read.bigEndian(tree, at: 16, as: UInt32.self)) == entries.count)

    let leaf = block(Read.bigEndian(tree, at: 8, as: UInt32.self))
    #expect(Read.bigEndian(leaf, at: 0, as: UInt16.self) == 1)
    let count = Int(Read.bigEndian(leaf, at: 2, as: UInt16.self))
    #expect(count == entries.count)

    var names: [UInt32: String] = [:]
    var paths: [String] = []
    for position in 0..<count {
      let info1 = block(Read.bigEndian(leaf, at: 12 + position * 8, as: UInt32.self))
      let file = block(Read.bigEndian(leaf, at: 16 + position * 8, as: UInt32.self))
      let id = Read.bigEndian(info1, at: 0, as: UInt32.self)
      let parent = Read.bigEndian(file, at: 0, as: UInt32.self)
      let name = String(decoding: file.dropFirst(4).prefix { $0 != 0 }, as: UTF8.self)
      let path = parent == 0 ? name : "\(names[parent] ?? "?")/\(name)"
      names[id] = path
      paths.append(path)

      let info2 = block(Read.bigEndian(info1, at: 4, as: UInt32.self))
      let isDirectory = info2[0] == 2
      #expect(Int(Read.bigEndian(info2, at: 4, as: UInt16.self)) == (isDirectory ? 0o040755 : 0o100644))
    }
    #expect(paths == [".", "./Library", "./Library/LaunchDaemons", "./Library/LaunchDaemons/com.example.job.plist"])
  }

  @Test func rejectsTooManyEntries() {
    let files = (0...BomWriter.maximumEntries).map { ("/usr/local/libexec/tool\($0)", Data(), 0o755) }
    #expect(throws: BomWriterError.self) { try BomWriter.bom(try PackagePayload.entries(files: files)) }
  }
}

private struct FakeSigner: PackageSigner {
  let certificates = [Data([0x30, 0x03, 0x02, 0x01, 0x01])]
  let rsaSignatureLength = 256

  func rsaSignature(forDigest digest: Data) throws -> Data {
    Data(repeating: 0xAA, count: rsaSignatureLength - digest.count) + digest
  }

  func cmsSignature(forDigest digest: Data) throws -> Data {
    Data(repeating: 0xBB, count: 64) + digest
  }
}

/// Counts private-key uses, each of which can show a keychain prompt.
private final class CountingSigner: PackageSigner {
  let certificates = [Data([0x30, 0x03, 0x02, 0x01, 0x01])]
  let rsaSignatureLength = 256
  let expectedCMSSignatureLength: Int
  let uses = Mutex(0)

  init(expectedCMSSignatureLength: Int) {
    self.expectedCMSSignatureLength = expectedCMSSignatureLength
  }

  func rsaSignature(forDigest digest: Data) throws -> Data {
    uses.withLock { $0 += 1 }
    return try FakeSigner().rsaSignature(forDigest: digest)
  }

  func cmsSignature(forDigest digest: Data) throws -> Data {
    uses.withLock { $0 += 1 }
    return try FakeSigner().cmsSignature(forDigest: digest)
  }
}

struct XarSigningPromptTests {
  private let entries = [XarEntry(name: "Distribution", kind: .file(Data("x".utf8)))]

  @Test func rightGuessUsesTheKeyTwice() throws {
    let signer = CountingSigner(expectedCMSSignatureLength: 64 + 20)
    let archive = try XarWriter.archive(entries, signer: signer)
    #expect(signer.uses.withLock { $0 } == 2)
    #expect(archive == (try XarWriter.archive(entries, signer: FakeSigner())))
  }

  @Test func wrongGuessCostsOneMoreSignatureAndGivesTheSameArchive() throws {
    let signer = CountingSigner(expectedCMSSignatureLength: 1000)
    let archive = try XarWriter.archive(entries, signer: signer)
    #expect(signer.uses.withLock { $0 } == 3)
    #expect(archive == (try XarWriter.archive(entries, signer: CountingSigner(expectedCMSSignatureLength: 84))))
  }
}

struct XarWriterTests {
  private func parse(_ archive: Data) -> (toc: String, heap: Data, compressedTOC: Data) {
    #expect(archive.prefix(4) == Data("xar!".utf8))
    #expect(Read.bigEndian(archive, at: 4, as: UInt16.self) == 28)
    let compressedLength = Int(Read.bigEndian(archive, at: 8, as: UInt64.self))
    let length = Int(Read.bigEndian(archive, at: 16, as: UInt64.self))
    #expect(Read.bigEndian(archive, at: 24, as: UInt32.self) == 1)
    let compressed = archive.subdata(in: 28..<28 + compressedLength)
    let toc = Read.inflate(compressed.subdata(in: 2..<compressed.count - 4), expectedSize: length)
    #expect(Read.bigEndian(compressed, at: compressed.count - 4, as: UInt32.self) == PackageCompression.adler32(toc))
    return (
      String(decoding: toc, as: UTF8.self), archive.subdata(in: 28 + compressedLength..<archive.count), compressed
    )
  }

  private func value(_ tag: String, after marker: String, in toc: String) -> Int? {
    guard let range = toc.range(of: marker),
      let open = toc.range(of: "<\(tag)>", range: range.upperBound..<toc.endIndex),
      let close = toc.range(of: "</\(tag)>", range: open.upperBound..<toc.endIndex)
    else { return nil }
    return Int(toc[open.upperBound..<close.lowerBound])
  }

  @Test func heapStartsWithTOCChecksumAndHoldsFiles() throws {
    let contents = Data("hello".utf8)
    let archive = try XarWriter.archive([
      XarEntry(name: "Distribution", kind: .file(contents)),
      XarEntry(name: "dir & <more>", kind: .directory([XarEntry(name: "Bom", kind: .file(Data([1, 2])))])),
    ])
    let (toc, heap, compressed) = parse(archive)
    #expect(heap.prefix(20) == Data(Insecure.SHA1.hash(data: compressed)))
    #expect(toc.contains("<name>dir &amp; &lt;more&gt;</name>"))
    // File 1 is Distribution; xar lists <data> before <name>, so read the offset inside file 1.
    let offset = try #require(value("offset", after: "<file id=\"1\">", in: toc))
    try #require(offset + contents.count <= heap.count)
    #expect(heap.subdata(in: offset..<offset + contents.count) == contents)
  }

  @Test func signaturesAreWrittenAtTheirDeclaredOffsets() throws {
    let archive = try XarWriter.archive(
      [XarEntry(name: "Distribution", kind: .file(Data("x".utf8)))], signer: FakeSigner())
    let (toc, heap, compressed) = parse(archive)
    let digest = Data(Insecure.SHA1.hash(data: compressed))
    #expect(toc.contains(#"<signature style="RSA">"#))
    #expect(toc.contains(#"<x-signature style="CMS">"#))
    #expect(toc.contains("<X509Certificate>MAMCAQE=</X509Certificate>"))

    let rsaOffset = try #require(value("offset", after: #"<signature style="RSA">"#, in: toc))
    let rsaSize = try #require(value("size", after: #"<signature style="RSA">"#, in: toc))
    #expect(heap.subdata(in: rsaOffset..<rsaOffset + rsaSize) == (try FakeSigner().rsaSignature(forDigest: digest)))

    let cmsOffset = try #require(value("offset", after: #"<x-signature style="CMS">"#, in: toc))
    let cmsSize = try #require(value("size", after: #"<x-signature style="CMS">"#, in: toc))
    #expect(heap.subdata(in: cmsOffset..<cmsOffset + cmsSize) == (try FakeSigner().cmsSignature(forDigest: digest)))
  }
}

struct FlatPackageBuilderTests {
  private func sampleProject() -> Project {
    var project = Project()
    project.settings.packageIdentifier = "com.example.pkg.tools"
    project.settings.version = "2.1"
    var job = LaunchJob(context: .daemon, label: "com.example.job")
    job.program = "/usr/local/libexec/run.sh"
    project.jobs = [job]
    project.payload = [
      PayloadFile(name: "run.sh", destination: "/usr/local/libexec", mode: 0o755, contents: Data("#!/bin/zsh\n".utf8))
    ]
    return project
  }

  @Test func productContainsDistributionAndComponent() throws {
    let package = try FlatPackageBuilder.package(FlatPackageBuilder.input(for: sampleProject()))
    let toc = String(decoding: XarReader.toc(package), as: UTF8.self)
    for name in ["Distribution", "component.pkg", "Bom", "PackageInfo", "Payload", "Scripts"] {
      #expect(toc.contains("<name>\(name)</name>"), "missing \(name)")
    }
  }

  @Test func packageInfoAndDistributionDescribeThePackage() throws {
    let input = try FlatPackageBuilder.input(for: sampleProject())
    let info = FlatPackageBuilder.packageInfo(input, fileCount: 8, installKilobytes: 1)
    #expect(info.contains(#"identifier="com.example.pkg.tools""#))
    #expect(info.contains(#"version="2.1""#))
    #expect(info.contains(#"<postinstall file="./postinstall"/>"#))
    let distribution = FlatPackageBuilder.distribution(input, installKilobytes: 1)
    #expect(distribution.contains("#component.pkg</pkg-ref>"))
    #expect(distribution.contains(#"<pkg-ref id="com.example.pkg.tools" version="2.1""#))
  }

  @Test func unsignedPackageIsDeterministic() throws {
    let input = try FlatPackageBuilder.input(for: sampleProject())
    #expect(try FlatPackageBuilder.package(input) == (try FlatPackageBuilder.package(input)))
  }

  @Test func exportWritesOnePackageFile() throws {
    var project = sampleProject()
    project.settings.packageOutput = .installerPackage
    let paths = try ProjectExporter.export(project).files.map(\.path).filter { $0.hasSuffix(".pkg") }
    // A blank project name follows the job label.
    #expect(paths == ["com.example.job-2.1-unsigned.pkg"])

    project.settings.signingIdentity = "Developer ID Installer: Example (ABCDE12345)"
    let preview = try ProjectExporter.export(project, buildsPackage: false).files.filter {
      $0.path.hasSuffix(".pkg")
    }
    #expect(preview.map(\.path) == ["com.example.job-2.1.pkg"])
    #expect(preview.first?.contents.isEmpty == true)
  }

  @Test func validatorFlagsUnsignedPackage() {
    var project = sampleProject()
    project.settings.packageOutput = .installerPackage
    #expect(Validator.validate(project).contains { $0.rule == "package.unsigned" })
    project.settings.signingIdentity = "Developer ID Installer: Example (ABCDE12345)"
    #expect(!Validator.validate(project).contains { $0.rule == "package.unsigned" })
    project.settings.packageOutput = .buildScript
    project.settings.signingIdentity = ""
    #expect(!Validator.validate(project).contains { $0.rule == "package.unsigned" })
  }
}

private enum XarReader {
  static func toc(_ archive: Data) -> Data {
    let compressedLength = Int(Read.bigEndian(archive, at: 8, as: UInt64.self))
    let length = Int(Read.bigEndian(archive, at: 16, as: UInt64.self))
    let compressed = archive.subdata(in: 28..<28 + compressedLength)
    return Read.inflate(compressed.subdata(in: 2..<compressed.count - 4), expectedSize: length)
  }
}

/// Opens a finished package the way Installer does: TOC → component files → gunzip → cpio, and the Bom.
struct FinishedPackageTests {
  private func project(payloadCount: Int = 1) -> Project {
    var project = Project()
    project.settings.packageIdentifier = "com.example.pkg.tools"
    var job = LaunchJob(context: .daemon, label: "com.example.job")
    job.program = "/usr/local/libexec/tool0"
    project.jobs = [job]
    project.payload = (0..<payloadCount).map {
      PayloadFile(
        name: "tool\($0)", destination: "/usr/local/libexec", mode: 0o755, contents: Data("#!/bin/zsh\n".utf8))
    }
    return project
  }

  private func files(in package: Data) throws -> [String: Data] {
    let toc = try XMLDocument(data: XarReader.toc(package))
    let compressedLength = Int(Read.bigEndian(package, at: 8, as: UInt64.self))
    let heap = package.subdata(in: 28 + compressedLength..<package.count)
    var result: [String: Data] = [:]
    var seenIDs = Set<String>()
    for node in try toc.nodes(forXPath: "//file") {
      guard let element = node as? XMLElement else { continue }
      let id = element.attribute(forName: "id")?.stringValue ?? ""
      #expect(seenIDs.insert(id).inserted, "duplicate xar id \(id)")
      guard let data = element.elements(forName: "data").first,
        let name = element.elements(forName: "name").first?.stringValue,
        let offset = Int(data.elements(forName: "offset").first?.stringValue ?? ""),
        let size = Int(data.elements(forName: "size").first?.stringValue ?? ""),
        let length = Int(data.elements(forName: "length").first?.stringValue ?? "")
      else { continue }
      #expect(size == length)
      try #require(offset + size <= heap.count)
      let contents = heap.subdata(in: offset..<offset + size)
      let checksum = data.elements(forName: "extracted-checksum").first?.stringValue
      #expect(checksum == Insecure.SHA1.hash(data: contents).map { String(format: "%02x", $0) }.joined())
      result[name] = contents
    }
    return result
  }

  @Test func payloadAndScriptsUnpack() throws {
    let project = project()
    let package = try FlatPackageBuilder.package(FlatPackageBuilder.input(for: project))
    let files = try files(in: package)

    let payload = Read.cpioEntries(Read.gunzip(try #require(files["Payload"])))
    let modes = Dictionary(uniqueKeysWithValues: payload.map { ($0.name, $0.mode) })
    #expect(modes["./Library/LaunchDaemons"] == 0o040755)
    #expect(modes["./Library/LaunchDaemons/com.example.job.plist"] == 0o100644)
    #expect(modes["./usr/local/libexec/tool0"] == 0o100755)

    let scripts = Read.cpioEntries(Read.gunzip(try #require(files["Scripts"])))
    #expect(scripts.map(\.name) == [".", "./postinstall", "./preinstall"])
    #expect(scripts.dropFirst().allSatisfy { $0.mode == 0o100755 })
    #expect(files["PackageInfo"].map { String(decoding: $0, as: UTF8.self).contains("com.example.pkg.tools") } == true)
  }

  @Test func bomMatchesPayloadSizesAndChecksums() throws {
    let input = try FlatPackageBuilder.input(for: project())
    let entries = try PackagePayload.entries(files: input.files)
    let bom = try BomWriter.bom(entries)
    let indexOffset = Int(Read.bigEndian(bom, at: 16, as: UInt32.self))
    func block(_ index: UInt32) -> Data {
      let pointer = indexOffset + 4 + Int(index) * 8
      let address = Int(Read.bigEndian(bom, at: pointer, as: UInt32.self))
      let length = Int(Read.bigEndian(bom, at: pointer + 4, as: UInt32.self))
      return bom.subdata(in: address..<address + length)
    }
    let varsOffset = Int(Read.bigEndian(bom, at: 24, as: UInt32.self))
    let tree = block(Read.bigEndian(bom, at: varsOffset + 4 + 5 + "BomInfo".count, as: UInt32.self))
    let leaf = block(Read.bigEndian(tree, at: 8, as: UInt32.self))
    for (position, entry) in entries.enumerated() {
      let info1 = block(Read.bigEndian(leaf, at: 12 + position * 8, as: UInt32.self))
      let info2 = block(Read.bigEndian(info1, at: 4, as: UInt32.self))
      #expect(Int(Read.bigEndian(info2, at: 4, as: UInt16.self)) == entry.mode)
      #expect(Int(Read.bigEndian(info2, at: 18, as: UInt32.self)) == entry.contents.count)
      let checksum = Read.bigEndian(info2, at: 23, as: UInt32.self)
      #expect(checksum == (entry.isDirectory ? 0 : POSIXChecksum.cksum(entry.contents)))
    }
  }

  @Test func rejectsPathsPkgbuildWouldNotProduce() {
    #expect(throws: PackagePayloadError.invalidPath("/usr/../etc/x")) {
      try PackagePayload.entries(files: [("/usr/../etc/x", Data(), 0o644)])
    }
    #expect(throws: PackagePayloadError.duplicatePath("/usr/local/x")) {
      try PackagePayload.entries(files: [("/usr/local/x", Data(), 0o644), ("/usr/local/x", Data(), 0o644)])
    }
    #expect(throws: PackagePayloadError.fileAndFolder("/usr/local/x")) {
      try PackagePayload.entries(files: [("/usr/local/x", Data(), 0o644), ("/usr/local/x/y", Data(), 0o644)])
    }
    #expect(throws: PackagePayloadError.fileAndFolder("/usr/local/x")) {
      try PackagePayload.entries(files: [("/usr/local/x/y", Data(), 0o644), ("/usr/local/x", Data(), 0o644)])
    }
  }

  @Test func validatorFlagsTooManyFiles() {
    var large = project(payloadCount: BomWriter.maximumEntries)
    large.settings.packageOutput = .installerPackage
    #expect(Validator.validate(large).contains { $0.rule == "package.too-many-files" })
    var small = project(payloadCount: 3)
    small.settings.packageOutput = .installerPackage
    #expect(!Validator.validate(small).contains { $0.rule == "package.too-many-files" })
  }

  @Test func validatorRequiresDeveloperIDForNotarization() {
    var project = project()
    project.settings.packageOutput = .installerPackage
    project.settings.notarizeAfterExport = true
    project.settings.signingIdentity = "Developer ID Installer: Example (ABCDE12345)"
    #expect(!Validator.validate(project).contains { $0.rule == "package.notarize-identity" })
    project.settings.signingIdentity = "3rd Party Mac Developer Installer: Example (ABCDE12345)"
    #expect(Validator.validate(project).contains { $0.rule == "package.notarize-identity" })
  }
}
