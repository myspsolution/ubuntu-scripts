#!/usr/bin/env bash
#
# ubuntu-update.sh
# Ubuntu/Debian update script with "smart restart".
#
# Behavior:
#   (no option)    update, then reboot ONLY if /var/run/reboot-required exists
#   --restart      update, then ALWAYS reboot at the end, even if update steps fail
#   --no-restart   update, never reboot (only report whether a reboot is needed)
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
# Example cron (sudoer with NOPASSWD, forced daily restart):
#   12 2 * * * /usr/bin/bash /home/orangt/ubuntu-update.sh --restart
#
# Log: /var/log/daily-update.log (rotated to .1 when larger than 10 MB)
#
# Prepared by dicky.dwijanto@myspsolution.com
# Last update: 2026-11-11
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

From a terminal, a reboot is announced ${REBOOT_COUNTDOWN} seconds in advance
and can be cancelled with Ctrl+C.
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
    if ! sudo "${SUDO_OPTS[@]}" -v; then
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
  local RED='' YLW='' GRN='' STD=''
  if [ "$INTERACTIVE" -eq 1 ] && [ -z "${NO_COLOR:-}" ]; then
    RED='\033[1;41;37m'; YLW='\033[1;33m'; GRN='\033[1;32m'; STD='\033[0m'
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

  echo ""
  line
  echo "Update started at: $(now)"
  echo "Running as user: $(id -un)"
  echo "Original sudo user: ${SUDO_USER:-root}"
  echo "Hostname: $(hostname -f 2>/dev/null || hostname)"
  echo "Kernel before update: $(uname -r)"
  echo "Restart mode: ${RESTART_MODE}"
  line

  local ERROR_COUNT=0
  local FAILED_STEPS=()

  log_error_step() {
    local STEP_NAME="$1" EXIT_CODE="$2"
    ERROR_COUNT=$((ERROR_COUNT + 1))
    FAILED_STEPS+=("${STEP_NAME} exited with code ${EXIT_CODE}")
    echo ""
    echo -e "${RED}ERROR:${STD} ${STEP_NAME} failed with exit code ${EXIT_CODE}"
    echo "Continuing to next step..."
  }

  # run_step "Name" [--retry] command args...
  # Never stops the script; a failure is counted and reported at the end.
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
        echo "Attempt ${TRY} failed (exit code ${EXIT_CODE}). Retrying in 30 seconds..."
        sleep 30
      fi
    done
    if [ "$EXIT_CODE" -eq 0 ]; then
      echo ""
      echo -e "${GRN}OK:${STD} ${STEP_NAME} completed successfully."
    else
      log_error_step "$STEP_NAME" "$EXIT_CODE"
    fi
    echo "Finished at: $(now)"
    return 0
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
    echo 'No reboot triggered because another update process may be active.'
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
    echo 'Cannot safely run apt-get update/full-upgrade.'
    line
    if [ "$RESTART_MODE" = 'always' ]; then
      echo 'Restart mode is "always" (--restart): rebooting anyway.'
      do_reboot
    fi
    return 1
  fi
  echo "Detected OS: ${OS_NAME}"

  # ----------------------------------------------------------
  # APT non-interactive settings
  # ----------------------------------------------------------
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a
  local APT_OPTIONS=(
    -y
    -o "DPkg::Lock::Timeout=${APT_LOCK_TIMEOUT}"
    -o "Dpkg::Options::=--force-confdef"
    -o "Dpkg::Options::=--force-confold"
  )

  # ----------------------------------------------------------
  # Update steps (each step runs even if a previous one failed)
  # ----------------------------------------------------------
  run_step 'Refresh package index' --retry \
    apt-get update -o "DPkg::Lock::Timeout=${APT_LOCK_TIMEOUT}"
  run_step 'Full upgrade packages' \
    apt-get "${APT_OPTIONS[@]}" full-upgrade
  run_step 'Autoremove unused packages' \
    apt-get "${APT_OPTIONS[@]}" autoremove --purge
  run_step 'Clean APT cache' \
    apt-get clean

  # ----------------------------------------------------------
  # Summary
  # ----------------------------------------------------------
  echo ""
  line
  echo 'Update command summary'
  echo "Finished update steps at: $(now)"
  echo "Kernel currently running: $(uname -r)"
  echo "Error count: ${ERROR_COUNT}"
  if [ "$ERROR_COUNT" -gt 0 ]; then
    echo ""
    echo 'Failed steps:'
    local FAILED_STEP
    for FAILED_STEP in "${FAILED_STEPS[@]}"; do
      echo " - ${FAILED_STEP}"
    done
  else
    echo 'All update steps completed successfully.'
  fi
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
      echo 'Restart policy: --restart was used.'
      echo 'Server will reboot regardless of update result.'
      do_reboot
      ;;
    never)
      echo 'Restart policy: --no-restart was used. Server will not reboot.'
      if [ "$REBOOT_REQUIRED" -eq 1 ]; then
        echo -e "${YLW}Remember to reboot later:${STD} sudo reboot"
      fi
      ;;
    *)
      if [ "$REBOOT_REQUIRED" -eq 1 ]; then
        echo 'Restart policy: conditional.'
        echo 'Reboot is required, so the server will reboot now.'
        do_reboot
      fi
      echo 'Restart policy: conditional.'
      echo 'No reboot required. Server will not reboot.'
      ;;
  esac
  echo "Update script finished at: $(now)"
  line

  [ "$ERROR_COUNT" -eq 0 ]
}

main "$@"; exit $?
