import Foundation

enum GuideGenerator {
  static func readme(for project: Project, profileName: String?, issues: [ValidationIssue] = []) -> String {
    let settings = project.settings
    var sections: [String] = []

    sections.append("""
    # \(settings.name)

    \(GeneratorInfo.banner). Review the steps for your management tool and test on a non-production Mac first.

    ## Jobs

    \(jobTable(for: project))
    """)

    switch settings.mode {
    case .package:
      sections.append(packageSections(for: project, profileName: profileName))
    case .declarative:
      sections.append(declarativeSections(for: project, profileName: profileName))
    }

    if settings.includeScripts {
      sections.append("""
      ## Checking deployed Macs

      `check.sh` with no arguments prints one line with the package version and each job's state, for your \
      MDM's inventory: a custom attribute, extension attribute or script result. Each job reports \
      `loaded (last exit N)`, `not-loaded`, `program-missing` (the program isn't on the Mac) or `no-user` \
      (an agent with nobody logged in); `version=not-installed` means the package receipt is missing. For tools \
      that read the value between `<result>` tags, run it with `--result` or set `RESULT_TAGS=true` in the \
      script (see Notes for common tools). The `launchctl print` output it reads is not a stable interface, so \
      re-test it after major macOS updates.
      """)
    }

    sections.append(validationSection(for: project, issues: issues))

    return sections.joined(separator: "\n\n") + "\n"
  }

  /// User Launch Agents are staged by the package and copied into each account's home folder by postinstall.
  private static func userAgentNote(for project: Project) -> String {
    guard !project.userAgentJobs.isEmpty else { return "" }
    return """
       User launch agents are installed in `\(Project.userAgentStagingFolder)`; postinstall copies each one \
      into the logged-in user's `~/Library/LaunchAgents` (running as that user) and loads it. If nobody is \
      logged in, the agent isn't installed (the install log says so); install the package again after login. \
      Other users don't get it: make the job a Launch Agent (All Users) for that. uninstall.sh removes the copy \
      from every user account.
      """
  }

  private static func jobTable(for project: Project) -> String {
    guard !project.jobs.isEmpty else { return "No jobs." }
    let rows = project.jobs.map { job in
      "| `\(job.label)` | \(job.context.title) | `\(job.installPath)` |"
    }
    return (["| Label | Type | Installed at |", "| --- | --- | --- |"] + rows).joined(separator: "\n")
  }

  private static func packageSections(for project: Project, profileName: String?) -> String {
    let settings = project.settings
    var text =
      settings.packageOutput == .installerPackage
      ? builtPackageSection(for: project) : buildScriptSection(for: project)
    text += """


    The preinstall script stops the current jobs and removes any retired labels. \
    The postinstall script secures file ownership and modes, enables each job and loads it with \
    `launchctl bootstrap`. Launch agents are loaded for every user who is logged in; \
    other users get them at their next login.\(userAgentNote(for: project))

    ## 2. Test

    Install the package on a test Mac, then run:

    ```sh
    sudo ./check.sh --details          # check files, ownership and launchd state
    sudo ./check.sh --details --run    # also start each job now
    sudo ./check.sh --collect          # save launchd details and logs for support
    ```

    ## 3. Deploy

    Use any MDM or software distribution tool:

    1. Add the package as a macOS package and scope it to the Macs that need the jobs. Apple requires packages \
    installed by a device management service to carry a signature the Mac can verify, so sign it with a \
    Developer ID Installer identity (LaunchdOps ▸ Settings ▸ Signing); some tools also accept unsigned packages.
    2. For reporting, run `check.sh` from your tool's inventory feature (a custom attribute, \
    extension attribute or script). It prints one line with the package version and each job's state; add \
    `--result` if your tool reads the value between `<result>` tags.
    3. If your tool supports an uninstall script, use `uninstall.sh`.
    """
    if let profileName {
      text += "\n4. Deliver `\(profileName)` as a device configuration profile."
    }
    text += """


    On supervised Macs with macOS 26 or later, MDMs can also install packages with declarative app management. \
    From macOS 27 the Mac can remove a package's files when that configuration is removed, but not changes \
    made by install scripts (such as loaded jobs), so keep `uninstall.sh` for a complete removal.
    """
    text += """


    ### Notes for common tools
    The steps above work with any MDM. Where to find each feature, in some common tools \
    (menus change, so check your vendor's documentation):

    | Tool | Package | Inventory script (`check.sh`) | Profile |
    | --- | --- | --- | --- |
    | Jamf Pro | Policy with the package | Computer extension attribute, script input; set `RESULT_TAGS=true` in the script (Jamf stores the text between `<result>` tags) | Configuration profile (upload) |
    | Microsoft Intune | macOS app (PKG), or a line-of-business app, which must be signed with Developer ID Installer | macOS custom attribute (runs about every 8 hours; output up to 20 KB) | Custom configuration profile |
    | Workspace ONE UEM | macOS app | Sensor (Bash or Zsh; the whole output is one value) | Custom settings profile |
    | Addigy | Custom software | Custom fact | Custom profile |
    | Kandji | Custom App | Custom Script (runs as an audit script; check Kandji's documentation for reporting its output) | Custom Profile |
    | Mosyle | Custom package | Custom attribute (check Mosyle's documentation) | Custom profile |
    | Munki (not an MDM) | `munkiimport`, with `uninstall.sh` as the uninstall script | — | Deliver with your MDM |
    """
    if profileName != nil {
      text += """


      ## Managed Login Items profile
      The `com.apple.servicemanagement` payload (macOS 13 or later) marks these jobs as managed, so they are \
      enabled and users cannot turn them off in System Settings. It must be delivered by an MDM on the device \
      channel of a user-approved or Automated Device Enrollment; it cannot be installed manually.
      """
    }
    text += """


    ## Logs
    The install and removal scripts record each step in `/var/log/install.log` and in the unified log. \
    To see them on a Mac:

    ```sh
    log show --last 7d --style compact \\
      --predicate 'process == "logger" AND eventMessage BEGINSWITH "\(ScriptGenerator.logPrefix)"'
    ```

    `sudo ./check.sh --collect` saves the same lines in `install-steps.log`.
    """
    if let rotation = LogRotation.configFile(for: project) {
      text += """


        The package installs `\(rotation.path)`, so macOS rotates the job's log files: it keeps \
        \(LogRotation.keptFiles) compressed copies and starts a new file at \(LogRotation.rotateAtKilobytes / 1024) MB.
        """
    }
    text += """


    ## Removal
    Run `sudo ./uninstall.sh`, or deploy it as a script from your management tool. \
    It unloads each job, deletes the files this project installs and forgets the package receipt.
    """
    return text
  }

  private static func buildScriptSection(for project: Project) -> String {
    let settings = project.settings
    return """
      ## 1. Build the package

      On a Mac with the Xcode command line tools:

      ```sh
      cd package
      SIGN_IDENTITY="Developer ID Installer: Your Name (TEAMID)" ./build-pkg.sh
      ```

      The package identifier is `\(settings.packageIdentifier)`, version `\(settings.version)`. \
      Leave `SIGN_IDENTITY` unset to build an unsigned package for testing with tools that accept one. \
      MDM `InstallEnterpriseApplication` and the DDM package declaration require a signed distribution package.
      """
  }

  private static func builtPackageSection(for project: Project) -> String {
    let settings = project.settings
    let signing =
      settings.signingIdentity.isEmpty
      ? "The package is unsigned. Some deployment tools install unsigned packages, but many MDMs and Apple's "
        + "`InstallEnterpriseApplication` command need a signed package, and double-click installs need it notarized."
      : "The package is signed with `\(settings.signingIdentity)`. Check it with "
        + "`pkgutil --check-signature \(settings.packageFileName)`."
    return """
      ## 1. The package

      LaunchdOps built `\(settings.packageFileName)` (identifier `\(settings.packageIdentifier)`, \
      version `\(settings.version)`). \(signing)
      \(notarizationText(for: settings))
      """
  }

  /// Notarization matters only for double-click installs; which steps remain depends on Settings ▸ Signing.
  private static func notarizationText(for settings: ProjectSettings) -> String {
    let file = settings.packageFileName
    if settings.signingIdentity.isEmpty {
      return """

        Apple notarizes only signed packages. To let people install it by double-clicking a downloaded copy, \
        turn on Sign the Package in LaunchdOps ▸ Settings ▸ Signing and export again (MDM installs do not need this).
        """
    }
    let expiry = """
      The signature has no secure timestamp, so re-export and re-notarize before the Developer ID Installer \
      certificate expires.
      """
    if settings.notarizeAfterExport {
      return """

        LaunchdOps sends this package to Apple for notarization right after export and staples the ticket to \
        it, so there is nothing to run. It shows the result when Apple finishes, usually within a few minutes. \
        To confirm on any Mac:

        ```sh
        xcrun stapler validate \(file)
        spctl -a -vv -t install \(file)
        ```

        \(expiry)
        """
    }
    return """

      To let people install it by double-clicking a downloaded copy, notarize and staple it on a Mac with \
      the Xcode command line tools (MDM installs do not need this):

      ```sh
      xcrun notarytool submit \(file) --keychain-profile "notary-profile" --wait
      xcrun stapler staple \(file)
      ```

      Create the profile once with `xcrun notarytool store-credentials`, or turn on Notarize After Export in \
      LaunchdOps ▸ Settings ▸ Signing. \(expiry)
      """
  }

  private static func declarativeSections(for project: Project, profileName: String?) -> String {
    let settings = project.settings
    var text = """
    ## DDM background task

    ### What you need
    - **An MDM server that can send declarations.** DDM background tasks can't be installed by hand: no \
    `profiles` command, double-click or `sudo`. Jamf Pro does it with Blueprints; for other MDMs, check that they \
    support the `com.apple.configuration.services.background-tasks` declaration. For a test lab, the open-source \
    NanoMDM with KMFDDM can send the raw declarations in this folder.
    - **Supervised Macs**, in practice enrolled through Apple Business Manager or Apple School Manager \
    (Automated Device Enrollment).
    - **macOS 15 or later.**

    ### Why use it
    The Mac keeps the launchd plists and executables in tamper-resistant folders under \
    `/private/var/db/ManagedConfigurationFiles/BackgroundTaskServices`; executables are expanded into \
    `\(Project.servicesRoot)/\(settings.taskType)`. Not even root can change those files, and the job can't be \
    unloaded or disabled, which makes this the better choice for tools users must not stop. If your Macs aren't \
    supervised, or you only need the job deployed, use an installer package instead.

    The Mac stops and restarts the task itself when the configuration changes, so these jobs work best with \
    Run at Load rather than Keep Alive: launchd relaunching a Keep Alive job during an update has been seen \
    to fail with "Operation already in progress".

    ### What's in this folder
    - `ddm/assets/`: the files to host. The ZIP holds the task's executables in a `\(settings.taskType)` folder; \
    each plist is one launchd job.
    - `ddm/declarations/`: the configuration and one asset declaration per file, for MDMs that accept raw \
    declarations. Replace each `DataURL` with your URL first.

    The SHA-256 and content type of each asset are in the table in Step 2.

    The declarations set asset authentication to `None` for a plain HTTPS server; remove the \
    `Authentication` key to use MDM authentication instead.

    ### Step 1: Host the assets
    Upload each file in `ddm/assets/` to an HTTPS location that Macs can download from without signing in. \
    Your server must return exactly the `Content-Type` listed for each asset, or the Mac rejects it. \
    Check each file:

    ```sh
    curl -sI https://your-server/FILE | grep -i '^content-type'
    ```

    Some storage services return `binary/octet-stream` by default (Amazon S3 does); change the file's \
    content type there until the header matches the table below. To check a hash, run \
    `shasum -a 256 ddm/assets/FILE`.

    ### Step 2: Give it to your MDM
    MDMs that deploy service background tasks ask for these values (field names vary by vendor). In Jamf Pro, \
    use the Service background tasks component in Blueprints. MDMs that accept raw declarations take the files \
    in `ddm/declarations/` instead, with your URLs filled in. Scope it to supervised Macs with macOS 15 or later.

    | Field (declaration key) | Value |
    | --- | --- |
    | Task type (`TaskType`) | `\(settings.taskType)`; keep it equal to the daemon label |
    \(descriptionRow(settings))\(blueprintAssetRows(for: project))

    ### Step 3: Check a Mac
    In System Settings ▸ General ▸ Device Management, select the enrollment profile. Device Declarations \
    lists "Background Tasks: \(settings.taskType)"; select it to see how many executables, daemons and agents \
    arrived. The files are in `/private/var/db/ManagedConfigurationFiles/BackgroundTaskServices`; list them \
    with `sudo ls -R /var/db/ManagedConfigurationFiles/BackgroundTaskServices`.

    ### Updating
    Export again, re-host the changed files in `ddm/assets/`, and send the new declarations (or the new hashes) \
    to your MDM. Each declaration's `ServerToken` comes from the files' hashes, so it changes by itself whenever \
    the files do, and the Mac picks up the update.

    ### Removing
    Remove the background task from your MDM. There's no uninstall script for this mode.

    ### Troubleshooting
    Run `sudo ./check.sh --collect` on an affected Mac. The declarative status for background tasks \
    reports each task as enabled, requires-approval, not-registered or not-found. A wrong `Content-Type` or \
    hash stops the device from installing the task.
    """
    if let profileName {
      text += """


      ## Managed Login Items profile
      Deploy `\(profileName)` from your MDM to mark the jobs as managed.
      """
    }
    return text
  }

  private static func descriptionRow(_ settings: ProjectSettings) -> String {
    settings.taskDescription.isEmpty ? "" : "| Description (`TaskDescription`) | \(settings.taskDescription) |\n"
  }

  /// One row per asset: the executables ZIP (`ExecutableAssetReference`), then each launchd plist
  /// (`LaunchdConfigurations`).
  private static func blueprintAssetRows(for project: Project) -> String {
    // The exporter builds the same declarations before the README and stops on failure, so an error cannot
    // reach this point; an empty table is the harmless fallback.
    let assets = (try? DeclarativeGenerator.generate(for: project))?.assets ?? []
    var plistNumber = 0
    return assets.map { asset in
      let field: String
      if asset.contentType == "application/zip" {
        field = "Executable asset (`ExecutableAssetReference`)"
      } else {
        plistNumber += 1
        field = "Launchd asset \(plistNumber) (`LaunchdConfigurations`)"
      }
      return "| \(field) | URL of `\(asset.fileName)`, SHA-256 `\(asset.hash)`, content type `\(asset.contentType)` |"
    }.joined(separator: "\n")
  }

  /// The issues LaunchdOps found when exporting, so whoever deploys the folder sees them.
  static func validationSection(for project: Project, issues: [ValidationIssue]) -> String {
    guard !issues.isEmpty else { return "## Validation\n\nNo issues found." }
    let lines = issues.map { issue -> String in
      let scope = issue.jobID.flatMap { project.job(withID: $0)?.displayName } ?? "Project"
      return "- **\(issue.severity.title)** (\(scope)): \(issue.message) _Source: \(issue.source.rawValue)_"
    }
    return "## Validation\n\n\(issues.errorCount) errors, \(issues.warningCount) warnings.\n\n"
      + lines.joined(separator: "\n")
  }
}
