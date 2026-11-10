#!/usr/bin/env bash
#
# install-spstool.sh
# Install (or update) spstool for ALL users on this server:
#   - downloads spstool.sh from github.com/myspsolution/ubuntu-scripts
#   - installs it as /usr/local/bin/spstool (overwrites an older version)
#   - shows "spstool sysinfo" at every interactive login (/etc/profile.d/spstool.sh)
#   - creates /etc/spstool.conf with examples, only if it does not exist yet
#
# Run it as any sudoer (or root). Safe to run more than once.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/myspsolution/ubuntu-scripts/main/install-spstool.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/myspsolution/ubuntu-scripts/main/install-spstool.sh | bash -s -- --uninstall
#
# Prepared by dicky.dwijanto@myspsolution.com
# Last update: 2026-11-11
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

  local REPO_RAW='https://raw.githubusercontent.com/myspsolution/ubuntu-scripts/main'
  local SOURCE_URL="${REPO_RAW}/spstool.sh"
  local TARGET='/usr/local/bin/spstool'
  local PROFILE_HOOK='/etc/profile.d/spstool.sh'
  local CONFIG_FILE='/etc/spstool.conf'
  local LEGACY_FILES=(/usr/local/bin/spstool.sh /tmp/03-install-spstool.sh)

  # ---------- Appearance ----------
  local RED='' GRN='' YLW='' CYN='' STD=''
  if [[ -t 1 && "${TERM:-dumb}" != 'dumb' && -z "${NO_COLOR:-}" ]]; then
    RED=$'\033[1;31m'; GRN=$'\033[1;32m'; YLW=$'\033[1;33m'
    CYN=$'\033[1;36m'; STD=$'\033[0m'
  fi
  step() { printf '\n%s[%s]%s %s\n' "$CYN" "$1" "$STD" "$2"; }
  ok()   { printf '  %s✔%s %s\n' "$GRN" "$STD" "$*"; }
  note() { printf '  %s\n' "$*"; }
  warn() { printf '  %s! %s%s\n' "$YLW" "$*" "$STD" >&2; }
  fail() { printf '\n%sERROR:%s %s\n' "$RED" "$STD" "$*" >&2; exit 1; }

  # ---------- Options ----------
  local MODE='install' ARG
  for ARG in "$@"; do
    case "$ARG" in
      --uninstall) MODE='uninstall' ;;
      -h|--help)
        printf '%s\n' 'Usage: install-spstool.sh [--uninstall]' \
          '  (no option)   install or update spstool for all users' \
          '  --uninstall   remove spstool and its login summary (keeps /etc/spstool.conf)'
        return 0 ;;
      *) fail "Unknown option: ${ARG} (see --help)" ;;
    esac
  done

  # ---------- Privileges: run each admin step with sudo, nothing else ----------
  as_root() {
    if (( EUID == 0 )); then "$@"; else sudo "${SUDO_OPTS[@]}" -- "$@"; fi
  }

  local WORKDIR=''
  cleanup() {
    local dir="${WORKDIR:-}"
    [[ -n "$dir" && -d "$dir" ]] && rm -rf -- "$dir"
    return 0
  }
  trap cleanup EXIT
  trap 'fail "Unexpected problem at line $LINENO. You can safely run this script again."' ERR

  # ================================================================
  step '1/4' 'Checking this server'
  local os_name=''
  os_name=$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-}") || true
  [[ "${os_name,,}" == *ubuntu* ]] || fail "This script supports Ubuntu only. Detected: ${os_name:-unknown}"
  ok "Operating system: ${os_name}"

  local SUDO_OPTS=()
  if (( EUID == 0 )); then
    ok 'Running as root'
  else
    command -v sudo >/dev/null 2>&1 || fail 'This script must be run by a sudoer (or root).'
    # Without a keyboard (e.g. cron), never wait for a password.
    (exec </dev/tty) 2>/dev/null || SUDO_OPTS=(-n)
    note "Your password may be asked, to confirm that $(id -un) can use sudo."
    sudo "${SUDO_OPTS[@]}" -v || fail 'sudo access is required. Nothing was changed.'
    ok "sudo access confirmed for $(id -un)"
  fi

  # ---------- Uninstall ----------
  if [[ "$MODE" == uninstall ]]; then
    step '2/2' 'Removing spstool'
    as_root rm -f -- "$TARGET" "$PROFILE_HOOK" "${LEGACY_FILES[@]}"
    ok "Removed ${TARGET} and ${PROFILE_HOOK}"
    note "Settings kept in ${CONFIG_FILE} (delete it manually if no longer needed)."
    printf '\n'
    return 0
  fi

  command -v curl >/dev/null 2>&1 || fail 'curl is required. Install it with: sudo apt install curl'

  # ---------- [2/4] Download ----------
  step '2/4' 'Downloading spstool'
  WORKDIR=$(mktemp -d)
  curl -fsSL --retry 3 --connect-timeout 15 -o "$WORKDIR/spstool" "$SOURCE_URL" \
    || fail "Cannot download ${SOURCE_URL}. Check the internet connection, DNS or proxy."
  # Basic checks before anything is replaced
  head -1 "$WORKDIR/spstool" | grep -q '^#!.*bash' || fail 'Downloaded file is not a bash script. Nothing was changed.'
  bash -n "$WORKDIR/spstool" || fail 'Downloaded file has a syntax error. Nothing was changed.'
  local new_version old_version='(not installed)'
  new_version=$(grep -m1 -oE "SPSTOOL_VERSION=['\"]?[0-9][0-9.]*" "$WORKDIR/spstool" | grep -oE '[0-9][0-9.]*$') \
    || fail 'Downloaded file does not look like spstool. Nothing was changed.'
  if [[ -x "$TARGET" ]]; then
    old_version=$(grep -m1 -oE "SPSTOOL_VERSION=['\"]?[0-9][0-9.]*" "$TARGET" | grep -oE '[0-9][0-9.]*$') || old_version='unknown'
  fi
  ok "Downloaded spstool ${new_version} from ${REPO_RAW%/main}"

  # ---------- [3/4] Install ----------
  step '3/4' 'Installing for all users'
  # install(1) writes a new file and renames it into place: a running spstool is never half-written.
  as_root install -m 0755 -o root -g root "$WORKDIR/spstool" "$TARGET"
  ok "${TARGET}: ${old_version} -> ${new_version}"

  cat > "$WORKDIR/profile-hook" <<'EOF'
# spstool: show a system summary at every interactive login.
# Installed by install-spstool.sh (github.com/myspsolution/ubuntu-scripts).
# To stop it, delete this file: sudo rm /etc/profile.d/spstool.sh
case $- in
  *i*) [ -x /usr/local/bin/spstool ] && /usr/local/bin/spstool sysinfo ;;
esac
EOF
  as_root install -m 0644 -o root -g root "$WORKDIR/profile-hook" "$PROFILE_HOOK"
  ok "Login summary: ${PROFILE_HOOK}"

  if as_root test -e "$CONFIG_FILE"; then
    ok "Settings kept: ${CONFIG_FILE} (not overwritten)"
  else
    cat > "$WORKDIR/spstool.conf" <<'EOF'
# /etc/spstool.conf - settings for spstool (KEY=value, one per line).
# Lines starting with # are ignored. Remove the # to use a setting.

# Shown in "spstool sysinfo", e.g. PRODUCTION, STAGING, TRAINING
#SERVER_ENVIRONMENT=TRAINING

# Usage (%) of CPU, RAM and disk above this value is shown in red
#RED_THRESHOLD=80

# Fewer CPU cores than this is shown in red
#MINIMUM_CPU_CORES=2

# Extra services to show, separated by spaces
#EXTRA_SERVICES=demo-web

# host:port pairs to check in sysinfo, separated by spaces
#REMOTE_PORTS=172.16.0.3:3306 172.16.0.4:9042
EOF
    as_root install -m 0644 -o root -g root "$WORKDIR/spstool.conf" "$CONFIG_FILE"
    ok "Settings file created: ${CONFIG_FILE}"
  fi

  local f
  for f in "${LEGACY_FILES[@]}"; do
    if as_root test -e "$f"; then
      as_root rm -f -- "$f"
      ok "Old file removed: ${f}"
    fi
  done
  # Old installer cloned github.com/myspsolution/spstool into a home folder. Only report it.
  local old_clone
  while IFS= read -r old_clone; do
    [[ -n "$old_clone" ]] || continue
    warn "Old copy found (no longer used): ${old_clone%/.git}"
    warn "Remove it if you wish: sudo rm -rf ${old_clone%/.git}"
  done < <(as_root find /home /root -maxdepth 3 -type d -path '*/spstool/.git' 2>/dev/null || true)

  # ---------- [4/4] Check ----------
  step '4/4' 'Checking'
  hash -r
  command -v spstool >/dev/null 2>&1 || fail "spstool is not found in PATH. Check that /usr/local/bin is in PATH."
  ok "$(spstool version) is ready for every user (no sudo needed)"
  printf '\n'
  spstool sysinfo || true
  note "Commands: spstool sysinfo | spstool internet | spstool port <host> <port>"
  note 'The summary also appears at every new login.'
  printf '\n'
}

main "$@"; exit $?
