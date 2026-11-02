import Foundation
import Testing

@testable import LaunchdOps

struct EnvironmentTextTests {
  private typealias Assignment = EnvironmentVariable.Assignment

  @Test func parsesAssignments() {
    let parsed = EnvironmentVariable.parse(
      """
      # Proxy settings
      HTTPS_PROXY=http://proxy.example.com:8080

      export LANG=en_US.UTF-8
      GREETING="hello world"
      EMPTY=
      """
    )
    #expect(parsed.invalidLines.isEmpty)
    #expect(
      parsed.assignments == [
        Assignment(name: "HTTPS_PROXY", value: "http://proxy.example.com:8080"),
        Assignment(name: "LANG", value: "en_US.UTF-8"),
        Assignment(name: "GREETING", value: "hello world"),
        Assignment(name: "EMPTY", value: ""),
      ]
    )
  }

  @Test func valueKeepsLaterEqualsSigns() {
    let parsed = EnvironmentVariable.parse("QUERY=a=b&c=d")
    #expect(parsed.assignments == [Assignment(name: "QUERY", value: "a=b&c=d")])
  }

  @Test func laterLinesReplaceEarlierOnes() {
    let parsed = EnvironmentVariable.parse("MODE=one\nMODE=two\r\n")
    #expect(parsed.assignments == [Assignment(name: "MODE", value: "two")])
  }

  @Test func reportsInvalidLines() {
    let parsed = EnvironmentVariable.parse("GOOD=1\n1BAD=2\nno equals sign\nBAD-NAME=3")
    #expect(parsed.assignments == [Assignment(name: "GOOD", value: "1")])
    #expect(parsed.invalidLines == [2, 3, 4])
  }
}

struct EnvironmentMergeTests {
  @Test func updatesExistingAndAppendsNewInOrder() {
    var variables = [
      EnvironmentVariable(name: "A", value: "1"),
      EnvironmentVariable(name: "B", value: "2"),
    ]
    let firstID = variables[0].id
    EnvironmentVariable.merge(
      [.init(name: "C", value: "3"), .init(name: "A", value: "10"), .init(name: "D", value: "4")],
      into: &variables
    )
    #expect(variables.map(\.name) == ["A", "B", "C", "D"])
    #expect(variables.map(\.value) == ["10", "2", "3", "4"])
    #expect(variables[0].id == firstID)
  }
}

struct KeepAlivePlistTests {
  @Test func crashOnlyDetection() {
    #expect(KeepAlive(mode: .conditional, crashed: true).isCrashOnly)
    #expect(!KeepAlive(mode: .conditional, crashed: false).isCrashOnly)
    #expect(!KeepAlive(mode: .conditional, successfulExit: false, crashed: true).isCrashOnly)
    #expect(
      !KeepAlive(
        mode: .conditional, crashed: true,
        pathStates: [PathStateCondition(path: "/tmp/flag", keepAliveWhenExists: true)]
      ).isCrashOnly
    )
    #expect(
      !KeepAlive(mode: .conditional, crashed: true, otherKeys: ["AfterInitialDemand": .bool(true)]).isCrashOnly
    )
    #expect(!KeepAlive(mode: .always, crashed: true).isCrashOnly)
  }

  @Test func afterCrashWritesOnlyCrashed() {
    var job = LaunchJob(context: .daemon, label: "com.example.crash")
    job.keepAlive = KeepAlive(mode: .conditional, crashed: true)
    #expect(job.plistDictionary["KeepAlive"] == .dictionary(["Crashed": .bool(true)]))
  }

  @Test func crashedOnlyImportRoundTrips() {
    let keepAlive: PlistValue = .dictionary(["Crashed": .bool(true)])
    let job = LaunchJob(dictionary: ["Label": .string("a.b"), "KeepAlive": keepAlive], context: .daemon)
    #expect(job.keepAlive.mode == .conditional)
    #expect(job.keepAlive.crashed == true)
    #expect(job.plistDictionary["KeepAlive"] == keepAlive)
  }
}

struct PlistXMLTests {
  @Test func renderedXMLMatchesRenderedData() throws {
    var job = LaunchJob(context: .globalAgent, label: "com.example.copy")
    job.program = "/usr/local/bin/tool"
    let xml = try job.renderedPlistXML()
    #expect(xml.hasPrefix("<?xml"))
    #expect(xml.contains("<string>com.example.copy</string>"))
    #expect(Data(xml.utf8) == (try job.renderedPlist()))
  }
}

struct OptionValueTests {
  // Display titles changed for clarity; the values written to the plist must not.
  @Test func sessionTypesWriteLaunchdValues() {
    #expect(SessionType.allCases.map(\.rawValue) == ["Aqua", "Background", "LoginWindow", "StandardIO"])
    #expect(SessionType.allCases.allSatisfy { $0.title.hasPrefix($0.rawValue) })
  }

  @Test func processTypesWriteLaunchdValues() {
    #expect(ProcessTypeOption.allCases.map(\.rawValue) == ["Background", "Standard", "Adaptive", "Interactive"])
  }
}

struct ProgramPathTests {
  @Test func pathsOnlyOnThisMacNeedAPayload() {
    #expect(PayloadFile.isLocalOnly("/Users/admin/Scripts/backup.sh"))
    #expect(PayloadFile.isLocalOnly("/Volumes/USB/tool"))
    #expect(PayloadFile.isLocalOnly("/private/var/folders/xy/T/tool"))
    #expect(!PayloadFile.isLocalOnly("/usr/bin/python3"))
    #expect(!PayloadFile.isLocalOnly("/usr/local/bin/tool"))
    #expect(!PayloadFile.isLocalOnly("/Library/Application Support/Example/run"))
  }
}

struct ProfileSigningTests {
  /// Stands in for the keychain signer: wraps the profile so the test can see what was signed.
  private struct WrappingSigner: ProfileSigner {
    func signedProfile(_ profile: Data) throws -> Data { Data("SIGNED:".utf8) + profile }
  }

  private func project() -> Project {
    var project = Project()
    project.jobs = [LaunchJob(context: .globalAgent, label: "com.example.agent")]
    return project
  }

  private func profile(in tree: FileTree) -> Data? {
    tree.files.first { $0.path.hasSuffix(".mobileconfig") }?.contents
  }

  @Test func exportSignsTheProfileWhenASignerIsGiven() throws {
    let project = project()
    let unsigned = try #require(profile(in: try ProjectExporter.export(project)))
    let signed = try #require(profile(in: try ProjectExporter.export(project, profileSigner: WrappingSigner())))
    #expect(signed == Data("SIGNED:".utf8) + unsigned)
  }

  @Test func oldProjectsLoadWithAnUnsignedProfile() throws {
    let settings = try JSONDecoder().decode(ProjectSettings.self, from: Data("{}".utf8))
    #expect(settings.profileSigningIdentity.isEmpty)
    var changed = ProjectSettings()
    changed.profileSigningIdentity = "Developer ID Application: Example (ABCDE12345)"
    let decoded = try JSONDecoder().decode(ProjectSettings.self, from: JSONEncoder().encode(changed))
    #expect(decoded.profileSigningIdentity == changed.profileSigningIdentity)
  }
}

struct SplitByJobTests {
  @Test func eachJobKeepsItsOwnPayloadAndSettings() throws {
    var project = Project()
    project.settings.name = "Tools"
    project.settings.packageIdentifier = "com.example.pkg.tools"
    project.settings.version = "3.0"
    var backup = LaunchJob(context: .daemon, label: "com.example.backup")
    backup.program = "/usr/local/libexec/backup.sh"
    var notify = LaunchJob(context: .globalAgent, label: "com.example.notify")
    notify.arguments = [TextItem(value: "/usr/local/libexec/notify")]
    project.jobs = [backup, notify]
    let files = ["backup.sh", "notify", "shared.conf"].map {
      PayloadFile(name: $0, destination: "/usr/local/libexec", mode: 0o755, contents: Data())
    }
    project.payload = files

    let parts = project.splitByJob()
    try #require(parts.count == 2)
    #expect(parts[0].jobs.map(\.label) == ["com.example.backup"])
    #expect(parts[0].payload.map(\.name) == ["backup.sh", "shared.conf"])
    #expect(parts[1].payload.map(\.name) == ["notify"])
    // Name and identifier follow each job's label; other settings carry over.
    #expect(parts.allSatisfy { $0.settings.name.isEmpty && $0.settings.packageIdentifier.isEmpty })
    #expect(parts.allSatisfy { $0.settings.version == "3.0" })
    #expect(parts[0].settings.profileUUID != parts[1].settings.profileUUID)
  }

  @Test func singleJobProjectIsUnchanged() {
    var project = Project()
    project.settings.name = "Tools"
    project.jobs = [LaunchJob(context: .daemon, label: "com.example.backup")]
    #expect(project.splitByJob() == [project])
  }
}

struct SigningPreferencesTests {
  private let installer = "Developer ID Installer: Example (ABCDE12345)"

  private func project(output: PackageOutput) -> Project {
    var project = Project()
    project.settings.packageIdentifier = "com.example.pkg.backup"
    project.settings.packageOutput = output
    project.jobs = [LaunchJob(context: .daemon, label: "com.example.backup")]
    return project
  }

  @Test func settingsDecideSigningForEveryExport() {
    var signing = SigningPreferences()
    signing.signsPackage = true
    signing.packageIdentity = installer
    signing.notarizeAfterExport = true
    signing.signsProfile = true
    signing.profileIdentity = "Developer ID Application: Example (ABCDE12345)"

    let applied = signing.applied(to: project(output: .installerPackage)).settings
    #expect(applied.signingIdentity == installer)
    #expect(applied.notarizeAfterExport)
    #expect(applied.profileSigningIdentity == signing.profileIdentity)
    #expect(!applied.packageFileName.contains("unsigned"))
    let issues = Validator.validate(signing.applied(to: project(output: .installerPackage)))
    #expect(!issues.contains { $0.rule == "package.unsigned" })
  }

  @Test func switchingSigningOffKeepsTheIdentityButSignsNothing() {
    var signing = SigningPreferences()
    signing.packageIdentity = installer
    signing.notarizeAfterExport = true
    signing.profileIdentity = "Developer ID Application: Example (ABCDE12345)"
    let applied = signing.applied(to: project(output: .installerPackage)).settings
    #expect(applied.signingIdentity.isEmpty)
    #expect(!applied.notarizeAfterExport)
    #expect(applied.profileSigningIdentity.isEmpty)
    #expect(signing.packageIdentity == installer)
  }

  @Test func buildScriptSignsWithThePackageIdentity() {
    var signing = SigningPreferences()
    signing.signsPackage = true
    signing.packageIdentity = installer
    signing.notarizeAfterExport = true
    let applied = signing.applied(to: project(output: .buildScript))
    #expect(!applied.settings.notarizeAfterExport)  // Only finished packages are notarized by LaunchdOps.
    let script = PackageGenerator.buildScript(for: applied)
    #expect(script.contains("Example (ABCDE12345)"))
    #expect(script.contains("SIGN_IDENTITY"))
  }

  @Test func unsignedPreferencesNeverNotarize() {
    var signing = SigningPreferences()
    signing.signsPackage = true  // Switched on, but no identity chosen yet.
    signing.notarizeAfterExport = true
    let applied = signing.applied(to: project(output: .installerPackage)).settings
    #expect(applied.signingIdentity.isEmpty)
    #expect(!applied.notarizeAfterExport)
    #expect(applied.packageFileName.hasSuffix("-unsigned.pkg"))
  }

  /// A preferences domain of its own, so tests never touch the app's settings.
  private func scratchDefaults() throws -> UserDefaults {
    let name = "LaunchdOpsTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  @Test func eachChoiceIsItsOwnPreferenceKey() throws {
    let defaults = try scratchDefaults()
    var signing = SigningPreferences()
    signing.signsPackage = true
    signing.packageIdentity = installer
    signing.notarizeAfterExport = true
    signing.profileIdentity = "Apple Development: Example (1234567890)"
    signing.save(to: defaults)

    #expect(defaults.bool(forKey: "SignPackage"))
    #expect(defaults.string(forKey: "PackageSigningIdentity") == installer)
    #expect(defaults.bool(forKey: "NotarizeAfterExport"))
    #expect(!defaults.bool(forKey: "SignProfile"))
    #expect(defaults.string(forKey: "ProfileSigningIdentity") == signing.profileIdentity)
    #expect(SigningPreferences(defaults: defaults) == signing)
  }

  @Test func earlierSingleValueMovesToSeparateKeys() throws {
    let defaults = try scratchDefaults()
    defaults.set(#"{"buildScriptIdentity":"\#(installer)","notarizeAfterExport":true}"#, forKey: "SigningPreferences")
    SigningPreferences.migrateLegacyValue(in: defaults)

    let migrated = SigningPreferences(defaults: defaults)
    #expect(migrated.packageIdentity == installer)
    #expect(migrated.signsPackage)  // Saved before the switches existed: an identity meant signing was on.
    #expect(migrated.notarizeAfterExport)
    #expect(!migrated.signsProfile)
    #expect(defaults.object(forKey: "SigningPreferences") == nil)
  }

  @Test func projectChoicesMoveIntoSettings() {
    var settings = ProjectSettings()
    settings.packageOutput = .installerPackage
    settings.signingIdentity = installer
    settings.notarizeAfterExport = true
    let migrated = SigningPreferences(migrating: settings)
    #expect(migrated.packageIdentity == installer)
    #expect(migrated.signsPackage)
    #expect(migrated.notarizeAfterExport)
    #expect(SigningPreferences(migrating: ProjectSettings()).isEmpty)
  }
}

struct LabelPrefixTests {
  @Test func newJobsUseTheLabelPrefixFromSettings() {
    var project = Project()
    #expect(project.nextLabel(for: .daemon) == "com.example.daemon")
    #expect(project.nextLabel(for: .daemon, prefix: "com.acme") == "com.acme.daemon")
    #expect(project.nextLabel(for: .globalAgent, prefix: " com.acme. ") == "com.acme.agent")
    project.jobs = [LaunchJob(context: .daemon, label: "com.acme.daemon")]
    #expect(project.nextLabel(for: .daemon, prefix: "com.acme") == "com.acme.daemon2")
  }

  @Test func prefixIsCleanedForTheNewJobSheet() {
    #expect(Project.labelPrefix(from: " com.karthikmac. ") == "com.karthikmac")
    #expect(Project.labelPrefix(from: "") == nil)
    #expect(Project.labelPrefix(from: "not valid!") == nil)
  }

  @Test func invalidPrefixIsIgnored() {
    #expect(Project().nextLabel(for: .daemon, prefix: "not valid!") == "com.example.daemon")
  }
}
