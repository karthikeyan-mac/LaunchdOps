import SwiftUI

/// Read-only plist XML for the selected job: a popover from the toolbar, or a sheet from Project ▸ Show Plist XML.
struct PlistPopover: View {
  let job: LaunchJob
  let onCopy: () -> Void

  private var renderedXML: Result<String, Error> {
    Result { try job.renderedPlistXML() }
  }

  var body: some View {
    Form {
      Section {
        switch renderedXML {
        case .success(let xml):
          ScrollView {
            Text(xml)
              .font(.caption.monospaced())
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          // A scroll view has no natural height inside a fixed-size form; this matches the Help sheet.
          .frame(minHeight: 200, idealHeight: 420)
          .accessibilityLabel("Plist XML")
          HStack {
            Spacer()
            Button("Copy Plist XML", systemImage: "doc.on.doc") { onCopy() }
          }
        case .failure(let error):
          Label {
            Text(
              "The plist can’t be shown. \(error.localizedDescription) Check Additional Keys for values a plist can’t store."
            )
          } icon: {
            SeverityIcon(severity: .error)
          }
        }
      } header: {
        Text(job.fileName)
          .monospaced()
      } footer: {
        Text("Installs to \(job.context.installDirectory). Read-only; edit the job on General and Options.")
      }
    }
    .formStyle(.grouped)
    .frame(width: 520)
    .fixedSize(horizontal: false, vertical: true)
  }
}

/// The same view as a sheet, for Project ▸ Show Plist XML.
struct PlistSheet: View {
  let job: LaunchJob
  let onCopy: () -> Void

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      PlistPopover(job: job, onCopy: onCopy)
      HStack {
        Spacer()
        Button("Done") { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
      .padding(24)
    }
    .onExitCommand { dismiss() }
  }
}
