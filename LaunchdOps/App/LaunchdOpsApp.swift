import SwiftUI

@main
struct LaunchdOpsApp: App {
  @State private var library = ProjectLibrary.standard()

  init() {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "?"
    let build = info?["CFBundleVersion"] as? String ?? "?"
    let system = ProcessInfo.processInfo.operatingSystemVersionString
    Log.app.notice(
      "LaunchdOps \(version, privacy: .public) (\(build, privacy: .public)) started on \(system, privacy: .public)"
    )
    SigningPreferences.migrateLegacyValue(in: .standard)
  }

  var body: some Scene {
    Window("LaunchdOps", id: "main") {
      ContentView(library: library)
    }
    .commands {
      SidebarCommands()
      LibraryCommands()
      ProjectCommands()
      HelpCommands()
    }

    Settings {
      TabView {
        Tab("General", systemImage: "gearshape") {
          GeneralSettingsView()
        }
        Tab("Signing", systemImage: "signature") {
          SigningSettingsView()
        }
      }
    }
  }
}

struct ProjectActions {
  var importProject: @MainActor () -> Void
  var exportProjectFile: (@MainActor () -> Void)?
  var deleteJob: (@MainActor () -> Void)?
  var renameJob: (@MainActor () -> Void)?
  var duplicateJob: (@MainActor () -> Void)?
  var newJobFromClipboard: @MainActor () -> Void
  var newJob: @MainActor () -> Void
  var importPlists: @MainActor () -> Void
  var addPayloadFiles: @MainActor () -> Void
  var exportProject: @MainActor () -> Void
  var exportSelectedPlist: (@MainActor () -> Void)?
  var copySelectedPlist: (@MainActor () -> Void)?
  var showSelectedPlist: (@MainActor () -> Void)?
  var showHelp: @MainActor () -> Void
  var openLogInConsole: @MainActor () -> Void
  var selectTab: (@MainActor (EditorTab) -> Void)?
}

extension FocusedValues {
  @Entry var projectActions: ProjectActions?
}

/// File menu: jobs save automatically, so New and Open become New Job and Import Project, and the Save commands
/// are replaced by Export Project.
struct LibraryCommands: Commands {
  @FocusedValue(\.projectActions) private var actions

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("New Job…") { actions?.newJob() }
        .keyboardShortcut("n", modifiers: .command)
        .disabled(actions == nil)
      Button("Import Project…") { actions?.importProject() }
        .disabled(actions == nil)
    }
    CommandGroup(replacing: .saveItem) {
      Button("Export Project…") { actions?.exportProjectFile?() }
        .disabled(actions?.exportProjectFile == nil)
    }
  }
}

struct ProjectCommands: Commands {
  @FocusedValue(\.projectActions) private var actions

  var body: some Commands {
    CommandMenu("Project") {
      Group {
        menuItems
      }
      .disabled(actions == nil)
    }
  }

  @ViewBuilder
  private var menuItems: some View {
    Button("Rename…") { actions?.renameJob?() }
      .disabled(actions?.renameJob == nil)
    Button("Duplicate Job") { actions?.duplicateJob?() }
      .keyboardShortcut("d", modifiers: .command)
      .disabled(actions?.duplicateJob == nil)
    Button("Delete Job…") { actions?.deleteJob?() }
      .disabled(actions?.deleteJob == nil)

    Divider()

    Button("Import Launchd Plists…") { actions?.importPlists() }
      .keyboardShortcut("i", modifiers: [.command, .shift])
    Button("New Job from Clipboard") { actions?.newJobFromClipboard() }
    Button("Add Payload Files…") { actions?.addPayloadFiles() }
      .keyboardShortcut("a", modifiers: [.command, .option])

    Divider()

    Button("General") { actions?.selectTab?(.general) }
      .keyboardShortcut("1", modifiers: .command)
      .disabled(actions?.selectTab == nil)
    Button("Options") { actions?.selectTab?(.options) }
      .keyboardShortcut("2", modifiers: .command)
      .disabled(actions?.selectTab == nil)
    Button("Export") { actions?.selectTab?(.export) }
      .keyboardShortcut("3", modifiers: .command)
      .disabled(actions?.selectTab == nil)
    Button("Summary") { actions?.selectTab?(.summary) }
      .keyboardShortcut("4", modifiers: .command)
      .disabled(actions?.selectTab == nil)

    Divider()

    Button("Export Deployment Folder…") { actions?.exportProject() }
      .keyboardShortcut("e", modifiers: [.command, .shift])
    Button("Export Selected Plist…") { actions?.exportSelectedPlist?() }
      .keyboardShortcut("e", modifiers: [.command, .option])
      .disabled(actions?.exportSelectedPlist == nil)
    Button("Show Plist XML…") { actions?.showSelectedPlist?() }
      .disabled(actions?.showSelectedPlist == nil)
    Button("Copy Plist XML") { actions?.copySelectedPlist?() }
      .disabled(actions?.copySelectedPlist == nil)
  }
}

struct HelpCommands: Commands {
  @FocusedValue(\.projectActions) private var actions

  var body: some Commands {
    CommandGroup(replacing: .help) {
      Button("LaunchdOps Help…") { actions?.showHelp() }
        .keyboardShortcut("?", modifiers: .command)
        .disabled(actions == nil)
      Button("View Logs") { actions?.openLogInConsole() }
        .disabled(actions == nil)
    }
  }
}
