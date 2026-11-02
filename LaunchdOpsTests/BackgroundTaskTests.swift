import Foundation
import Testing

@testable import LaunchdOps

/// DDM background task guidance from SupportCompanion's deployment notes (SupportCompanion wiki, "Deploying the helper").
struct BackgroundTaskTests {
  private func ddmProject(keepAlive: KeepAliveMode) -> Project {
    var job = LaunchJob(context: .daemon, label: "com.acme.helper")
    job.program = "\(Project.servicesRoot)/com.acme.helper/helper"
    job.runAtLoad = true
    job.keepAlive.mode = keepAlive
    var project = Project()
    project.jobs = [job]
    project.settings.mode = .declarative
    project.settings.taskType = "com.acme.helper"
    return project.resolved()
  }

  @Test func keepAliveInABackgroundTaskIsFlagged() {
    #expect(Validator.validate(ddmProject(keepAlive: .always)).contains { $0.rule == "ddm.keepalive" })
    #expect(!Validator.validate(ddmProject(keepAlive: .off)).contains { $0.rule == "ddm.keepalive" })
    var package = ddmProject(keepAlive: .always)
    package.settings.mode = .package
    #expect(!Validator.validate(package).contains { $0.rule == "ddm.keepalive" })
  }

  @Test func readmeExplainsProtectionKeepAliveAndUpdates() {
    let readme = GuideGenerator.readme(for: ddmProject(keepAlive: .off), profileName: nil)
    #expect(readme.contains("can't be unloaded or disabled"))
    #expect(readme.contains("Run at Load rather than Keep Alive"))
    #expect(readme.contains("`ServerToken` comes from the files' hashes"))
  }

  @Test func readmeWalksThroughRequirementsAndSteps() {
    let readme = GuideGenerator.readme(for: ddmProject(keepAlive: .off), profileName: nil)
    for heading in [
      "### What you need", "### Why use it", "### What's in this folder", "### Step 1: Host the assets",
      "### Step 2: Give it to your MDM", "### Step 3: Check a Mac", "### Updating", "### Removing",
    ] {
      #expect(readme.contains(heading), "README should contain \(heading)")
    }
    #expect(readme.contains("An MDM server that can send declarations"))
    #expect(readme.contains("Supervised Macs"))
  }

  @Test func serverTokenChangesWhenTheFilesChange() throws {
    var project = ddmProject(keepAlive: .off)
    let before = try DeclarativeGenerator.generate(for: project).declarations
    project.jobs[0].startInterval = 600
    let after = try DeclarativeGenerator.generate(for: project).declarations
    let token = { (declarations: [(name: String, data: Data)]) -> String? in
      guard let configuration = declarations.first(where: { $0.name == "configuration.json" }),
        let object = try? JSONSerialization.jsonObject(with: configuration.data) as? [String: Any]
      else { return nil }
      return object["ServerToken"] as? String
    }
    #expect(token(before) != nil)
    #expect(token(before) != token(after))
  }
}
