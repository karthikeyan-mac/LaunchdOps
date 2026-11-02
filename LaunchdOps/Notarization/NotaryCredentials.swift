import CryptoKit
import Foundation
import Security

/// An App Store Connect API key, used to sign requests to Apple's notary service.
struct NotaryCredentials: Codable, Equatable, Sendable {
  enum KeyKind: String, Codable, Sendable {
    /// Created by an Account Holder or Admin for the team; tokens name the issuer ID.
    case team
    /// Created by any team member for themselves; tokens use `sub: user` and have no issuer ID.
    case individual
  }

  var kind = KeyKind.team
  /// Team keys only; empty for individual keys.
  var issuerID: String
  var keyID: String
  /// The contents of the downloaded `AuthKey_<KeyID>.p8` file (PEM, PKCS #8, P-256).
  var privateKeyPEM: String

  init(kind: KeyKind = .team, issuerID: String, keyID: String, privateKeyPEM: String) {
    self.kind = kind
    self.issuerID = issuerID
    self.keyID = keyID
    self.privateKeyPEM = privateKeyPEM
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // Keys saved before individual keys were supported are team keys.
    kind = try container.decodeIfPresent(KeyKind.self, forKey: .kind) ?? .team
    issuerID = try container.decodeIfPresent(String.self, forKey: .issuerID) ?? ""
    keyID = try container.decode(String.self, forKey: .keyID)
    privateKeyPEM = try container.decode(String.self, forKey: .privateKeyPEM)
  }

  enum ValidationError: LocalizedError, Equatable {
    case issuerID
    case keyID
    case privateKey

    var errorDescription: String? {
      switch self {
      case .issuerID:
        "Enter the issuer ID from App Store Connect ▸ Users and Access ▸ Integrations, for example 57246542-96fe-1a63-e053-0824d011072a."
      case .keyID:
        "Enter the 10-character key ID shown next to the key in App Store Connect."
      case .privateKey:
        "Choose the AuthKey_….p8 file you downloaded when you created the key."
      }
    }
  }

  func validate() throws(ValidationError) {
    if kind == .team {
      guard UUID(uuidString: issuerID.trimmingCharacters(in: .whitespacesAndNewlines)) != nil else { throw .issuerID }
    }
    guard keyID.trimmingCharacters(in: .whitespacesAndNewlines).wholeMatch(of: /[A-Z0-9]{10}/) != nil else {
      throw .keyID
    }
    do {
      _ = try P256.Signing.PrivateKey(pemRepresentation: privateKeyPEM)
    } catch {
      throw .privateKey
    }
  }
}

enum NotaryCredentialStoreError: LocalizedError {
  case keychain(OSStatus)
  case corrupt

  var errorDescription: String? {
    switch self {
    case .keychain(let status):
      "The notarization key could not be read from or saved to your keychain "
        + "(\(SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)")). Set it up again in LaunchdOps ▸ Settings."
    case .corrupt:
      "The saved notarization key could not be read. Remove it and set it up again in LaunchdOps ▸ Settings."
    }
  }
}

/// Stores one set of notary credentials as a generic-password item in the user's keychain.
///
/// The key is kept in the data protection keychain, available only while the Mac is unlocked and never leaving this
/// Mac (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`), when the build can use it: that needs an
/// `application-identifier` entitlement, which Mac App Store builds get from their provisioning profile. Other builds
/// fall back to the login keychain, which ignores accessibility classes; the item is marked as not synchronizable
/// either way. A key found in the login keychain moves to the data protection keychain once that's available.
enum NotaryCredentialStore {
  private static let service = "com.karthikmac.LaunchdOps.notarization"
  private static let account = "AppStoreConnectAPIKey"

  private static func query(dataProtection: Bool) -> [CFString: Any] {
    var query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
      kSecAttrSynchronizable: false,
    ]
    if dataProtection {
      query[kSecUseDataProtectionKeychain] = true
    }
    return query
  }

  /// Attributes for a new item: this Mac only, readable while unlocked, never synced.
  static func newItemAttributes(dataProtection: Bool) -> [CFString: Any] {
    var item = query(dataProtection: dataProtection)
    item[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    item[kSecAttrLabel] = "LaunchdOps notarization key"
    return item
  }

  /// Statuses meaning "this build can't use the data protection keychain", so the login keychain is used.
  private static func isUnavailable(_ status: OSStatus) -> Bool {
    status == errSecMissingEntitlement || status == errSecNotAvailable
  }

  /// Whether a key is saved, without reading the private key.
  static func exists() -> Bool {
    [true, false].contains { dataProtection in
      var query = query(dataProtection: dataProtection)
      query[kSecReturnAttributes] = true
      query[kSecMatchLimit] = kSecMatchLimitOne
      return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
  }

  static func load() throws -> NotaryCredentials? {
    let protected = try read(dataProtection: true)
    if let data = protected.data { return try decode(data) }
    guard let data = try read(dataProtection: false).data else { return nil }
    let credentials = try decode(data)
    if protected.available {
      // Move the key out of the login keychain. If that fails, the key still works from where it is.
      do {
        try write(data, dataProtection: true)
        try deleteItem(dataProtection: false)
        Log.notarization.info("Moved the notarization key to the data protection keychain")
      } catch {
        Log.notarization.error("Moving the notarization key failed: \(error.localizedDescription, privacy: .public)")
      }
    }
    return credentials
  }

  static func save(_ credentials: NotaryCredentials) throws {
    let data = try JSONEncoder().encode(credentials)
    do {
      try write(data, dataProtection: true)
      try deleteItem(dataProtection: false)  // An older copy in the login keychain would be read by nothing.
    } catch NotaryCredentialStoreError.keychain(let status) where isUnavailable(status) {
      try write(data, dataProtection: false)
    }
  }

  static func delete() throws {
    try deleteItem(dataProtection: true)
    try deleteItem(dataProtection: false)
  }

  // MARK: - Keychain calls

  private static func read(dataProtection: Bool) throws -> (data: Data?, available: Bool) {
    var query = query(dataProtection: dataProtection)
    query[kSecReturnData] = true
    query[kSecMatchLimit] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return (nil, true) }
    if dataProtection && isUnavailable(status) { return (nil, false) }
    guard status == errSecSuccess, let data = result as? Data else { throw NotaryCredentialStoreError.keychain(status) }
    return (data, true)
  }

  private static func write(_ data: Data, dataProtection: Bool) throws {
    let update = SecItemUpdate(
      query(dataProtection: dataProtection) as CFDictionary, [kSecValueData: data] as CFDictionary
    )
    if update == errSecSuccess { return }
    guard update == errSecItemNotFound else { throw NotaryCredentialStoreError.keychain(update) }
    var item = newItemAttributes(dataProtection: dataProtection)
    item[kSecValueData] = data
    let add = SecItemAdd(item as CFDictionary, nil)
    guard add == errSecSuccess else { throw NotaryCredentialStoreError.keychain(add) }
  }

  private static func deleteItem(dataProtection: Bool) throws {
    let status = SecItemDelete(query(dataProtection: dataProtection) as CFDictionary)
    if status == errSecSuccess || status == errSecItemNotFound { return }
    if dataProtection && isUnavailable(status) { return }
    throw NotaryCredentialStoreError.keychain(status)
  }

  private static func decode(_ data: Data) throws -> NotaryCredentials {
    do {
      return try JSONDecoder().decode(NotaryCredentials.self, from: data)
    } catch {
      throw NotaryCredentialStoreError.corrupt
    }
  }
}
