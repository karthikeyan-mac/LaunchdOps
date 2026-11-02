import OSLog
import SwiftUI
import UniformTypeIdentifiers

enum EditorTab: String, CaseIterable, Identifiable {
  case general
  case options
  case export
  case summary

  var id: String { rawValue }

  var title: String {
    switch self {
    case .general: String(localized: "General")
    case .options: String(localized: "Options")
    case .export: String(localized: "Export")
    case .summary: String(localized: "Summary")
    }
  }
}

struct ContentView: View {
  let library: ProjectLibrary

  @Environment(\.undoManager) private var undoManager
  @Environment(\.scenePhase) private var scenePhase
  // The last selected project, restored at launch. UI state only; projects live in the library.
  @AppStorage("SelectedProjectID") private var savedProjectID = ""
  @StoredSigningPreferences private var signing
  @State private var severityCache = SeverityCache()
  @AppStorage(GeneralSettingsView.labelPrefixKey) private var labelPrefix = ""
  @AppStorage(GeneralSettingsView.logFolderKey) private var logFolder = ""
  // Set once signing choices saved in projects have been copied into Settings.
  @AppStorage("SigningPreferencesMigrated") private var signingMigrated = false
  @State private var selectedProjectID: UUID?
  @State private var deletingProjectID: UUID?
  @State private var renaming: RenameRequest?
  /// The project an export in progress came from, so it is marked published even if the selection changes.
  @State private var exportedProjectID: UUID?
  @State private var tab = EditorTab.general
  @State private var searchText = ""
  @State private var isNewJobPresented = false
  @State private var isIssuesPresented = false
  @State private var isHelpPresented = false
  @State private var isPlistPresented = false
  // Project ▸ Show Plist XML uses a sheet: the toolbar popover's anchor can be in the overflow menu or hidden.
  @State private var isPlistSheetPresented = false
  @State private var importKind = ImportKind.plists
  @State private var isImporterPresented = false
  @State private var exportDocument: ExportDocument?
  @State private var exportType = UTType.folder
  @State private var exportName = ""
  @State private var isExporterPresented = false
  @State private var isExporting = false
  @State private var isConfirmingExport = false
  @State private var errorMessage: String?
  @State private var pendingNotarization: PackageToNotarize?
  @State private var notarizationActivity: NotarizationActivity?
  @State private var notarizationTask: Task<Void, Never>?
  @State private var notarizationResult: NotarizationOutcome?
  @State private var notice: Notice?
  @State private var chosenProgram: ChosenProgram?

  private let logger = Log.app

  private enum ImportKind: Equatable {
    case project
    case plists
    case payload
    case program(LaunchJob.ID)

    var contentTypes: [UTType] {
      switch self {
      case .project: [.launchdOpsProject]
      case .plists: [.propertyList, .xml]
      case .payload, .program: [.item]
      }
    }
  }

  /// A program chosen with Choose… that exists only on this Mac, waiting for the user to decide how to use it.
  private struct ChosenProgram {
    let url: URL
    let jobID: LaunchJob.ID
  }

  private struct PackageToNotarize {
    let name: String
    let data: Data
    /// Where the package was saved, so the ticket can be stapled to it once Apple accepts it.
    var fileURL: URL?
  }

  private struct RenameRequest: Identifiable {
    let id: UUID
  }

  private struct Notice: Identifiable {
    let id = UUID()
    let title: String
    let message: String

    /// Literal text is looked up in the String Catalog here, so the alert shows it as is.
    init(title: String.LocalizationValue, message: String.LocalizationValue) {
      self.title = String(localized: title)
      self.message = String(localized: message)
    }
  }

  private enum StapleOutcome {
    case notAttempted
    case stapled
    case failed(String)
  }

  private struct NotarizationOutcome: Identifiable {
    let id = UUID()
    let name: String
    let result: NotaryResult
    var staple = StapleOutcome.notAttempted
  }

  /// The selected project. Setting it goes through the library, which saves it and registers undo.
  private var project: Project {
    get { library.project(selectedProjectID) ?? Project() }
    nonmutating set {
      if let selectedProjectID {
        library.apply(newValue, to: selectedProjectID, undoManager: undoManager)
      }
    }
  }

  private var projectBinding: Binding<Project> {
    Binding(get: { project }, set: { project = $0 })
  }

  /// Each project holds one job.
  private var selectedJob: LaunchJob? {
    selectedProjectID == nil ? nil : project.jobs.first
  }

  private var sidebarSelection: Binding<UUID?> {
    Binding(get: { selectedProjectID }, set: { selectProject($0) })
  }

  var body: some View {
    // With no job selected there is nothing to validate; an empty placeholder project would report errors.
    let issues = library.project(selectedProjectID).map { Validator.validate(signing.applied(to: $0)) } ?? []

    let window = NavigationSplitView {
      SidebarView(
        library: library,
        selection: sidebarSelection,
        searchText: searchText,
        severities: severityCache.severities(
          for: library.entries,
          signing: signing,
          selected: selectedProjectID.map { ($0, issues) }
        ),
        onAddJob: { isNewJobPresented = true },
        onCopyPlist: { copyPlist(inProject: $0) },
        onExportProject: { exportProjectFile($0) },
        onRename: { renaming = RenameRequest(id: $0) },
        onDuplicate: { duplicateProject($0) },
        onDelete: { deletingProjectID = $0 }
      )
      .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 340)
    } detail: {
      detail(issues: issues)
    }
    .searchable(text: $searchText, placement: .sidebar, prompt: "Search")
    .navigationTitle(library.project(selectedProjectID).map(ProjectLibrary.displayName(of:)) ?? "LaunchdOps")
    .navigationSubtitle(subtitle)
    .toolbar { toolbarContent(issues: issues) }
    .frame(minWidth: 900, minHeight: 560)
    .sheet(isPresented: $isNewJobPresented) {
      NewJobSheet(
        suggestedLabel: { context in
          // With a Label Prefix, start with just the prefix so the admin types the rest.
          Project.labelPrefix(from: labelPrefix).map { "\($0)." } ?? library.nextLabel(for: context)
        },
        existingLabels: Set(library.entries.flatMap { $0.project.jobs.map(\.label) })
      ) { context, label in
        addJob(context, label: label)
      }
    }
    .sheet(isPresented: $isHelpPresented) {
      HelpSheet()
    }
    .sheet(item: $renaming) { request in
      let renamed = library.project(request.id)
      RenameSheet(name: renamed?.settings.name ?? "", label: renamed?.primaryLabel ?? "") { name in
        rename(request.id, to: name)
      }
    }
    .confirmationDialog(
      "Delete “\(library.project(deletingProjectID).map(ProjectLibrary.displayName(of:)) ?? "")”?",
      item: $deletingProjectID
    ) { id in
      Button("Delete Job", role: .destructive) { deleteProject(id) }
      Button("Cancel", role: .cancel) {}
    } message: { _ in
      Text("The job, its export settings and its payload files are removed. You can undo this with Edit ▸ Undo.")
    }
    .sheet(isPresented: $isPlistSheetPresented) {
      if let job = selectedJob {
        PlistSheet(job: job) { copyPlist(for: job.id) }
      }
    }
    .fileImporter(
      isPresented: $isImporterPresented,
      allowedContentTypes: importKind.contentTypes,
      allowsMultipleSelection: importKind == .plists || importKind == .payload || importKind == .project
    ) { result in
      handleImport(result)
    }
    .fileExporter(
      isPresented: $isExporterPresented,
      document: exportDocument,
      contentTypes: [exportType],
      defaultFilename: exportName,
      onCompletion: { result in handleExport(result) },
      onCancellation: { clearPendingExport() }
    )
    .confirmationDialog(
      "Add \(chosenProgram?.url.lastPathComponent ?? "") to the Payload?",
      item: $chosenProgram
    ) { chosen in
      Button("Add to Payload") { addProgramToPayload(chosen) }
        .keyboardShortcut(.defaultAction)
      Button("Reference Existing Path") { setProgram(chosen.url.path(percentEncoded: false), for: chosen.jobID) }
      Button("Cancel", role: .cancel) {}
    } message: { chosen in
      Text(chosenProgramMessage(chosen))
    }

    alerts(on: window, issues: issues)
      .onAppear {
        migrateSigningPreferences()
        if selectedProjectID == nil {
          let saved = UUID(uuidString: savedProjectID)
          selectProject(library.project(saved) != nil ? saved : library.entries.first?.id)
        }
      }
      .onOpenURL { url in
        guard url.isFileURL, url.pathExtension == ProjectLibrary.fileExtension else { return }
        importProjects([url])
      }
      .onChange(of: scenePhase) { _, phase in
        if phase != .active {
          library.saveNow()
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
        library.saveNow()
      }
      .focusedSceneValue(\.projectActions, actions(issues: issues))
      .onDisappear {
        notarizationTask?.cancel()
      }
  }

  /// The window's alerts, applied separately so the compiler can type-check `body` in reasonable time.
  private func alerts(on content: some View, issues: [ValidationIssue]) -> some View {
    content
      .alert("Export with errors?", isPresented: $isConfirmingExport) {
        Button("Export Anyway") { beginExport() }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("\(issues.errorCount) validation errors remain. The exported files may not work until you fix them.")
      }
      .alert(
        notarizationResult?.result.status == .accepted
          ? LocalizedStringKey("Package Notarized") : LocalizedStringKey("Notarization Failed"),
        item: $notarizationResult
      ) { _ in
      } message: { outcome in
        Text(notarizationMessage(outcome))
      }
      // Notice and error text is localized where it is created.
      .alert(notice?.title ?? "", item: $notice) { _ in
      } message: { notice in
        Text(verbatim: notice.message)
      }
      .alert("Something Went Wrong", item: $errorMessage) { _ in
      } message: { message in
        Text(verbatim: message)
      }
  }

  private var subtitle: String {
    guard let job = selectedJob else { return "" }
    return "\(job.displayName) · \(job.context.title)"
  }

  // MARK: - Detail

  @ViewBuilder
  private func detail(issues: [ValidationIssue]) -> some View {
    if let job = selectedJob {
      switch tab {
      case .summary:
        SummaryTab(
          job: job,
          summary: JobExplainer.summarize(job),
          issues: issues.issues(for: job.id)
        ) { tab = $0 }
        .id(job.id)
      case .general:
        GeneralTab(
          job: binding(for: job),
          project: projectBinding,
          issues: issues.issues(for: job.id),
          onAddFiles: { presentImporter(.payload) },
          onChooseProgram: { presentImporter(.program(job.id)) },
          onLabelEditEnded: { [selectedProjectID] old, new in
            noteLabelChange(in: selectedProjectID, from: old, to: new)
          }
        )
        .id(job.id)
      case .options:
        OptionsTab(job: binding(for: job), rotateLogs: rotateLogsBinding(for: job), issues: issues.issues(for: job.id))
          .id(job.id)
      case .export:
        ExportTab(
          project: projectBinding,
          job: job,
          issues: issues,
          isExporting: isExporting,
          onSelectIssue: { select($0) },
          onExportFolder: { requestExport(issues: issues) },
          onExportPlist: { exportPlist(for: job.id) }
        )
      }
    } else if library.entries.isEmpty {
      ContentUnavailableView {
        Label("Create Your First Launchd Job", systemImage: "gearshape.2")
      } description: {
        Text("Build a launch daemon or agent from scratch, or import plists you already have.")
      } actions: {
        Button("New Job…") { isNewJobPresented = true }
          .buttonStyle(.borderedProminent)
        Button("Import Launchd Plists…") { presentImporter(.plists) }
      }
    } else {
      ContentUnavailableView {
        Label("No Job Selected", systemImage: "sidebar.left")
      } description: {
        Text("Select a job in the sidebar, or add one.")
      } actions: {
        Button("New Job…") { isNewJobPresented = true }
      }
    }
  }

  /// Options ▸ Logging ▸ Rotate Logs, only for daemons installed by a package that start and exit.
  private func rotateLogsBinding(for job: LaunchJob) -> Binding<Bool>? {
    guard LogRotation.canRotateLogs(job), project.settings.mode == .package else { return nil }
    return projectBinding.settings.rotateLogs
  }

  private func binding(for job: LaunchJob) -> Binding<LaunchJob> {
    Binding(
      get: { project.job(withID: job.id) ?? job },
      set: { newValue in
        if let index = project.jobs.firstIndex(where: { $0.id == job.id }) {
          project.jobs[index] = newValue
        }
      }
    )
  }

  // MARK: - Toolbar

  @ToolbarContentBuilder
  private func toolbarContent(issues: [ValidationIssue]) -> some ToolbarContent {
    ToolbarItem(placement: .principal) {
      Picker("Section", selection: $tab) {
        ForEach(EditorTab.allCases) { tab in
          Text(tab.title).tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
      .disabled(selectedJob == nil)
      .help("Switch between General, Options, Export and Summary")
    }

    ToolbarItemGroup(placement: .primaryAction) {
      if let notarizationActivity {
        NotarizationProgressButton(activity: notarizationActivity) { cancelActivity() }
      }
      Button("Show Plist XML", systemImage: "doc.text") { isPlistPresented = true }
        .labelStyle(.iconOnly)
        .help("Show the selected job’s plist XML")
        .disabled(selectedJob == nil)
        .popover(isPresented: $isPlistPresented, arrowEdge: .bottom) {
          if let job = selectedJob {
            PlistPopover(job: job) { copyPlist(for: job.id) }
          }
        }
      if library.project(selectedProjectID) != nil {
        ValidationStatusButton(issues: issues, isPresented: $isIssuesPresented) { select($0) }
      }

      if tab != .export {
        Button("Export…", systemImage: "square.and.arrow.up") { tab = .export }
          .help("Review export options")
          .disabled(selectedJob == nil)
      }
    }
  }

  // MARK: - Actions

  private func actions(issues: [ValidationIssue]) -> ProjectActions {
    var exportSelected: (@MainActor () -> Void)?
    var copySelected: (@MainActor () -> Void)?
    var showSelected: (@MainActor () -> Void)?
    var selectTab: (@MainActor (EditorTab) -> Void)?
    if let id = selectedJob?.id {
      exportSelected = { exportPlist(for: id) }
      copySelected = { copyPlist(for: id) }
      showSelected = { isPlistSheetPresented = true }
      selectTab = { tab = $0 }
    }
    var exportProject: (@MainActor () -> Void)?
    var deleteJob: (@MainActor () -> Void)?
    var rename: (@MainActor () -> Void)?
    var duplicate: (@MainActor () -> Void)?
    if let id = selectedProjectID {
      exportProject = { exportProjectFile(id) }
      deleteJob = { deletingProjectID = id }
      rename = { renaming = RenameRequest(id: id) }
      duplicate = { duplicateProject(id) }
    }
    return ProjectActions(
      importProject: { presentImporter(.project) },
      exportProjectFile: exportProject,
      deleteJob: deleteJob,
      renameJob: rename,
      duplicateJob: duplicate,
      newJobFromClipboard: { newJobFromClipboard() },
      newJob: { isNewJobPresented = true },
      importPlists: { presentImporter(.plists) },
      addPayloadFiles: { presentImporter(.payload) },
      exportProject: { requestExport(issues: issues) },
      exportSelectedPlist: exportSelected,
      copySelectedPlist: copySelected,
      showSelectedPlist: showSelected,
      showHelp: { isHelpPresented = true },
      openLogInConsole: { openLogInConsole() },
      selectTab: selectTab
    )
  }

  // MARK: - Projects

  /// Signing used to be set per project. The first time, copy the selected project's choices (else the first
  /// project that signed anything) into Settings so nothing set earlier is lost.
  private func migrateSigningPreferences() {
    guard !signingMigrated else { return }
    signingMigrated = true
    guard signing.isEmpty else { return }
    let saved = UUID(uuidString: savedProjectID).flatMap { id in library.entries.first { $0.id == id } }
    let candidates = (saved.map { [$0] } ?? []) + library.entries
    if let settings = candidates.map(\.project.settings).first(where: { !SigningPreferences(migrating: $0).isEmpty }) {
      signing = SigningPreferences(migrating: settings)
    }
  }

  private func selectProject(_ id: UUID?) {
    guard id != selectedProjectID else { return }
    selectedProjectID = id
    savedProjectID = id?.uuidString ?? ""
    tab = .general
  }

  private func deleteProject(_ id: UUID) {
    let index = library.entries.firstIndex { $0.id == id }
    library.delete(id, undoManager: undoManager)
    undoManager?.setActionName(String(localized: "Delete Job"))
    logger.info("Deleted a job")
    if selectedProjectID == id {
      let next = index.flatMap { library.entries.indices.contains($0) ? $0 : library.entries.indices.last }
      selectedProjectID = nil
      selectProject(next.map { library.entries[$0].id })
    }
  }

  /// Sets Export ▸ Project Name; an empty name goes back to following the job label.
  /// Records a finished label edit on the project it belongs to, even if another job is selected by now.
  private func noteLabelChange(in id: UUID?, from old: String, to new: String) {
    guard let id, var edited = library.project(id) else { return }
    edited.noteLabelChange(from: old, to: new)
    library.apply(edited, to: id, undoManager: undoManager)
  }

  /// Opens Console with this app's log search on the clipboard, since Console can't be told what to search for.
  private func openLogInConsole() {
    Pasteboard.copy(ConsoleLog.search)
    Task {
      do {
        try await ConsoleLog.open()
        Log.app.info("Opened Console for viewing logs")
        notice = Notice(
          title: "View LaunchdOps Logs in Console",
          message: """
            The search is on the clipboard: \(ConsoleLog.search)

            1. In Console, click the search field.
            2. Paste (⌘V) and press Return.
            3. Click Start Streaming.
            4. To see everyday messages, choose Action ▸ Include Info Messages.
            5. To see one area, add a category to the search, for example category:Export.
            """
        )
      } catch {
        logger.error("Opening Console failed: \(error.localizedDescription, privacy: .public)")
        errorMessage = error.localizedDescription
      }
    }
  }

  private func rename(_ id: UUID, to name: String) {
    guard var renamed = library.project(id), renamed.settings.name != name else { return }
    renamed.settings.name = name
    library.apply(renamed, to: id, undoManager: undoManager)
    undoManager?.setActionName(String(localized: "Rename"))
  }

  private func importProjects(_ urls: [URL]) {
    var failures: [String] = []
    var lastID: UUID?
    for url in urls {
      do {
        lastID = try library.importProject(from: url, undoManager: undoManager).last ?? lastID
      } catch {
        logger.error("Project import failed: \(error.localizedDescription, privacy: .public)")
        failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
      }
    }
    logger.info("Imported \(urls.count - failures.count) of \(urls.count) projects")
    if let lastID {
      selectProject(lastID)
    }
    if !failures.isEmpty {
      let list = failures.joined(separator: "\n")
      errorMessage = String(
        localized: "Some projects could not be imported. Check that each file is a LaunchdOps project.\n\n\(list)"
      )
    }
  }

  private func exportProjectFile(_ id: UUID) {
    guard let project = library.project(id) else { return }
    clearPendingExport()
    exportDocument = ExportDocument(content: .project(project))
    exportType = .launchdOpsProject
    exportName = ProjectLibrary.displayName(of: project)
    isExporterPresented = true
  }

  /// Opens the tab where an issue is fixed. Issues from rules that span tabs keep the current tab, except that
  /// job issues leave Export and project issues open it.
  private func select(_ issue: ValidationIssue) {
    switch issue.editorArea {
    case .general: tab = .general
    case .options: tab = .options
    case .export: tab = .export
    case nil:
      if issue.jobID != nil {
        if tab == .export {
          tab = .general
        }
      } else if selectedJob != nil {
        tab = .export
      }
    }
  }

  /// Each job is its own project, with its own export settings.
  private func addJob(_ context: JobContext, label: String) {
    var job = LaunchJob(context: context, label: label)
    if context == .daemon {
      job.runAtLoad = true
    }
    job.useLogFolder(logFolder)
    var newProject = Project()
    newProject.jobs = [job]
    newProject.settings.rotateLogs = !job.standardOutPath.isEmpty
    let id = library.create(newProject, undoManager: undoManager)
    logger.info("Created job \(label, privacy: .public)")
    undoManager?.setActionName(String(localized: "New Job"))
    selectProject(id)
  }

  /// Project ▸ Duplicate Job and the sidebar's Duplicate: a copy with a new label, selected. Undoable.
  private func duplicateProject(_ id: UUID) {
    guard let original = library.project(id) else { return }
    let labels = Set(library.entries.flatMap { $0.project.jobs.map(\.label) })
    let copy = original.duplicated(existingLabels: labels)
    let newID = library.create(copy, undoManager: undoManager)
    let from = original.primaryLabel ?? "", to = copy.primaryLabel ?? ""
    logger.info("Duplicated \(from, privacy: .public) as \(to, privacy: .public)")
    undoManager?.setActionName(String(localized: "Duplicate Job"))
    selectProject(newID)
  }

  /// Project ▸ New Job from Clipboard: plist XML copied from a text editor, Terminal or a web page.
  private func newJobFromClipboard() {
    do {
      let project = try Project.fromClipboard(Pasteboard.string())
      let id = library.create(project, undoManager: undoManager)
      logger.info("Created \(project.primaryLabel ?? "", privacy: .public) from the clipboard")
      undoManager?.setActionName(String(localized: "New Job from Clipboard"))
      selectProject(id)
    } catch {
      logger.error("New job from clipboard failed: \(error.localizedDescription, privacy: .public)")
      errorMessage = error.localizedDescription
    }
  }

  private func presentImporter(_ kind: ImportKind) {
    importKind = kind
    isImporterPresented = true
  }

  private func handleImport(_ result: Result<[URL], Error>) {
    switch result {
    case .success(let urls):
      switch importKind {
      case .project: importProjects(urls)
      case .plists: importPlists(urls)
      case .payload: importPayload(urls)
      case .program(let jobID):
        if let url = urls.first {
          chooseProgram(url, for: jobID)
        }
      }
    case .failure(let error):
      errorMessage = error.localizedDescription
    }
  }

  private func importPlists(_ urls: [URL]) {
    var failures: [String] = []
    var lastID: UUID?
    for url in urls {
      do {
        let data = try SecureFileReader.read(url)
        let dictionary = try PropertyListCoding.dictionary(from: data)
        let job = LaunchJob(dictionary: dictionary, context: .inferred(fromPath: url.path(percentEncoded: false)))
        // Each imported plist becomes its own job in the sidebar.
        var imported = Project()
        imported.jobs = [job]
        imported.markPublished([job.label])
        lastID = library.create(imported, undoManager: undoManager)
      } catch {
        logger.error("Plist import failed: \(error.localizedDescription, privacy: .public)")
        failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
      }
    }
    logger.info("Imported \(urls.count - failures.count) of \(urls.count) plists")
    if let lastID {
      selectProject(lastID)
    }
    if !failures.isEmpty {
      let list = failures.joined(separator: "\n")
      errorMessage = String(
        localized: "Some files could not be imported. Check that each file is a launchd property list.\n\n\(list)"
      )
    }
  }

  private func importPayload(_ urls: [URL]) {
    var failures: [String] = []
    for url in urls {
      do {
        let data = try SecureFileReader.read(url)
        let mode = SecureFileReader.isExecutable(url) ? 0o755 : 0o644
        let destination = project.settings.mode == .package ? Project.defaultPayloadDestination : ""
        project.payload.append(
          PayloadFile(name: url.lastPathComponent, destination: destination, mode: mode, contents: data)
        )
      } catch {
        logger.error("Payload import failed: \(error.localizedDescription, privacy: .public)")
        failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
      }
    }
    if !failures.isEmpty {
      let list = failures.joined(separator: "\n")
      errorMessage = String(localized: "Some files could not be added.\n\n\(list)")
    }
  }

  private func chooseProgram(_ chosen: URL, for jobID: LaunchJob.ID) {
    var url = chosen
    // launchd runs an executable, not a bundle: use the one inside an app or other bundle.
    if url.hasDirectoryPath {
      guard let executable = Bundle(url: url)?.executableURL else {
        errorMessage = String(
          localized: """
            \(url.lastPathComponent) is a folder, not a program. Choose the executable inside it, for an app in \
            Contents/MacOS.
            """
        )
        return
      }
      url = executable
    }
    let path = url.path(percentEncoded: false)
    if PayloadFile.isLocalOnly(path) {
      chosenProgram = ChosenProgram(url: url, jobID: jobID)
    } else {
      setProgram(path, for: jobID)
    }
  }

  private func setProgram(_ path: String, for jobID: LaunchJob.ID) {
    guard let index = project.jobs.firstIndex(where: { $0.id == jobID }) else { return }
    project.jobs[index].program = path
  }

  /// Adds the chosen program as an executable payload file and points the job at its installed path.
  private func addProgramToPayload(_ chosen: ChosenProgram) {
    // The job may have been deleted while the dialog was open.
    guard project.job(withID: chosen.jobID) != nil else { return }
    do {
      let data = try SecureFileReader.read(chosen.url)
      let destination = project.settings.mode == .package ? Project.defaultPayloadDestination : ""
      let file = PayloadFile(name: chosen.url.lastPathComponent, destination: destination, mode: 0o755, contents: data)
      project.payload.append(file)
      setProgram(project.installPath(for: file), for: chosen.jobID)
    } catch {
      logger.error("Program import failed: \(error.localizedDescription, privacy: .public)")
      let name = chosen.url.lastPathComponent
      errorMessage = String(localized: "\(name) could not be added. \(error.localizedDescription)")
    }
  }

  private func requestExport(issues: [ValidationIssue]) {
    guard selectedProjectID != nil, !project.jobs.isEmpty, !isExporting else { return }
    let blocking = issues.blocking
    if !blocking.isEmpty {
      // These would be unsafe in file paths or root install scripts, so there's no Export Anyway.
      Log.export.notice("Export stopped by \(blocking.count) blocking issues")
      let list = blocking.prefix(5).map { "• \($0.message)" }.joined(separator: "\n")
      let more =
        blocking.count > 5 ? String(localized: "\n…and \(blocking.count - 5) more in the Validation list.") : ""
      notice = Notice(
        title: "Fix These Before Exporting",
        message: """
          \(list)\(more)

          These values would be unsafe in file paths or in the install scripts that run as root, so they can’t \
          be exported anyway.
          """
      )
    } else if issues.errorCount > 0 {
      isConfirmingExport = true
    } else {
      beginExport()
    }
  }

  private func beginExport() {
    exportedProjectID = selectedProjectID
    let snapshot = signing.applied(to: project)
    let settings = snapshot.settings
    if settings.mode == .package && settings.includePackage && settings.packageOutput == .installerPackage
      && settings.notarizeAfterExport && !NotaryCredentialStore.exists()
    {
      errorMessage = NotaryError.notSignedIn.localizedDescription
      return
    }
    isExporting = true
    let label = snapshot.primaryLabel ?? "untitled"
    let issues = Validator.validate(snapshot)
    Log.export.notice(
      """
      Exporting \(label, privacy: .public): \(settings.mode.rawValue, privacy: .public), \
      \(settings.packageOutput.rawValue, privacy: .public), signed \(!settings.signingIdentity.isEmpty), \
      \(issues.errorCount) errors, \(issues.warningCount) warnings
      """
    )
    let started = ContinuousClock.now
    Task {
      do {
        let tree = try await Task.detached(priority: .userInitiated) {
          let settings = snapshot.settings
          let signs =
            settings.mode == .package && settings.includePackage && settings.packageOutput == .installerPackage
            && !settings.signingIdentity.isEmpty
          let signer = signs ? try KeychainPackageSigner(identityName: settings.signingIdentity) : nil
          let signsProfile = settings.includeLoginItemsProfile && !settings.profileSigningIdentity.isEmpty
          let profileSigner =
            signsProfile ? try KeychainProfileSigner(identityName: settings.profileSigningIdentity) : nil
          return try ProjectExporter.export(snapshot, signer: signer, profileSigner: profileSigner)
        }.value
        let bytes = tree.files.reduce(0) { $0 + $1.contents.count }
        Log.export.info(
          "Built \(tree.files.count) files, \(bytes) bytes, in \(Log.milliseconds(since: started)) ms"
        )
        pendingNotarization = packageToNotarize(in: tree, settings: snapshot.resolvedSettings)
        exportDocument = ExportDocument(content: .folder(tree))
        exportType = .folder
        exportName = ProjectExporter.defaultFolderName(for: snapshot)
        isExporterPresented = true
      } catch {
        Log.export.error("Export of \(label, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        errorMessage = String(localized: "The deployment folder could not be created. \(error.localizedDescription)")
      }
      isExporting = false
    }
  }

  private func exportPlist(for id: LaunchJob.ID) {
    guard let job = project.job(withID: id) else { return }
    clearPendingExport()
    exportedProjectID = selectedProjectID
    do {
      exportDocument = ExportDocument(content: .file(try job.renderedPlist()))
      exportType = .propertyList
      exportName = job.label.isEmpty ? "Untitled" : job.label
      isExporterPresented = true
    } catch {
      errorMessage = String(localized: "The plist could not be created. \(error.localizedDescription)")
    }
  }

  // MARK: - Notarization

  private func cancelActivity() {
    notarizationTask?.cancel()
  }

  /// Staples after Apple accepts. The ticket can take a moment to appear, so "not found" is retried.
  private func stapleAfterAcceptance(_ url: URL) async throws {
    for attempt in 1...4 {
      do {
        try await Stapler.staple(fileAt: url)
        return
      } catch StapleError.ticketNotFound where attempt < 4 {
        try await Task.sleep(for: .seconds(10))
      }
    }
  }

  private func packageToNotarize(in tree: FileTree, settings: ProjectSettings) -> PackageToNotarize? {
    guard settings.mode == .package, settings.includePackage, settings.packageOutput == .installerPackage,
      settings.notarizeAfterExport, !settings.signingIdentity.isEmpty,
      let file = tree.files.first(where: { $0.path == settings.packageFileName })
    else { return nil }
    return PackageToNotarize(name: settings.packageFileName, data: file.contents)
  }

  private func startNotarization(_ package: PackageToNotarize) {
    guard notarizationTask == nil else {
      errorMessage = String(
        localized: """
          A notarization is already running. Wait for it to finish, or cancel it from Notarizing in the toolbar.
          """
      )
      return
    }
    let credentials: NotaryCredentials
    do {
      guard let saved = try NotaryCredentialStore.load() else {
        errorMessage = NotaryError.notSignedIn.localizedDescription
        return
      }
      credentials = saved
    } catch {
      errorMessage = error.localizedDescription
      return
    }
    notarizationActivity = NotarizationActivity(packageName: package.name, startedAt: .now, phase: .uploading)
    notarizationTask = Task {
      do {
        let result = try await NotaryClient(credentials: credentials).notarize(package.data, name: package.name) {
          phase in
          await MainActor.run { notarizationActivity?.phase = phase }
        }
        var outcome = NotarizationOutcome(name: package.name, result: result)
        if result.status == .accepted, let fileURL = package.fileURL {
          notarizationActivity?.phase = .stapling
          do {
            try await stapleAfterAcceptance(fileURL)
            outcome.staple = .stapled
          } catch {
            if isCancellation(error) {
              outcome.staple = .notAttempted  // Notarized; the alert gives the stapler command for later.
            } else {
              logger.error("Stapling failed: \(error.localizedDescription, privacy: .public)")
              outcome.staple = .failed(error.localizedDescription)
            }
          }
        }
        logger.info(
          "Notarization of \(package.name, privacy: .public) finished: \(result.status.rawValue, privacy: .public)"
        )
        notarizationResult = outcome
        AppAttention.requestIfInactive()
      } catch {
        if isCancellation(error) || Task.isCancelled {
          logger.info("Notarization cancelled")
          if case .waiting(let submissionID) = notarizationActivity?.phase {
            notice = Notice(
              title: "Notarization Cancelled",
              message: """
                Apple already received the package and may still finish checking it. Check later with xcrun \
                notarytool info \(submissionID).
                """
            )
          }
        } else {
          logger.error("Notarization failed: \(error.localizedDescription, privacy: .public)")
          errorMessage = error.localizedDescription
          AppAttention.requestIfInactive()
        }
      }
      notarizationActivity = nil
      notarizationTask = nil
    }
  }

  private func notarizationMessage(_ outcome: NotarizationOutcome) -> String {
    let result = outcome.result
    switch result.status {
    case .accepted:
      let stapleCommand = "xcrun stapler staple \(Shell.quoted(outcome.name))"
      switch outcome.staple {
      case .stapled:
        return String(
          localized: """
            Apple notarized \(outcome.name), and LaunchdOps stapled the ticket to it, so Macs install it without a \
            warning even when offline.
            """
        )
      case .failed(let reason):
        return String(
          localized: """
            Apple notarized \(outcome.name), but the ticket could not be stapled. \(reason) The package still \
            installs on Macs that are online. To staple it later, run \(stapleCommand)
            """
        )
      case .notAttempted:
        return String(
          localized: """
            Apple notarized \(outcome.name). To let Macs that are offline install it without a warning, run \
            \(stapleCommand)
            """
        )
      }
    case .invalid, .rejected:
      let issues = result.issues.prefix(5).map { "• \($0)" }.joined(separator: "\n")
      return String(
        localized: """
          Apple did not notarize \(outcome.name): \(result.summary)

          \(issues)

          Submission ID: \(result.submissionID)
          """
      )
    }
  }

  private func copyPlist(inProject id: UUID) {
    if let job = library.project(id)?.jobs.first {
      copyPlist(of: job)
    }
  }

  private func copyPlist(for id: LaunchJob.ID) {
    if let job = project.job(withID: id) {
      copyPlist(of: job)
    }
  }

  private func copyPlist(of job: LaunchJob) {
    do {
      Pasteboard.copy(try job.renderedPlistXML())
    } catch {
      logger.error("Copying plist failed: \(error.localizedDescription, privacy: .public)")
      errorMessage = String(
        localized: """
          The plist could not be created. Check Additional Keys for values a property list can’t store, then try \
          again.
          """
      )
    }
  }

  private func handleExport(_ result: Result<URL, Error>) {
    // Saving a copy of the project is not a deployment, so labels are not marked as published.
    if case .success(let saved) = result {
      logger.info("Saved \(saved.lastPathComponent, privacy: .public)")
    }
    if case .success(let folder) = result, exportType != .launchdOpsProject {
      // Bookkeeping, not an edit: no undo step.
      if let id = exportedProjectID, var exported = library.project(id) {
        exported.markPublished(exported.jobs.map(\.label))
        library.apply(exported, to: id, undoManager: nil)
      }
      if var package = pendingNotarization {
        package.fileURL = folder.appending(path: package.name)
        startNotarization(package)
      }
    }
    clearPendingExport()
    if case .failure(let error) = result {
      logger.error("Saving export failed: \(error.localizedDescription, privacy: .public)")
      errorMessage = String(
        localized: """
          The files could not be saved. Choose another location and try again.

          \(error.localizedDescription)
          """
      )
    }
  }

  private func chosenProgramMessage(_ chosen: ChosenProgram) -> String {
    let path = chosen.url.path(percentEncoded: false)
    return String(
      localized: """
        \(path) exists only on this Mac. Add it to the payload so the package installs it with the job. Reference \
        the existing path only if the file is already at that path on every Mac, for example installed by another \
        package.
        """
    )
  }

  /// Forgets what the last save panel was for, so a later export can't notarize or mark an earlier one.
  private func clearPendingExport() {
    pendingNotarization = nil
    exportedProjectID = nil
    exportDocument = nil
  }
}
