import SwiftUI

struct HelpSheet: View {
  @Environment(\.dismiss) private var dismiss

  private struct Topic: Identifiable {
    let id: Int
    let title: LocalizedStringResource
    let body: LocalizedStringResource
  }

  private let topics: [Topic] = [
    Topic(
      id: 1,
      title: "Build a Job",
      body: """
        Add a launch daemon, launch agent or user launch agent with the Add button or Project ▸ New Job…. \
        General sets what runs; Options sets when it runs. The status button in the toolbar lists every \
        validation issue.
        """
    ),
    Topic(
      id: 2,
      title: "Export",
      body: """
        Choose Project ▸ Export Deployment Folder… to save the plists, scripts, profile and deployment guide. \
        LaunchdOps only writes files; it never loads jobs on this Mac. Open README.md in the exported folder \
        for step-by-step deployment instructions.
        """
    ),
    Topic(
      id: 3,
      title: "Install and Test",
      body: """
        In package mode, LaunchdOps writes the installer package into the export folder, signed if you choose \
        a signing identity. With Build Script output, run ./build-pkg.sh in the package folder instead. \
        Install the package on a test Mac, then run sudo ./check.sh --details to check files and launchd \
        state, or sudo ./check.sh --details --run to also start each job. With no options, check.sh prints one \
        status line for your MDM's inventory.
        """
    ),
    Topic(
      id: 8,
      title: "Deploy with DDM",
      body: """
        A DDM background task installs a job the Mac protects: not even root can change its files, and it \
        can’t be unloaded or disabled. You need an MDM that can send declarations (for example Jamf Pro \
        Blueprints; for a test lab, NanoMDM with KMFDDM), supervised Macs enrolled through Apple Business \
        Manager or Apple School Manager, and macOS 15 or later. It can’t be installed by hand.

        1. Create a Launch Daemon. On General, choose Payload ▸ Add Files…, add the program, open it and \
        choose Use as Program, so the task delivers and protects it.
        2. On Options, turn on Run at Load and add any schedule. Leave Keep Alive off: the Mac restarts the \
        task itself when its configuration changes.
        3. On Export, choose Deploy As ▸ DDM Background Task and click Use Daemon Label for the Task Type.
        4. Export the folder. Upload the files in ddm/assets to an HTTPS location Macs can reach without \
        signing in, and check each file’s Content-Type (application/zip and application/xml).
        5. Give the values to your MDM: fill in its background-task fields from the README’s table, or put \
        your URLs in the files in ddm/declarations and upload those.
        6. On a Mac, check System Settings ▸ General ▸ Device Management ▸ the enrollment profile ▸ \
        Device Declarations.

        To update, export again, re-host the changed files and send the new declarations. If your Macs aren’t \
        supervised, or you only need the job deployed, use an installer package instead.
        """
    ),
    Topic(
      id: 7,
      title: "Notarize",
      body: """
        In LaunchdOps ▸ Settings (⌘,) ▸ Signing, turn on Sign the Package, choose an identity and turn on Notarize After Export, then \
        set up the Notarization Key (an App Store Connect API key). LaunchdOps sends the signed package to Apple \
        after saving and shows the result. Leave Notarize After Export off to use notarytool instead. \
        LaunchdOps staples Apple’s ticket to packages it notarizes, so Macs install them without a warning \
        even when offline. While it runs, click Notarizing in the toolbar to see each step or cancel.
        """
    ),
    Topic(
      id: 4,
      title: "Remove",
      body: """
        In package mode, run sudo scripts/uninstall.sh on the Mac. It stops each job with launchctl bootout \
        and deletes only the files this project installed. In declarative mode there is no uninstall script: \
        remove the background task declarations from your MDM.
        """
    ),
    Topic(
      id: 5,
      title: "Troubleshoot",
      body: """
        Run sudo ./check.sh --collect on the affected Mac. It collects launchctl print and blame output, file \
        permissions and recent launchd log messages into a folder in /private/tmp that you can attach to a \
        support request.
        """
    ),
    Topic(
      id: 6,
      title: "User Launch Agents",
      body: """
        User launch agents are exported as plists only. The installer package and DDM background tasks \
        include daemons and agents for all users.
        """
    ),
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("LaunchdOps Help")
        .font(.headline)
        .accessibilityAddTraits(.isHeader)

      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          ForEach(topics) { topic in
            VStack(alignment: .leading, spacing: 4) {
              Text(topic.title)
                .fontWeight(.semibold)
                .accessibilityAddTraits(.isHeader)
              Text(topic.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      // A scroll view has no natural height; this keeps the sheet usable at the 900 × 560 minimum window.
      .frame(minHeight: 320, idealHeight: 420)

      HStack {
        Spacer()
        Button("Done") { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(width: 520)
    .onExitCommand { dismiss() }
  }
}
