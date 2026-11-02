import Foundation

/// A newsyslog rule (`newsyslog.conf(5)`) that rotates a daemon's StandardOutPath and StandardErrorPath, installed
/// by the package when Options ▸ Logging ▸ Rotate Logs is on.
///
/// launchd opens the log files when it starts the job, so only jobs that start and exit are rotated: a job that
/// keeps running (KeepAlive) would go on writing to the rotated file, and after compression to a deleted one.
/// The `N` flag stops newsyslog sending SIGHUP to syslogd, which it does when a rule names no PID file.
enum LogRotation {
  static let directory = "/private/etc/newsyslog.d"
  static let keptFiles = 5
  static let rotateAtKilobytes = 10_240

  /// Log files the rule covers: absolute daemon log paths, each once. newsyslog splits fields on whitespace and
  /// treats `#` as a comment, so paths containing either are left out (the validator reports them).
  static func logPaths(for project: Project) -> [String] {
    guard project.settings.mode == .package, project.settings.rotateLogs else { return [] }
    var seen = Set<String>()
    return project.packagedJobs
      .filter(canRotateLogs)
      .flatMap { [$0.standardOutPath, $0.standardErrorPath] }
      .filter { isRotatable($0) && seen.insert($0).inserted }
  }

  /// Daemons whose log files launchd reopens on each run.
  static func canRotateLogs(_ job: LaunchJob) -> Bool {
    job.context == .daemon && job.keepAlive.mode == .off
  }

  static func isRotatable(_ path: String) -> Bool {
    path.hasPrefix("/") && !path.contains(where: { $0.isWhitespace || $0 == "#" })
  }

  /// Where a package with this identifier installs its rule, whether or not this version rotates logs. Scripts
  /// always remove it, so a rule from an earlier version doesn't keep rotating a log a running job holds open.
  static func configPath(for project: Project) -> String? {
    guard project.settings.mode == .package else { return nil }
    return "\(directory)/\(project.settings.packageIdentifier).conf"
  }

  /// The installed rule, named after the package identifier, or nil when there is nothing to rotate.
  static func configFile(for project: Project) -> (path: String, contents: String)? {
    let paths = logPaths(for: project)
    guard !paths.isEmpty else { return nil }
    let rules = paths.map { "\($0)\troot:wheel\t644\t\(keptFiles)\t\(rotateAtKilobytes)\t*\tNZ" }
    let contents = """
      # \(GeneratorInfo.banner) for \(project.settings.name).
      # Keeps \(keptFiles) gzip-compressed copies and starts a new file at \(rotateAtKilobytes / 1024) MB.
      # logfilename\t[owner:group]\tmode\tcount\tsize(KB)\twhen\tflags
      \(rules.joined(separator: "\n"))

      """
    guard let path = configPath(for: project) else { return nil }
    return (path, contents)
  }

  /// Folders of daemon log files, which launchd does not create.
  static func logFolders(for project: Project) -> [String] {
    guard project.settings.mode == .package else { return [] }
    var seen = Set<String>()
    return project.packagedJobs
      .filter { $0.context == .daemon }
      .flatMap { [$0.standardOutPath, $0.standardErrorPath] }
      .filter { $0.hasPrefix("/") }
      .map { ($0 as NSString).deletingLastPathComponent }
      .filter { !$0.isEmpty && $0 != "/" && seen.insert($0).inserted }
  }
}
