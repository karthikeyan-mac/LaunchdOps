import SwiftUI

/// Every job in the library, one row each, grouped by type. Each job is its own project with its own export
/// settings, so selecting a row selects that project.
struct SidebarView: View {
  let library: ProjectLibrary
  @Binding var selection: UUID?
  let searchText: String
  /// The highest issue severity of each job, by library entry.
  let severities: [UUID: IssueSeverity]
  let onAddJob: () -> Void
  let onCopyPlist: (UUID) -> Void
  let onExportProject: (UUID) -> Void
  let onRename: (UUID) -> Void
  let onDuplicate: (UUID) -> Void
  let onDelete: (UUID) -> Void

  var body: some View {
    let visible = visibleEntries
    let daemons = visible.filter { $0.project.jobs.first?.context == .daemon }
    let agents = visible.filter { $0.project.jobs.first?.context == .globalAgent }
    let userAgents = visible.filter { $0.project.jobs.first?.context == .userAgent }

    List(selection: $selection) {
      if !daemons.isEmpty {
        Section("Launch Daemons") {
          rows(for: daemons)
        }
      }
      if !agents.isEmpty {
        Section("Launch Agents") {
          rows(for: agents)
        }
      }
      if !userAgents.isEmpty {
        Section("User Launch Agents") {
          rows(for: userAgents)
        }
      }
    }
    .overlay {
      if library.entries.isEmpty {
        ContentUnavailableView {
          Label("No Jobs", systemImage: "gearshape.2")
        } description: {
          Text("Click the Add button to create a launch daemon or agent.")
        }
      } else if visible.isEmpty {
        ContentUnavailableView.search(text: searchText)
      }
    }
    .onDeleteCommand {
      if let selection {
        onDelete(selection)
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      bottomBar
    }
  }

  private func rows(for entries: [ProjectLibrary.Entry]) -> some View {
    ForEach(entries) { entry in
      if let job = entry.project.jobs.first {
        JobRow(
          title: ProjectLibrary.displayName(of: entry.project),
          job: job,
          severity: severities[entry.id]
        )
        .tag(entry.id)
        .contextMenu {
          Button("Rename…") { onRename(entry.id) }
          Button("Duplicate", systemImage: "plus.square.on.square") { onDuplicate(entry.id) }
          Button("Copy Plist XML", systemImage: "doc.on.doc") { onCopyPlist(entry.id) }
          Button("Export Project…", systemImage: "square.and.arrow.up") { onExportProject(entry.id) }
          Divider()
          Button("Delete…", systemImage: "trash", role: .destructive) { onDelete(entry.id) }
        }
      }
    }
  }

  private var bottomBar: some View {
    VStack(spacing: 0) {
      Divider()
      HStack(spacing: 2) {
        Button("Add Job", systemImage: "plus") { onAddJob() }
          .help("Add Job (⌘N)")
        Button("Remove Job", systemImage: "minus") {
          if let selection {
            onDelete(selection)
          }
        }
        .help("Remove Job")
        .disabled(selection == nil)
        Spacer()
        Text("^[\(library.entries.count) job](inflect: true)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
      .padding(.horizontal, 10)
      .frame(height: 30)
    }
  }

  private var visibleEntries: [ProjectLibrary.Entry] {
    let query = searchText.trimmingCharacters(in: .whitespaces)
    guard !query.isEmpty else { return library.entries }
    return library.entries.filter { entry in
      ProjectLibrary.displayName(of: entry.project).localizedCaseInsensitiveContains(query)
        || entry.project.jobs.contains { $0.label.localizedCaseInsensitiveContains(query) }
    }
  }
}

private struct JobRow: View {
  /// The Project Name when set, otherwise the label.
  let title: String
  let job: LaunchJob
  let severity: IssueSeverity?

  var body: some View {
    HStack(spacing: 6) {
      Label {
        VStack(alignment: .leading, spacing: 1) {
          Text(title)
            .lineLimit(1)
            .truncationMode(.middle)
          if title != job.displayName {
            Text(job.displayName)
              .font(.caption)
              .foregroundStyle(.secondary)
              .monospaced()
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }
      } icon: {
        Image(systemName: job.context.systemImage)
      }
      Spacer(minLength: 4)
      if job.disabled {
        Text("Disabled")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if let severity, severity > .info {
        SeverityIcon(severity: severity)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityHint(job.context.title)
    .help("\(title), \(job.displayName), \(job.context.title)")
  }
}
