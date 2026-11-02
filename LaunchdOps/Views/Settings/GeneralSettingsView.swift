import SwiftUI

/// LaunchdOps ▸ Settings ▸ General.
struct GeneralSettingsView: View {
  /// Key in the app's preferences plist.
  static let labelPrefixKey = "LabelPrefix"

  static let logFolderKey = "LogFolder"

  @AppStorage(Self.labelPrefixKey) private var labelPrefix = ""
  @AppStorage(Self.logFolderKey) private var logFolder = ""

  private var trimmed: String {
    labelPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    Form {
      Section {
        TextField(text: $labelPrefix, prompt: Text("com.example")) {
          InfoLabel(
            "Label Prefix",
            info: "Your organization’s reverse-DNS prefix. New Job starts the label with it, for example com.example."
          )
        }
        .monospaced()
        if !trimmed.isEmpty && !Validator.isValidLabel(trimmed) {
          Label {
            Text("Use letters, numbers, dots, hyphens and underscores, for example com.example.")
          } icon: {
            SeverityIcon(severity: .warning)
          }
        }
        TextField(text: $logFolder, prompt: Text("/Library/Logs/Example")) {
          InfoLabel(
            "Log Folder",
            info: "New daemons write output to <folder>/<label>.log and errors to <label>.error.log."
          )
        }
        .monospaced()
        if !logFolder.trimmingCharacters(in: .whitespaces).isEmpty && LaunchJob.logFolder(from: logFolder) == nil {
          Label {
            Text("Use an absolute folder that only root can change, such as /Library/Logs/Example.")
          } icon: {
            SeverityIcon(severity: .warning)
          }
        }
      } header: {
        Text("New Jobs")
      } footer: {
        Text(
          """
          Leave Label Prefix empty to use com.example. Log Folder applies to new daemons only; agents run as the \
          user and can’t write there. You can change both for each job.
          """
        )
      }
    }
    .formStyle(.grouped)
    .frame(width: 520)
    .fixedSize(horizontal: false, vertical: true)
  }
}
