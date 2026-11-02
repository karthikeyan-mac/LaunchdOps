import SwiftUI

/// LaunchdOps ▸ Settings ▸ Signing: how every job's package and profile are signed and notarized.
struct SigningSettingsView: View {
  @StoredSigningPreferences private var signing

  // Keychain identity names for the pickers; read once per appearance, not project data.
  @State private var installerNames: Result<[String], Error> = .success([])
  @State private var profileNames: Result<[String], Error> = .success([])
  @State private var hasNotaryKey = false
  @State private var isNotaryKeyPresented = false

  var body: some View {
    Form {
      packageSection
      profileSection
    }
    .formStyle(.grouped)
    .frame(width: 520)
    .fixedSize(horizontal: false, vertical: true)
    .task {
      installerNames = await Task.detached(priority: .utility) {
        Result { try SigningIdentities.installerIdentityNames() }
      }.value
      profileNames = await Task.detached(priority: .utility) {
        Result { try SigningIdentities.profileIdentityNames() }
      }.value
      hasNotaryKey = NotaryCredentialStore.exists()
    }
    .sheet(isPresented: $isNotaryKeyPresented) {
      NotaryCredentialsSheet { hasNotaryKey = NotaryCredentialStore.exists() }
    }
  }

  private var packageSection: some View {
    Section {
      Toggle(isOn: signsPackage) {
        InfoLabel(
          "Sign the Package",
          info: """
            Signs every job’s installer package with a Developer ID Installer certificate from your keychain. \
            To get one:
            """,
          steps: [
            "Only the Account Holder of your Apple Developer team can create it (up to five per team).",
            "At developer.apple.com, open Certificates, Identifiers & Profiles ▸ Certificates and click +.",
            """
            Choose Developer ID, then Developer ID Installer, and upload a certificate signing request made with \
            Keychain Access ▸ Certificate Assistant.
            """,
            """
            Download the certificate and double-click it on the Mac that made the request. It appears in Keychain \
            Access ▸ My Certificates with its private key.
            """,
          ],
          link: SigningHelp.developerID
        )
      }
      if signing.signsPackage {
        IdentityPicker(
          title: "Signing Identity",
          info: """
            Developer ID Installer certificates in your keychain that have their private key. If yours is \
            missing:
            """,
          steps: [
            "Open Keychain Access ▸ My Certificates and check that the certificate shows a private key under it.",
            """
            A certificate made on another Mac needs its private key: on that Mac, export the certificate as a .p12 \
            file from My Certificates, then double-click the file here.
            """,
            "Expired certificates aren’t listed. Create a new one; packages signed earlier stay valid.",
          ],
          link: SigningHelp.developerID,
          selection: $signing.packageIdentity,
          names: installerNames
        )
        Toggle(isOn: $signing.notarizeAfterExport) {
          InfoLabel(
            "Notarize After Export",
            info: """
              Apple checks the signed package for malicious software, so Macs open it without a warning, even \
              when a person double-clicks a downloaded copy. MDM installs don’t need it.
              """,
            steps: [
              "Choose a Signing Identity and set up the Notarization Key below.",
              "After Export Folder… saves the folder, LaunchdOps uploads the package to Apple.",
              """
              Apple usually answers within a few minutes. Notarizing in the toolbar shows each step; you can keep \
              working.
              """,
              """
              When Apple accepts it, LaunchdOps staples the ticket to the .pkg, so it also installs on Macs that \
              are offline.
              """,
            ],
            link: SigningHelp.notarization
          )
        }
        .disabled(signing.packageIdentity.isEmpty)
        if signing.notarizeAfterExport {
          LabeledContent {
            HStack {
              Text(hasNotaryKey ? "Saved in keychain" : "Not set up")
                .foregroundStyle(.secondary)
              Button(hasNotaryKey ? "Change…" : "Set Up…") { isNotaryKeyPresented = true }
            }
          } label: {
            InfoLabel(
              "Notarization Key",
              info: """
                An App Store Connect API key lets LaunchdOps send packages to Apple. It’s saved only in your \
                keychain. To create a team key:
                """,
              steps: [
                """
                In App Store Connect, open Users and Access ▸ Integrations ▸ Team Keys. You need the Account Holder \
                or Admin role.
                """,
                "Click Generate API Key (or +), enter a name, choose the Developer role, and click Generate.",
                "Download the .p8 file. Apple lets you download it only once, so keep it safe.",
                "Note the Key ID in the list and the Issuer ID above it, then click Set Up… here and enter them.",
              ],
              link: SigningHelp.apiKeys
            )
          }
        }
      }
    } header: {
      Text("Installer Package")
    } footer: {
      Text(packageFooter)
    }
  }

  private var packageFooter: LocalizedStringKey {
    guard signing.signsPackage else {
      return """
        Some deployment tools install unsigned packages; many MDMs and InstallEnterpriseApplication need a signed \
        one.
        """
    }
    return """
      Applies to every job, and build-pkg.sh signs with it too. macOS asks before LaunchdOps uses your signing key; \
      choose Always Allow to skip the repeats. Notarization usually takes a few minutes.
      """
  }

  private var profileSection: some View {
    Section {
      Toggle(isOn: $signing.signsProfile) {
        InfoLabel(
          "Sign the Profile",
          info: "Signs the Managed Login Items profile with an identity from your keychain."
        )
      }
      if signing.signsProfile {
        IdentityPicker(
          title: "Signing Identity",
          info: """
            Any Developer ID Application, Apple Development or Apple Distribution certificate in your keychain \
            that has its private key. If you have none:
            """,
          steps: [
            "In Xcode, open Settings ▸ Accounts, select your team and click Manage Certificates.",
            "Click + and choose Apple Development (any team member can create one).",
            "The certificate appears in Keychain Access ▸ My Certificates and in this list.",
          ],
          link: SigningHelp.certificates,
          selection: $signing.profileIdentity,
          names: profileNames
        )
      }
    } header: {
      Text("Managed Login Items Profile")
    } footer: {
      Text(
        """
        A signed profile shows as verified when installed by hand. MDM delivery doesn’t need a signature; check \
        that your MDM accepts signed profiles before uploading one.
        """
      )
    }
  }

  /// Turning signing off also turns notarization off, because Apple notarizes only signed packages.
  private var signsPackage: Binding<Bool> {
    Binding(
      get: { signing.signsPackage },
      set: { isOn in
        signing.signsPackage = isOn
        if !isOn {
          signing.notarizeAfterExport = false
        }
      }
    )
  }
}

/// Apple's instructions, opened in the browser from the ⓘ popovers.
@MainActor
private enum SigningHelp {
  static let developerID = link(
    "Creating Developer ID Certificates",
    "https://developer.apple.com/help/account/certificates/create-developer-id-certificates/"
  )
  static let certificates = link(
    "Certificates Overview",
    "https://developer.apple.com/help/account/certificates/certificates-overview/"
  )
  static let notarization = link(
    "Notarizing macOS Software Before Distribution",
    "https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution"
  )
  static let apiKeys = link(
    "App Store Connect API Keys",
    "https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api"
  )

  private static func link(_ title: LocalizedStringKey, _ address: String) -> InfoLabel.HelpLink? {
    URL(string: address).map { InfoLabel.HelpLink(title: title, url: $0) }
  }
}

/// A keychain identity picker that keeps a chosen identity even when it is no longer in the keychain.
private struct IdentityPicker: View {
  let title: LocalizedStringKey
  let info: LocalizedStringKey
  let steps: [LocalizedStringKey]
  let link: InfoLabel.HelpLink?
  @Binding var selection: String
  let names: Result<[String], Error>

  var body: some View {
    let available = (try? names.get()) ?? []  // A read failure is shown below the picker.
    Picker(selection: $selection) {
      Text("Choose an Identity").tag("")
      ForEach(available, id: \.self) { name in
        Text(name).tag(name)
      }
      if !selection.isEmpty && !available.contains(selection) {
        Text("\(selection) (expired or not in keychain)").tag(selection)
      }
    } label: {
      InfoLabel(title, info: info, steps: steps, link: link)
    }
    if case .success(let found) = names, found.isEmpty {
      Label {
        Text("No matching identities in your keychain. Add your Developer ID certificate in Keychain Access or Xcode.")
      } icon: {
        SeverityIcon(severity: .warning)
      }
    } else if case .failure(let error) = names {
      Label {
        Text("Signing identities could not be read. \(error.localizedDescription)")
      } icon: {
        SeverityIcon(severity: .error)
      }
    }
  }
}
