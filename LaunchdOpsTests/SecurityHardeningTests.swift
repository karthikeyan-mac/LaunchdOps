import Foundation
import Security
import Testing

@testable import LaunchdOps

/// Paths and names that reach customer Macs pass one canonical validator.
struct SafeInstallPathTests {
  @Test func foldersMustBeCanonicalAbsolutePaths() {
    #expect(SafeInstallPath.problem(withFolder: "/usr/local/libexec") == nil)
    #expect(SafeInstallPath.problem(withFolder: "/usr/local/libexec/") == nil)  // One trailing slash is ignored.
    #expect(SafeInstallPath.problem(withFolder: "/usr/local//libexec") == .doubleSlash)
    #expect(SafeInstallPath.problem(withFolder: "//usr/local/libexec") == .doubleSlash)
    #expect(SafeInstallPath.problem(withFolder: "/usr/local/./libexec") == .dotComponent)
    #expect(SafeInstallPath.problem(withFolder: "/usr/local/libexec/../bin") == .dotComponent)
    #expect(SafeInstallPath.problem(withFolder: "usr/local/libexec") == .relative)
    #expect(SafeInstallPath.problem(withFolder: "") == .empty)
    #expect(SafeInstallPath.problem(withFolder: "/usr/local\n/bin") == .controlCharacter)
    #expect(SafeInstallPath.problem(withFolder: "/" + String(repeating: "a", count: 256)) == .tooLong)
  }

  @Test func ddmSubfoldersStayInsideTheTaskFolder() {
    #expect(SafeInstallPath.problem(withSubfolder: "") == nil)
    #expect(SafeInstallPath.problem(withSubfolder: "bin") == nil)
    #expect(SafeInstallPath.problem(withSubfolder: "/usr/local") == .absolute)
    #expect(SafeInstallPath.problem(withSubfolder: "bin/../../x") == .dotComponent)
  }

  @Test func namesAreSingleSafeComponents() {
    #expect(SafeInstallPath.problem(withName: "backup.sh") == nil)
    #expect(SafeInstallPath.problem(withName: "..") == .dotComponent)
    #expect(SafeInstallPath.problem(withName: ".hidden") == .dotComponent)
    #expect(SafeInstallPath.problem(withName: "../evil") == .dotComponent)
    #expect(SafeInstallPath.problem(withName: "a/b") == .doubleSlash)
    #expect(SafeInstallPath.problem(withName: "run\u{0}me") == .controlCharacter)
    #expect(SafeInstallPath.problem(withName: String(repeating: "é", count: 128)) == .tooLong)  // 256 bytes.
    // A look-alike slash (U+2215) is an ordinary character on disk, not a separator.
    #expect(SafeInstallPath.problem(withName: "a\u{2215}b") == nil)
  }

  @Test func packageWriterRejectsNonCanonicalPaths() {
    #expect(throws: PackagePayloadError.self) {
      try PackagePayload.entries(files: [("/usr/local//libexec/tool", Data(), 0o755)])
    }
    #expect(throws: PackagePayloadError.self) {
      try PackagePayload.entries(files: [("/usr/local/libexec/../tool", Data(), 0o755)])
    }
  }
}

/// Unsafe values are blocking: Export Anyway can't override them, and the exporter refuses them too.
struct BlockingIssueTests {
  private func project(label: String = "com.acme.backup", payload: [PayloadFile] = []) -> Project {
    var job = LaunchJob(context: .daemon, label: label)
    job.program = "/usr/bin/true"
    var project = Project()
    project.jobs = [job]
    project.payload = payload
    return project
  }

  @Test func unsafeValuesAreBlockingAndOrdinaryErrorsAreNot() {
    let badLabel = Validator.validate(project(label: "com.x\n/bin/sh"))
    #expect(badLabel.contains { $0.rule == "label.characters" && $0.isBlocking })

    let writable = PayloadFile(name: "tool", destination: "/usr/local/libexec", mode: 0o777, contents: Data())
    let writableIssues = Validator.validate(project(payload: [writable]))
    #expect(writableIssues.contains { $0.rule == "payload.writable" && $0.isBlocking })

    let traversal = PayloadFile(name: "tool", destination: "/usr/local/../../etc", mode: 0o755, contents: Data())
    #expect(
      Validator.validate(project(payload: [traversal])).contains { $0.rule == "payload.destination" && $0.isBlocking }
    )

    // A package identifier without a dot is an error but safe in paths, so it can still be exported anyway.
    var noDot = project()
    noDot.settings.packageIdentifier = "backup"
    let identifier = Validator.validate(noDot).first { $0.rule == "package.identifier" }
    #expect(identifier?.isBlocking == false)
  }

  @Test func exporterRefusesWritablePayloads() {
    let writable = PayloadFile(name: "tool", destination: "/usr/local/libexec", mode: 0o775, contents: Data())
    #expect(throws: ProjectExporter.UnsafeValue.payloadWritable("tool")) {
      try ProjectExporter.export(project(payload: [writable]), buildsPackage: false)
    }
  }

  @Test func rootProgramsInUnverifiedLocationsAreFlagged() {
    var custom = project()
    custom.jobs[0].program = "/Library/Management/super/super"
    // A note, not a warning: common management agents (for example /usr/local/jamf/bin/jamf) are root-owned.
    #expect(Validator.validate(custom).contains { $0.rule == "program.location-unverified" && $0.severity == .info })

    #expect(!Validator.validate(project()).contains { $0.rule == "program.location-unverified" })  // /usr/bin

    var fromPayload = custom
    fromPayload.payload = [
      PayloadFile(name: "super", destination: "/Library/Management/super", mode: 0o755, contents: Data())
    ]
    #expect(!Validator.validate(fromPayload).contains { $0.rule == "program.location-unverified" })

    var agent = custom
    agent.jobs[0].context = .globalAgent
    #expect(!Validator.validate(agent).contains { $0.rule == "program.location-unverified" })
  }
}

/// A `.launchdops` package can come from anyone, so reading one is a security boundary.
struct HostileProjectImportTests {
  private let jobID = UUID()
  private let payloadID = UUID()

  private func plist(label: String = "com.acme.backup") -> Data {
    // Only valid plists reach here; malformed ones are tested separately.
    (try? PropertyListSerialization.data(
      fromPropertyList: ["Label": label, "Program": "/usr/bin/true"], format: .xml, options: 0
    )) ?? Data()
  }

  private func package(
    jobs: [[String: Any]]? = nil,
    payload: [[String: Any]] = [],
    jobFiles: [String: Data]? = nil,
    manifest: Data? = nil
  ) throws -> FileWrapper {
    let jobs = jobs ?? [["id": jobID.uuidString, "context": "daemon", "file": "job.plist"]]
    let object: [String: Any] = ["formatVersion": 1, "settings": [String: Any](), "jobs": jobs, "payload": payload]
    let manifestData = try manifest ?? JSONSerialization.data(withJSONObject: object)
    let files = (jobFiles ?? ["job.plist": plist()]).mapValues { FileWrapper(regularFileWithContents: $0) }
    return FileWrapper(directoryWithFileWrappers: [
      "project.json": FileWrapper(regularFileWithContents: manifestData),
      "Jobs": FileWrapper(directoryWithFileWrappers: files),
      "Payload": FileWrapper(directoryWithFileWrappers: ["p": FileWrapper(regularFileWithContents: Data("x".utf8))]),
    ])
  }

  private func payloadEntry(
    name: String = "tool",
    destination: String = "/usr/local/libexec",
    mode: Int = 0o755
  ) -> [String: Any] {
    ["id": payloadID.uuidString, "name": name, "destination": destination, "mode": mode, "file": "p"]
  }

  @Test func outOfRangeModesAreRejected() throws {
    for mode in [-1, 0o10000, Int.max] {
      #expect(throws: ProjectPackage.PackageError.self) {
        try ProjectPackage.read(try package(payload: [payloadEntry(mode: mode)]))
      }
    }
    #expect(try ProjectPackage.read(try package(payload: [payloadEntry(mode: 0o7777)])).payload.count == 1)
  }

  @Test func duplicateIDsAreRejected() throws {
    let twice = [
      ["id": jobID.uuidString, "context": "daemon", "file": "job.plist"],
      ["id": jobID.uuidString, "context": "daemon", "file": "job.plist"],
    ]
    let error = #expect(throws: ProjectPackage.PackageError.self) {
      try ProjectPackage.read(try package(jobs: twice))
    }
    if case .duplicateID(let id) = error {
      #expect(id == jobID)
    } else {
      Issue.record("Expected duplicateID, got \(String(describing: error))")
    }
  }

  @Test func fileReferencesCannotLeaveThePackage() throws {
    for reference in ["../../etc/passwd", "/etc/passwd", "..", "."] {
      let jobs = [["id": jobID.uuidString, "context": "daemon", "file": reference]]
      #expect(throws: ProjectPackage.PackageError.self) {
        try ProjectPackage.read(try package(jobs: jobs))
      }
    }
  }

  @Test func projectFromANewerFormatIsRefusedWithAClearError() throws {
    let object: [String: Any] = [
      "formatVersion": 99, "settings": [String: Any](), "jobs": [[String: Any]](), "payload": [[String: Any]](),
    ]
    let manifest = try JSONSerialization.data(withJSONObject: object)
    do {
      _ = try ProjectPackage.read(try package(manifest: manifest))
      Issue.record("A newer format should not open")
    } catch let error as ProjectPackage.PackageError {
      guard case .unsupportedVersion(99) = error else {
        Issue.record("Expected unsupportedVersion(99), got \(error)")
        return
      }
      #expect(error.localizedDescription.contains("newer version of LaunchdOps"))
    }
  }

  @Test func malformedContentIsRejected() throws {
    #expect(throws: (any Error).self) {
      try ProjectPackage.read(try package(jobFiles: ["job.plist": Data("<plist><dict>".utf8)]))
    }
    #expect(throws: (any Error).self) {
      try ProjectPackage.read(try package(manifest: Data("{\"formatVersion\": 1, \"jobs\": 5}".utf8)))
    }
  }

  @Test func hostileValuesImportButCanNeverBeExported() throws {
    let cases: [[String: Any]] = [
      payloadEntry(name: "../evil"),
      payloadEntry(name: ".hidden"),
      payloadEntry(name: "run\nme"),
      payloadEntry(name: String(repeating: "a", count: 300)),
      payloadEntry(destination: "/usr/local/../../etc"),
      payloadEntry(destination: "/usr/local//libexec"),
      payloadEntry(destination: "relative/path"),
      payloadEntry(mode: 0o777),
    ]
    for entry in cases {
      // Importing is allowed so the admin can see and fix the values; exporting is not.
      let project = try ProjectPackage.read(try package(payload: [entry]))
      #expect(Validator.validate(project).contains { $0.isBlocking }, "\(entry)")
      #expect(throws: ProjectExporter.UnsafeValue.self) {
        try ProjectExporter.export(project, buildsPackage: false)
      }
    }
    let injected = try ProjectPackage.read(try package(jobFiles: ["job.plist": plist(label: "com.x\n/bin/sh #")]))
    #expect(throws: ProjectExporter.UnsafeValue.self) {
      try ProjectExporter.export(injected, buildsPackage: false)
    }
  }
}

struct NotaryKeyStorageTests {
  @Test func newKeysStayOnThisMacAndNeverSync() {
    for dataProtection in [true, false] {
      let item = NotaryCredentialStore.newItemAttributes(dataProtection: dataProtection)
      #expect(item[kSecAttrAccessible] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
      #expect(item[kSecAttrSynchronizable] as? Bool == false)
      #expect((item[kSecUseDataProtectionKeychain] as? Bool ?? false) == dataProtection)
    }
  }
}

struct PayloadSizeTests {
  private func project(fileSizes: [Int]) -> Project {
    var job = LaunchJob(context: .daemon, label: "com.acme.backup")
    job.program = "/usr/local/bin/tool0"
    var project = Project()
    project.jobs = [job]
    project.payload = fileSizes.enumerated().map { index, size in
      PayloadFile(name: "tool\(index)", destination: "/usr/local/bin", mode: 0o755, contents: Data(count: size))
    }
    return project
  }

  private func sizeIssue(_ sizes: [Int]) -> ValidationIssue? {
    Validator.validate(project(fileSizes: sizes)).first { $0.rule == "payload.total-size" }
  }

  @Test func smallPayloadsAreFine() {
    #expect(sizeIssue([1024, Validator.payloadWarningSize - 2048]) == nil)
  }

  @Test func largePayloadsWarnAndHugeOnesAreErrors() {
    let fifty = 50 * 1024 * 1024
    // The total counts, not the size of each file (each stays under the 50 MB file limit).
    #expect(sizeIssue(Array(repeating: fifty, count: 5))?.severity == .warning)
    let error = sizeIssue(Array(repeating: fifty, count: 21))
    #expect(error?.severity == .error)
    #expect(error?.isBlocking == false)
  }
}
