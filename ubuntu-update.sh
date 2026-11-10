#!/bin/bash
# update.sh
# Ubuntu/Debian automatic update script
#
# Behavior:
# - Normal run:
#     reboot only if /var/run/reboot-required exists
#
# - Run with --restart:
#     always reboot at the end, even if update commands fail
#
# Example manual:
#     /usr/bin/bash /home/orangt/update.sh
#
# Example cron with forced daily restart:
#     12 2 * * * /usr/sbin/runuser -l orangt -c '/usr/bin/bash /home/orangt/update.sh --restart'
# prepared by dicky.dwijanto@myspsolution.com
# last update: May 18th, 2026
set -u
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
LOG_FILE="/var/log/daily-update.log"
LOCK_FILE="/run/daily-update.lock"
APT_LOCK_TIMEOUT=600
RED='\033[1;41;37m'
YLW='\033[1;33m'
GRN='\033[1;32m'
STD='\033[0m'
FORCE_RESTART=0
CLEAN_ARGS=()
# ------------------------------------------------------------
# Parse arguments
# ------------------------------------------------------------
for ARG in "$@"; do
  case "$ARG" in
    --restart|--force-restart)
      FORCE_RESTART=1
      ;;
    --help|-h)
      echo "Usage:"
      echo "  $0"
      echo "  $0 --restart"
      echo ""
      echo "Without --restart:"
      echo "  Reboot only if /var/run/reboot-required exists."
      echo ""
      echo "With --restart:"
      echo "  Always reboot at the end, even if update commands fail."
      exit 0
      ;;
    *)
      CLEAN_ARGS+=("$ARG")
      ;;
  esac
done
# ------------------------------------------------------------
# Re-run as root if started by a sudoer
# ------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
  if ! command -v sudo >/dev/null 2>&1; then
    echo "ERROR: This script must be run as root or by a sudoer with sudo installed."
    exit 1
  fi
  SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
  SUDO_ARGS=()
  if [ "$FORCE_RESTART" -eq 1 ]; then
    SUDO_ARGS+=(--restart)
  fi
  echo "Script started as user: $(id -un)"
  echo "Re-running as root using sudo..."
  echo ""
  sudo -n /usr/bin/bash "$SCRIPT_PATH" "${SUDO_ARGS[@]}" "${CLEAN_ARGS[@]}"
  exit $?
fi
# ------------------------------------------------------------
# Root-only section starts here
# ------------------------------------------------------------
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 0644 "$LOG_FILE"
# If run from terminal, show output and log it.
# If run from cron/non-interactive shell, write only to log.
if [ -t 1 ]; then
  exec > >(tee -a "$LOG_FILE") 2>&1
else
  exec >> "$LOG_FILE" 2>&1
fi
echo ""
echo "============================================================"
echo "Update started at: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "Running as user: $(id -un)"
echo "Original sudo user: ${SUDO_USER:-root}"
echo "Hostname: $(hostname -f 2>/dev/null || hostname)"
echo "Kernel before update: $(uname -r)"
echo "Force restart: ${FORCE_RESTART}"
echo "============================================================"
ERROR_COUNT=0
FAILED_STEPS=()
log_error_step() {
  local STEP_NAME="$1"
  local EXIT_CODE="$2"
  ERROR_COUNT=$((ERROR_COUNT + 1))
  FAILED_STEPS+=("${STEP_NAME} exited with code ${EXIT_CODE}")
  echo ""
  echo -e "${RED}ERROR:${STD} ${STEP_NAME} failed with exit code ${EXIT_CODE}"
  echo "Continuing to next step..."
}
run_step() {
  local STEP_NAME="$1"
  shift
  echo ""
  echo "------------------------------------------------------------"
  echo "Step: ${STEP_NAME}"
  echo "Started at: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "Command: $*"
  echo "------------------------------------------------------------"
  "$@"
  local EXIT_CODE=$?
  if [ "$EXIT_CODE" -eq 0 ]; then
    echo ""
    echo -e "${GRN}OK:${STD} ${STEP_NAME} completed successfully."
  else
    log_error_step "$STEP_NAME" "$EXIT_CODE"
  fi
  echo "Finished at: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  # Always return success so the script continues.
  return 0
}
# ------------------------------------------------------------
# Flush logs and reboot
# ------------------------------------------------------------
flush_and_reboot() {
  sync
  sleep 1
  /sbin/reboot
}
# ------------------------------------------------------------
# Prevent overlapping runs
# ------------------------------------------------------------
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo ""
  echo -e "${RED}ERROR:${STD} Another update process is already running."
  echo "Skipped at: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "No reboot triggered because another update process may be active."
  echo "============================================================"
  exit 1
fi
# ------------------------------------------------------------
# Check OS family
# ------------------------------------------------------------
if [ ! -f /etc/os-release ]; then
  echo ""
  echo -e "${RED}ERROR:${STD} /etc/os-release not found."
  echo "Cannot safely continue."
  echo "============================================================"
  if [ "$FORCE_RESTART" -eq 1 ]; then
    echo "Force restart is enabled, but OS detection failed."
    echo "Rebooting anyway because --restart was requested."
    echo "============================================================"
    flush_and_reboot
  fi
  exit 1
fi
. /etc/os-release
OS_ID="${ID:-unknown}"
OS_LIKE="${ID_LIKE:-}"
if ! echo "$OS_ID $OS_LIKE" | grep -qiE 'ubuntu|debian'; then
  echo ""
  echo -e "${RED}ERROR:${STD} This script must run on Ubuntu/Debian family only."
  echo "Detected OS: ${PRETTY_NAME:-unknown}"
  echo "Cannot safely run apt-get update/full-upgrade."
  echo "============================================================"
  if [ "$FORCE_RESTART" -eq 1 ]; then
    echo "Force restart is enabled."
    echo "Rebooting anyway because --restart was requested."
    echo "============================================================"
    flush_and_reboot
  fi
  exit 1
fi
echo "Detected OS: ${PRETTY_NAME:-unknown}"
# ------------------------------------------------------------
# APT non-interactive settings
# ------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
APT_OPTIONS=(
  -y
  -o "DPkg::Lock::Timeout=${APT_LOCK_TIMEOUT}"
  -o "Dpkg::Options::=--force-confdef"
  -o "Dpkg::Options::=--force-confold"
)
# ------------------------------------------------------------
# Update steps
# All of these continue even if previous steps fail.
# ------------------------------------------------------------
run_step "Refresh package index" \
  apt-get update \
  -o "DPkg::Lock::Timeout=${APT_LOCK_TIMEOUT}"
run_step "Full upgrade packages" \
  apt-get "${APT_OPTIONS[@]}" full-upgrade
run_step "Autoremove unused packages" \
  apt-get "${APT_OPTIONS[@]}" autoremove --purge
run_step "Autoclean APT cache" \
  apt-get -y autoclean
run_step "Clean APT cache" \
  apt-get clean
# ------------------------------------------------------------
# Summary
# ------------------------------------------------------------
echo ""
echo "============================================================"
echo "Update command summary"
echo "Finished update steps at: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "Kernel currently running: $(uname -r)"
echo "Error count: ${ERROR_COUNT}"
if [ "$ERROR_COUNT" -gt 0 ]; then
  echo ""
  echo "Failed steps:"
  for FAILED_STEP in "${FAILED_STEPS[@]}"; do
    echo " - ${FAILED_STEP}"
  done
else
  echo "All update steps completed successfully."
fi
echo "============================================================"
# ------------------------------------------------------------
# Check reboot requirement
# ------------------------------------------------------------
REBOOT_REQUIRED=0
echo ""
echo "Checking reboot requirement..."
if [ -f /var/run/reboot-required ]; then
  REBOOT_REQUIRED=1
  echo -e "${YLW}Reboot is required by the system.${STD}"
  if [ -f /var/run/reboot-required.pkgs ]; then
    echo ""
    echo "Packages requiring reboot:"
    cat /var/run/reboot-required.pkgs
  fi
else
  echo "No system-required reboot detected."
fi
# ------------------------------------------------------------
# Reboot logic
# ------------------------------------------------------------
if [ "$FORCE_RESTART" -eq 1 ]; then
  echo ""
  echo "Restart policy: --restart was used."
  echo "Server will reboot regardless of update result."
  echo "Rebooting now at: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "============================================================"
  flush_and_reboot
elif [ "$REBOOT_REQUIRED" -eq 1 ]; then
  echo ""
  echo "Restart policy: conditional."
  echo "Reboot is required, so server will reboot now."
  echo "Rebooting now at: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "============================================================"
  flush_and_reboot
else
  echo ""
  echo "Restart policy: conditional."
  echo "No reboot required. Server will not reboot."
  echo "Update script finished at: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "============================================================"
fi
exit 0
