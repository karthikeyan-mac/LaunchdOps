import Foundation

/// A short checklist of what an export will produce and what still needs attention, for the Export tab.
/// Built from the project with Settings ▸ Signing already applied, and its validation issues.
struct ExportReadiness: Equatable, Sendable {
  enum State: Equatable, Sendable {
    case ready
    /// Exports, but review before deploying.
    case attention
    /// Must be fixed first.
    case blocked
  }

  struct Item: Identifiable, Equatable, Sendable {
    let title: String
    let detail: String
    let state: State

    var id: String { title }
  }

  let items: [Item]

  var state: State {
    if items.contains(where: { $0.state == .blocked }) { return .blocked }
    if items.contains(where: { $0.state == .attention }) { return .attention }
    return .ready
  }

  var headline: String {
    switch state {
    case .ready: "Ready to export"
    case .attention: "Ready to export, with items to review"
    case .blocked: "Fix the errors before deploying"
    }
  }

  init(project: Project, issues: [ValidationIssue]) {
    let settings = project.settings
    var items = [Self.validationItem(issues)]

    switch settings.mode {
    case .package where settings.includePackage:
      switch settings.packageOutput {
      case .installerPackage:
        if settings.signingIdentity.isEmpty {
          items.append(
            Item(
              title: "Package",
              detail: "Not signed. MDMs install only signed packages; choose an identity in Settings ▸ Signing.",
              state: .attention
            ))
        } else {
          items.append(Item(title: "Package", detail: "Signed with Developer ID Installer", state: .ready))
          items.append(
            settings.notarizeAfterExport
              ? Item(title: "Notarization", detail: "Notarized and stapled after export", state: .ready)
              : Item(
                title: "Notarization", detail: "Not notarized. Notarize it before deploying outside MDM.",
                state: .attention
              ))
        }
      case .buildScript:
        items.append(
          Item(title: "Package", detail: "Build and sign it on your Mac with build-pkg.sh", state: .attention))
      }
    case .package:
      items.append(Item(title: "Package", detail: "Not included; install the files another way", state: .attention))
    case .declarative:
      items.append(
        Item(
          title: "Background Task",
          detail: "Host the assets on a web server, then give the declarations to your MDM",
          state: .attention
        ))
    }

    if settings.includeLoginItemsProfile {
      items.append(
        settings.profileSigningIdentity.isEmpty
          ? Item(title: "Profile", detail: "Not signed; optional when your MDM delivers it", state: .ready)
          : Item(title: "Profile", detail: "Signed", state: .ready))
    }

    let payloadCount = project.payload.count
    if payloadCount > 0 {
      items.append(
        Item(
          title: "Payload",
          detail: payloadCount == 1 ? "1 file" : "\(payloadCount) files",
          state: .ready
        ))
    }
    self.items = items
  }

  private static func validationItem(_ issues: [ValidationIssue]) -> Item {
    let blocking = issues.blocking.count
    let errors = issues.errorCount
    let warnings = issues.warningCount
    if blocking > 0 {
      return Item(
        title: "Validation",
        detail: blocking == 1 ? "1 unsafe value stops the export" : "\(blocking) unsafe values stop the export",
        state: .blocked
      )
    }
    if errors > 0 {
      return Item(
        title: "Validation", detail: errors == 1 ? "1 error to fix" : "\(errors) errors to fix", state: .blocked)
    }
    if warnings > 0 {
      return Item(
        title: "Validation",
        detail: warnings == 1 ? "1 warning to review" : "\(warnings) warnings to review",
        state: .attention
      )
    }
    return Item(title: "Validation", detail: "No errors or warnings", state: .ready)
  }
}
