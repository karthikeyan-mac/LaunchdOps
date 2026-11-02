import Foundation

enum DeploymentMode: String, Codable, CaseIterable, Identifiable, Sendable {
  case package
  case declarative

  var id: String { rawValue }

  var title: String {
    switch self {
    case .package: "Installer Package"
    case .declarative: "DDM Background Task"
    }
  }
}

enum PackageOutput: String, Codable, CaseIterable, Identifiable, Sendable {
  /// A finished .pkg written by LaunchdOps, signed when a signing identity is set.
  case installerPackage
  /// The package project and build-pkg.sh, built with Apple's tools on the admin's Mac.
  case buildScript

  var id: String { rawValue }
}

struct ProjectSettings: Codable, Hashable, Sendable {
  /// Empty means "follow the primary job's label" (see `Project.resolvedSettings`).
  var name = ""
  var organization = ""
  /// Empty means "follow the primary job's label" (see `Project.resolvedSettings`).
  var packageIdentifier = ""
  var version = "1.0"
  var mode = DeploymentMode.package
  var taskType = ""
  var taskDescription = ""
  var signingIdentity = ""
  /// Keychain identity that signs the Managed Login Items profile; empty leaves it unsigned.
  var profileSigningIdentity = ""
  var includePackage = true
  var packageOutput = PackageOutput.installerPackage
  var notarizeAfterExport = false
  var includeLoginItemsProfile = true
  var includeScripts = true
  var includeGuide = true
  /// Options ▸ Logging ▸ Rotate Logs: the package installs a newsyslog rule for the daemon's log files.
  var rotateLogs = false
  var retiredLabels: [String] = []
  /// Labels that have left LaunchdOps in an export or came in through a plist import. Renaming one of these
  /// adds the old label to `retiredLabels`, because Macs may still have it installed.
  var publishedLabels: [String] = []
  var profileUUID = UUID()
  var profilePayloadUUID = UUID()

  init() {}

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = ProjectSettings()
    // The old fixed defaults become "follow the job label".
    let savedName = try container.decodeIfPresent(String.self, forKey: .name) ?? defaults.name
    name = savedName == "Untitled" ? "" : savedName
    organization = try container.decodeIfPresent(String.self, forKey: .organization) ?? defaults.organization
    let savedIdentifier =
      try container.decodeIfPresent(String.self, forKey: .packageIdentifier)
      ?? defaults.packageIdentifier
    packageIdentifier = savedIdentifier == "com.example.pkg.untitled" ? "" : savedIdentifier
    version = try container.decodeIfPresent(String.self, forKey: .version) ?? defaults.version
    mode = try container.decodeIfPresent(DeploymentMode.self, forKey: .mode) ?? defaults.mode
    taskType = try container.decodeIfPresent(String.self, forKey: .taskType) ?? defaults.taskType
    taskDescription = try container.decodeIfPresent(String.self, forKey: .taskDescription) ?? defaults.taskDescription
    signingIdentity = try container.decodeIfPresent(String.self, forKey: .signingIdentity) ?? ""
    profileSigningIdentity = try container.decodeIfPresent(String.self, forKey: .profileSigningIdentity) ?? ""
    includePackage = try container.decodeIfPresent(Bool.self, forKey: .includePackage) ?? true
    // Projects saved before this setting existed keep the build script they were exported with.
    packageOutput = try container.decodeIfPresent(PackageOutput.self, forKey: .packageOutput) ?? .buildScript
    notarizeAfterExport = try container.decodeIfPresent(Bool.self, forKey: .notarizeAfterExport) ?? false
    includeLoginItemsProfile =
      try container.decodeIfPresent(Bool.self, forKey: .includeLoginItemsProfile)
      ?? defaults.includeLoginItemsProfile
    includeScripts = try container.decodeIfPresent(Bool.self, forKey: .includeScripts) ?? true
    includeGuide = try container.decodeIfPresent(Bool.self, forKey: .includeGuide) ?? true
    rotateLogs = try container.decodeIfPresent(Bool.self, forKey: .rotateLogs) ?? false
    retiredLabels = try container.decodeIfPresent([String].self, forKey: .retiredLabels) ?? []
    publishedLabels = try container.decodeIfPresent([String].self, forKey: .publishedLabels) ?? []
    profileUUID = try container.decodeIfPresent(UUID.self, forKey: .profileUUID) ?? defaults.profileUUID
    profilePayloadUUID =
      try container.decodeIfPresent(UUID.self, forKey: .profilePayloadUUID)
      ?? defaults.profilePayloadUUID
  }

  var packageFileName: String {
    "\(safeName)-\(version)\(signingIdentity.isEmpty ? "-unsigned" : "").pkg"
  }

  var safeName: String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
    let cleaned = name.unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }.joined()
    // No leading dots: ".." or a hidden name must not become a folder or file name.
    let trimmed = String(cleaned.drop { $0 == "." })
    return trimmed.isEmpty ? "LaunchdOps" : trimmed
  }
}

struct PayloadFile: Identifiable, Hashable, Sendable {
  static let maximumSize = 50 * 1024 * 1024

  var id = UUID()
  var name: String
  var destination: String
  var mode: Int
  var contents: Data

  var isExecutable: Bool { mode & 0o111 != 0 }

  /// A path in a user's folder or on another volume exists only on this Mac, so a job on fleet Macs can't run it
  /// unless it is installed as a payload file.
  static func isLocalOnly(_ path: String) -> Bool {
    let prefixes = [
      "/Users/", "/Volumes/", "/private/var/folders/", "/var/folders/", "/private/tmp/", "/tmp/", "/private/var/tmp/",
      "/var/tmp/",
    ]
    return prefixes.contains { path.hasPrefix($0) }
  }

  var modeString: String { String(mode, radix: 8) }
}

struct Project: Hashable, Sendable {
  static let servicesRoot = "/private/var/db/ManagedConfigurationFiles/BackgroundTaskServices/Services"
  static let defaultPayloadDestination = "/usr/local/libexec"

  var settings = ProjectSettings()
  var jobs: [LaunchJob] = []
  var payload: [PayloadFile] = []

  /// Label of the job the project is named after: the first daemon, otherwise the first job.
  var primaryLabel: String? {
    (daemons + jobs).first { !$0.label.isEmpty }?.label
  }

  /// Settings with an empty project name or package identifier filled in from the primary job's label.
  /// Generators and validation use these; the document keeps the empty values so they keep following the label.
  var resolvedSettings: ProjectSettings {
    var resolved = settings
    // One line only: the name appears in script comments and plist or profile strings.
    let name = settings.name.components(separatedBy: .newlines).joined(separator: " ")
      .trimmingCharacters(in: .whitespaces)
    resolved.name = name.isEmpty ? primaryLabel ?? "Untitled" : name
    let identifier = settings.packageIdentifier.trimmingCharacters(in: .whitespaces)
    resolved.packageIdentifier = identifier.isEmpty ? primaryLabel ?? "" : identifier
    return resolved
  }

  /// Records labels that are now out in the world (exported or imported).
  mutating func markPublished(_ labels: [String]) {
    for label in labels where !label.isEmpty && !settings.publishedLabels.contains(label) {
      settings.publishedLabels.append(label)
    }
  }

  /// Called when the user finishes renaming a job. A published old label becomes a retired label so the next
  /// package removes it; renaming back to a retired label takes it off the list.
  mutating func noteLabelChange(from old: String, to new: String) {
    guard old != new else { return }
    settings.retiredLabels.removeAll { $0 == new }
    guard settings.publishedLabels.contains(old), Validator.isValidLabel(old),
      !jobs.contains(where: { $0.label == old }), !settings.retiredLabels.contains(old)
    else { return }
    settings.retiredLabels.append(old)
  }

  func resolved() -> Project {
    var project = self
    project.settings = resolvedSettings
    return project
  }

  /// Where the package puts User Launch Agents; postinstall copies them into each user's ~/Library/LaunchAgents.
  static let userAgentStagingFolder = "/Library/Application Support/LaunchdOps/UserAgents"

  /// Jobs the package installs in place and postinstall loads: daemons and agents for all users.
  var packagedJobs: [LaunchJob] {
    jobs.filter { $0.context != .userAgent }
  }

  /// User Launch Agents, which the package stages and postinstall copies into each local user's home folder.
  var userAgentJobs: [LaunchJob] {
    jobs.filter { $0.context == .userAgent }
  }

  static func stagedPath(for job: LaunchJob) -> String {
    "\(userAgentStagingFolder)/\(job.fileName)"
  }

  /// Every plist in the package, with the absolute path it installs to.
  var packagedPlists: [(job: LaunchJob, path: String)] {
    packagedJobs.map { ($0, $0.installPath) } + userAgentJobs.map { ($0, Self.stagedPath(for: $0)) }
  }

  func installPath(for file: PayloadFile) -> String {
    switch settings.mode {
    case .package:
      let directory = file.destination.hasSuffix("/") ? String(file.destination.dropLast()) : file.destination
      return "\(directory)/\(file.name)"
    case .declarative:
      let subfolder = file.destination.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      let base = "\(Self.servicesRoot)/\(settings.taskType)"
      return subfolder.isEmpty ? "\(base)/\(file.name)" : "\(base)/\(subfolder)/\(file.name)"
    }
  }

  var agents: [LaunchJob] {
    jobs.filter(\.context.isAgent)
  }

  var daemons: [LaunchJob] {
    jobs.filter { $0.context == .daemon }
  }

  /// One project per job, because each item in LaunchdOps is a single launchd job with its own export settings.
  /// A payload file goes with the job whose Program or arguments use its install path; files no job uses go with
  /// the first job. Every project after the first gets new profile identifiers, and a Project Name or package
  /// identifier set for the whole project is cleared so each one follows its own label.
  func splitByJob() -> [Project] {
    guard jobs.count > 1 else { return [self] }
    let usedPaths = jobs.map { job in Set([job.program] + job.argumentValues) }
    return jobs.enumerated().map { index, job in
      var single = self
      single.jobs = [job]
      single.payload = payload.filter { file in
        let path = installPath(for: file)
        if usedPaths[index].contains(path) { return true }
        return index == 0 && !usedPaths.contains { $0.contains(path) }
      }
      single.settings.name = ""
      single.settings.packageIdentifier = ""
      if single.settings.mode == .declarative {
        single.settings.taskType = job.label
      }
      if index > 0 {
        single.settings.profileUUID = UUID()
        single.settings.profilePayloadUUID = UUID()
      }
      return single
    }
  }

  func job(withID id: LaunchJob.ID) -> LaunchJob? {
    jobs.first { $0.id == id }
  }

  /// Settings ▸ General ▸ Label Prefix without surrounding dots or spaces, or nil when it is empty or invalid.
  static func labelPrefix(from setting: String) -> String? {
    let prefix = setting.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines))
    return Validator.isValidLabel(prefix) ? prefix : nil
  }

  /// A label no job in this project uses. `prefix` (Settings ▸ General ▸ Label Prefix) wins; otherwise the
  /// first two parts of the package identifier, else `com.example`.
  func nextLabel(for context: JobContext, prefix preferred: String = "") -> String {
    let prefix =
      Self.labelPrefix(from: preferred)
      ?? resolvedSettings.packageIdentifier.split(separator: ".").prefix(2).joined(separator: ".")
    let base = "\(prefix.isEmpty ? "com.example" : prefix).\(context == .daemon ? "daemon" : "agent")"
    var candidate = base
    var index = 2
    while jobs.contains(where: { $0.label == candidate }) {
      candidate = "\(base)\(index)"
      index += 1
    }
    return candidate
  }
}
