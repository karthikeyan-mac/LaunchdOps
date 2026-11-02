import Foundation

/// Builds a flat distribution package: a xar archive holding `Distribution` and one component package
/// (`PackageInfo`, `Bom`, `Payload`, `Scripts`), the same shape `pkgbuild` plus `productbuild` produce.
enum FlatPackageBuilder {
  static let componentName = "component.pkg"

  struct Input: Sendable {
    var identifier: String
    var version: String
    var title: String
    /// Absolute install paths with contents and permission bits.
    var files: [(path: String, contents: Data, permissions: Int)]
    var preinstall: String
    var postinstall: String
  }

  static func input(for project: Project) throws -> Input {
    let plists = try project.packagedPlists.map { entry in (entry.path, try entry.job.renderedPlist(), 0o644) }
    let payload = project.payload.map { (project.installPath(for: $0), $0.contents, $0.mode) }
    let rotation = LogRotation.configFile(for: project).map { [($0.path, Data($0.contents.utf8), 0o644)] } ?? []
    return Input(
      identifier: project.settings.packageIdentifier,
      version: project.settings.version,
      title: project.settings.name,
      files: plists + payload + rotation,
      preinstall: ScriptGenerator.preinstall(for: project),
      postinstall: ScriptGenerator.postinstall(for: project)
    )
  }

  static func package(_ input: Input, signer: (any PackageSigner)? = nil) throws -> Data {
    let entries = try PackagePayload.entries(files: input.files)
    let scripts = [
      PackageEntry(path: "", kind: .directory, permissions: 0o755),
      PackageEntry(path: "postinstall", kind: .file(Data(input.postinstall.utf8)), permissions: 0o755),
      PackageEntry(path: "preinstall", kind: .file(Data(input.preinstall.utf8)), permissions: 0o755),
    ]
    let installKilobytes = PackagePayload.installKilobytes(entries)

    let component: [XarEntry] = [
      XarEntry(name: "Bom", kind: .file(try BomWriter.bom(entries))),
      XarEntry(
        name: "PackageInfo",
        kind: .file(Data(packageInfo(input, fileCount: entries.count, installKilobytes: installKilobytes).utf8))
      ),
      XarEntry(name: "Payload", kind: .file(try PackageCompression.gzip(CpioWriter.archive(entries)))),
      XarEntry(name: "Scripts", kind: .file(try PackageCompression.gzip(CpioWriter.archive(scripts)))),
    ]
    let product: [XarEntry] = [
      XarEntry(name: "Distribution", kind: .file(Data(distribution(input, installKilobytes: installKilobytes).utf8))),
      XarEntry(name: componentName, kind: .directory(component), permissions: 0o755),
    ]
    return try XarWriter.archive(product, signer: signer)
  }

  static func packageInfo(_ input: Input, fileCount: Int, installKilobytes: Int) -> String {
    // overwrite-permissions="false" leaves existing folders such as /Library/Application Support untouched.
    """
    <?xml version="1.0" encoding="utf-8"?>
    <pkg-info format-version="2" identifier="\(XML.escaped(input.identifier))" \
    version="\(XML.escaped(input.version))" install-location="/" auth="root" relocatable="false" \
    overwrite-permissions="false" postinstall-action="none">
        <payload numberOfFiles="\(fileCount)" installKBytes="\(installKilobytes)"/>
        <bundle-version/>
        <upgrade-bundle/>
        <update-bundle/>
        <atomic-update-bundle/>
        <strict-identifier/>
        <relocate/>
        <scripts>
            <preinstall file="./preinstall"/>
            <postinstall file="./postinstall"/>
        </scripts>
    </pkg-info>

    """
  }

  static func distribution(_ input: Input, installKilobytes: Int) -> String {
    let identifier = XML.escaped(input.identifier)
    return """
      <?xml version="1.0" encoding="utf-8"?>
      <installer-gui-script minSpecVersion="2">
          <title>\(XML.escaped(input.title))</title>
          <pkg-ref id="\(identifier)"/>
          <options customize="never" require-scripts="false" hostArchitectures="x86_64,arm64"/>
          <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
          <choices-outline>
              <line choice="default">
                  <line choice="\(identifier)"/>
              </line>
          </choices-outline>
          <choice id="default"/>
          <choice id="\(identifier)" visible="false">
              <pkg-ref id="\(identifier)"/>
          </choice>
          <pkg-ref id="\(identifier)" version="\(XML.escaped(input.version))" onConclusion="none" \
      installKBytes="\(installKilobytes)">#\(componentName)</pkg-ref>
      </installer-gui-script>

      """
  }
}
