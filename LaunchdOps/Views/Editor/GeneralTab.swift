import SwiftUI

struct GeneralTab: View {
  @Binding var job: LaunchJob
  @Binding var project: Project
  let issues: [ValidationIssue]
  let onAddFiles: () -> Void
  let onChooseProgram: () -> Void
  /// Called when a label edit ends, with the label before and after. It is bound to this job's own project,
  /// because editing can end after another job is selected (for example from `onDisappear`).
  let onLabelEditEnded: (_ old: String, _ new: String) -> Void

  @FocusState private var isLabelFocused: Bool
  // The label when editing began, to compare once editing ends (not on every keystroke).
  @State private var labelBeforeEditing: String?

  var body: some View {
    Form {
      JobIssuesSection(issues: issues)
      identitySection
      programSection
      if job.context == .daemon {
        runAsSection
      }
    }
    .formStyle(.grouped)
    .onDisappear { finishLabelEdit() }
  }

  private func finishLabelEdit() {
    guard let old = labelBeforeEditing else { return }
    onLabelEditEnded(old, job.label)
    labelBeforeEditing = isLabelFocused ? job.label : nil
  }

  private var identitySection: some View {
    Section {
      TextField(text: $job.label, prompt: Text("com.example.backup")) {
        InfoLabel("Label", info: "Unique reverse-DNS name for the job. It is also the plist file name.", key: "Label")
      }
      .monospaced()
      .focused($isLabelFocused)
      .onSubmit { finishLabelEdit() }
      .onChange(of: isLabelFocused) { _, focused in
        if focused {
          labelBeforeEditing = job.label
        } else {
          finishLabelEdit()
        }
      }
      Picker(selection: $job.context) {
        ForEach(JobContext.allCases) { context in
          Label(context.title, systemImage: context.systemImage).tag(context)
        }
      } label: {
        InfoLabel(
          "Type",
          info: """
            Daemons run at startup, as root by default. Launch Agents run for every user who logs in; a User \
            Launch Agent runs only for its own user.
            """
        )
      }
      LabeledContent {
        Text(job.installPath)
          .monospaced()
          .textSelection(.enabled)
      } label: {
        InfoLabel("Installs To", info: "Where the plist is installed on each Mac.")
      }
      Toggle(isOn: $job.disabled) {
        InfoLabel(
          "Disabled",
          info: "Installs the job without loading it. launchctl enable can override this.",
          key: "Disabled"
        )
      }
    } header: {
      Text("Identity")
    } footer: {
      Text("The label uniquely identifies the job. Use reverse-DNS form; it is also the file name.")
    }
  }

  private var programSection: some View {
    Section {
      LabeledContent {
        HStack {
          TextField("Program", text: $job.program, prompt: Text("Optional when arguments are set"))
            .labelsHidden()
            .monospaced()
          Button("Choose…") { onChooseProgram() }
            .help("Choose the executable in a file dialog")
        }
      } label: {
        InfoLabel(
          "Program",
          info: "Absolute path to the executable. When empty, the first argument is used.",
          key: "Program"
        )
      }
      LabeledContent {
        ArgumentsEditor(arguments: $job.arguments, program: job.program)
      } label: {
        InfoLabel(
          "Arguments",
          info: """
            One per row, passed as-is without a shell. The first row is the program path; with Program set, it's \
            only the process name, so put options such as --silent on the second row and below.
            """,
          key: "ProgramArguments"
        )
      }
      TextField(text: $job.workingDirectory, prompt: Text("Optional")) {
        InfoLabel(
          "Working Directory",
          info: "Folder launchd changes to before starting the job.",
          key: "WorkingDirectory"
        )
      }
      .monospaced()
      LabeledContent {
        PayloadField(project: $project, job: $job, onAddFiles: onAddFiles)
      } label: {
        InfoLabel(
          "Payload",
          info: """
            The script or tool this job runs, installed with the job. Deploy apps and large software separately \
            and set Program to their installed path.
            """
        )
      }
    } header: {
      Text("Program")
    } footer: {
      Text(
        """
        launchd does not use a shell, so ~, $VARIABLES, pipes and wildcards are not expanded. The payload is for \
        the script or tool this job runs (installed with root ownership); deploy apps and large software \
        separately and reference their installed path.
        """
      )
    }
  }

  private var runAsSection: some View {
    Section {
      TextField(text: $job.userName, prompt: Text("root")) {
        InfoLabel("User Name", info: "User account the daemon runs as. Leave empty to run as root.", key: "UserName")
      }
      TextField(text: $job.groupName, prompt: Text("Primary group of the user")) {
        InfoLabel(
          "Group Name",
          info: "Group the daemon runs as. Leave empty to use the user’s primary group.",
          key: "GroupName"
        )
      }
      Picker(selection: $job.initGroups) {
        Text("Default (On)").tag(Bool?.none)
        Text("On").tag(Bool?.some(true))
        Text("Off").tag(Bool?.some(false))
      } label: {
        InfoLabel(
          "Initialize Groups",
          info: "Gives the daemon the user’s supplementary groups. Ignored when User Name is empty.",
          key: "InitGroups"
        )
      }
    } header: {
      Text("Run As")
    } footer: {
      Text("Daemons run as root unless a user is set.")
    }
  }
}

struct JobIssuesSection: View {
  let issues: [ValidationIssue]

  var body: some View {
    let visible = issues.filter { $0.severity > .info }
    if !visible.isEmpty {
      Section("Issues") {
        ForEach(visible) { issue in
          Label {
            Text(issue.message)
              .textSelection(.enabled)
          } icon: {
            SeverityIcon(severity: issue.severity)
          }
          .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { Pasteboard.copy(issue.copyText) }
          }
        }
      }
    }
  }
}

private struct ArgumentsEditor: View {
  @Binding var arguments: [TextItem]
  let program: String

  var body: some View {
    VStack(alignment: .trailing, spacing: 6) {
      ForEach($arguments) { $argument in
        HStack(spacing: 4) {
          TextField("Argument", text: $argument.value, prompt: Text(prompt(for: argument.id)))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .monospaced()
            .accessibilityLabel("Argument \(position(of: argument.id))")
          RowMenu(
            canMoveUp: position(of: argument.id) > 1,
            canMoveDown: position(of: argument.id) < arguments.count,
            onMoveUp: { move(argument.id, by: -1) },
            onMoveDown: { move(argument.id, by: 1) },
            onRemove: { arguments.removeAll { $0.id == argument.id } }
          )
        }
      }
      Button("Add Argument", systemImage: "plus.circle") {
        arguments = LaunchJob.addingArgument(to: arguments, program: program)
      }
      .buttonStyle(.borderless)
      .help(
        arguments.isEmpty && !program.isEmpty
          ? "Adds the program path as the first argument (the process name), then a row for the first option"
          : "Adds an argument row"
      )
    }
    .frame(maxWidth: 380)
  }

  /// With Program set, the first row is only the process name; the others are the program's options.
  private func prompt(for id: TextItem.ID) -> String {
    if position(of: id) == 1 {
      return program.isEmpty ? String(localized: "Program path") : String(localized: "Process name (program path)")
    }
    return String(localized: "Option, for example --silent")
  }

  private func position(of id: TextItem.ID) -> Int {
    (arguments.firstIndex { $0.id == id } ?? 0) + 1
  }

  private func move(_ id: TextItem.ID, by offset: Int) {
    guard let index = arguments.firstIndex(where: { $0.id == id }) else { return }
    let target = index + offset
    guard arguments.indices.contains(target) else { return }
    arguments.swapAt(index, target)
  }
}
