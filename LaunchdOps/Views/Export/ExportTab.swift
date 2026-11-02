import SwiftUI

struct ExportTab: View {
  @Binding var project: Project
  let job: LaunchJob
  let issues: [ValidationIssue]
  let isExporting: Bool
  let onSelectIssue: (ValidationIssue) -> Void
  let onExportFolder: () -> Void
  let onExportPlist: () -> Void

  @State private var newRetiredLabel = ""
  @StoredSigningPreferences private var signing

  var body: some View {
    GeometryReader { proxy in
      if proxy.size.width >= 860 {
        HStack(spacing: 0) {
          settingsForm
          Divider()
          summaryForm
            .frame(width: 360)
        }
      } else {
        Form {
          settingsSections
          summarySections
        }
        .formStyle(.grouped)
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      actionBar
    }
    .onChange(of: project.settings.mode) { _, mode in
      if mode == .declarative && project.settings.taskType.isEmpty {
        project.settings.taskType = defaultTaskType
      }
    }
  }

  private var settingsForm: some View {
    Form { settingsSections }
      .formStyle(.grouped)
  }

  private var summaryForm: some View {
    Form { summarySections }
      .formStyle(.grouped)
  }

  @ViewBuilder
  private var settingsSections: some View {
    deploySection
    includeSection
    switch project.settings.mode {
    case .package:
      packageSection
      upgradesSection
    case .declarative:
      backgroundTaskSection
    }
    if signsSomething {
      signingSection
    }
  }

  @ViewBuilder
  private var summarySections: some View {
    ReadinessSection(readiness: ExportReadiness(project: signing.applied(to: project), issues: issues))
    Section("Output") {
      OutputPreview(project: signing.applied(to: project))
    }
    validationSection
  }

  @ViewBuilder
  private var validationSection: some View {
    Section("Validation") {
      if issues.isEmpty {
        Label {
          Text("No errors or warnings")
        } icon: {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.green)
        }
      } else {
        ForEach(issues) { issue in
          Button {
            onSelectIssue(issue)
          } label: {
            IssueRow(issue: issue)
          }
          .buttonStyle(.plain)
        }
        HStack {
          Spacer()
          Button("Copy All Issues", systemImage: "doc.on.doc") { Pasteboard.copy(issues.copyText) }
            .buttonStyle(.link)
        }
      }
    }
  }

  // MARK: - Settings

  private var deploySection: some View {
    Section("Deploy As") {
      ChoiceRow(
        title: "Installer Package",
        detail: "Package with preinstall and postinstall scripts, for any MDM or software distribution tool.",
        isSelected: project.settings.mode == .package
      ) {
        project.settings.mode = .package
      }
      // Background tasks install daemons and agents for all users; a User Launch Agent lives in ~/Library.
      let isUserAgent = job.context == .userAgent
      ChoiceRow(
        title: "DDM Background Task",
        detail: isUserAgent
          ? "Not available for User Launch Agents: background tasks install daemons and agents for all users, not in ~/Library."
          : "Assets and declarations for tamper-resistant background tasks. macOS 15 or later, supervised Macs.",
        isSelected: project.settings.mode == .declarative
      ) {
        project.settings.mode = .declarative
      }
      .disabled(isUserAgent)
    }
  }

  private var includeSection: some View {
    Section("Include") {
      IncludeRow(
        title: "Property List",
        detail: "The launchd plist for each job. Always included.",
        systemImage: "doc.text",
        fileType: ".plist",
        isOn: .constant(true)
      )
      .disabled(true)
      switch project.settings.mode {
      case .package:
        IncludeRow(
          title: "Installer Package",
          detail: project.settings.packageOutput == .installerPackage
            ? "A finished package with the payload and install scripts, signed if you choose an identity."
            : "Payload, install scripts and build-pkg.sh to build and sign on your Mac.",
          systemImage: "shippingbox",
          fileType: ".pkg",
          isOn: $project.settings.includePackage
        )
      case .declarative:
        IncludeRow(
          title: "Background Task Declarations",
          detail: "Assets, SHA-256 hashes and declarations for your MDM. Always included.",
          systemImage: "shippingbox",
          fileType: ".json",
          isOn: .constant(true)
        )
        .disabled(true)
      }
      IncludeRow(
        title: "Managed Login Items Profile",
        detail: "Stops users turning the jobs off in Login Items. Deliver it with MDM.",
        systemImage: "checkmark.shield",
        fileType: ".mobileconfig",
        isOn: $project.settings.includeLoginItemsProfile
      )
      IncludeRow(
        title: "Scripts",
        detail: project.settings.mode == .package
          ? "check.sh reports each job’s state to your MDM, tests and collects logs; uninstall.sh removes it all."
          : "check.sh reports each job’s state for your MDM’s inventory, tests and collects logs.",
        systemImage: "terminal",
        fileType: ".sh",
        isOn: $project.settings.includeScripts
      )
      IncludeRow(
        title: "Deployment Guide",
        detail: "README with steps to test, deploy, check and remove the jobs with any MDM, and the validation results.",
        systemImage: "book",
        fileType: ".md",
        isOn: $project.settings.includeGuide
      )
    }
  }

  private var packageSection: some View {
    Section {
      ChoiceRow(
        title: "Finished Package (.pkg)",
        detail: "LaunchdOps writes the finished package and signs it with an identity from your keychain.",
        isSelected: project.settings.packageOutput == .installerPackage
      ) {
        project.settings.packageOutput = .installerPackage
      }
      ChoiceRow(
        title: "Build Script",
        detail: "Package project and build-pkg.sh, built and signed with Apple’s tools on your Mac.",
        isSelected: project.settings.packageOutput == .buildScript
      ) {
        project.settings.packageOutput = .buildScript
      }
      projectNameField
      TextField(text: $project.settings.packageIdentifier, prompt: Text(labelPrompt)) {
        InfoLabel(
          "Identifier",
          info: "Package identifier for the installer receipt. Keep it the same across versions."
        )
      }
      .monospaced()
      TextField(text: $project.settings.version, prompt: Text("1.0")) {
        InfoLabel("Version", info: "Package version. Raise it for each release so management tools see the update.")
      }
      TextField(text: $project.settings.organization, prompt: Text("Optional")) {
        InfoLabel("Organization", info: "Organization name shown in the Managed Login Items profile.")
      }
    } header: {
      Text("Package")
    } footer: {
      Text(packageFooter)
    }
  }

  /// Package or profile output that Settings ▸ Signing applies to.
  private var signsSomething: Bool {
    (project.settings.mode == .package && project.settings.includePackage) || project.settings.includeLoginItemsProfile
  }

  /// Signing is set once for every job in Settings; this shows what applies to this job's export.
  private var signingSection: some View {
    let applied = signing.applied(to: project).settings
    return Section {
      if project.settings.mode == .package && project.settings.includePackage {
        LabeledContent("Package", value: applied.signingIdentity.isEmpty ? "Not signed" : applied.signingIdentity)
        if applied.packageOutput == .installerPackage && !applied.signingIdentity.isEmpty {
          LabeledContent(
            "Notarization",
            value: applied.notarizeAfterExport ? "Automatically after export" : "You notarize it"
          )
        }
      }
      if project.settings.includeLoginItemsProfile {
        let profile = applied.profileSigningIdentity
        LabeledContent("Profile", value: profile.isEmpty ? "Not signed" : profile)
      }
      HStack {
        Spacer()
        SettingsLink {
          Text("Change in Settings…")
        }
      }
    } header: {
      Text("Signing")
    } footer: {
      Text("Signing and notarization apply to every job. Change them in LaunchdOps ▸ Settings (⌘,).")
    }
  }

  /// The job label a blank Project Name or Identifier follows.
  private var labelPrompt: String {
    project.primaryLabel ?? "com.example.backup"
  }

  private var projectNameField: some View {
    TextField(text: $project.settings.name, prompt: Text(labelPrompt)) {
      InfoLabel("Project Name", info: "Names the export folder and the package file.")
    }
  }

  private var packageFooter: LocalizedStringKey {
    switch project.settings.packageOutput {
    case .installerPackage:
      """
      Leave Project Name or Identifier empty to use the job label. The package identifier names the installer \
      receipt.
      """
    case .buildScript:
      """
      Leave Project Name or Identifier empty to use the job label. The package identifier names the installer \
      receipt. Run build-pkg.sh on your Mac to build and sign it; set SIGN_IDENTITY to sign with a different \
      identity.
      """
    }
  }

  private var backgroundTaskSection: some View {
    Section {
      projectNameField
      LabeledContent {
        HStack {
          TextField("Task Type", text: $project.settings.taskType, prompt: Text("com.example.backup"))
            .labelsHidden()
            .monospaced()
          Button("Use Daemon Label") {
            project.settings.taskType = defaultTaskType
          }
          .disabled(defaultTaskType.isEmpty)
        }
      } label: {
        InfoLabel(
          "Task Type",
          info: "Identifier of the background task. It also names the folder its payload installs in.",
          key: "TaskType"
        )
      }
      TextField(text: $project.settings.taskDescription, prompt: Text("Optional")) {
        InfoLabel(
          "Description",
          info: "Short description included in the background task declaration.",
          key: "TaskDescription"
        )
      }
      TextField(text: $project.settings.organization, prompt: Text("Optional")) {
        InfoLabel("Organization", info: "Organization name shown in the Managed Login Items profile.")
      }
    } header: {
      Text("Background Task")
    } footer: {
      Text("Payload files install in \(Project.servicesRoot)/\(project.settings.taskType.isEmpty ? "<task type>" : project.settings.taskType).")
    }
  }

  private var upgradesSection: some View {
    Section {
      ForEach(project.settings.retiredLabels, id: \.self) { label in
        HStack {
          Text(label)
            .monospaced()
            .textSelection(.enabled)
          Spacer()
          Button("Remove \(label)", systemImage: "minus.circle", role: .destructive) {
            project.settings.retiredLabels.removeAll { $0 == label }
          }
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
          .help("Remove")
        }
      }
      HStack {
        TextField("Retired Label", text: $newRetiredLabel, prompt: Text("com.example.old-job"))
          .labelsHidden()
          .monospaced()
          .onSubmit { addRetiredLabel() }
          .help("Label of an old job the package should stop and delete before installing.")
        Button("Add") { addRetiredLabel() }
          .disabled(newRetiredLabel.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    } header: {
      Text("Upgrades")
    } footer: {
      Text(
        """
        Labels from earlier versions that the package stops and deletes before installing. Renaming a job that was \
        exported or imported adds its old label here.
        """
      )
    }
  }

  // MARK: - Actions

  private var actionBar: some View {
    VStack(spacing: 0) {
      Divider()
      HStack(spacing: 8) {
        Text("Export Folder ⇧⌘E · Export Plist ⌥⌘E")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        if isExporting {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel("Exporting")
        }
        Button("Export Plist…") { onExportPlist() }
          .help("Save the plist for \(job.displayName)")
        Button("Export Folder…") { onExportFolder() }
          .buttonStyle(.borderedProminent)
          .disabled(isExporting)
          .help("Save the complete deployment folder")
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 12)
    }
    .background(.bar)
  }

  private var defaultTaskType: String {
    project.daemons.first?.label ?? project.jobs.first?.label ?? ""
  }

  private func addRetiredLabel() {
    let label = newRetiredLabel.trimmingCharacters(in: .whitespaces)
    guard !label.isEmpty, !project.settings.retiredLabels.contains(label) else { return }
    project.settings.retiredLabels.append(label)
    newRetiredLabel = ""
  }
}
