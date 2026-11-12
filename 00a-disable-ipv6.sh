#!/usr/bin/env bash
#
# 00a-disable-ipv6.sh
# Stop IPv6 from breaking apt / do-release-upgrade (common on Indonesian networks
# where IPv6 is announced but does not actually work).
#
# What it does (two layers, both persistent and safe to run again):
#   1. apt always uses IPv4:   /etc/apt/apt.conf.d/99force-ipv4
#   2. IPv6 disabled on all network interfaces (now and after reboot):
#                              /etc/sysctl.d/99-disable-ipv6.conf
#      The loopback interface (lo, ::1) keeps IPv6, so local services that
#      listen on ::1 keep working. No outside traffic can use IPv6.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/myspsolution/ubuntu-scripts/main/00a-disable-ipv6.sh | bash
#   ... | bash -s -- --status    show the current state, change nothing
#   ... | bash -s -- --enable    undo: remove both settings and enable IPv6 again
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

  local SYSCTL_FILE='/etc/sysctl.d/99-disable-ipv6.conf'
  local APT_FILE='/etc/apt/apt.conf.d/99force-ipv4'
  local IPV6_PROC='/proc/sys/net/ipv6/conf'

  local RED='' GRN='' YLW='' CYN='' STD=''
  if [[ -t 1 && "${TERM:-dumb}" != 'dumb' && -z "${NO_COLOR:-}" ]]; then
    RED=$'\033[1;31m'; GRN=$'\033[1;32m'; YLW=$'\033[1;33m'; CYN=$'\033[1;36m'; STD=$'\033[0m'
  fi
  step() { printf '\n%s[%s]%s %s\n' "$CYN" "$1" "$STD" "$2"; }
  ok()   { printf '  %s✔%s %s\n' "$GRN" "$STD" "$*"; }
  note() { printf '  %s\n' "$*"; }
  warn() { printf '  %s! %s%s\n' "$YLW" "$*" "$STD" >&2; }
  fail() { printf '\n%sERROR:%s %s\n' "$RED" "$STD" "$*" >&2; exit 1; }

  local MODE='disable' FORCE=0 ARG
  for ARG in "$@"; do
    case "$ARG" in
      --status) MODE='status' ;;
      --enable|--undo) MODE='enable' ;;
      --force) FORCE=1 ;;
      -h|--help)
        printf '%s\n' 'Usage: 00a-disable-ipv6.sh [--status | --enable] [--force]' \
          '  (no option)  apt uses IPv4 only + disable IPv6 on all interfaces (lo keeps ::1)' \
          '  --status     show the current state, change nothing' \
          '  --enable     undo everything and enable IPv6 again' \
          '  --force      continue even if this SSH session itself runs over IPv6'
        return 0 ;;
      *) fail "Unknown option: ${ARG} (see --help)" ;;
    esac
  done

  local SUDO_OPTS=()
  as_root() { if (( EUID == 0 )); then "$@"; else sudo "${SUDO_OPTS[@]}" -- "$@"; fi; }

  local WORKDIR=''
  cleanup() { [[ -n "${WORKDIR:-}" && -d "${WORKDIR:-}" ]] && rm -rf -- "$WORKDIR"; return 0; }
  trap cleanup EXIT
  trap 'fail "Unexpected problem at line $LINENO. You can safely run this script again."' ERR

  # Interfaces that still have IPv6 switched on (lo is expected to keep it)
  ipv6_on_interfaces() {
    local f dev
    [[ -d "$IPV6_PROC" ]] || return 0
    for f in "$IPV6_PROC"/*/disable_ipv6; do
      dev=$(basename "$(dirname "$f")")
      case "$dev" in all|default|lo) continue ;; esac
      [[ "$(cat "$f" 2>/dev/null)" == 0 ]] && printf '%s ' "$dev"
    done
    return 0
  }
  global_ipv6() { ip -6 -o addr show scope global 2>/dev/null | awk '{print $2": "$4}' || true; }

  show_status() {
    local on
    if [[ ! -d "$IPV6_PROC" ]]; then
      ok 'IPv6 is switched off in the kernel (no IPv6 at all)'
    else
      on=$(ipv6_on_interfaces)
      if [[ -z "$on" ]]; then ok 'IPv6 is off on all network interfaces'; else warn "IPv6 is ON for: ${on}"; fi
      local addrs; addrs=$(global_ipv6)
      if [[ -z "$addrs" ]]; then ok 'No public (global) IPv6 address'; else warn "Global IPv6 address(es): ${addrs//$'\n'/, }"; fi
    fi
    if [[ -f "$SYSCTL_FILE" ]]; then ok "After reboot: kept off (${SYSCTL_FILE})"; else note "After reboot: no setting (${SYSCTL_FILE} not present)"; fi
    if [[ -f "$APT_FILE" ]]; then ok "apt uses IPv4 only (${APT_FILE})"; else note "apt may use IPv6 (${APT_FILE} not present)"; fi
  }

  # ================================================================
  step '1' 'Checking this server'
  local os_name=''
  os_name=$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-}") || true
  [[ "${os_name,,}" == *ubuntu* ]] || fail "This script supports Ubuntu only. Detected: ${os_name:-unknown}"
  ok "Operating system: ${os_name}"

  if [[ "$MODE" == status ]]; then
    step '2' 'Current IPv6 state'
    show_status
    printf '\n'
    return 0
  fi

  if (( EUID == 0 )); then
    ok 'Running as root'
  else
    command -v sudo >/dev/null 2>&1 || fail 'This script must be run by a sudoer (or root).'
    (exec </dev/tty) 2>/dev/null || SUDO_OPTS=(-n)
    note "Your password may be asked, to confirm that $(id -un) can use sudo."
    # "sudo true", not "sudo -v": -v asks for a password even for NOPASSWD sudoers.
    sudo "${SUDO_OPTS[@]}" true || fail 'sudo access is required. Nothing was changed.'
    ok "sudo access confirmed for $(id -un)"
  fi

  # ---------- Undo ----------
  if [[ "$MODE" == enable ]]; then
    step '2' 'Removing the settings'
    as_root rm -f -- "$SYSCTL_FILE" "$APT_FILE"
    ok "Removed ${SYSCTL_FILE} and ${APT_FILE}"
    step '3' 'Enabling IPv6 again'
    if [[ -d "$IPV6_PROC" ]]; then
      local f
      as_root sysctl -q -w net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.default.disable_ipv6=0 >/dev/null
      for f in "$IPV6_PROC"/*/disable_ipv6; do
        printf '0\n' | as_root tee "$f" >/dev/null
      done
    fi
    show_status
    note 'Global IPv6 addresses come back after: sudo netplan apply (or a reboot).'
    printf '\n'
    return 0
  fi

  # ---------- Safety: do not cut off the SSH session we are running in ----------
  local ssh_server_ip
  ssh_server_ip=$(awk '{print $3}' <<<"${SSH_CONNECTION:-}")
  if [[ "$ssh_server_ip" == *:* && "$ssh_server_ip" != ::ffff:* ]] && (( ! FORCE )); then
    fail "This SSH session uses IPv6 (${ssh_server_ip}). Disabling IPv6 would disconnect you.
       Connect to the server's IPv4 address and run again, or add --force if you are on the console."
  fi

  # ---------- [2/3] Settings ----------
  step '2' 'Writing the settings (kept after reboot)'
  WORKDIR=$(mktemp -d)
  cat > "$WORKDIR/sysctl" <<'EOF'
# Managed by 00a-disable-ipv6.sh (github.com/myspsolution/ubuntu-scripts)
# IPv6 off on all network interfaces, now and for interfaces added later.
# The loopback interface keeps ::1 so local services listening on it still work.
# Undo: run 00a-disable-ipv6.sh --enable
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 0
EOF
  cat > "$WORKDIR/apt" <<'EOF'
// Managed by 00a-disable-ipv6.sh (github.com/myspsolution/ubuntu-scripts)
// apt (and do-release-upgrade) always connect over IPv4.
Acquire::ForceIPv4 "true";
EOF

  install_file() {   # install_file SOURCE TARGET LABEL
    local src="$1" dst="$2" label="$3"
    if as_root cmp -s -- "$src" "$dst" 2>/dev/null; then
      ok "${label}: already correct (${dst})"
      return 0
    fi
    if as_root test -e "$dst"; then
      local backup
      # ".bak" at the end: apt and sysctl both ignore such files silently
      backup="${dst}.$(date +%Y%m%d-%H%M%S).bak"
      as_root cp -a -- "$dst" "$backup"
      note "Old version saved as ${backup}"
    fi
    as_root install -m 0644 -o root -g root -- "$src" "$dst"
    ok "${label}: written (${dst})"
  }
  install_file "$WORKDIR/apt" "$APT_FILE" 'apt uses IPv4 only'
  install_file "$WORKDIR/sysctl" "$SYSCTL_FILE" 'IPv6 off after reboot'

  # ---------- [3/3] Apply now ----------
  step '3' 'Switching IPv6 off now'
  if [[ ! -d "$IPV6_PROC" ]]; then
    ok 'IPv6 is already switched off in the kernel; nothing to do now.'
  else
    as_root sysctl -q -p "$SYSCTL_FILE" >/dev/null
    local remaining
    remaining=$(ipv6_on_interfaces)
    if [[ -n "$remaining" ]]; then
      local dev
      for dev in $remaining; do
        printf '1\n' | as_root tee "$IPV6_PROC/$dev/disable_ipv6" >/dev/null
      done
    fi
    remaining=$(ipv6_on_interfaces)
    [[ -z "$remaining" ]] || fail "IPv6 is still on for: ${remaining}"
  fi
  show_status

  printf '\n'
  ok 'Done. No reboot needed. Safe to run again.'
  note 'Check again after the next reboot with: ip -6 addr show scope global  (should print nothing)'
  note 'Undo: run this script with --enable'
  printf '\n'
}

main "$@"; exit $?
