import OSLog
import SwiftUI
import UniformTypeIdentifiers

/// Sets up the App Store Connect API key used for notarization. The key is saved only in the keychain.
struct NotaryCredentialsSheet: View {
  let onSaved: () -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var issuerID = ""
  @State private var keyID = ""
  @State private var privateKeyPEM = ""
  @State private var keyFileName = ""
  @State private var isImporterPresented = false
  @State private var hasSavedKey = false
  @State private var errorMessage: String?
  @State private var isConfirmingRemove = false

  private let logger = Log.notarization

  private var credentials: NotaryCredentials {
    NotaryCredentials(
      issuerID: issuerID.trimmingCharacters(in: .whitespacesAndNewlines),
      keyID: keyID.trimmingCharacters(in: .whitespacesAndNewlines),
      privateKeyPEM: privateKeyPEM
    )
  }

  private var validationError: NotaryCredentials.ValidationError? {
    do {
      try credentials.validate()
      return nil
    } catch {
      return error
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Notarization Key")
          .font(.headline)
        Text(
          "LaunchdOps notarizes packages with a team key from App Store Connect ▸ Users and Access ▸ Integrations ▸ Team Keys. Give it the Developer role. Individual keys can't notarize."
        )
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }

      Form {
        TextField("Issuer ID", text: $issuerID, prompt: Text("57246542-96fe-1a63-e053-0824d011072a"))
          .monospaced()
        TextField("Key ID", text: $keyID, prompt: Text("2X9R4HXF34"))
          .monospaced()
        LabeledContent("Key File") {
          HStack {
            Text(keyFileName.isEmpty ? "None" : keyFileName)
              .monospaced()
              .foregroundStyle(keyFileName.isEmpty ? .secondary : .primary)
            Button("Choose…") { isImporterPresented = true }
          }
        }
      }
      .formStyle(.grouped)
      .fixedSize(horizontal: false, vertical: true)

      feedback

      HStack {
        if hasSavedKey {
          Button("Remove Saved Key…", role: .destructive) { isConfirmingRemove = true }
        }
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Save") { save() }
          .keyboardShortcut(.defaultAction)
          .disabled(validationError != nil)
      }
    }
    .padding(24)
    .frame(width: 520)
    .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.item]) { result in
      importKey(result)
    }
    .task { loadSaved() }
    .confirmationDialog("Remove the saved notarization key?", isPresented: $isConfirmingRemove) {
      Button("Remove Key", role: .destructive) { remove() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("App Store Connect lets you download a key file only once. Keep a copy of the .p8 file before removing it.")
    }
  }

  @ViewBuilder
  private var feedback: some View {
    if let errorMessage {
      Label(errorMessage, systemImage: "xmark.octagon.fill")
        .font(.caption)
        .foregroundStyle(.red)
        .fixedSize(horizontal: false, vertical: true)
    } else if let validationError, !(issuerID.isEmpty && keyID.isEmpty && privateKeyPEM.isEmpty) {
      Label(validationError.localizedDescription, systemImage: "xmark.octagon.fill")
        .font(.caption)
        .foregroundStyle(.red)
        .fixedSize(horizontal: false, vertical: true)
    } else {
      Text("Saved only in your keychain, never in the project file. Used only to talk to Apple’s notary service.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private func loadSaved() {
    do {
      guard let saved = try NotaryCredentialStore.load() else { return }
      issuerID = saved.issuerID
      keyID = saved.keyID
      privateKeyPEM = saved.privateKeyPEM
      keyFileName = "Saved in keychain"
      hasSavedKey = true
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func importKey(_ result: Result<URL, Error>) {
    errorMessage = nil
    switch result {
    case .success(let url):
      do {
        let data = try SecureFileReader.read(url, limit: 16 * 1024)
        privateKeyPEM = String(decoding: data, as: UTF8.self)
        keyFileName = url.lastPathComponent
        // AuthKey_<KeyID>.p8 carries the key ID; fill it in when the field is empty.
        if keyID.isEmpty, let match = url.lastPathComponent.firstMatch(of: /AuthKey_([A-Z0-9]{10})\.p8/) {
          keyID = String(match.output.1)
        }
      } catch {
        logger.error("Reading the key file failed: \(error.localizedDescription, privacy: .public)")
        errorMessage = "The key file could not be read. \(error.localizedDescription)"
      }
    case .failure(let error):
      errorMessage = error.localizedDescription
    }
  }

  private func save() {
    do {
      try NotaryCredentialStore.save(credentials)
      onSaved()
      dismiss()
    } catch {
      logger.error("Saving the notarization key failed: \(error.localizedDescription, privacy: .public)")
      errorMessage = error.localizedDescription
    }
  }

  private func remove() {
    do {
      try NotaryCredentialStore.delete()
      onSaved()
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}
