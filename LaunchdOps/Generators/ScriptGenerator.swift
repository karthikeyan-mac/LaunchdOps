import Foundation

enum ScriptGenerator {
  private static let header = "#!/bin/zsh --no-rcs"

  private static let guiUsersFunction = #"""
  gui_uids() {
    /bin/ps -axo uid=,comm= | /usr/bin/awk '$2 ~ /loginwindow$/ && $1 != 0 { print $1 }' | /usr/bin/sort -u
  }
  """#

  /// Local user accounts (UID 501 and up) and their home folders, for User Launch Agents.
  private static let userAccountFunctions = #"""
  local_users() {
    /usr/bin/dscl . -list /Users UniqueID | /usr/bin/awk '$2 >= 501 { print $1 }'
  }

  home_of() {
    /usr/bin/dscl . -read "/Users/$1" NFSHomeDirectory 2>/dev/null | /usr/bin/sed -n 's/^NFSHomeDirectory: //p'
  }
  """#

  private static let waitFunction = #"""
  wait_for_removal() {
    local target=$1 attempt
    for attempt in {1..20}; do
      /bin/launchctl print "$target" >/dev/null 2>&1 || return 0
      /bin/sleep 0.25
    done
    return 1
  }
  """#

  /// Prefix of every message the scripts send to the unified log, so admins can find them with
  /// `log show --predicate 'process == "logger" AND eventMessage BEGINSWITH "LaunchdOps:"'`.
  static let logPrefix = "LaunchdOps:"

  /// Prints a step (Installer copies it to /var/log/install.log) and sends it to the unified log.
  private static let logFunction = #"""
  log_step() {
    echo "LaunchdOps: $*"
    /usr/bin/logger -- "LaunchdOps: $*"
  }
  """#

  /// Copies a staged User Launch Agent into the logged-in user's ~/Library/LaunchAgents and loads it in their
  /// session. The copy runs as that user, so root never writes into a folder the user controls (a symbolic link
  /// there could otherwise send root's write anywhere). With nobody logged in, nothing is installed.
  private static let userAgentFunction = #"""
  home_of() {
    /usr/bin/dscl . -read "/Users/$1" NFSHomeDirectory 2>/dev/null | /usr/bin/sed -n 's/^NFSHomeDirectory: //p'
  }

  install_user_agent() {
    local label=$1 staged=$2 name=$3 load=$4 user uid home folder plist
    secure_plist "$staged" || { failures+=1; return }
    user=$(/usr/bin/stat -f %Su /dev/console)
    if [[ -z "$user" || "$user" == root || "$user" == loginwindow || "$user" == _mbsetupuser ]]; then
      log_step "no user is logged in, so $label was not installed; install the package again after login"
      return
    fi
    home=$(home_of "$user")
    uid=$(/usr/bin/id -u "$user") || { failures+=1; return }
    if [[ -z "$home" || ! -d "$home/Library" ]]; then
      log_step "could not find the home folder of $user"
      failures+=1
      return
    fi
    folder="$home/Library/LaunchAgents"
    plist="$folder/$name"
    if ! /usr/bin/sudo -u "$user" /bin/mkdir -p -m 755 "$folder" \
      || ! /usr/bin/sudo -u "$user" /bin/cp -f "$staged" "$plist" \
      || ! /usr/bin/sudo -u "$user" /bin/chmod 644 "$plist"; then
      log_step "could not install $label for $user"
      failures+=1
      return
    fi
    log_step "installed $label for $user"
    [[ "$load" == load ]] || return
    /bin/launchctl bootout "gui/$uid/$label" 2>/dev/null
    wait_for_removal "gui/$uid/$label"
    /bin/launchctl enable "gui/$uid/$label"
    if /bin/launchctl bootstrap "gui/$uid" "$plist"; then
      log_step "loaded $label for $user"
    else
      log_step "could not load $label for $user"
      failures+=1
    fi
  }
  """#

  /// Removes a User Launch Agent's exact plist from each local account, as that user.
  private static let removeUserAgentFunction = #"""
  \#(userAccountFunctions)

  remove_user_agent() {
    local name=$1 user home
    for user in $(local_users); do
      home=$(home_of "$user")
      [[ -n "$home" ]] || continue
      if [[ -e "$home/Library/LaunchAgents/$name" || -L "$home/Library/LaunchAgents/$name" ]]; then
        /usr/bin/sudo -u "$user" /bin/rm -f "$home/Library/LaunchAgents/$name" && log_step "removed $name for $user"
      fi
    done
  }
  """#

  private static func domain(for job: LaunchJob) -> String {
    job.context == .daemon ? "system" : "gui"
  }

  // MARK: - Package scripts

  static func preinstall(for project: Project) -> String {
    let unloads = (project.packagedJobs + project.userAgentJobs)
      .map { "unload_job \(Shell.quoted($0.label))" }
    let retired = project.settings.retiredLabels
      .filter(Validator.isValidLabel)
      .map { "remove_retired \(Shell.quoted($0))" }
    // The payload puts the rule back when this version still rotates logs.
    let rotation = LogRotation.configPath(for: project).map { ["/bin/rm -f \(Shell.quoted($0))"] } ?? []

    return #"""
    \#(header)
    # \#(GeneratorInfo.banner) for \#(project.settings.name).
    # Runs as root before the package installs. Stops current jobs so their files can be replaced,
    # and removes jobs retired in earlier versions.

    [[ "$3" == "/" ]] || exit 0

    \#(guiUsersFunction)

    \#(logFunction)

    unload_job() {
      local label=$1 uid
      log_step "stopping $label"
      /bin/launchctl bootout "system/$label" 2>/dev/null
      for uid in $(gui_uids); do
        /bin/launchctl bootout "gui/$uid/$label" 2>/dev/null
      done
    }

    remove_retired() {
      local label=$1
      unload_job "$label"
      /bin/rm -f "/Library/LaunchDaemons/$label.plist" "/Library/LaunchAgents/$label.plist"
      log_step "removed retired job $label"
    }

    \#(lines(unloads + retired + rotation))

    exit 0

    """#
  }

  static func postinstall(for project: Project) -> String {
    let payloadLines = project.payload.flatMap { file -> [String] in
      let path = Shell.quoted(project.installPath(for: file))
      return [
        "/usr/sbin/chown root:wheel \(path)",
        "/bin/chmod \(file.modeString) \(path)"
      ]
    }
    let rotation = LogRotation.configFile(for: project).map { config -> [String] in
      let path = Shell.quoted(config.path)
      return ["/usr/sbin/chown root:wheel \(path)", "/bin/chmod 644 \(path)"]
    } ?? []
    let folderLines = LogRotation.logFolders(for: project).map { "make_log_folder \(Shell.quoted($0))" }
    let loadLines = project.packagedJobs.map { job -> String in
      let label = Shell.quoted(job.label)
      let plist = Shell.quoted(job.installPath)
      if job.disabled {
        // The comment names no value from the project, so nothing can end it early.
        return "secure_plist \(plist)  # Disabled: installed but not loaded"
      }
      return job.context == .daemon ? "load_daemon \(label) \(plist)" : "load_agent \(label) \(plist)"
    }
    let userAgentLines = project.userAgentJobs.map { job -> String in
      let arguments = [job.label, Project.stagedPath(for: job), job.fileName].map(Shell.quoted)
      return "install_user_agent \(arguments.joined(separator: " ")) \(job.disabled ? "no-load" : "load")"
    }

    return #"""
    \#(header)
    # \#(GeneratorInfo.banner) for \#(project.settings.name).
    # Runs as root after the package installs. Secures files, then loads each job.

    [[ "$3" == "/" ]] || exit 0

    typeset -i failures=0

    \#(guiUsersFunction)

    \#(waitFunction)

    \#(logFunction)

    # launchd creates missing log files but not missing folders.
    make_log_folder() {
      [[ -d "$1" ]] || /bin/mkdir -p -m 755 "$1"
    }

    secure_plist() {
      /usr/sbin/chown root:wheel "$1" && /bin/chmod 644 "$1"
    }

    load_daemon() {
      local label=$1 plist=$2
      secure_plist "$plist" || { failures+=1; return }
      /bin/launchctl bootout "system/$label" 2>/dev/null
      wait_for_removal "system/$label"
      /bin/launchctl enable "system/$label"
      if /bin/launchctl bootstrap system "$plist"; then
        log_step "loaded $label"
      else
        log_step "could not load $label"
        failures+=1
      fi
    }

    load_agent() {
      local label=$1 plist=$2 uid
      secure_plist "$plist" || { failures+=1; return }
      for uid in $(gui_uids); do
        /bin/launchctl bootout "gui/$uid/$label" 2>/dev/null
        wait_for_removal "gui/$uid/$label"
        /bin/launchctl enable "gui/$uid/$label"
        if /bin/launchctl bootstrap "gui/$uid" "$plist"; then
          log_step "loaded $label for user $uid"
        else
          log_step "could not load $label for user $uid"
          failures+=1
        fi
      done
    }
    \#(project.userAgentJobs.isEmpty ? "" : "\n" + userAgentFunction + "\n")
    \#(lines(payloadLines + rotation))

    \#(lines(folderLines))

    \#(lines(loadLines + userAgentLines))

    log_step \#(Shell.quoted("installed \(project.settings.packageIdentifier) \(project.settings.version)"))
    exit $(( failures > 0 ? 1 : 0 ))

    """#
  }

  // MARK: - Standalone scripts

  static func uninstall(for project: Project) -> String {
    let unloads = (project.packagedJobs + project.userAgentJobs).map { "unload_job \(Shell.quoted($0.label))" }
    let removals = project.packagedPlists.map { "/bin/rm -f \(Shell.quoted($0.path))" }
      + project.userAgentJobs.map { "remove_user_agent \(Shell.quoted($0.fileName))" }
      + project.payload.map { "/bin/rm -f \(Shell.quoted(project.installPath(for: $0)))" }
      + (LogRotation.configPath(for: project).map { ["/bin/rm -f \(Shell.quoted($0))"] } ?? [])

    return #"""
    \#(header)
    # \#(GeneratorInfo.banner) for \#(project.settings.name).
    # Removes every job and file this project installs. Usage: sudo ./uninstall.sh

    if [[ $EUID -ne 0 ]]; then
      echo "Run this script with sudo." >&2
      exit 1
    fi

    \#(guiUsersFunction)

    \#(logFunction)

    unload_job() {
      local label=$1 uid
      log_step "stopping $label"
      /bin/launchctl bootout "system/$label" 2>/dev/null
      for uid in $(gui_uids); do
        /bin/launchctl bootout "gui/$uid/$label" 2>/dev/null
      done
    }
    \#(project.userAgentJobs.isEmpty ? "" : "\n" + removeUserAgentFunction + "\n")
    \#(lines(unloads))

    \#(lines(removals))

    /usr/sbin/pkgutil --forget \#(Shell.quoted(project.settings.packageIdentifier)) >/dev/null 2>&1

    log_step \#(Shell.quoted("removed \(project.settings.name)"))
    exit 0

    """#
  }

  // MARK: - check.sh

  /// One script for every check: a status line for any MDM's inventory by default, `--details` to test an
  /// installed copy, and `--collect` to gather launchd details and logs for support.
  static func check(for project: Project) -> String {
    let settings = project.settings
    let isPackage = settings.mode == .package
    let plists = isPackage ? project.packagedPlists : project.jobs.map { ($0, $0.installPath) }
    let statusLines = plists.map { entry in
      let arguments = [entry.job.label, domain(for: entry.job), entry.job.executablePath].map(Shell.quoted)
      return "results+=(\"$(job_status \(arguments.joined(separator: " ")))\")"
    }
    // DDM keeps its plists in a protected folder, so only launchd state is checked there.
    let detailLines = plists.map { entry in
      let path = isPackage ? entry.path : ""
      return "check_job \(Shell.quoted(entry.job.label)) \(Shell.quoted(path)) \(domain(for: entry.job))"
    }
    let payloadChecks =
      isPackage
      ? project.payload.map { "check_file \(Shell.quoted(project.installPath(for: $0))) \($0.modeString)" }
        + (LogRotation.configFile(for: project).map { ["check_file \(Shell.quoted($0.path)) 644"] } ?? [])
      : []
    let collectLines = plists.map { entry in
      let job = entry.job
      let arguments = [job.label, entry.path, domain(for: job), job.standardOutPath, job.standardErrorPath]
      return "collect_job \(arguments.map(Shell.quoted).joined(separator: " ")) \"$output\""
    }
    let labelTerms = plists.map { "eventMessage CONTAINS \"\($0.job.label)\"" }.joined(separator: " OR ")
    let predicate = labelTerms.isEmpty ? "process == \"launchd\"" : "process == \"launchd\" AND (\(labelTerms))"
    let identifier = Shell.quoted(settings.packageIdentifier)
    let versionLine =
      isPackage
      ? "pkg_version=$(/usr/sbin/pkgutil --pkg-info \(identifier) 2>/dev/null | /usr/bin/awk '/^version:/ { print $2 }')"
        + "\n  summary=\"version=${pkg_version:-not-installed}\""
      : "summary=\"\""

    return #"""
    \#(header)
    # \#(GeneratorInfo.banner) for \#(settings.name).
    # Checks this project's jobs on a Mac.
    # Usage: check.sh                        one status line, for your MDM's inventory
    #        check.sh --result               the same line inside <result></result>
    #        sudo check.sh --details         check files, ownership and launchd state on a test Mac
    #        sudo check.sh --details --run   also start each job now with launchctl kickstart
    #        sudo check.sh --collect         save launchd details and logs for support
    # Status values: loaded (last exit N), not-loaded, program-missing, no-user (agents, nobody logged in),
    # and version=not-installed when the package receipt is missing.
    # Tools that can't pass arguments (for example Jamf Pro extension attributes): set RESULT_TAGS=true below.

    RESULT_TAGS=false
    mode=status
    run_jobs=false
    # Unknown arguments are ignored: some tools pass their own (a policy script gets the target volume first).
    for argument in "$@"; do
      case $argument in
        --result) RESULT_TAGS=true ;;
        --details) mode=details ;;
        --run) run_jobs=true ;;
        --collect) mode=collect ;;
      esac
    done

    \#(guiUsersFunction)

    require_root() {
      if [[ $EUID -ne 0 ]]; then
        echo "Run this with sudo." >&2
        exit 1
      fi
    }

    # MARK: Status line

    job_status() {
      local label=$1 domain=$2 program=$3 console_uid target output code
      if [[ "$program" == /* && ! -e "$program" ]]; then
        print -r -- "$label=program-missing"
        return
      fi
      if [[ "$domain" == system ]]; then
        target="system/$label"
      else
        console_uid=$(/usr/bin/stat -f %u /dev/console)
        if (( console_uid == 0 )); then
          print -r -- "$label=no-user"
          return
        fi
        target="gui/$console_uid/$label"
      fi
      if ! output=$(/bin/launchctl print "$target" 2>/dev/null); then
        print -r -- "$label=not-loaded"
        return
      fi
      code=$(print -r -- "$output" | /usr/bin/awk -F'= ' '/last exit code/ { print $2; exit }')
      print -r -- "$label=loaded${code:+ (last exit $code)}"
    }

    report_status() {
      local -a results
      \#(versionLine)
      \#(lines(statusLines, indent: "  "))
      (( ${#results} > 0 )) && summary="${summary:+$summary; }${(j:; :)results}"
      if [[ "$RESULT_TAGS" == true ]]; then
        echo "<result>$summary</result>"
      else
        echo "$summary"
      fi
    }

    # MARK: Details

    typeset -i problems=0

    check_file() {
      local file=$1 mode=$2 actual
      if [[ ! -e "$file" ]]; then
        echo "  MISSING  $file"
        problems+=1
        return
      fi
      actual=$(/usr/bin/stat -f '%Su:%Sg %Lp' "$file")
      if [[ "$actual" != "root:wheel $mode" ]]; then
        echo "  PERMS    $file is $actual, expected root:wheel $mode"
        problems+=1
      else
        echo "  OK       $file"
      fi
    }

    check_job() {
      local label=$1 plist=$2 domain=$3 target uid
      local -a targets
      echo "== $label"
      if [[ -n "$plist" ]]; then
        check_file "$plist" 644
        [[ -f "$plist" ]] || return
        if ! /usr/bin/plutil -lint "$plist" >/dev/null; then
          echo "  INVALID  $plist does not parse"
          problems+=1
        fi
      fi
      if [[ "$domain" == system ]]; then
        targets=("system/$label")
      else
        for uid in $(gui_uids); do targets+=("gui/$uid/$label"); done
        if (( ${#targets} == 0 )); then
          echo "  SKIPPED  no user is logged in, so the agent cannot be checked"
          return
        fi
      fi
      for target in $targets; do
        if /bin/launchctl print "$target" >/dev/null 2>&1; then
          echo "  LOADED   $target"
          /bin/launchctl print "$target" | /usr/bin/grep -E '^[[:space:]]*(state|last exit code|runs) =' \
            | /usr/bin/sed 's/^[[:space:]]*/           /'
          if $run_jobs; then
            /bin/launchctl kickstart -k "$target" && echo "  STARTED  $target"
          fi
        else
          echo "  UNLOADED $target"
          problems+=1
        fi
      done
    }

    report_details() {
      require_root
      echo "Payload"
      \#(lines(payloadChecks, indent: "  "))

      \#(lines(detailLines, indent: "  "))

      echo
      if (( problems > 0 )); then
        echo "$problems problem(s) found. Run sudo ./check.sh --collect for details."
        exit 1
      fi
      echo "All checks passed."
    }

    # MARK: Collect

    # The last lines of a log file the job itself defines. Read only; a missing path is noted.
    log_tail() {
      local file=$1
      [[ -n "$file" ]] || return
      echo
      echo "## Last 200 lines of $file"
      if [[ -f "$file" ]]; then
        /usr/bin/tail -n 200 "$file" 2>&1
      else
        echo "(no file)"
      fi
    }

    collect_job() {
      local label=$1 plist=$2 domain=$3 stdout=$4 stderr=$5 output=$6 target uid domain_target
      local -a targets domains
      if [[ "$domain" == system ]]; then
        targets=("system/$label")
        domains=(system)
      else
        for uid in $(gui_uids); do
          targets+=("gui/$uid/$label")
          domains+=("gui/$uid")
        done
      fi
      {
        echo "## Files"
        /bin/ls -le "$plist" 2>&1
        /usr/bin/plutil -p "$plist" 2>&1
        for domain_target in $domains; do
          echo
          echo "## launchctl print-disabled $domain_target (this job)"
          /bin/launchctl print-disabled "$domain_target" 2>&1 | /usr/bin/grep -F "\"$label\"" \
            || echo "not listed: the job has not been enabled or disabled explicitly"
        done
        for target in $targets; do
          echo
          echo "## launchctl print $target"
          /bin/launchctl print "$target" 2>&1
          echo
          echo "## launchctl blame $target"
          /bin/launchctl blame "$target" 2>&1
        done
        log_tail "$stdout"
        [[ "$stderr" != "$stdout" ]] && log_tail "$stderr"
      } > "$output/$label.txt"
    }

    report_collect() {
      require_root
      local output="/private/tmp/LaunchdOps-\#(settings.safeName)-$(/bin/date +%Y%m%d-%H%M%S)"
      /bin/mkdir -p "$output"
      /bin/chmod 700 "$output"
      \#(lines(collectLines, indent: "  "))
      /usr/bin/sfltool dumpbtm > "$output/background-task-management.txt" 2>&1
      /usr/bin/log show --last 1h --style compact --predicate \#(Shell.quoted(predicate)) \
        > "$output/launchd.log" 2>&1
      /usr/bin/log show --last 7d --style compact \
        --predicate \#(Shell.quoted("process == \"logger\" AND eventMessage BEGINSWITH \"\(logPrefix)\"")) \
        > "$output/install-steps.log" 2>&1
      # Hand the folder to the admin who ran sudo, so Finder can open it. Still mode 700.
      if [[ "${SUDO_UID:-}" == <1-> ]]; then
        /usr/sbin/chown -R "$SUDO_UID" "$output"
      fi
      echo "Diagnostics saved to $output"
    }

    case $mode in
      status) report_status ;;
      details) report_details ;;
      collect) report_collect ;;
    esac
    exit 0

    """#
  }

  /// Script lines for a template; `indent` lines up every line after the first inside a function body.
  private static func lines(_ values: [String], indent: String = "") -> String {
    values.isEmpty ? ":" : values.joined(separator: "\n" + indent)
  }
}
