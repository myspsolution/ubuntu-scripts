#!/usr/bin/env bash
#
# ubuntu-update.sh
# Ubuntu/Debian update script with "smart restart" and all-or-nothing network handling.
#
# Behavior:
#   (no option)    update, then reboot ONLY if /var/run/reboot-required exists
#   --restart      update, then ALWAYS reboot at the end (only after a successful update)
#   --no-restart   update, never reboot (only report whether a reboot is needed)
#
# All or nothing:
#   Everything that needs the network happens first: checking the network,
#   refreshing the package index and downloading every upgrade. If the network
#   is down or a repository fails, the script stops right there: no package is
#   installed, upgraded or removed, and the server does NOT reboot, whatever the
#   restart option. Installing then runs offline from the downloaded files.
#   Any failure means: no reboot, and no "Finished update steps at:" line in the log.
#
# Phases:
#   0. Preflight   network route + DNS for every apt repository (or the apt proxy)
#   1. Fetch       apt-get update (strict: any failed repository is an error)
#                  + download all upgrades, with retries and time limits
#   2. Install     full-upgrade from the downloaded files only (no network, Ctrl+C disabled)
#   3. Tidy up     autoremove + clean
#
# Exit codes:
#   0  update completed successfully
#   1  failed while installing or tidying up, or could not start (sudo, lock, OS)
#   2  unknown option
#   3  network or download problem: nothing was changed
#
# When started from a terminal, a reboot is announced with a countdown
# that can be cancelled with Ctrl+C. From cron, it reboots immediately.
#
# Usage:
#   curl -fsSL <raw-url>/ubuntu-update.sh | bash
#   curl -fsSL <raw-url>/ubuntu-update.sh | bash -s -- --no-restart
#   bash ubuntu-update.sh --restart
#
# Example cron (root crontab, daily 02:12, conditional restart):
#   12 2 * * * /usr/bin/bash /opt/scripts/ubuntu-update.sh
# Example cron (sudoer with NOPASSWD, daily restart after a successful update):
#   12 2 * * * /usr/bin/bash /home/adminuic/ubuntu-update.sh --restart
#
# Log: /var/log/daily-update.log (rotated to .1 when larger than 10 MB)
# The line "Finished update steps at:" is written ONLY after a successful
# update; spstool.sh shows it as the latest update.
#
# Prepared by dicky.dwijanto@myspsolution.com
# Last update: 2026-11-12
#
# The whole script is wrapped in main(), which runs on the last line.
# If the download is cut off halfway, nothing runs at all.

main() {
  set -u
  PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

  local SCRIPT_NAME='ubuntu-update.sh'
  local LOG_FILE='/var/log/daily-update.log'
  local LOG_MAX_BYTES=$((10 * 1024 * 1024))
  local LOCK_FILE='/run/daily-update.lock'
  local APT_LOCK_TIMEOUT=600
  local UPDATE_TIMEOUT=$((APT_LOCK_TIMEOUT + 600))      # seconds per attempt
  local DOWNLOAD_TIMEOUT=$((APT_LOCK_TIMEOUT + 3600))   # seconds per attempt
  local RETRY_DELAY=30
  local REBOOT_COUNTDOWN=15

  # ----------------------------------------------------------
  # Parse arguments
  # ----------------------------------------------------------
  local RESTART_MODE='auto'   # auto | always | never
  local ARG
  for ARG in "$@"; do
    case "$ARG" in
      --restart|--force-restart) RESTART_MODE='always' ;;
      --no-restart)              RESTART_MODE='never' ;;
      --help|-h)
        cat <<EOF
Usage:
  ${SCRIPT_NAME}                 Update, reboot only if the system requires it.
  ${SCRIPT_NAME} --restart       Update, always reboot at the end.
  ${SCRIPT_NAME} --no-restart    Update, never reboot.

All or nothing: the network work (package index + downloads) runs first.
If it fails, nothing is changed and the server does not reboot.
Any failed update means no reboot, whatever the option.

From a terminal, a reboot is announced ${REBOOT_COUNTDOWN} seconds in advance
and can be cancelled with Ctrl+C.

Exit codes: 0 success, 1 install/tidy-up or start failure,
            2 unknown option, 3 network/download failure (nothing changed).
Log file: ${LOG_FILE}
EOF
        return 0
        ;;
      *)
        printf 'ERROR: unknown option: %s (see --help)\n' "$ARG" >&2
        return 2
        ;;
    esac
  done

  # Is there a person at the keyboard? (also true for "curl ... | bash")
  local INTERACTIVE=0
  if [ -t 1 ] && (exec </dev/tty) 2>/dev/null; then
    INTERACTIVE=1
  fi

  # ----------------------------------------------------------
  # Re-run as root if started by a sudoer.
  # Works for a saved file and for "curl ... | bash": the function itself
  # is handed to sudo, so no script file is needed.
  # ----------------------------------------------------------
  if [ "$(id -u)" -ne 0 ]; then
    if ! command -v sudo >/dev/null 2>&1; then
      echo 'ERROR: run this script as root, or as a sudoer with sudo installed.' >&2
      return 1
    fi
    echo "Script started as user: $(id -un)"
    echo 'Re-running as root using sudo...'
    local SUDO_OPTS=()
    if [ "$INTERACTIVE" -eq 0 ]; then
      SUDO_OPTS=(-n)   # cron: never wait for a password
    fi
    local RESTART_ARGS=()
    case "$RESTART_MODE" in
      always) RESTART_ARGS=(--restart) ;;
      never)  RESTART_ARGS=(--no-restart) ;;
    esac
    # "sudo true", not "sudo -v": -v asks for a password whenever ANY sudoers
    # rule of the user needs one (e.g. %sudo), even if NOPASSWD also applies.
    if ! sudo "${SUDO_OPTS[@]}" true; then
      echo 'ERROR: sudo access is required. Nothing was changed.' >&2
      return 1
    fi
    sudo "${SUDO_OPTS[@]}" /usr/bin/env bash -c "$(declare -f main); main \"\$@\"" \
      "$SCRIPT_NAME" "${RESTART_ARGS[@]}" </dev/null
    return $?
  fi

  # ----------------------------------------------------------
  # Root-only section starts here
  # ----------------------------------------------------------
  local RED='' YLW='' GRN='' CYN='' STD=''
  if [ "$INTERACTIVE" -eq 1 ] && [ -z "${NO_COLOR:-}" ]; then
    RED='\033[1;41;37m'; YLW='\033[1;33m'; GRN='\033[1;32m'; CYN='\033[1;36m'; STD='\033[0m'
  fi

  mkdir -p "$(dirname "$LOG_FILE")"
  if [ -f "$LOG_FILE" ] && [ "$(stat -c %s "$LOG_FILE")" -gt "$LOG_MAX_BYTES" ]; then
    mv -f "$LOG_FILE" "${LOG_FILE}.1"
  fi
  touch "$LOG_FILE"
  chmod 0644 "$LOG_FILE"

  # Terminal: show output and log it. Cron: write only to the log.
  # tee ignores Ctrl+C, so the last messages are still shown and logged.
  if [ "$INTERACTIVE" -eq 1 ]; then
    exec > >(trap '' INT; tee -a "$LOG_FILE") 2>&1
  else
    exec >>"$LOG_FILE" 2>&1
  fi

  now() { date '+%Y-%m-%d %H:%M:%S %Z'; }
  line() { echo '============================================================'; }
  phase() { echo ""; echo -e "${CYN}>>> PHASE $1${STD}"; }

  echo ""
  line
  echo "Update started at: $(now)"
  echo "Running as user: $(id -un)"
  echo "Original sudo user: ${SUDO_USER:-root}"
  # timeout: "hostname -f" asks DNS, which may hang when the network is down
  echo "Hostname: $(timeout 5 hostname -f 2>/dev/null || hostname)"
  echo "Kernel before update: $(uname -r)"
  echo "Restart mode: ${RESTART_MODE}"
  line

  local FAILED_STEP='' FAILED_CODE=0

  # run_step "Name" [--retry] command args...
  # Returns the command's exit code; the caller decides to stop on failure.
  run_step() {
    local STEP_NAME="$1"; shift
    local ATTEMPTS=1 TRY EXIT_CODE=0
    if [ "${1:-}" = '--retry' ]; then ATTEMPTS=3; shift; fi
    echo ""
    echo '------------------------------------------------------------'
    echo "Step: ${STEP_NAME}"
    echo "Started at: $(now)"
    echo "Command: $*"
    echo '------------------------------------------------------------'
    for ((TRY = 1; TRY <= ATTEMPTS; TRY++)); do
      "$@" </dev/null
      EXIT_CODE=$?
      [ "$EXIT_CODE" -eq 0 ] && break
      if [ "$TRY" -lt "$ATTEMPTS" ]; then
        echo "Attempt ${TRY} of ${ATTEMPTS} failed (exit code ${EXIT_CODE}). Retrying in ${RETRY_DELAY} seconds..."
        sleep "$RETRY_DELAY"
      fi
    done
    echo ""
    if [ "$EXIT_CODE" -eq 0 ]; then
      echo -e "${GRN}OK:${STD} ${STEP_NAME} completed successfully."
    else
      FAILED_STEP="$STEP_NAME"
      FAILED_CODE="$EXIT_CODE"
      echo -e "${RED}ERROR:${STD} ${STEP_NAME} failed with exit code ${EXIT_CODE}."
    fi
    echo "Step ended at: $(now)"
    return "$EXIT_CODE"
  }

  # Failure summary. Never writes "Finished update steps at:" and never reboots.
  report_failure() {
    local WHAT
    echo ""
    line
    echo -e "${RED}UPDATE FAILED${STD} at: $(now)"
    echo "Failed step: ${FAILED_STEP} (exit code ${FAILED_CODE})"
    for WHAT in "$@"; do
      echo "$WHAT"
    done
    echo "Restart mode: ${RESTART_MODE}. The server will NOT reboot because the update failed."
    if [ -f /var/run/reboot-required ]; then
      echo -e "${YLW}Note:${STD} a reboot is still pending from an earlier update (sudo reboot)."
    fi
    echo "Update script stopped at: $(now)"
    line
  }

  # ----------------------------------------------------------
  # Reboot, with a cancellable countdown when someone is watching
  # ----------------------------------------------------------
  do_reboot() {
    if [ "$INTERACTIVE" -eq 1 ]; then
      trap 'echo ""; echo -e "${YLW}Reboot cancelled.${STD} Reboot later with: sudo reboot"; line; sync; exit 130' INT
      echo ""
      echo -e "${YLW}The server will reboot in ${REBOOT_COUNTDOWN} seconds.${STD} Press Ctrl+C to cancel."
      echo 'Your SSH connection will drop; reconnect after 1-2 minutes.'
      sleep 0.5   # let the log writer (tee) finish printing first
      local SEC
      for ((SEC = REBOOT_COUNTDOWN; SEC > 0; SEC--)); do
        printf '\r  %2d ' "$SEC" >/dev/tty
        sleep 1
      done
      printf '\r     \n' >/dev/tty
      trap - INT
    fi
    echo "Rebooting at: $(now)"
    line
    sync
    sleep 1
    systemctl reboot || /sbin/reboot
    exit 0
  }

  # ----------------------------------------------------------
  # Prevent overlapping runs
  # ----------------------------------------------------------
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    echo ""
    echo -e "${RED}ERROR:${STD} Another update process is already running."
    echo "Skipped at: $(now)"
    echo 'Nothing was changed. No reboot triggered because another update process may be active.'
    line
    return 1
  fi

  # ----------------------------------------------------------
  # Check OS family
  # ----------------------------------------------------------
  local OS_ID='unknown' OS_LIKE='' OS_NAME='unknown'
  if [ -f /etc/os-release ]; then
    OS_ID=$(. /etc/os-release; echo "${ID:-unknown}")
    OS_LIKE=$(. /etc/os-release; echo "${ID_LIKE:-}")
    OS_NAME=$(. /etc/os-release; echo "${PRETTY_NAME:-unknown}")
  fi
  if ! echo "$OS_ID $OS_LIKE" | grep -qiE 'ubuntu|debian'; then
    echo ""
    echo -e "${RED}ERROR:${STD} This script runs on the Ubuntu/Debian family only."
    echo "Detected OS: ${OS_NAME}"
    echo 'Cannot safely run apt-get update/full-upgrade. Nothing was changed; no reboot.'
    line
    return 1
  fi
  echo "Detected OS: ${OS_NAME}"

  # ----------------------------------------------------------
  # APT settings
  # ----------------------------------------------------------
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a
  local APT_OPTIONS=(
    -y
    -o "DPkg::Lock::Timeout=${APT_LOCK_TIMEOUT}"
    -o "Dpkg::Options::=--force-confdef"
    -o "Dpkg::Options::=--force-confold"
  )
  # Network: retry each file, and give up on a stalled connection
  local NET_OPTS=(
    -o Acquire::Retries=3
    -o Acquire::http::Timeout=30
    -o Acquire::https::Timeout=30
  )

  # Phase 0: is there a network at all, and can apt's servers be found?
  net_preflight() {
    if command -v ip >/dev/null 2>&1 &&
       ! ip route show default 2>/dev/null | grep -q . &&
       ! ip -6 route show default 2>/dev/null | grep -q .; then
      echo 'No default network route: this server has no network/internet connection.'
      return 1
    fi
    echo 'Default network route: OK'

    local PROXY HOSTS H F BAD=0
    local LIST_FILES=() SRC_FILES=()
    # With an apt proxy, the repository names are resolved by the proxy, not here
    PROXY=$(apt-config dump 2>/dev/null |
      sed -nE 's/^Acquire::https?::Proxy "([^"]+)";$/\1/p' | grep -viE '^(DIRECT|false)$' | head -n 1)
    [ -z "$PROXY" ] && PROXY="${https_proxy:-${http_proxy:-}}"
    if [ -n "$PROXY" ]; then
      HOSTS=$(printf '%s\n' "$PROXY" | sed -E 's#^[a-z]+://##; s#^[^@]*@##; s#[:/].*$##')
      echo "apt uses a proxy; checking the proxy host: ${HOSTS}"
    else
      for F in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
        [ -f "$F" ] && LIST_FILES+=("$F")
      done
      for F in /etc/apt/sources.list.d/*.sources; do
        [ -f "$F" ] && SRC_FILES+=("$F")
      done
      # One-line style: "deb [options] URI ..."; deb822 style: "URIs:" in a
      # paragraph that is not "Enabled: no"
      HOSTS=$( {
          if [ "${#LIST_FILES[@]}" -gt 0 ]; then
            grep -hE '^[[:space:]]*deb(-src)?[[:space:]]' "${LIST_FILES[@]}"
          fi
          if [ "${#SRC_FILES[@]}" -gt 0 ]; then
            awk 'BEGIN { RS = "" } { p = tolower($0) } p !~ /(^|\n)[ \t]*enabled:[ \t]*no/ { print }' \
              "${SRC_FILES[@]}" | grep -iE '^[[:space:]]*URIs:'
          fi
        } | grep -oE '[a-z+]+://[^/[:space:]]+' |
          sed -E 's#^[a-z+]+://##; s#^[^@]*@##; s#:[0-9]+$##' | sort -u)
      if [ -z "$HOSTS" ]; then
        echo 'No network repositories found in the apt sources (nothing to check).'
        return 0
      fi
    fi
    for H in $HOSTS; do
      if timeout 20 getent ahosts "$H" >/dev/null 2>&1; then
        echo "DNS OK: ${H}"
      else
        echo "DNS FAILED: cannot resolve ${H}"
        BAD=1
      fi
    done
    [ "$BAD" -eq 0 ] || echo 'Check the network/DNS settings of this server (resolvectl status, /etc/resolv.conf).'
    return "$BAD"
  }

  # Phase 1a: apt-get update that fails when ANY repository fails.
  # By default apt-get update exits 0 when a repository cannot be reached.
  apt_update_strict() {
    local OUT RC
    OUT=$(mktemp) || return 1
    timeout --foreground -k 30 "$UPDATE_TIMEOUT" \
      apt-get update "${NET_OPTS[@]}" -o APT::Update::Error-Mode=any \
        -o "DPkg::Lock::Timeout=${APT_LOCK_TIMEOUT}" 2>&1 | tee "$OUT"
    RC=${PIPESTATUS[0]}
    # Older apt (e.g. Ubuntu 20.04) ignores Error-Mode: check the output too
    if [ "$RC" -eq 0 ] && grep -qE '^[WE]: (Failed to fetch|Some index files failed)' "$OUT"; then
      RC=100
    fi
    [ "$RC" -eq 124 ] && echo "apt-get update did not finish within ${UPDATE_TIMEOUT} seconds."
    rm -f "$OUT"
    return "$RC"
  }

  # Phase 1b: download every upgrade now, install nothing yet
  apt_download_all() {
    local RC
    timeout --foreground -k 30 "$DOWNLOAD_TIMEOUT" \
      apt-get "${APT_OPTIONS[@]}" "${NET_OPTS[@]}" --download-only full-upgrade
    RC=$?
    [ "$RC" -eq 124 ] && echo "Download did not finish within ${DOWNLOAD_TIMEOUT} seconds."
    return "$RC"
  }

  local NET_FAIL_MSG=(
    'Network or repository problem while fetching updates.'
    'Nothing was changed: no package was installed, upgraded or removed.'
    'Fix the network, then run this script again (files already downloaded are kept).'
    'Tip: broken IPv6 or a bad local mirror? See 00a-disable-ipv6.sh and 00b-fix-ubuntu-mirror.sh.'
  )

  # ----------------------------------------------------------
  # PHASE 0 + 1: everything that needs the network (no system change)
  # ----------------------------------------------------------
  phase '0/3: Network preflight (no changes)'
  run_step 'Check network and repository DNS' --retry net_preflight ||
    { report_failure "${NET_FAIL_MSG[@]}"; return 3; }

  phase '1/3: Fetch package index and download all upgrades (no changes)'
  run_step 'Refresh package index (strict)' --retry apt_update_strict ||
    { report_failure "${NET_FAIL_MSG[@]}"; return 3; }
  run_step 'Download all upgrades' --retry apt_download_all ||
    { report_failure "${NET_FAIL_MSG[@]}"; return 3; }

  # ----------------------------------------------------------
  # PHASE 2 + 3: offline. Ctrl+C is ignored so dpkg is never interrupted.
  # ----------------------------------------------------------
  trap '' INT
  phase '2/3: Install upgrades (offline, from the downloaded files)'
  [ "$INTERACTIVE" -eq 1 ] && echo 'Ctrl+C is disabled while packages are being installed.'
  if ! run_step 'Install upgrades' \
      apt-get "${APT_OPTIONS[@]}" --no-download full-upgrade; then
    trap - INT
    report_failure \
      'Installing failed. Some packages may be partly upgraded.' \
      'Fix the problem shown above, then run: sudo dpkg --configure -a' \
      'and run this script again.'
    return 1
  fi

  phase '3/3: Tidy up'
  if ! run_step 'Autoremove unused packages' \
      apt-get "${APT_OPTIONS[@]}" autoremove --purge ||
     ! run_step 'Clean APT cache' apt-get clean; then
    trap - INT
    report_failure \
      'All upgrades were installed, but tidying up failed.' \
      'Fix the problem shown above and run this script again.'
    return 1
  fi
  trap - INT

  # ----------------------------------------------------------
  # Summary (success only)
  # ----------------------------------------------------------
  echo ""
  line
  echo 'Update command summary'
  echo "Finished update steps at: $(now)"
  echo "Kernel currently running: $(uname -r)"
  echo -e "${GRN}All update steps completed successfully.${STD}"
  line

  # ----------------------------------------------------------
  # Check reboot requirement
  # ----------------------------------------------------------
  local REBOOT_REQUIRED=0
  echo ""
  echo 'Checking reboot requirement...'
  if [ -f /var/run/reboot-required ]; then
    REBOOT_REQUIRED=1
    echo -e "${YLW}Reboot is required by the system.${STD}"
    if [ -f /var/run/reboot-required.pkgs ]; then
      echo ""
      echo 'Packages requiring reboot:'
      sort -u /var/run/reboot-required.pkgs
    fi
  else
    echo 'No system-required reboot detected.'
  fi

  # ----------------------------------------------------------
  # Reboot logic
  # ----------------------------------------------------------
  echo ""
  case "$RESTART_MODE" in
    always)
      echo 'Restart policy: --restart was used. Server will reboot now.'
      do_reboot
      ;;
    never)
      echo 'Restart policy: --no-restart was used. Server will not reboot.'
      if [ "$REBOOT_REQUIRED" -eq 1 ]; then
        echo -e "${YLW}Remember to reboot later:${STD} sudo reboot"
      fi
      ;;
    *)
      echo 'Restart policy: conditional.'
      if [ "$REBOOT_REQUIRED" -eq 1 ]; then
        echo 'Reboot is required, so the server will reboot now.'
        do_reboot
      fi
      echo 'No reboot required. Server will not reboot.'
      ;;
  esac
  echo "Update script finished at: $(now)"
  line
  return 0
}

main "$@"; exit $?
