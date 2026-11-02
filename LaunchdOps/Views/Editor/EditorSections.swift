import SwiftUI

struct EnvironmentSection: View {
  @Binding var variables: [EnvironmentVariable]

  @State private var isTextSheetPresented = false

  var body: some View {
    Section {
      ForEach($variables) { $variable in
        HStack {
          TextField("Name", text: $variable.name, prompt: Text("NAME"))
            .labelsHidden()
            .accessibilityLabel("Variable name")
            .frame(maxWidth: 180)
          TextField("Value", text: $variable.value, prompt: Text("Value"))
            .labelsHidden()
            .accessibilityLabel("Value of \(variable.name)")
          RowMenu(onRemove: { variables.removeAll { $0.id == variable.id } })
        }
      }
      HStack {
        Button("Add Variable", systemImage: "plus.circle") {
          variables.append(EnvironmentVariable(name: "", value: ""))
        }
        Button("Add from Text…", systemImage: "text.alignleft") {
          isTextSheetPresented = true
        }
        .help("Paste several NAME=value lines at once")
      }
      .buttonStyle(.borderless)
    } header: {
      Text("Environment Variables")
    } footer: {
      Text("Plists are readable by every user on the Mac. Never store passwords or tokens here.")
    }
    .sheet(isPresented: $isTextSheetPresented) {
      EnvironmentTextSheet { EnvironmentVariable.merge($0, into: &variables) }
    }
  }
}

struct CalendarSection: View {
  @Binding var intervals: [CalendarInterval]

  @State private var editingID: CalendarInterval.ID?
  @State private var isCronSheetPresented = false

  var body: some View {
    Section {
      ForEach(intervals) { interval in
        HStack {
          Button {
            editingID = interval.id
          } label: {
            Label(interval.summary, systemImage: "calendar")
              .foregroundStyle(.primary)
          }
          .buttonStyle(.borderless)
          .accessibilityHint("Edits the schedule")
          .popover(isPresented: isEditing(interval.id), arrowEdge: .trailing) {
            if let binding = binding(for: interval.id) {
              CalendarIntervalEditor(interval: binding)
            }
          }
          Spacer()
          RowMenu(onRemove: { remove(interval.id) })
        }
        .contextMenu {
          Button("Edit…") { editingID = interval.id }
          Button("Duplicate") { duplicate(interval.id) }
          Button("Remove", role: .destructive) { remove(interval.id) }
        }
      }
      addButtons
    } header: {
      Text("Calendar Schedule")
    } footer: {
      Text("Runs missed while the Mac sleeps happen once on wake. If Day and Weekday are both set, either can match.")
    }
    .sheet(isPresented: $isCronSheetPresented) {
      CronExpressionSheet { intervals.append(contentsOf: $0) }
    }
  }

  private var addButtons: some View {
    HStack {
      Button("Add Custom Schedule…", systemImage: "plus.circle") {
        let interval = CalendarInterval(minute: 0, hour: 9)
        intervals.append(interval)
        editingID = interval.id
      }
      Button("Add from Cron Expression…", systemImage: "chevron.left.forwardslash.chevron.right") {
        isCronSheetPresented = true
      }
      .help("Convert a crontab schedule such as 0 9 * * 1-5 into calendar schedules")
    }
    .buttonStyle(.borderless)
  }

  private func duplicate(_ id: CalendarInterval.ID) {
    guard let index = intervals.firstIndex(where: { $0.id == id }) else { return }
    var copy = intervals[index]
    copy.id = UUID()
    intervals.insert(copy, at: index + 1)
  }

  private func remove(_ id: CalendarInterval.ID) {
    editingID = nil
    intervals.removeAll { $0.id == id }
  }

  private func isEditing(_ id: CalendarInterval.ID) -> Binding<Bool> {
    Binding(
      get: { editingID == id },
      set: { if !$0 { editingID = nil } }
    )
  }

  private func binding(for id: CalendarInterval.ID) -> Binding<CalendarInterval>? {
    guard let current = intervals.first(where: { $0.id == id }) else { return nil }
    return Binding(
      get: { intervals.first { $0.id == id } ?? current },
      set: { newValue in
        if let index = intervals.firstIndex(where: { $0.id == id }) {
          intervals[index] = newValue
        }
      }
    )
  }
}

private struct CalendarIntervalEditor: View {
  @Binding var interval: CalendarInterval

  private let number = IntegerFormatStyle<Int>().grouping(.never)

  var body: some View {
    Form {
      Section {
        TextField("Minute", value: $interval.minute, format: number, prompt: Text("Any (0–59)"))
        TextField("Hour", value: $interval.hour, format: number, prompt: Text("Any (0–23)"))
        TextField("Day of Month", value: $interval.day, format: number, prompt: Text("Any (1–31)"))
        Picker("Weekday", selection: $interval.weekday) {
          Text("Any").tag(Int?.none)
          ForEach(0..<7, id: \.self) { day in
            Text(Calendar.current.weekdaySymbols[day]).tag(Int?.some(day))
          }
          if interval.weekday == 7 {
            Text("Sunday (7)").tag(Int?.some(7))
          }
        }
        Picker("Month", selection: $interval.month) {
          Text("Any").tag(Int?.none)
          ForEach(1...12, id: \.self) { month in
            Text(Calendar.current.monthSymbols[month - 1]).tag(Int?.some(month))
          }
        }
      } footer: {
        Text(interval.summary)
      }
    }
    .formStyle(.grouped)
    .frame(width: 340)
    .fixedSize(horizontal: false, vertical: true)
  }
}

struct KeepAliveSection: View {
  @Binding var keepAlive: KeepAlive

  // Editor state only: keeps the full condition editor open after the user picks it, even while the
  // conditions still match the simpler "After a Crash" choice.
  @State private var showsConditions = false

  private enum Choice: Hashable {
    case off
    case always
    case afterCrash
    case conditional
  }

  private var choice: Binding<Choice> {
    Binding(
      get: {
        switch keepAlive.mode {
        case .off: .off
        case .always: .always
        case .conditional: keepAlive.isCrashOnly && !showsConditions ? .afterCrash : .conditional
        }
      },
      set: { newChoice in
        switch newChoice {
        case .off:
          keepAlive.mode = .off
        case .always:
          keepAlive.mode = .always
        case .afterCrash:
          keepAlive = KeepAlive(mode: .conditional, crashed: true)
          showsConditions = false
        case .conditional:
          keepAlive.mode = .conditional
          showsConditions = true
        }
      }
    )
  }

  var body: some View {
    Section {
      Picker(selection: choice) {
        Text("Off").tag(Choice.off)
        Text("Always").tag(Choice.always)
        Text("After a Crash").tag(Choice.afterCrash)
        Text("When Conditions Match").tag(Choice.conditional)
      } label: {
        InfoLabel("Keep Alive", info: "Whether launchd restarts the job after it exits.", key: "KeepAlive")
      }
      if choice.wrappedValue == .conditional {
        Picker(selection: $keepAlive.successfulExit) {
          Text("Not Used").tag(Bool?.none)
          Text("Restart after a successful exit").tag(Bool?.some(true))
          Text("Restart after a failed exit").tag(Bool?.some(false))
        } label: {
          InfoLabel(
            "Exit Status",
            info: "Restarts the job depending on whether it exited with status 0.",
            key: "SuccessfulExit"
          )
        }
        Picker(selection: $keepAlive.crashed) {
          Text("Not Used").tag(Bool?.none)
          Text("Restart after a crash").tag(Bool?.some(true))
          Text("Restart unless it crashed").tag(Bool?.some(false))
        } label: {
          InfoLabel("Crashes", info: "Restarts the job depending on whether it crashed.", key: "Crashed")
        }
        ForEach($keepAlive.pathStates) { $state in
          HStack {
            TextField("Path", text: $state.path, prompt: Text("/path/to/file"))
              .labelsHidden()
              .accessibilityLabel("Path condition")
            Picker("Condition", selection: $state.keepAliveWhenExists) {
              Text("Exists").tag(true)
              Text("Missing").tag(false)
            }
            .labelsHidden()
            .fixedSize()
            .help("Keeps the job running while the path exists, or while it is missing.")
            RowMenu(onRemove: { keepAlive.pathStates.removeAll { $0.id == state.id } })
          }
        }
        Button("Add Path Condition", systemImage: "plus.circle") {
          keepAlive.pathStates.append(PathStateCondition(path: "", keepAliveWhenExists: true))
        }
        .buttonStyle(.borderless)
        if !keepAlive.otherKeys.isEmpty {
          LabeledContent("Preserved Keys", value: keepAlive.otherKeys.keys.sorted().joined(separator: ", "))
        }
      }
    } header: {
      Text("Keep Alive")
    } footer: {
      Text(footer)
    }
  }

  private var footer: LocalizedStringKey {
    switch choice.wrappedValue {
    case .off: "The job runs only when a trigger starts it."
    case .always: "launchd restarts the job whenever it exits. This implies Run at Load."
    case .afterCrash:
      """
      launchd restarts the job when it exits because of a crash signal, such as SIGSEGV. This implies Run at Load. \
      Choosing this removes other Keep Alive conditions.
      """
    case .conditional: "launchd restarts the job when any condition matches. This implies Run at Load."
    }
  }
}

struct AdditionalKeysSection: View {
  @Binding var keys: [String: PlistValue]

  var body: some View {
    if !keys.isEmpty {
      Section {
        ForEach(keys.keys.sorted(), id: \.self) { key in
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              Text(key)
                .monospaced()
              Text("\(keys[key]?.typeName ?? "") · \(keys[key]?.summary ?? "")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            // Only the key and its value read as one item, so Remove stays its own button.
            .accessibilityElement(children: .combine)
            Spacer()
            RowMenu(onRemove: { keys[key] = nil })
          }
        }
      } header: {
        Text("Additional Keys")
      } footer: {
        Text("Keys LaunchdOps does not edit are kept exactly as imported.")
      }
    }
  }
}
