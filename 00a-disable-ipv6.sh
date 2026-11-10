#!/usr/bin/env bash

# 00a-disable-ipv6.sh
# Disable IPv6 persistently and on current interfaces.
# Revised: 2026-10-28 05-55-45
# prepared by dicky.dwijanto@myspsolution.com
# Usage: bash 00a-disable-ipv6.sh

if [ -z "${BASH_VERSION:-}" ]; then
  printf '%s\n' 'Error: run this script with bash, not another shell.' >&2
  exit 1
fi

if shopt -oq posix; then
  printf '%s\n' 'Error: run this script with bash, not sh or Bash POSIX mode.' >&2
  exit 1
fi

set -Eeuo pipefail

readonly RED="\033[1;41;37m"
readonly YLW="\033[1;33m"
readonly STD="\033[0m"
readonly BLD="\033[1;97m"
readonly SYSCTL_FILE="/etc/sysctl.d/99-disable-ipv6.conf"
readonly IPV6_CONTROLS="/proc/sys/net/ipv6/conf"

TEMPORARY_FILE=""
TEMPORARY_OWNED=0
BACKUP=""
INSTALL_NEEDED=1
SETTINGS=()
ENABLED_INTERFACES=()

log() {
  printf '[disable-ipv6] %s\n' "$*"
}

fail() {
  printf '[disable-ipv6] ERROR: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if (( TEMPORARY_OWNED )); then
    rm -f -- "$TEMPORARY_FILE"
  fi
}

configuration() {
  printf '%s\n' \
    '# Managed by disable-ipv6.sh' \
    '# Disable IPv6 persistently without disabling the IPv6 kernel module.' \
    'net.ipv6.conf.all.disable_ipv6 = 1' \
    'net.ipv6.conf.default.disable_ipv6 = 1' \
    'net.ipv6.conf.lo.disable_ipv6 = 1'
}

require_authorization() {
  if (( EUID == 0 )); then
    return 0
  fi
  if [[ -t 0 && -t 2 ]]; then
    sudo -l -- "$@" >/dev/null || fail "Sudo authentication or authorization failed for $1; check its arguments in sudoers."
  else
    sudo -n -l -- "$@" >/dev/null || fail "Noninteractive sudo authentication or authorization failed for $1; authenticate or check its arguments in sudoers."
  fi
}

run_privileged() {
  if (( EUID == 0 )); then
    "$@"
  else
    sudo -n -- "$@"
  fi
}

# ---------------- Starting script ----------------

trap cleanup EXIT

command -v sysctl >/dev/null 2>&1 || fail 'sysctl was not found.'
SYSCTL_COMMAND=$(command -v sysctl)
INSTALL_COMMAND=$(command -v install) || fail 'install was not found.'
CP_COMMAND=$(command -v cp) || fail 'cp was not found.'
TEE_COMMAND=$(command -v tee) || fail 'tee was not found.'

if [[ -f "$SYSCTL_FILE" ]]; then
  [[ -r "$SYSCTL_FILE" ]] || fail "Cannot read $SYSCTL_FILE; grant read access before running this script."
  if cmp -s -- "$SYSCTL_FILE" <(configuration); then
    INSTALL_NEEDED=0
  else
    CMP_STATUS=$?
    (( CMP_STATUS == 1 )) || fail "Could not compare $SYSCTL_FILE with the desired configuration."
  fi
fi

if (( INSTALL_NEEDED )); then
  TEMPORARY_FILE="${TMPDIR:-/tmp}/disable-ipv6-${BASHPID}-${RANDOM}-${RANDOM}"
  if [[ -e "$SYSCTL_FILE" ]]; then
    BACKUP="${SYSCTL_FILE}.bak-$(date -u +%Y%m%dT%H%M%SZ)"
  fi
fi

if [[ -d "$IPV6_CONTROLS" ]]; then
  for SETTING in "$IPV6_CONTROLS"/*/disable_ipv6; do
    [[ -e "$SETTING" ]] || continue
    SETTINGS+=("$SETTING")
  done
fi

if (( EUID != 0 )) && { (( INSTALL_NEEDED )) || [[ -d "$IPV6_CONTROLS" ]]; }; then
  command -v sudo >/dev/null 2>&1 || fail 'sudo was not found; install it or run from an authorized root session.'
fi

if (( INSTALL_NEEDED )); then
  if [[ -n "$BACKUP" ]]; then
    require_authorization "$CP_COMMAND" -a -- "$SYSCTL_FILE" "$BACKUP"
  fi
  require_authorization "$INSTALL_COMMAND" -o root -g root -m 0644 -- "$TEMPORARY_FILE" "$SYSCTL_FILE"
fi
if [[ -d "$IPV6_CONTROLS" ]]; then
  require_authorization "$SYSCTL_COMMAND" -p "$SYSCTL_FILE"
  for SETTING in "${SETTINGS[@]}"; do
    require_authorization "$TEE_COMMAND" "$SETTING"
  done
fi

if (( INSTALL_NEEDED )); then
  if (set -o noclobber; : > "$TEMPORARY_FILE"); then
    TEMPORARY_OWNED=1
  else
    fail "Cannot safely create temporary file $TEMPORARY_FILE; check the temporary directory and retry."
  fi
  configuration > "$TEMPORARY_FILE" || fail 'Could not write temporary configuration.'
  if [[ -n "$BACKUP" ]]; then
    run_privileged "$CP_COMMAND" -a -- "$SYSCTL_FILE" "$BACKUP" || fail 'Could not back up the existing configuration.'
    log "Backed up existing configuration to: $BACKUP"
  fi
  run_privileged "$INSTALL_COMMAND" -o root -g root -m 0644 -- "$TEMPORARY_FILE" "$SYSCTL_FILE" || fail 'Could not install the persistent configuration.'
  log "Installed persistent configuration: $SYSCTL_FILE"
else
  log "Persistent configuration is already correct: $SYSCTL_FILE"
fi

# If this directory is absent, IPv6 is already disabled at kernel/module level.
if [[ ! -d "$IPV6_CONTROLS" ]]; then
  log 'IPv6 kernel controls are unavailable; IPv6 is already disabled at kernel level.'
  log 'Persistent sysctl configuration is ready for future boots.'
  exit 0
fi

# Apply the persistent settings immediately.
run_privileged "$SYSCTL_COMMAND" -p "$SYSCTL_FILE" >/dev/null || fail 'Could not apply the persistent sysctl configuration.'

# Explicitly disable IPv6 on every interface found during preflight.
for SETTING in "${SETTINGS[@]}"; do
  printf '1\n' | run_privileged "$TEE_COMMAND" "$SETTING" >/dev/null || fail "Could not disable IPv6 at $SETTING."
done

for SETTING in "$IPV6_CONTROLS"/*/disable_ipv6; do
  [[ -e "$SETTING" ]] || continue
  if [[ "$(<"$SETTING")" != '1' ]]; then
    ENABLED_INTERFACES+=("$(basename "$(dirname "$SETTING")")")
  fi
done

if ((${#ENABLED_INTERFACES[@]} > 0)); then
  fail "IPv6 remains enabled on: ${ENABLED_INTERFACES[*]}"
fi

log 'IPv6 is disabled on all current interfaces.'
log 'New interfaces will inherit the disabled setting.'
log 'No reboot is required.'
