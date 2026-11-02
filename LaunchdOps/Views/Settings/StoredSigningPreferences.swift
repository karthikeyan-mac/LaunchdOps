import SwiftUI

/// `SigningPreferences` read from and written to their separate keys in the app's preferences, updating the view
/// when Settings changes them.
@propertyWrapper
struct StoredSigningPreferences: DynamicProperty {
  @AppStorage(SigningPreferences.Key.signsPackage) private var signsPackage = false
  @AppStorage(SigningPreferences.Key.packageIdentity) private var packageIdentity = ""
  @AppStorage(SigningPreferences.Key.notarizeAfterExport) private var notarizeAfterExport = false
  @AppStorage(SigningPreferences.Key.signsProfile) private var signsProfile = false
  @AppStorage(SigningPreferences.Key.profileIdentity) private var profileIdentity = ""

  var wrappedValue: SigningPreferences {
    get {
      var value = SigningPreferences()
      value.signsPackage = signsPackage
      value.packageIdentity = packageIdentity
      value.notarizeAfterExport = notarizeAfterExport
      value.signsProfile = signsProfile
      value.profileIdentity = profileIdentity
      return value
    }
    nonmutating set {
      signsPackage = newValue.signsPackage
      packageIdentity = newValue.packageIdentity
      notarizeAfterExport = newValue.notarizeAfterExport
      signsProfile = newValue.signsProfile
      profileIdentity = newValue.profileIdentity
    }
  }

  var projectedValue: Binding<SigningPreferences> {
    Binding(get: { wrappedValue }, set: { wrappedValue = $0 })
  }
}
