import Foundation

enum PackageGenerator {
  static func buildScript(for project: Project) -> String {
    let settings = project.settings
    let payloadModes = project.payload.map { file in
      "/bin/chmod \(file.modeString) \(Shell.quoted("root" + project.installPath(for: file)))"
    }
    let lintLines = project.packagedPlists.map { entry in
      "/usr/bin/plutil -lint \(Shell.quoted("root" + entry.path)) >/dev/null"
    }
    let commands = (payloadModes + lintLines).joined(separator: "\n")

    return #"""
      #!/bin/zsh --no-rcs
      # \#(GeneratorInfo.banner) for \#(settings.name).
      # Builds a distribution package from this folder on a Mac with Xcode command line tools.
      # Usage: ./build-pkg.sh
      #        SIGN_IDENTITY="Developer ID Installer: Name (TEAMID)" ./build-pkg.sh

      set -euo pipefail
      cd "${0:A:h}"

      identifier=\#(Shell.quoted(settings.packageIdentifier))
      version=\#(Shell.quoted(settings.version))
      name=\#(Shell.quoted(settings.safeName))
      out="build"
      default_identity=\#(Shell.quoted(settings.signingIdentity))
      sign_identity="${SIGN_IDENTITY:-$default_identity}"

      /bin/rm -rf "$out"
      /bin/mkdir -p "$out"

      # Files saved by a sandboxed app carry quarantine attributes, and copying can change their modes.
      /usr/bin/xattr -cr root scripts
      /bin/chmod 755 scripts/preinstall scripts/postinstall
      /usr/bin/find root -type d -exec /bin/chmod 755 {} +
      /usr/bin/find root -path '*/Launch*/*.plist' -exec /bin/chmod 644 {} +
      \#(commands.isEmpty ? ":" : commands)

      /usr/bin/pkgbuild \
        --root root \
        --scripts scripts \
        --identifier "$identifier" \
        --version "$version" \
        --install-location / \
        --ownership recommended \
        "$out/component.pkg"

      /usr/bin/productbuild --package "$out/component.pkg" "$out/$name-$version-unsigned.pkg"
      /bin/rm "$out/component.pkg"

      if [[ -n "$sign_identity" ]]; then
        /usr/bin/productsign --sign "$sign_identity" "$out/$name-$version-unsigned.pkg" "$out/$name-$version.pkg"
        /bin/rm "$out/$name-$version-unsigned.pkg"
        /usr/sbin/pkgutil --check-signature "$out/$name-$version.pkg"
        echo "Built $out/$name-$version.pkg"
      else
        echo "Built $out/$name-$version-unsigned.pkg"
        echo "MDM installation requires a signed package. Set SIGN_IDENTITY or a signing identity in LaunchdOps."
      fi

      """#
  }
}

enum ProfileGenerator {
  static func managedLoginItems(for project: Project) throws -> Data {
    let settings = project.settings
    let baseIdentifier = settings.mode == .package ? settings.packageIdentifier : settings.taskType
    let rules: [PlistValue] = project.jobs
      .filter { Validator.isValidLabel($0.label) }
      .map { job in
        .dictionary([
          "RuleType": .string("Label"),
          "RuleValue": .string(job.label),
          "Comment": .string("\(settings.name): \(job.context.title)"),
        ])
      }

    var payload: [String: PlistValue] = [
      "PayloadType": .string("com.apple.servicemanagement"),
      "PayloadIdentifier": .string("\(baseIdentifier).loginitems.payload"),
      "PayloadUUID": .string(settings.profilePayloadUUID.uuidString),
      "PayloadVersion": .integer(1),
      "PayloadDisplayName": .string("Managed Login Items"),
      "Rules": .array(rules),
    ]
    if !settings.organization.isEmpty {
      payload["PayloadOrganization"] = .string(settings.organization)
    }

    var profile: [String: PlistValue] = [
      "PayloadContent": .array([.dictionary(payload)]),
      "PayloadDisplayName": .string("\(settings.name) Managed Login Items"),
      "PayloadDescription": .string(
        "Marks the \(settings.name) launchd jobs as managed so users cannot turn them off."),
      "PayloadIdentifier": .string("\(baseIdentifier).loginitems"),
      "PayloadScope": .string("System"),
      "PayloadType": .string("Configuration"),
      "PayloadUUID": .string(settings.profileUUID.uuidString),
      "PayloadVersion": .integer(1),
    ]
    if !settings.organization.isEmpty {
      profile["PayloadOrganization"] = .string(settings.organization)
    }
    return try PropertyListCoding.xmlData(from: profile)
  }
}

enum DeclarativeGenerator {
  struct Asset {
    var identifier: String
    var fileName: String
    var contentType: String
    var contents: Data
    var hash: String { Hashing.sha256(contents) }
  }

  struct Output {
    var assets: [Asset]
    var declarations: [(name: String, data: Data)]
  }

  static func generate(for project: Project) throws -> Output {
    let taskType = project.settings.taskType
    var assets: [Asset] = []
    var launchdConfigurations: [[String: String]] = []

    if !project.payload.isEmpty {
      var archive = ZipWriter()
      archive.addDirectory(taskType)
      for file in project.payload.sorted(by: { project.installPath(for: $0) < project.installPath(for: $1) }) {
        let relative = String(project.installPath(for: file).dropFirst(Project.servicesRoot.count + 1))
        var folder = ""
        for component in relative.split(separator: "/").dropLast() {
          folder += String(component) + "/"
          archive.addDirectory(folder)
        }
        archive.addFile(relative, contents: file.contents, mode: file.mode)
      }
      assets.append(
        Asset(
          identifier: "\(taskType).asset.executables",
          fileName: "\(taskType).zip",
          contentType: "application/zip",
          contents: archive.archive()
        ))
    }

    for job in project.jobs where job.context != .userAgent {
      let asset = Asset(
        identifier: "\(taskType).asset.\(job.label)",
        fileName: job.fileName,
        contentType: "application/xml",
        contents: try job.renderedPlist()
      )
      assets.append(asset)
      launchdConfigurations.append([
        "FileAssetReference": asset.identifier,
        "Context": job.context == .daemon ? "daemon" : "agent",
      ])
    }

    var payload: [String: Any] = [
      "TaskType": taskType,
      "LaunchdConfigurations": launchdConfigurations,
    ]
    if !project.settings.taskDescription.isEmpty {
      payload["TaskDescription"] = project.settings.taskDescription
    }
    if let executables = assets.first(where: { $0.contentType == "application/zip" }) {
      payload["ExecutableAssetReference"] = executables.identifier
    }

    let combinedHash = Hashing.sha256(Data(assets.map(\.hash).joined().utf8))
    let configuration: [String: Any] = [
      "Type": "com.apple.configuration.services.background-tasks",
      "Identifier": "\(taskType).background-tasks",
      "ServerToken": String(combinedHash.prefix(16)),
      "Payload": payload,
    ]
    var declarations: [(name: String, data: Data)] = []
    declarations.append((name: "configuration.json", data: try json(configuration)))

    for asset in assets {
      let reference: [String: Any] = [
        "DataURL": "https://REPLACE-WITH-YOUR-SERVER/\(asset.fileName)",
        "ContentType": asset.contentType,
        "Size": asset.contents.count,
        "Hash-SHA-256": asset.hash,
      ]
      let assetPayload: [String: Any] = [
        "Reference": reference,
        "Authentication": ["Type": "None"],
      ]
      let declaration: [String: Any] = [
        "Type": "com.apple.asset.data",
        "Identifier": asset.identifier,
        "ServerToken": String(asset.hash.prefix(16)),
        "Payload": assetPayload,
      ]
      declarations.append((name: "asset-\(asset.fileName).json", data: try json(declaration)))
    }
    return Output(assets: assets, declarations: declarations)
  }

  private static func json(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
  }
}
