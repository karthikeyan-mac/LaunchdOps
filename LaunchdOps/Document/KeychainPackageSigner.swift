import Foundation
import Security
import Synchronization

enum PackageSigningError: LocalizedError {
  case identityNotFound(String)
  case unsupportedKey
  case keychain(OSStatus)
  case signingDenied
  case signingFailed(String)

  /// Status codes macOS returns when the user clicks Deny or cancels the key-access prompt.
  static func isDenial(_ status: OSStatus) -> Bool {
    status == errSecUserCanceled || status == errSecAuthFailed
  }

  var errorDescription: String? {
    switch self {
    case .identityNotFound(let name):
      "The signing identity “\(name)” is not in your keychain. Choose another identity in LaunchdOps ▸ Settings, or Don’t Sign."
    case .unsupportedKey:
      "The signing identity does not use an RSA key. Choose a Developer ID Installer identity."
    case .keychain(let status):
      "The keychain could not be read (\(SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)")). "
        + "Check the identity in Keychain Access, or choose Don’t Sign in LaunchdOps ▸ Settings."
    case .signingDenied:
      "Signing was not allowed. Export again and click Allow (or Always Allow), or choose Don’t Sign."
    case .signingFailed(let reason):
      "The package could not be signed. \(reason)"
    }
  }
}

/// Signing identities in the user's keychains, found by certificate common name.
enum SigningIdentities {
  private static let installerPrefixes = ["Developer ID Installer:", "3rd Party Mac Developer Installer:"]
  private static let profilePrefixes = ["Developer ID Application:", "Apple Development:", "Apple Distribution:"]

  /// Names of installer signing identities that have not expired, unique and sorted. Only certificates are read;
  /// there is no key access, so no prompt.
  static func installerIdentityNames() throws -> [String] {
    try currentIdentities().keys.filter { name in installerPrefixes.contains { name.hasPrefix($0) } }.sorted()
  }

  /// Names of unexpired identities that can sign configuration profiles, read the same way.
  static func profileIdentityNames() throws -> [String] {
    try currentIdentities().keys.filter { name in profilePrefixes.contains { name.hasPrefix($0) } }.sorted()
  }

  /// A renewed certificate keeps its name, so the keychain can hold an expired and a current identity with the
  /// same name. This returns the unexpired one that stays valid longest.
  static func identity(named name: String) throws -> SecIdentity {
    guard let identity = try currentIdentities()[name] else {
      throw PackageSigningError.identityNotFound(name)
    }
    return identity
  }

  private static func currentIdentities(now: Date = Date()) throws -> [String: SecIdentity] {
    var best: [String: (identity: SecIdentity, notAfter: Date)] = [:]
    for candidate in try identities() {
      guard let notAfter = candidate.notAfter, notAfter > now else { continue }
      if let existing = best[candidate.name], existing.notAfter >= notAfter { continue }
      best[candidate.name] = (candidate.identity, notAfter)
    }
    return best.mapValues(\.identity)
  }

  private static func identities() throws -> [(name: String, identity: SecIdentity, notAfter: Date?)] {
    let query: [CFString: Any] = [
      kSecClass: kSecClassIdentity,
      kSecMatchLimit: kSecMatchLimitAll,
      kSecReturnRef: true,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return [] }
    guard status == errSecSuccess, let array = result as? [SecIdentity] else {
      throw PackageSigningError.keychain(status)
    }
    return array.compactMap { identity in
      var certificate: SecCertificate?
      guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate,
        let name = SecCertificateCopySubjectSummary(certificate) as String?
      else { return nil }
      return (name, identity, SecCertificateCopyNotValidAfterDate(certificate) as Date?)
    }
  }
}

/// Signs package tables of contents with a keychain identity. macOS asks the user to allow each use of
/// the private key; the key never leaves the keychain.
///
/// `@unchecked Sendable`: the stored Security objects are immutable CF references, and the Security
/// framework's signing calls are safe to make from any thread.
final class KeychainPackageSigner: PackageSigner, @unchecked Sendable {
  /// CMS signature lengths seen this session, by leaf certificate, so later exports lay the archive out right
  /// the first time and use the private key only twice.
  private static let knownCMSLengths = Mutex<[Data: Int]>([:])

  let certificates: [Data]
  let rsaSignatureLength: Int
  private let identity: SecIdentity
  private let privateKey: SecKey

  init(identityName: String) throws {
    Log.signing.info("Signing the package with \(identityName, privacy: .private)")
    identity = try SigningIdentities.identity(named: identityName)

    var key: SecKey?
    let keyStatus = SecIdentityCopyPrivateKey(identity, &key)
    guard keyStatus == errSecSuccess, let key else { throw PackageSigningError.keychain(keyStatus) }
    guard SecKeyIsAlgorithmSupported(key, .sign, .rsaSignatureDigestPKCS1v15SHA1) else {
      throw PackageSigningError.unsupportedKey
    }
    privateKey = key
    rsaSignatureLength = SecKeyGetBlockSize(key)

    var certificate: SecCertificate?
    let certificateStatus = SecIdentityCopyCertificate(identity, &certificate)
    guard certificateStatus == errSecSuccess, let certificate else {
      throw PackageSigningError.keychain(certificateStatus)
    }
    certificates = Self.chain(for: certificate).map { SecCertificateCopyData($0) as Data }
  }

  func rsaSignature(forDigest digest: Data) throws -> Data {
    var error: Unmanaged<CFError>?
    guard
      let signature = SecKeyCreateSignature(privateKey, .rsaSignatureDigestPKCS1v15SHA1, digest as CFData, &error)
    else {
      if let cfError = error?.takeRetainedValue() {
        if PackageSigningError.isDenial(OSStatus(CFErrorGetCode(cfError))) { throw PackageSigningError.signingDenied }
        throw PackageSigningError.signingFailed((cfError as Error).localizedDescription)
      }
      throw PackageSigningError.signingFailed("The keychain did not allow the signature.")
    }
    return signature as Data
  }

  func cmsSignature(forDigest digest: Data) throws -> Data {
    var encoder: CMSEncoder?
    try check(CMSEncoderCreate(&encoder))
    guard let encoder else { throw PackageSigningError.signingFailed("The CMS encoder could not be created.") }
    try check(CMSEncoderAddSigners(encoder, identity))
    try check(CMSEncoderSetHasDetachedContent(encoder, true))
    try check(CMSEncoderSetCertificateChainMode(encoder, .chainWithRoot))
    try digest.withUnsafeBytes { buffer in
      guard let base = buffer.baseAddress else { return }
      try check(CMSEncoderUpdateContent(encoder, base, buffer.count))
    }
    var encoded: CFData?
    try check(CMSEncoderCopyEncodedContent(encoder, &encoded))
    guard let encoded else { throw PackageSigningError.signingFailed("The CMS signature is empty.") }
    let signature = encoded as Data
    if let leaf = certificates.first {
      Self.knownCMSLengths.withLock { $0[leaf] = signature.count }
    }
    return signature
  }

  var expectedCMSSignatureLength: Int {
    let known = certificates.first.flatMap { leaf in Self.knownCMSLengths.withLock { $0[leaf] } }
    return known ?? estimatedCMSSignatureLength
  }

  private func check(_ status: OSStatus) throws {
    guard status == errSecSuccess else {
      throw PackageSigningError.isDenial(status) ? PackageSigningError.signingDenied : .keychain(status)
    }
  }

  /// Leaf first, then intermediates and root, as far as the keychain can build the chain.
  private static func chain(for certificate: SecCertificate) -> [SecCertificate] {
    var trust: SecTrust?
    guard SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust) == errSecSuccess,
      let trust
    else { return [certificate] }
    // Only local certificates: no network fetches for missing intermediates or revocation.
    SecTrustSetNetworkFetchAllowed(trust, false)
    // Evaluation only builds the chain; an untrusted result still returns the certificates found.
    _ = SecTrustEvaluateWithError(trust, nil)
    return (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? [certificate]
  }
}
