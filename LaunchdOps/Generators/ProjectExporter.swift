import Foundation

enum ProjectExporter {
  /// A value that would end up in a file path or a root script in a form that isn't safe. Unlike validation
  /// issues, these stop the export even after Export Anyway.
  enum UnsafeValue: LocalizedError, Equatable {
    case label(String)
    case packageIdentifier(String)
    case taskType(String)
    case payloadName(String)
    case payloadDestination(String)
    case payloadWritable(String)

    var errorDescription: String? {
      switch self {
      case .label(let value):
        "The label “\(value)” can’t be used in file names or install scripts. Use only letters, numbers, dots, "
          + "hyphens and underscores (General ▸ Label), then export again."
      case .packageIdentifier(let value):
        "The package identifier “\(value)” can’t be used in file names or install scripts. Use only letters, "
          + "numbers, dots, hyphens and underscores (Export ▸ Identifier), then export again."
      case .taskType(let value):
        "The task type “\(value)” can’t be used as a folder name. Use only letters, numbers, dots, hyphens and "
          + "underscores (Export ▸ Task Type), then export again."
      case .payloadName(let value):
        "The payload file name “\(value)” can’t be installed safely. Rename the file so it has no slash and "
          + "doesn’t start with a dot, then add it again."
      case .payloadDestination(let value):
        "The payload destination “\(value)” isn’t a safe folder: use an absolute path with no //, . or .. parts "
          + "(a subfolder in DDM mode), then export again."
      case .payloadWritable(let value):
        "The payload file “\(value)” is writable by users other than root. Change its mode (for example to 755), "
          + "then export again."
      }
    }
  }

  /// Every value that becomes part of a path or is written into an install script must pass here.
  static func checkSafety(of project: Project) throws {
    for job in project.jobs where !Validator.isValidLabel(job.label) {
      throw UnsafeValue.label(job.label)
    }
    let settings = project.settings
    switch settings.mode {
    case .package:
      if !Validator.isValidLabel(settings.packageIdentifier) {
        throw UnsafeValue.packageIdentifier(settings.packageIdentifier)
      }
    case .declarative:
      if !Validator.isValidLabel(settings.taskType) {
        throw UnsafeValue.taskType(settings.taskType)
      }
    }
    for file in project.payload {
      if SafeInstallPath.problem(withName: file.name) != nil {
        throw UnsafeValue.payloadName(file.name)
      }
      let destinationProblem =
        settings.mode == .package
        ? SafeInstallPath.problem(withFolder: file.destination)
        : SafeInstallPath.problem(withSubfolder: file.destination)
      if destinationProblem != nil {
        throw UnsafeValue.payloadDestination(file.destination)
      }
      if file.mode & 0o022 != 0 {
        throw UnsafeValue.payloadWritable(file.name)
      }
    }
  }

  /// The export is one flat folder: the package, the profile, a reference copy of each plist, check.sh,
  /// uninstall.sh and README.md. Build Script output keeps `package/`, the layout build-pkg.sh expects, and DDM
  /// keeps `ddm/`, the files the MDM needs as a set.
  ///
  /// `signer` signs the installer package and `profileSigner` the Managed Login Items profile; `buildsPackage`
  /// false skips building the package (for previews), leaving an empty placeholder at its path.
  static func export(
    _ project: Project,
    signer: (any PackageSigner)? = nil,
    profileSigner: (any ProfileSigner)? = nil,
    buildsPackage: Bool = true
  ) throws -> FileTree {
    let project = project.resolved()
    try checkSafety(of: project)
    var tree = FileTree()
    let settings = project.settings
    let issues = Validator.validate(project)

    for job in project.jobs {
      tree.add(job.fileName, try job.renderedPlist())
    }

    var profileName: String?
    if settings.includeLoginItemsProfile && !project.jobs.isEmpty {
      let name = "\(settings.safeName)-ManagedLoginItems.mobileconfig"
      let profile = try ProfileGenerator.managedLoginItems(for: project)
      tree.add(name, try profileSigner?.signedProfile(profile) ?? profile)
      profileName = name
    }

    switch settings.mode {
    case .package:
      if settings.includePackage {
        switch settings.packageOutput {
        case .installerPackage:
          let package =
            buildsPackage
            ? try FlatPackageBuilder.package(FlatPackageBuilder.input(for: project), signer: signer) : Data()
          tree.add(settings.packageFileName, package)
        case .buildScript:
          for entry in project.packagedPlists {
            tree.add("package/root\(entry.path)", try entry.job.renderedPlist())
          }
          for file in project.payload {
            tree.add("package/root\(project.installPath(for: file))", file.contents, mode: file.mode)
          }
          if let rotation = LogRotation.configFile(for: project) {
            tree.add("package/root\(rotation.path)", text: rotation.contents)
          }
          tree.add("package/scripts/preinstall", text: ScriptGenerator.preinstall(for: project), mode: 0o755)
          tree.add("package/scripts/postinstall", text: ScriptGenerator.postinstall(for: project), mode: 0o755)
          tree.add("package/build-pkg.sh", text: PackageGenerator.buildScript(for: project), mode: 0o755)
        }
      }
      if settings.includeScripts {
        tree.add("uninstall.sh", text: ScriptGenerator.uninstall(for: project), mode: 0o755)
      }
    case .declarative:
      let output = try DeclarativeGenerator.generate(for: project)
      for asset in output.assets {
        tree.add("ddm/assets/\(asset.fileName)", asset.contents)
      }
      for declaration in output.declarations {
        tree.add("ddm/declarations/\(declaration.name)", declaration.data)
      }
    }

    if settings.includeScripts {
      tree.add("check.sh", text: ScriptGenerator.check(for: project), mode: 0o755)
    }
    if settings.includeGuide {
      tree.add("README.md", text: GuideGenerator.readme(for: project, profileName: profileName, issues: issues))
    }
    return tree
  }

  static func defaultFolderName(for project: Project) -> String {
    "\(project.resolvedSettings.safeName)-\(project.settings.version)"
  }
}
