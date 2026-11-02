import SwiftUI

struct SeverityIcon: View {
  let severity: IssueSeverity

  var body: some View {
    Image(systemName: severity.systemImage)
      .foregroundStyle(color)
      .accessibilityLabel(severity.title)
      .help("\(severity.title): \(severity.guidance)")
  }

  private var color: Color {
    switch severity {
    case .info: .secondary
    case .warning: .orange
    case .error: .red
    }
  }
}

struct TextListSection: View {
  let title: LocalizedStringKey
  /// An example path or identifier, shown as is.
  let placeholder: String
  let addTitle: LocalizedStringKey
  var footer: LocalizedStringKey?
  @Binding var items: [TextItem]

  var body: some View {
    Section {
      ForEach($items) { $item in
        HStack {
          TextField(text: $item.value, prompt: Text(verbatim: placeholder)) {
            Text(title)
          }
          .labelsHidden()
          .accessibilityLabel(Text("\(Text(title)) \(position(of: item.id))"))
          RowMenu(
            canMoveUp: position(of: item.id) > 1,
            canMoveDown: position(of: item.id) < items.count,
            onMoveUp: { move(item.id, by: -1) },
            onMoveDown: { move(item.id, by: 1) },
            onRemove: { items.removeAll { $0.id == item.id } }
          )
        }
      }
      Button(addTitle, systemImage: "plus.circle") {
        items.append(TextItem(value: ""))
      }
      .buttonStyle(.borderless)
    } header: {
      Text(title)
    } footer: {
      if let footer {
        Text(footer)
      }
    }
  }

  private func position(of id: TextItem.ID) -> Int {
    (items.firstIndex { $0.id == id } ?? 0) + 1
  }

  private func move(_ id: TextItem.ID, by offset: Int) {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
    let target = index + offset
    guard items.indices.contains(target) else { return }
    items.swapAt(index, target)
  }
}

struct RowMenu: View {
  var canMoveUp = false
  var canMoveDown = false
  var onMoveUp: (() -> Void)?
  var onMoveDown: (() -> Void)?
  let onRemove: () -> Void

  var body: some View {
    HStack(spacing: 4) {
      if onMoveUp != nil || onMoveDown != nil {
        Menu {
          Button("Move Up", systemImage: "arrow.up") { onMoveUp?() }
            .disabled(!canMoveUp)
          Button("Move Down", systemImage: "arrow.down") { onMoveDown?() }
            .disabled(!canMoveDown)
        } label: {
          Label("Reorder", systemImage: "arrow.up.arrow.down")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .labelStyle(.iconOnly)
        .fixedSize()
        .help("Reorder")
      }
      Button("Remove", systemImage: "minus.circle", role: .destructive, action: onRemove)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .help("Remove")
    }
  }
}

struct ChoiceRow: View {
  let title: LocalizedStringKey
  let detail: LocalizedStringKey
  let isSelected: Bool
  let action: () -> Void

  // The plain button style doesn't dim a disabled row, so the row greys itself out.
  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    Button(action: action) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: isSelected ? "circle.inset.filled" : "circle")
          .foregroundStyle(isSelected && isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
          .padding(.top, 1)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .fontWeight(.semibold)
            .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
          Text(detail)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }
}

struct IncludeRow: View {
  let title: LocalizedStringKey
  let detail: LocalizedStringKey
  let systemImage: String
  let fileType: String
  @Binding var isOn: Bool

  var body: some View {
    Toggle(isOn: $isOn) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: systemImage)
          .foregroundStyle(.tint)
          .frame(width: 20)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .fontWeight(.semibold)
          Text(detail)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 8)
        Text(fileType)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
      }
    }
    .toggleStyle(.checkbox)
  }
}

/// A form row label followed by an info button. The button opens a popover with the description and, when
/// admins would search for it, the launchd key; hovering over the label shows the same description.
struct InfoLabel: View {
  /// A page with the full instructions, opened in the browser from the popover.
  struct HelpLink {
    let title: LocalizedStringKey
    let url: URL
  }

  private let title: Text
  private let info: Text
  private let key: String?
  private var steps: [LocalizedStringKey] = []
  private var link: HelpLink?

  @State private var isPresented = false

  init(_ title: LocalizedStringKey, info: LocalizedStringKey, key: String? = nil) {
    self.title = Text(title)
    self.info = Text(info)
    self.key = key
  }

  /// For settings that need setting up first: the popover lists the steps and links to Apple's instructions.
  init(_ title: LocalizedStringKey, info: LocalizedStringKey, steps: [LocalizedStringKey], link: HelpLink?) {
    self.title = Text(title)
    self.info = Text(info)
    self.key = nil
    self.steps = steps
    self.link = link
  }

  /// For a description built from model values.
  init(_ title: LocalizedStringKey, modelInfo: String, key: String? = nil) {
    self.title = Text(title)
    self.info = Text(modelInfo)
    self.key = key
  }

  /// For titles and descriptions that come from the model, such as enum values.
  init(title: String, info: String, key: String? = nil) {
    self.title = Text(title)
    self.info = Text(info)
    self.key = key
  }

  var body: some View {
    HStack(spacing: 4) {
      title
      Button {
        isPresented = true
      } label: {
        Label {
          Text("About \(title)")
        } icon: {
          Image(systemName: "info.circle")
        }
        .labelStyle(.iconOnly)
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.secondary)
      .help(Text("About \(title)"))
      .popover(isPresented: $isPresented, arrowEdge: .bottom) {
        VStack(alignment: .leading, spacing: 8) {
          info
            .fixedSize(horizontal: false, vertical: true)
          if !steps.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
              ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                  Text("\(index + 1).")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                  Text(step)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
              }
            }
            .font(.callout)
          }
          if let link {
            Link(destination: link.url) {
              Label(link.title, systemImage: "arrow.up.right.square")
            }
            .help(link.url.absoluteString)
          }
          if let key {
            Text("Key: \(key)")
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
        }
        .padding(12)
        .frame(width: steps.isEmpty ? 280 : 340, alignment: .leading)
      }
    }
    .help(info)
  }
}
