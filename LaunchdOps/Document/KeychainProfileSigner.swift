import Foundation
import Security

/// Signs a configuration profile: CMS signed data that contains the profile.
protocol ProfileSigner: Sendable {
  func signedProfile(_ profile: Data) throws -> Data
}

enum ProfileSigningError: LocalizedError {
  case signingDenied
  case signingFailed(String)

  var errorDescription: String? {
    switch self {
    case .signingDenied:
      "Signing the profile was not allowed. Export again and click Allow (or Always Allow), or set the profile’s "
        + "Signing Identity to Don’t Sign."
    case .signingFailed(let reason):
      "The profile could not be signed. \(reason) Check the identity in Keychain Access, or set the profile’s "
        + "Signing Identity to Don’t Sign."
    }
  }
}

/// Signs profiles with a keychain identity. macOS asks the user to allow use of the private key; the key never
/// leaves the keychain. No signing time is added, so with an RSA key the same profile and identity give the same
/// bytes; ECDSA signatures differ on every export.
///
/// `@unchecked Sendable`: the stored identity is an immutable CF reference, and CMS encoding is safe to run from
/// any thread.
final class KeychainProfileSigner: ProfileSigner, @unchecked Sendable {
  private let identity: SecIdentity

  init(identityName: String) throws {
    Log.signing.info("Signing the profile with \(identityName, privacy: .private)")
    identity = try SigningIdentities.identity(named: identityName)
  }

  func signedProfile(_ profile: Data) throws -> Data {
    var encoder: CMSEncoder?
    try check(CMSEncoderCreate(&encoder))
    guard let encoder else { throw ProfileSigningError.signingFailed("The CMS encoder could not be created.") }
    try check(CMSEncoderAddSigners(encoder, identity))
    try check(CMSEncoderSetCertificateChainMode(encoder, .chain))
    try profile.withUnsafeBytes { buffer in
      guard let base = buffer.baseAddress else { return }
      try check(CMSEncoderUpdateContent(encoder, base, buffer.count))
    }
    var encoded: CFData?
    try check(CMSEncoderCopyEncodedContent(encoder, &encoded))
    guard let encoded else { throw ProfileSigningError.signingFailed("The signed profile is empty.") }
    return encoded as Data
  }

  private func check(_ status: OSStatus) throws {
    guard status == errSecSuccess else {
      if PackageSigningError.isDenial(status) { throw ProfileSigningError.signingDenied }
      let message = SecCopyErrorMessageString(status, nil) as String? ?? "Error \(status)."
      throw ProfileSigningError.signingFailed(message)
    }
  }
}
