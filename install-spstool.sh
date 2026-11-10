#!/usr/bin/env bash

# 03-install-spstool.sh
# Install spstool and its dependencies for the configured sudo user.
# Revised: 2026-10-30 11-32-56
# prepared by dicky.dwijanto@myspsolution.com
# Usage: bash 03-install-spstool.sh

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

readonly CONFIG_FILE="/etc/orangt.conf"
readonly SPSTOOL_REPOSITORY="https://github.com/myspsolution/spstool.git"
readonly REQUIRED=(bc curl git ncat)

MISSING=()
OS_INFO=""
SUDO_BIN=""
SUDO_OPTIONS=()
USER_HOME=""
SPSTOOL_STAGE_DIR=""
SPSTOOL_PAYLOAD=()

# Color only human-facing terminal output; leave redirected output plain.
message() {
  local message_kind="$1"
  local message_text="$2"
  local message_color="$BLD"
  local message_reset="$STD"
  local message_label=""
  local message_end=$'\n'
  local message_fd=1

  case "$message_kind" in
    error)
      message_color="$RED"
      message_label='ERROR:'
      message_text=" $message_text"
      message_fd=2
      ;;
    warning)
      message_color="$YLW"
      message_label='WARNING:'
      message_text=" $message_text"
      message_fd=2
      ;;
    prompt)
      message_label="$message_text"
      message_text=""
      message_end=' '
      message_fd=2
      ;;
    info)
      message_label="$message_text"
      message_text=""
      ;;
  esac

  if [[ ! -t "$message_fd" || "${TERM:-dumb}" == 'dumb' || -n "${NO_COLOR:-}" ]]; then
    message_color=""
    message_reset=""
  fi

  printf '%b%s%b%s%s' "$message_color" "$message_label" "$message_reset" "$message_text" "$message_end" >&"$message_fd"
}

info() {
  message info "$*"
}

warn() {
  message warning "$*"
}

error() {
  message error "$*"
}

configure_privilege() {
  if (( EUID == 0 )); then
    command -v runuser >/dev/null 2>&1 || {
      error 'Root execution requires runuser to clone files as the configured account.'
      exit 1
    }
    return
  fi

  SUDO_BIN=$(type -P sudo || true)
  [[ -n "$SUDO_BIN" ]] || {
    error 'This installer requires root access or an authorized sudo account.'
    printf '%s\n' 'Start an authorized session, then run: bash 03-install-spstool.sh' >&2
    exit 1
  }

  # Never request a sudo password; required commands must already be authorized.
  SUDO_OPTIONS=(-n)

}

require_sudo_command() {
  if (( EUID == 0 )); then
    return
  fi

  if ! "$SUDO_BIN" "${SUDO_OPTIONS[@]}" -l -- "$@" >/dev/null 2>&1; then
    error "Sudo cannot run the required command without a password: $*. Use an authorized root session or arrange noninteractive sudo authorization."
    exit 1
  fi
}

preflight_privileged_commands() {
  local source_file
  local installed_source
  local target_file

  require_sudo_command rm -rf -- "/home/${CHECK_USER}/spstool"
  require_sudo_command rm -f -- /etc/profile.d/spstool.sh
  require_sudo_command rm -f -- /tmp/03-install-spstool.sh
  require_sudo_command rm -f -- /usr/local/bin/spstool /usr/local/bin/spstool.sh
  require_sudo_command mv -- "$SPSTOOL_STAGE_DIR" "$USER_HOME/spstool"
  for source_file in "${SPSTOOL_PAYLOAD[@]}"; do
    installed_source="$USER_HOME/spstool/${source_file##*/}"
    target_file="/usr/local/bin/${source_file##*/}"
    require_sudo_command cp -- "$installed_source" "$target_file"
    require_sudo_command chmod +x "$target_file"
  done
  require_sudo_command mv -- /usr/local/bin/spstool.sh /usr/local/bin/spstool
  require_sudo_command tee /etc/profile.d/spstool.sh
  require_sudo_command chmod +x /etc/profile.d/spstool.sh
}

preflight_package_bootstrap() {
  [[ ${#MISSING[@]} -gt 0 ]] || return 0

  require_sudo_command env DEBIAN_FRONTEND=noninteractive apt-get \
    -o Acquire::Retries=3 \
    -o Acquire::http::Timeout=30 \
    -o Acquire::https::Timeout=30 \
    update --error-on=any
  require_sudo_command env DEBIAN_FRONTEND=noninteractive apt-get \
    -o Acquire::Retries=3 \
    -o Acquire::http::Timeout=30 \
    -o Acquire::https::Timeout=30 \
    install -y "${MISSING[@]}"
}

apt_update_strict() {
  sudo env DEBIAN_FRONTEND=noninteractive apt-get \
    -o Acquire::Retries=3 \
    -o Acquire::http::Timeout=30 \
    -o Acquire::https::Timeout=30 \
    update --error-on=any
}

verify_apt_error_mode() {
  if ! apt-get update --error-on=any --print-uris >/dev/null 2>&1; then
    error 'This apt-get version does not support fatal partial-update checking.'
    printf '%s\n' 'Upgrade APT before running this installer.' >&2
    exit 1
  fi
}

probe_spstool_repository() {
  if ! GIT_TERMINAL_PROMPT=0 timeout 30 git ls-remote --exit-code \
    "$SPSTOOL_REPOSITORY" HEAD >/dev/null 2>&1; then
    error "Cannot access required Git repository: ${SPSTOOL_REPOSITORY}"
    printf '%s\n' 'Check DNS, proxy, TLS trust, GitHub access, and repository permissions.' >&2
    exit 1
  fi
}

cleanup() {
  if [[ -n "$SPSTOOL_STAGE_DIR" && -d "$SPSTOOL_STAGE_DIR" ]]; then
    rm -rf -- "$SPSTOOL_STAGE_DIR"
  fi
}

sudo() {
  if (( EUID == 0 )); then
    if [[ "${1:-}" == '-u' ]]; then
      local target_user="$2"
      shift 2
      command runuser -u "$target_user" -- "$@"
    else
      command "$@"
    fi
  else
    command "$SUDO_BIN" "${SUDO_OPTIONS[@]}" "$@"
  fi
}

run_as_user() {
  local target_user="$1"
  shift

  if [[ $(id -un) == "$target_user" ]]; then
    command "$@"
  elif (( EUID == 0 )); then
    command runuser -u "$target_user" -- "$@"
  else
    command "$SUDO_BIN" "${SUDO_OPTIONS[@]}" -u "$target_user" -- "$@"
  fi
}

# ---------------- Starting script ----------------

trap cleanup EXIT

if [[ -f "$CONFIG_FILE" ]]; then
  while IFS='=' read -r key value; do
    # Skip empty lines and comments, preserving the original config loader.
    [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
    key="$(printf '%s\n' "$key" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    value="$(printf '%s\n' "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    export "$key=$value"
  done < "$CONFIG_FILE"
fi

ORANGT_USER="${ORANGT_USER:-orangt}"
USER="$(id -un)"
# The original referenced CHECK_USER without providing a default.
CHECK_USER="${CHECK_USER:-$ORANGT_USER}"
USER_HOME=$(getent passwd "$ORANGT_USER" | cut -d: -f6)

# ---------------- Preliminary validation ----------------

# The original already-installed check remains disabled: reruns reinstall spstool.
if (( EUID != 0 )) && [[ "$USER" != "$ORANGT_USER" ]]; then
  error "Script must be run as user: ${ORANGT_USER}. Exiting."
  exit 1
fi

[[ -n "$USER_HOME" && -d "$USER_HOME" ]] || {
  error "Cannot find the home directory for configured user ${ORANGT_USER}."
  exit 1
}

OS_INFO=$(awk -F= '$1 == "PRETTY_NAME" {sub(/^[^=]*=/, ""); gsub(/^"|"$/, ""); print}' /etc/os-release)
if [[ "${OS_INFO,,}" != *ubuntu* ]]; then
  error 'This installation script must be run on Ubuntu only.'
  printf 'Your detected OS: %s\n' "$OS_INFO" >&2
  exit 1
fi

configure_privilege

# ---------------- Dependencies and installation ----------------

for cmd in "${REQUIRED[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    MISSING+=("$cmd")
  fi
done

verify_apt_error_mode
preflight_package_bootstrap

if [[ ${#MISSING[@]} -gt 0 ]]; then
  info "The following commands are not installed: ${MISSING[*]}"
  apt_update_strict
  sudo env DEBIAN_FRONTEND=noninteractive apt-get \
    -o Acquire::Retries=3 \
    -o Acquire::http::Timeout=30 \
    -o Acquire::https::Timeout=30 \
    install -y "${MISSING[@]}"
fi

command -v timeout >/dev/null 2>&1 || {
  error 'The required timeout command is unavailable.'
  exit 1
}
probe_spstool_repository

cd "$USER_HOME"

SPSTOOL_STAGE_DIR=$(run_as_user "$ORANGT_USER" \
  mktemp -d "${USER_HOME}/.spstool-stage.XXXXXX")
run_as_user "$ORANGT_USER" git clone --depth 1 \
  "$SPSTOOL_REPOSITORY" "$SPSTOOL_STAGE_DIR"
[[ -f "$SPSTOOL_STAGE_DIR/spstool.sh" ]] || {
  error 'The staged repository does not contain spstool.sh.'
  exit 1
}
mapfile -t SPSTOOL_PAYLOAD < <(find "$SPSTOOL_STAGE_DIR" -maxdepth 1 \
  -type f -name 'spstool*' -print)
[[ ${#SPSTOOL_PAYLOAD[@]} -gt 0 ]] || {
  error 'The staged repository does not contain an spstool payload.'
  exit 1
}

preflight_privileged_commands

if [[ -d "/home/${CHECK_USER}/spstool" ]]; then
  if ! rm -rf "/home/${CHECK_USER}/spstool"; then
    sudo rm -rf "/home/${CHECK_USER}/spstool"
  fi
fi

sudo rm -f /etc/profile.d/spstool.sh
if ! rm -f /tmp/03-install-spstool.sh; then
  sudo rm -f /tmp/03-install-spstool.sh
fi
sudo mv -- "$SPSTOOL_STAGE_DIR" "$USER_HOME/spstool"
SPSTOOL_STAGE_DIR=""
sudo rm -f -- /usr/local/bin/spstool /usr/local/bin/spstool.sh
for source_file in "${SPSTOOL_PAYLOAD[@]}"; do
  installed_source="$USER_HOME/spstool/${source_file##*/}"
  installed_target="/usr/local/bin/${source_file##*/}"
  sudo cp -- "$installed_source" "$installed_target"
  sudo chmod +x "$installed_target"
done
sudo mv -- /usr/local/bin/spstool.sh /usr/local/bin/spstool

# Keep this generated profile hook sourceable by the login shell.
printf '#!/bin/bash\n/usr/local/bin/spstool sysinfo\n' | sudo tee /etc/profile.d/spstool.sh >/dev/null
sudo chmod +x /etc/profile.d/spstool.sh

spstool sysinfo
