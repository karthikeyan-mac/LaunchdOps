import Foundation

extension Project {
  /// A copy for Project ▸ Duplicate Job. Everything that identifies the job on a Mac or in an MDM is new (label,
  /// package identifier, task type, profile UUIDs), so installing the copy never replaces the original. The copy
  /// has never been exported, so it has no published or retired labels.
  func duplicated(existingLabels: Set<String>) -> Project {
    var copy = self
    var labels = existingLabels
    copy.jobs = jobs.map { job in
      var job = job
      job.id = UUID()
      job.label = Self.copyLabel(for: job.label, avoiding: labels)
      labels.insert(job.label)
      return job
    }
    copy.payload = payload.map { file in
      var file = file
      file.id = UUID()
      return file
    }
    copy.settings.name = settings.name.isEmpty ? "" : "\(settings.name) Copy"
    // Empty follows the new label.
    copy.settings.packageIdentifier = ""
    if !settings.taskType.isEmpty {
      copy.settings.taskType = copy.jobs.first?.label ?? ""
    }
    copy.settings.retiredLabels = []
    copy.settings.publishedLabels = []
    copy.settings.profileUUID = UUID()
    copy.settings.profilePayloadUUID = UUID()
    return copy
  }

  /// `<label>.copy`, then `<label>.copy2`, `<label>.copy3`… until it is unused.
  static func copyLabel(for label: String, avoiding labels: Set<String>) -> String {
    let base = label.isEmpty ? "untitled" : label
    var candidate = "\(base).copy"
    var number = 2
    while labels.contains(candidate) {
      candidate = "\(base).copy\(number)"
      number += 1
    }
    return candidate
  }

  /// Largest plist Project ▸ New Job from Clipboard reads.
  static let maximumClipboardPlistSize = 1024 * 1024

  enum ClipboardError: LocalizedError, Equatable {
    case empty
    case tooLarge
    case notLaunchdPlist

    var errorDescription: String? {
      switch self {
      case .empty:
        "The clipboard has no text. Copy the plist XML (for example from a text editor or Terminal), then try again."
      case .tooLarge:
        "The clipboard text is larger than 1 MB, which is too large for a launchd plist."
      case .notLaunchdPlist:
        "The clipboard doesn’t contain a launchd property list. Copy the whole plist, from <?xml … to </plist>, "
          + "and make sure it has a Label."
      }
    }
  }

  /// A one-job project from plist XML on the clipboard. Keys LaunchdOps doesn't edit are kept, as with file
  /// import. Without a file path to go by, a plist that limits itself to login sessions becomes an agent for all
  /// users and anything else a daemon; the type can be changed on General.
  static func fromClipboard(_ text: String?) throws -> Project {
    guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ClipboardError.empty }
    let data = Data(text.utf8)
    guard data.count <= maximumClipboardPlistSize else { throw ClipboardError.tooLarge }
    let dictionary: [String: PlistValue]
    do {
      dictionary = try PropertyListCoding.dictionary(from: data)
    } catch {
      throw ClipboardError.notLaunchdPlist
    }
    guard dictionary["Label"] != nil else { throw ClipboardError.notLaunchdPlist }
    let context: JobContext = dictionary["LimitLoadToSessionType"] != nil ? .globalAgent : .daemon
    let job = LaunchJob(dictionary: dictionary, context: context)
    var project = Project()
    project.jobs = [job]
    // Like an imported file, a copied plist may already be installed on Macs.
    project.markPublished([job.label])
    return project
  }
}
