#!/usr/bin/env bash
#
# 00b-fix-ubuntu-mirror.sh
# Point Ubuntu's own package sources to the main international archive
# (http://archive.ubuntu.com/ubuntu) instead of an Indonesian/Singapore mirror,
# which often breaks apt update/upgrade and do-release-upgrade.
#
# Changed (only when needed):
#   /etc/apt/sources.list                     (Ubuntu 22.04 style)
#   /etc/apt/sources.list.d/ubuntu.sources    (Ubuntu 24.04 style)
# Mirrors replaced: id.archive.ubuntu.com, sg.archive.ubuntu.com, mirror.biznetgio.com
# and any host ending in .id (e.g. mirror.xxx.ac.id) that serves /ubuntu.
# With --all: ANY mirror in those two files except archive/security/ports.ubuntu.com
# (use it for another local mirror, or a cloud provider mirror that misbehaves).
# Never touched: security.ubuntu.com, ports.ubuntu.com, commented lines, PPAs and
# other third-party repository files (Docker, PostgreSQL, ...).
#
# Safe: checks the new mirror BEFORE changing anything, keeps a backup of every
# changed file, rolls back automatically if apt cannot use the new mirror.
# Safe to run again: a second run finds nothing to change.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/myspsolution/ubuntu-scripts/main/00b-fix-ubuntu-mirror.sh | bash
#   ... | bash -s -- --check     show what would change, change nothing
#   ... | bash -s -- --all       also replace any other (non-Indonesian) mirror
#   ... | bash -s -- --restore   put back the most recent backups
#
# Tip: run 00a-disable-ipv6.sh first; a broken IPv6 network also breaks apt.
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

  local TARGET_MIRROR='http://archive.ubuntu.com/ubuntu'
  local FILES=(/etc/apt/sources.list /etc/apt/sources.list.d/ubuntu.sources)
  # Backups end in .bak, which apt ignores silently: <file>.mirror-YYYYmmdd-HHMMSS.bak
  local BACKUP_TAG='.mirror-'
  # Problematic mirror: scheme://HOST/ubuntu where HOST is id./sg.archive.ubuntu.com or ends in .id
  local HOST_RE='((id|sg)\.archive\.ubuntu\.com|mirror\.biznetgio\.com|[A-Za-z0-9.-]+\.id)'
  local HOST_RE_ALL='(([A-Za-z0-9.-]+))'   # two groups, like HOST_RE, so \3 stays the suffix
  local MATCH="https?://${HOST_RE}/ubuntu(/|[[:space:]]|\$)"
  local REPLACE="${TARGET_MIRROR}\\3"

  local RED='' GRN='' YLW='' CYN='' STD=''
  if [[ -t 1 && "${TERM:-dumb}" != 'dumb' && -z "${NO_COLOR:-}" ]]; then
    RED=$'\033[1;31m'; GRN=$'\033[1;32m'; YLW=$'\033[1;33m'; CYN=$'\033[1;36m'; STD=$'\033[0m'
  fi
  step() { printf '\n%s[%s]%s %s\n' "$CYN" "$1" "$STD" "$2"; }
  ok()   { printf '  %s✔%s %s\n' "$GRN" "$STD" "$*"; }
  note() { printf '  %s\n' "$*"; }
  warn() { printf '  %s! %s%s\n' "$YLW" "$*" "$STD" >&2; }
  fail() { printf '\n%sERROR:%s %s\n' "$RED" "$STD" "$*" >&2; exit 1; }

  local MODE='fix' ARG
  for ARG in "$@"; do
    case "$ARG" in
      --all)     HOST_RE="$HOST_RE_ALL"; MATCH="https?://${HOST_RE}/ubuntu(/|[[:space:]]|\$)" ;;
      --check)   MODE='check' ;;
      --restore) MODE='restore' ;;
      -h|--help)
        printf '%s\n' 'Usage: 00b-fix-ubuntu-mirror.sh [--all] [--check | --restore]' \
          "  (no option)  replace Indonesian/Singapore mirrors with ${TARGET_MIRROR}" \
          '  --all        replace any other mirror too (not archive/security/ports.ubuntu.com)' \
          '  --check      show what would change, change nothing' \
          '  --restore    put back the most recent backups, then apt update'
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

  # Problematic URIs on active (non-comment) lines of one file
  bad_uris() {
    grep -vE '^[[:space:]]*#' "$1" 2>/dev/null | grep -oE "$MATCH" | sed -E 's#[/[:space:]]*$##' \
      | grep -vE '^https?://(archive|security|ports)\.ubuntu\.com/' | sort -u || true
  }
  rewrite() {   # rewrite SOURCE > stdout
    # Official hosts are protected with a placeholder, so --all never touches them.
    sed -E -e '/^[[:space:]]*#/!{' \
      -e 's#://(archive|security|ports)\.ubuntu\.com/#://@@\1@@/#g' \
      -e 's#'"$MATCH"'#'"$REPLACE"'#g' \
      -e 's#://@@(archive|security|ports)@@/#://\1.ubuntu.com/#g' \
      -e '}' "$1"
  }
  active_mirrors() {
    local f
    for f in "${FILES[@]}"; do
      [[ -f "$f" ]] || continue
      sed -nE '/^[[:space:]]*#/d; s#.*(https?://[^/[:space:]]+/[^[:space:]]*).*#\1#p' "$f"
    done | sort -u
  }

  # ================================================================
  step '1' 'Checking this server'
  local os_name='' codename=''
  os_name=$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-}") || true
  codename=$(. /etc/os-release 2>/dev/null && printf '%s' "${VERSION_CODENAME:-}") || true
  [[ "${os_name,,}" == *ubuntu* && -n "$codename" ]] || fail "This script supports Ubuntu only. Detected: ${os_name:-unknown}"
  ok "Operating system: ${os_name} (${codename})"

  local present=() f
  for f in "${FILES[@]}"; do [[ -f "$f" ]] && present+=("$f"); done
  (( ${#present[@]} > 0 )) || fail 'No Ubuntu source file found (sources.list or ubuntu.sources).'

  local to_change=() uris
  for f in "${present[@]}"; do
    uris=$(bad_uris "$f")
    if [[ -n "$uris" ]]; then
      to_change+=("$f")
      warn "${f}: ${uris//$'\n'/, }"
    fi
  done
  if (( ${#to_change[@]} == 0 )); then
    ok 'No Indonesian/Singapore mirror in use. Nothing to change.'
    note "Mirrors in use: $(active_mirrors | paste -sd ' ')"
    [[ "$MODE" != restore ]] && { printf '\n'; return 0; }
  fi
  if [[ "$MODE" == check ]]; then
    note "Would be changed to: ${TARGET_MIRROR}"
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

  # apt update. Prints only error/warning lines. Returns 1 if the official
  # Ubuntu archive could not be used (third-party repository errors are only shown).
  apt_update_ok() {
    local out
    out=$(as_root apt-get -o Acquire::Retries=3 -o DPkg::Lock::Timeout=120 update 2>&1) || true
    printf '%s\n' "$out" | grep -E '^(E|W|Err)[^:]*:' | grep -v 'configured multiple times' \
      | sed 's/^/    /' >&2 || true
    if grep -qE '^(E|W|Err)[^:]*:.*://(archive|security)\.ubuntu\.com/ubuntu[/ ]' <<<"$out"; then
      return 1
    fi
    grep -qE '://(archive|security)\.ubuntu\.com/ubuntu' <<<"$out"   # apt really used it
  }

  # ---------- Restore ----------
  if [[ "$MODE" == restore ]]; then
    step '2' 'Restoring the most recent backups'
    local backup restored=0
    for f in "${FILES[@]}"; do
      backup=$(as_root bash -c 'ls -1t -- "$1"'"${BACKUP_TAG}"'*.bak 2>/dev/null | head -1' _ "$f" || true)
      [[ -n "$backup" ]] || continue
      as_root cp -a -- "$backup" "$f"
      ok "${f} <- ${backup}"
      restored=1
    done
    (( restored )) || fail 'No backup found. Nothing was changed.'
    step '3' 'Refreshing the package list'
    as_root apt-get -o Acquire::Retries=3 -o DPkg::Lock::Timeout=120 update 2>&1 \
      | grep -E '^(E|W|Err)[^:]*:' | sed 's/^/    /' >&2 || true
    ok 'Package list refreshed with the restored mirror.'
    printf '\n'
    return 0
  fi

  # ---------- [2/4] Test the new mirror before changing anything ----------
  step '2' "Testing ${TARGET_MIRROR}"
  WORKDIR=$(mktemp -d)
  if /usr/lib/apt/apt-helper -o Acquire::Retries=2 download-file \
       "${TARGET_MIRROR}/dists/${codename}/InRelease" "$WORKDIR/InRelease" >/dev/null 2>&1; then
    ok "Reachable (dists/${codename}/InRelease downloaded)"
  else
    fail "Cannot reach ${TARGET_MIRROR}. Nothing was changed.
       Check the internet connection or proxy. If IPv6 is the problem, run 00a-disable-ipv6.sh first."
  fi

  # ---------- [3/4] Change the files (with backup) ----------
  step '3' 'Updating the source files'
  local stamp backups=()
  stamp=$(date +%Y%m%d-%H%M%S)
  for f in "${to_change[@]}"; do
    rewrite "$f" > "$WORKDIR/new"
    if [[ -n "$(bad_uris "$WORKDIR/new")" ]]; then
      fail "Could not rewrite ${f} safely. Nothing was changed."
    fi
    as_root cp -a -- "$f" "${f}${BACKUP_TAG}${stamp}.bak"
    backups+=("${f}${BACKUP_TAG}${stamp}.bak")
    # Keep the original owner and permissions; replace the content in one step.
    as_root install -m "$(stat -c %a "$f")" -o root -g root -- "$WORKDIR/new" "$f"
    ok "${f} (backup: ${f}${BACKUP_TAG}${stamp}.bak)"
  done

  # ---------- [4/4] apt update; roll back if the Ubuntu archive fails ----------
  step '4' 'Refreshing the package list'
  if apt_update_ok; then
    ok "apt now uses ${TARGET_MIRROR}"
  else
    warn 'apt could not use the new mirror. Rolling back...'
    local b
    for b in "${backups[@]}"; do
      as_root cp -a -- "$b" "${b%"${BACKUP_TAG}"*}"
    done
    as_root apt-get -qq update >/dev/null 2>&1 || true
    fail 'Rolled back to the previous mirror. If IPv6 is the problem, run 00a-disable-ipv6.sh first.'
  fi

  printf '\n'
  ok 'Done. Safe to run again.'
  note "Mirrors in use: $(active_mirrors | paste -sd ' ')"
  note 'Undo: run this script with --restore'
  printf '\n'
}

main "$@"; exit $?
