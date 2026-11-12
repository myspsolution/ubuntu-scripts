#!/usr/bin/env bash
#
# install-basic-apps.sh
# Install the basic tools used on every server:
#   git curl wget zip unzip netcat-openbsd bc tmpreaper fail2ban
#
# fail2ban starts automatically when installed. It is not needed yet, so it is
# stopped and disabled right after a NEW install. If fail2ban was already
# installed before, its current state is left untouched (it may be in use).
#
# Run it as any sudoer (or root). Safe to run more than once.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/myspsolution/ubuntu-scripts/main/install-basic-apps.sh | bash
#
# Prepared by dicky.dwijanto@myspsolution.com
# Last update: 2026-11-12
#
# The whole script is wrapped in main(), which runs on the last line.
# If the download is cut off halfway, nothing runs at all.

main() {
  if [ -z "${BASH_VERSION:-}" ]; then
    printf '%s\n' 'Error: run this script with bash, not sh.' >&2
    exit 1
  fi
  set -Eeuo pipefail
  umask 022
  PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

  local PACKAGES=(git curl wget zip unzip netcat-openbsd bc tmpreaper fail2ban)

  local RED='' GRN='' YLW='' CYN='' STD=''
  if [[ -t 1 && "${TERM:-dumb}" != 'dumb' && -z "${NO_COLOR:-}" ]]; then
    RED=$'\033[1;31m'; GRN=$'\033[1;32m'; YLW=$'\033[1;33m'; CYN=$'\033[1;36m'; STD=$'\033[0m'
  fi
  step() { printf '\n%s[%s]%s %s\n' "$CYN" "$1" "$STD" "$2"; }
  ok()   { printf '  %s✔%s %s\n' "$GRN" "$STD" "$*"; }
  note() { printf '  %s\n' "$*"; }
  warn() { printf '  %s! %s%s\n' "$YLW" "$*" "$STD" >&2; }
  fail() { printf '\n%sERROR:%s %s\n' "$RED" "$STD" "$*" >&2; exit 1; }

  case "${1:-}" in
    '') ;;
    -h|--help)
      printf '%s\n' 'Usage: install-basic-apps.sh' \
        "  Installs: ${PACKAGES[*]}" \
        '  fail2ban is stopped and disabled only when it is newly installed.'
      return 0 ;;
    *) fail "Unknown option: $1 (see --help)" ;;
  esac

  local SUDO_OPTS=()
  as_root() { if (( EUID == 0 )); then "$@"; else sudo "${SUDO_OPTS[@]}" -- "$@"; fi; }
  # apt without questions; needrestart restarts services by itself
  apt_get() {
    as_root env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
      apt-get -o DPkg::Lock::Timeout=600 "$@"
  }
  is_installed() { [[ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" == 'install ok installed' ]]; }

  local WORKDIR=''
  cleanup() { [[ -n "${WORKDIR:-}" && -d "${WORKDIR:-}" ]] && rm -rf -- "$WORKDIR"; return 0; }
  trap cleanup EXIT
  trap 'fail "Unexpected problem at line $LINENO. You can safely run this script again."' ERR

  # ================================================================
  step '1/4' 'Checking this server'
  local os_name=''
  os_name=$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-}") || true
  [[ "${os_name,,}" == *ubuntu* ]] || fail "This script supports Ubuntu only. Detected: ${os_name:-unknown}"
  ok "Operating system: ${os_name}"

  if (( EUID == 0 )); then
    ok 'Running as root'
  else
    command -v sudo >/dev/null 2>&1 || fail 'This script must be run by a sudoer (or root).'
    (exec </dev/tty) 2>/dev/null || SUDO_OPTS=(-n)
    # "sudo true", not "sudo -v": -v asks for a password even for NOPASSWD sudoers.
    if sudo -n true 2>/dev/null; then
      ok "sudo access confirmed for $(id -un) (no password needed)"
    else
      note "Your sudo password is needed, to confirm that $(id -un) can use sudo."
      sudo "${SUDO_OPTS[@]}" true || fail 'sudo access is required. Nothing was changed.'
      ok "sudo access confirmed for $(id -un)"
    fi
  fi

  # Remember what was already there, before installing anything
  local pkg missing=() fail2ban_was_installed=0
  for pkg in "${PACKAGES[@]}"; do
    is_installed "$pkg" || missing+=("$pkg")
  done
  is_installed fail2ban && fail2ban_was_installed=1

  # ================================================================
  step '2/4' 'Updating the package list'
  apt_get -qq update || fail 'apt update failed. Check the internet connection, DNS or proxy.'
  ok 'Package list updated'

  # ================================================================
  step '3/4' 'Installing the apps'
  if (( ${#missing[@]} == 0 )); then
    ok 'All apps are already installed. Nothing to install.'
  else
    note "To install: ${missing[*]}"
    note 'Please wait, this can take a few minutes...'
    WORKDIR=$(mktemp -d)
    # Full apt output goes to a temporary log; it is shown only if something fails
    if ! apt_get -y install "${missing[@]}" >"$WORKDIR/apt.log" 2>&1; then
      tail -n 20 "$WORKDIR/apt.log" >&2
      fail 'apt install failed (last lines above). Fix the problem, then run this script again.'
    fi
    ok "Installed: ${missing[*]}"
  fi

  if (( fail2ban_was_installed )); then
    local f2b_active f2b_enabled
    f2b_active=$(systemctl is-active fail2ban 2>/dev/null) || true
    f2b_enabled=$(systemctl is-enabled fail2ban 2>/dev/null) || true
    ok "fail2ban was already installed: left as it is (${f2b_active:-unknown}, ${f2b_enabled:-unknown})"
  else
    as_root systemctl disable --now fail2ban >/dev/null 2>&1 || true
    if [[ "$(systemctl is-active fail2ban 2>/dev/null || true)" == active ]]; then
      warn 'fail2ban is still running. Stop it with: sudo systemctl disable --now fail2ban'
    else
      ok 'fail2ban stopped and disabled (enable later with: sudo systemctl enable --now fail2ban)'
    fi
  fi

  # ================================================================
  step '4/4' 'Checking'
  local not_ok=()
  for pkg in "${PACKAGES[@]}"; do
    if is_installed "$pkg"; then
      printf '  %s✔%s %-16s %s\n' "$GRN" "$STD" "$pkg" "$(dpkg-query -W -f='${Version}' "$pkg")"
    else
      not_ok+=("$pkg")
    fi
  done
  (( ${#not_ok[@]} == 0 )) || fail "Not installed: ${not_ok[*]}"

  printf '\n'
  ok 'Done. Safe to run again.'
  printf '\n'
}

main "$@"; exit $?
