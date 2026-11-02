import Foundation
import Testing

@testable import LaunchdOps

/// A User Launch Agent can't be installed at a fixed path, so the package stages it and postinstall copies it into
/// each user's ~/Library/LaunchAgents.
struct UserAgentPackageTests {
  private func project(disabled: Bool = false) -> Project {
    var job = LaunchJob(context: .userAgent, label: "com.acme.sync")
    job.program = "/usr/local/bin/sync"
    job.runAtLoad = true
    job.disabled = disabled
    var project = Project()
    project.jobs = [job]
    project.settings.packageOutput = .installerPackage
    return project.resolved()
  }

  private let staged = "/Library/Application Support/LaunchdOps/UserAgents/com.acme.sync.plist"

  @Test func packageStagesTheAgent() throws {
    let input = try FlatPackageBuilder.input(for: project())
    #expect(input.files.map(\.path) == [staged])
    #expect(input.files.first?.permissions == 0o644)
  }

  @Test func postinstallCopiesForTheLoggedInUserAndLoadsIt() {
    let postinstall = ScriptGenerator.postinstall(for: project())
    #expect(postinstall.contains("install_user_agent 'com.acme.sync' '\(staged)' 'com.acme.sync.plist' load"))
    #expect(postinstall.contains("user=$(/usr/bin/stat -f %Su /dev/console)"))
    #expect(!postinstall.contains("local_users"))
    // Root never writes into the user's folder.
    #expect(postinstall.contains(#"/usr/bin/sudo -u "$user" /bin/cp -f "$staged" "$plist""#))
    #expect(postinstall.contains(#"/bin/launchctl bootstrap "gui/$uid" "$plist""#))
    #expect(ScriptGenerator.postinstall(for: project(disabled: true)).contains("'com.acme.sync.plist' no-load"))
  }

  @Test func preinstallStopsAndUninstallRemovesEachCopy() {
    let uninstall = ScriptGenerator.uninstall(for: project())
    #expect(ScriptGenerator.preinstall(for: project()).contains("unload_job 'com.acme.sync'"))
    #expect(uninstall.contains("unload_job 'com.acme.sync'"))
    #expect(uninstall.contains("/bin/rm -f '\(staged)'"))
    #expect(uninstall.contains("remove_user_agent 'com.acme.sync.plist'"))
  }

  @Test func projectsWithoutUserAgentsDontGetTheFunctions() {
    var daemon = project()
    daemon.jobs[0].context = .daemon
    #expect(!ScriptGenerator.postinstall(for: daemon).contains("install_user_agent"))
    #expect(!ScriptGenerator.uninstall(for: daemon).contains("remove_user_agent"))
  }

}
