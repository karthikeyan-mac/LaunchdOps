import Foundation

/// Signing and notarization choices from LaunchdOps ▸ Settings. They apply to every job, so they are app
/// preferences rather than project data; `applied(to:)` copies them into a project before it is validated or
/// exported.
///
/// Each choice is its own key in the app's preferences plist (see `Key`), so admins can read or set it with
/// `defaults` or a configuration profile.
struct SigningPreferences: Hashable, Sendable {
  enum Key {
    static let signsPackage = "SignPackage"
    static let packageIdentity = "PackageSigningIdentity"
    static let notarizeAfterExport = "NotarizeAfterExport"
    static let signsProfile = "SignProfile"
    static let profileIdentity = "ProfileSigningIdentity"
    /// One JSON string written by earlier development builds; read once by `migrateLegacyValue(in:)`.
    static let legacyJSON = "SigningPreferences"
  }

  /// Settings ▸ Signing ▸ Sign the Package. Turning it off keeps the chosen identity for next time.
  var signsPackage = false
  /// Developer ID Installer identity from the keychain. It signs finished packages and is written into
  /// build-pkg.sh, which also accepts a different identity in `SIGN_IDENTITY` when it runs.
  var packageIdentity = ""
  var notarizeAfterExport = false
  var signsProfile = false
  /// Identity that signs the Managed Login Items profile.
  var profileIdentity = ""

  init() {}

  init(defaults: UserDefaults) {
    signsPackage = defaults.bool(forKey: Key.signsPackage)
    packageIdentity = defaults.string(forKey: Key.packageIdentity) ?? ""
    notarizeAfterExport = defaults.bool(forKey: Key.notarizeAfterExport)
    signsProfile = defaults.bool(forKey: Key.signsProfile)
    profileIdentity = defaults.string(forKey: Key.profileIdentity) ?? ""
  }

  func save(to defaults: UserDefaults) {
    defaults.set(signsPackage, forKey: Key.signsPackage)
    defaults.set(packageIdentity, forKey: Key.packageIdentity)
    defaults.set(notarizeAfterExport, forKey: Key.notarizeAfterExport)
    defaults.set(signsProfile, forKey: Key.signsProfile)
    defaults.set(profileIdentity, forKey: Key.profileIdentity)
  }

  /// The choices a project made before signing moved to Settings.
  init(migrating settings: ProjectSettings) {
    packageIdentity = settings.signingIdentity
    notarizeAfterExport = settings.notarizeAfterExport
    profileIdentity = settings.profileSigningIdentity
    signsPackage = !settings.signingIdentity.isEmpty
    signsProfile = !profileIdentity.isEmpty
  }

  /// Moves the single JSON value from earlier development builds into separate keys, then removes it.
  static func migrateLegacyValue(in defaults: UserDefaults) {
    guard let json = defaults.string(forKey: Key.legacyJSON) else { return }
    defaults.removeObject(forKey: Key.legacyJSON)
    // An unreadable old value is dropped: the defaults (unsigned) are safe and Settings shows them.
    guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
      let values = object as? [String: Any]
    else { return }
    var migrated = SigningPreferences()
    let packageIdentity = values["packageIdentity"] as? String ?? ""
    let buildScriptIdentity = values["buildScriptIdentity"] as? String ?? ""
    migrated.packageIdentity = packageIdentity.isEmpty ? buildScriptIdentity : packageIdentity
    migrated.notarizeAfterExport = values["notarizeAfterExport"] as? Bool ?? false
    migrated.profileIdentity = values["profileIdentity"] as? String ?? ""
    // Saved before the switches existed: an identity meant signing was on.
    migrated.signsPackage = values["signsPackage"] as? Bool ?? !migrated.packageIdentity.isEmpty
    migrated.signsProfile = values["signsProfile"] as? Bool ?? !migrated.profileIdentity.isEmpty
    migrated.save(to: defaults)
  }

  var isEmpty: Bool {
    self == SigningPreferences()
  }

  func applied(to project: Project) -> Project {
    var project = project
    project.settings.signingIdentity = signsPackage ? packageIdentity : ""
    // Apple notarizes only signed finished packages.
    project.settings.notarizeAfterExport =
      notarizeAfterExport && signsPackage && !packageIdentity.isEmpty
      && project.settings.packageOutput == .installerPackage
    project.settings.profileSigningIdentity = signsProfile ? profileIdentity : ""
    return project
  }
}
