# LaunchdOps

A native macOS app for Mac admins that builds launchd LaunchDaemons, LaunchAgents and user LaunchAgents and packages them for fleet deployment. Create a job from scratch, import an existing plist or paste one from the clipboard, then set what runs, when it runs and how it restarts in a guided editor, with every setting explained and its plist key shown. LaunchdOps checks each job against Apple's launchd documentation and common deployment mistakes as you type, and its Summary tab describes in plain words what the plist will do, down to the exact command line launchd runs.

When the job is ready, export everything your MDM needs in one step:

- **A signed installer package, built by the app.** LaunchdOps writes the `.pkg` itself (no `pkgbuild`, no Terminal), with install scripts that also handle upgrades, and signs it with your Developer ID Installer certificate.
- **Notarized and stapled for you.** Turn on Notarize After Export and LaunchdOps sends the package to Apple with your App Store Connect API key, then staples the ticket, so Macs install it without warnings, even offline.
- **DDM background tasks.** For supervised Macs, export the assets and declarations for Apple's `background-tasks` configuration, the tamper-resistant way to run a job that even root can't stop or change.
- **Ready for any MDM.** A Managed Login Items profile so users can't turn the job off, a `check.sh` that reports each job's state to your MDM's inventory, an `uninstall.sh`, and a README with vendor-neutral steps plus notes for Jamf Pro, Intune, Workspace ONE, Kandji, Mosyle and others.

- **Bundle ID:** `com.karthikmac.LaunchdOps`
- **Requires:** macOS 15 or later (runs on macOS 15, 26 and 27; universal binary)
- **Distribution:** Mac App Store or Developer ID. The app is sandboxed, never loads jobs or asks for admin rights, and uses the network only to notarize and staple a package you choose to notarize.

## Features

**Build jobs**

- Launch Daemons, Launch Agents (all users) and User Launch Agents (`~/Library/LaunchAgents`), grouped that way in the sidebar
- Every job is its own item in a library that saves automatically: no Save dialogs, and jobs are there at the next launch. Rename, Duplicate Job (⌘D) and Delete are undoable
- New Job, Import Launchd Plists (XML or binary, one job per file), New Job from Clipboard (paste plist XML) and Import Project (`.launchdops`). Keys LaunchdOps doesn't edit are kept and exported unchanged
- General, Options and Export tabs, each setting with an ⓘ description and its plist key; Choose… for Program adds a file to the payload or references its existing path
- Add Argument puts the program path first when Program is set, so options such as `--silent` reach the program; empty rows are left out of the plist
- Calendar schedules, including conversion from a cron expression
- Payload files for the script or tool a job runs, installed root-owned with safe modes (apps and large software are better deployed separately and referenced by path)

**Understand and check**

- Summary tab: what the plist does in plain words, showing only keys it contains, with the full command line as it would be typed in Terminal
- Validation against `launchd.plist(5)`, Apple's daemon guide and Apple's MDM and DDM schemas, plus security checks (secrets, user-writable programs and folders, unsafe paths). Each issue says what it means (error: must fix, warning: review, note: recommendation), can be copied, and opens the tab that fixes it; every sidebar row shows its job's status
- Unsafe values (labels, identifiers, paths or payload modes that could be abused in root install scripts) stop the export even after Export Anyway
- Export tab ▸ Readiness: validation, signing, notarization, profile and payload at a glance

**Deploy with any MDM**

- Export one flat folder:
  - A finished installer package (`.pkg`) built by LaunchdOps, signed with your Developer ID Installer identity, or a package project with `build-pkg.sh` (Build Script output)
  - The Managed Login Items profile (`com.apple.servicemanagement`), optionally signed
  - A reference copy of each plist
  - `check.sh`: a status line for any MDM's inventory by default (`loaded (last exit N)`, `not-loaded`, `program-missing`, `no-user`, `version=not-installed`; `--result` or `RESULT_TAGS=true` for `<result>` tags), `--details` to test an installed copy, `--collect` for support diagnostics
  - `uninstall.sh`, which removes exactly what the package installed
  - `README.md` with vendor-neutral steps to test, deploy, check and remove the jobs, notes for common MDMs, and the validation results
- DDM background tasks (`com.apple.configuration.services.background-tasks`): assets, a deterministic executables ZIP and reference declarations in a `ddm/` folder, with the hashes and step-by-step MDM instructions in the README
- User Launch Agents are installed by the package into the logged-in user's `~/Library/LaunchAgents` and loaded for them
- Notarization in the app: after export, LaunchdOps uploads the package to Apple with your App Store Connect API key and staples the ticket. A Notarizing button in the toolbar shows each step and lets you cancel; the Dock icon bounces when it finishes
- Signing and notarization are set once for every job in Settings ▸ Signing, where each option explains how to get the certificate or API key it needs
- Deterministic output: the same job exports byte-identical files

## Preferences

LaunchdOps ▸ Settings stores each choice as its own key in the app's preferences (the domain is `com.karthikmac.LaunchdOps`; the file is in the app's sandbox container under `Library/Preferences`). You can read them with `defaults read com.karthikmac.LaunchdOps`, or set them for many Macs with a configuration profile for that domain.

| Key | Type | Setting |
| --- | --- | --- |
| `LabelPrefix` | String | General ▸ Label Prefix (for example `com.acme`) |
| `LogFolder` | String | General ▸ Log Folder for new daemons (for example `/Library/Logs/Acme`) |
| `SignPackage` | Boolean | Signing ▸ Sign the Package |
| `PackageSigningIdentity` | String | Signing ▸ Signing Identity (a Developer ID Installer identity name) |
| `NotarizeAfterExport` | Boolean | Signing ▸ Notarize After Export |
| `SignProfile` | Boolean | Signing ▸ Sign the Profile |
| `ProfileSigningIdentity` | String | Signing ▸ Managed Login Items Profile ▸ Signing Identity |

The notarization key is not a preference: it stays in the keychain.

## Keyboard shortcuts

Every command is also in the menu bar. The Delete key removes the selected job in the sidebar (Edit ▸ Delete).

| Shortcut | Command |
| --- | --- |
| ⌘N | File ▸ New Job… |
| ⌘D | Project ▸ Duplicate Job |
| ⇧⌘I | Project ▸ Import Launchd Plists… |
| ⌥⌘A | Project ▸ Add Payload Files… |
| ⌘1 · ⌘2 · ⌘3 · ⌘4 | Project ▸ General · Options · Export · Summary |
| ⇧⌘E | Project ▸ Export Deployment Folder… |
| ⌥⌘E | Project ▸ Export Selected Plist… |
| ⌘, | LaunchdOps ▸ Settings… |
| ⌘? | Help ▸ LaunchdOps Help |

## Where LaunchdOps keeps its data

| What | Where |
| --- | --- |
| Jobs | `~/Library/Containers/com.karthikmac.LaunchdOps/Data/Library/Application Support/Projects/<id>.launchdops`, one package per job, saved automatically |
| Settings | The preferences plist described above |
| Notarization API key | Your keychain (data protection keychain when the build is entitled to it, otherwise the login keychain; never synced) |
| Signing keys | Your keychain; LaunchdOps stores only the identity names and macOS asks before each use of a private key |

To move jobs to another Mac, use File ▸ Export Project… and Import Project….

## Logs

LaunchdOps writes to the unified log under the subsystem `com.karthikmac.LaunchdOps`, with one category per area: `App`, `Library`, `Export`, `Signing`, `Notarization` and `Stapling`. Help ▸ View Logs opens Console with the search on the clipboard. From Terminal:

```sh
log show --last 1h --info --predicate 'subsystem == "com.karthikmac.LaunchdOps"'
log stream --info --predicate 'subsystem == "com.karthikmac.LaunchdOps" AND category == "Notarization"'
```

File contents, environment values, keys and tokens are never logged; signing identity names are logged as private.

## Signing and notarization setup

Signing and notarization are optional. Without them LaunchdOps still validates and exports every file. Setting them up needs an Apple Developer Program membership. Settings ▸ Signing in the app explains each step too.

- **Developer ID Installer certificate** (signs the `.pkg`): [Creating Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/). Developer ID Application certificates, used for signing apps, are covered on the same page.
- **Signing the Managed Login Items profile** (optional) uses a Developer ID Application, Apple Development or Apple Distribution certificate: [Certificates overview](https://developer.apple.com/help/account/certificates/certificates-overview/).
- **App Store Connect API key** (for notarization): create a **Team key** and download its `.p8` file. Apple's [App Store Connect API key instructions](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api) describe the steps. The private key can be downloaded only once. Keep the Key ID and the Issuer ID, which LaunchdOps asks for. Apple's [Developer Program roles](https://developer.apple.com/support/roles/) list who can create Team keys and what each role can access.
  - Individual keys can't be used for notarization. Apple's page says they can't use `notaryTool`.
- **Notarization and stapling:** [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) explains the process. [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow) covers `notarytool` and `stapler`, which LaunchdOps uses behind the scenes.

LaunchdOps keeps the API key in your keychain. It never goes in a project, a log or a preference file.

## Building

You need a Mac with Xcode 16 or later. LaunchdOps has no third-party dependencies.

1. Clone the repository and open `LaunchdOps.xcodeproj`.
2. Select the **LaunchdOps** target ▸ **Signing & Capabilities**:
   - **Team:** choose your own team. A free Personal Team is enough to build and run on your Mac.
   - **Bundle Identifier:** change `com.karthikmac.LaunchdOps` to one of your own, for example `com.yourname.LaunchdOps`. The original is registered to the author's team.
3. Do the same for the **LaunchdOpsTests** target (use the same team; its bundle identifier ends in `Tests`).
4. Choose **Product ▸ Run** (⌘R) to build and run, or **Product ▸ Test** (⌘U) to run the tests.

For a universal app (Apple silicon and Intel), choose **Product ▸ Archive**; Release builds include both architectures.

Signing packages, signing profiles and notarizing inside the app need your own Developer ID certificates and App Store Connect API key (see [Signing and notarization setup](#signing-and-notarization-setup)). Everything else works without them.

The project uses folder-synchronized groups: files added to `LaunchdOps/` or `LaunchdOpsTests/` are picked up automatically.

## Project file format

A `.launchdops` project is a package folder, designed to be kept in git:

```
Example.launchdops/
  project.json        settings and manifest
  Jobs/<uuid>.plist   each job as a real launchd plist
  Payload/<uuid>      payload file contents
```

## License

LaunchdOps is released under the [MIT License](LICENSE).

## Acknowledgements

Developed by Karthikeyan Marappan.

- Apple — SwiftUI framework
- Jamf — Jamf Pro API documentation
- Mac Admins India — https://macadmins.in/
- Jamf Nation Community — Feedback and feature requests
