#!/usr/bin/env bash

# 00b-fix-ubuntu-mirror.sh
# Replace problematic Ubuntu mirrors and refresh APT package indexes.
# Revised: 2026-10-28 06-04-29
# prepared by dicky.dwijanto@myspsolution.com
# Usage: bash 00b-fix-ubuntu-mirror.sh

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
readonly TARGET_MIRROR="https://archive.ubuntu.com/ubuntu"
readonly APT_DIR="/etc/apt"
readonly MIRROR_PATTERN='https?://(id|sg)\.archive\.ubuntu\.com/ubuntu'
readonly REPLACEMENT="s#https?://(id|sg)\\.archive\\.ubuntu\\.com/ubuntu#${TARGET_MIRROR}#g"

SOURCE_FILES=()
CHANGE_FILES=()
STAGED_UPDATE=()
REAL_UPDATE=()
STAGE=""
STAGE_OWNED=0
BACKUP_SUFFIX=""

log() {
  printf '[mirror-fix] %s\n' "$*"
}

fail() {
  printf '[mirror-fix] ERROR: %s\n' "$*" >&2
  exit 1
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

cleanup() {
  local status=$?
  if (( STAGE_OWNED )); then
    if ! run_privileged "$RM_COMMAND" -rf -- "$STAGE"; then
      printf '[mirror-fix] WARNING: Could not remove temporary staging directory %s.\n' "$STAGE" >&2
      if (( status == 0 )); then
        status=1
      fi
    fi
  fi
  return "$status"
}

run_bounded_update() {
  if (( EUID == 0 )); then
    timeout 300s "$@"
  else
    timeout 300s sudo -n -- "$@"
  fi
}

# ---------------- Starting script ----------------

trap cleanup EXIT

for TOOL in apt-get apt-config sed cp rm grep timeout; do
  command -v "$TOOL" >/dev/null 2>&1 || fail "Required tool $TOOL was not found."
done
APT_GET=$(command -v apt-get)
APT_CONFIG=$(command -v apt-config)
SED_COMMAND=$(command -v sed)
CP_COMMAND=$(command -v cp)
RM_COMMAND=$(command -v rm)

if [[ -f "${APT_DIR}/sources.list" ]]; then
  SOURCE_FILES+=("${APT_DIR}/sources.list")
fi
if [[ -d "${APT_DIR}/sources.list.d" ]]; then
  for FILE in "${APT_DIR}"/sources.list.d/*.list "${APT_DIR}"/sources.list.d/*.sources; do
    [[ -f "$FILE" && ! -L "$FILE" ]] || continue
    SOURCE_FILES+=("$FILE")
  done
fi
((${#SOURCE_FILES[@]} > 0)) || fail 'No APT source files were found.'

for FILE in "${SOURCE_FILES[@]}"; do
  [[ -r "$FILE" ]] || fail "Cannot read APT source file $FILE."
  if grep -Eq "$MIRROR_PATTERN" "$FILE"; then
    CHANGE_FILES+=("$FILE")
  else
    STATUS=$?
    (( STATUS == 1 )) || fail "Could not inspect APT source file $FILE."
  fi
done

BACKUP_SUFFIX=".bak-before-mirror-fix-$(date -u +%Y%m%dT%H%M%SZ)"
STAGE="/tmp/mirror-fix-${BASHPID}-${RANDOM}-${RANDOM}"
STAGED_UPDATE=("$APT_GET" -c "${STAGE}/preflight.conf" -o Acquire::Retries=1 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30
  -o "Dir::Etc::sourcelist=${STAGE}/sources.list"
  -o "Dir::Etc::sourceparts=${STAGE}/sources.list.d"
  -o "Dir::State::lists=${STAGE}/lists" update --error-on=any)
REAL_UPDATE=("$APT_GET" -o Acquire::Retries=1 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 update --error-on=any)

if (( EUID != 0 )); then
  command -v sudo >/dev/null 2>&1 || fail 'sudo was not found; install it or run from an authorized root session.'
fi
require_authorization "$APT_CONFIG" shell SOURCE_LIST Dir::Etc::sourcelist/f
require_authorization "$APT_CONFIG" shell SOURCE_PARTS Dir::Etc::sourceparts/d
require_authorization "$RM_COMMAND" -rf -- "$STAGE"
require_authorization "${STAGED_UPDATE[@]}"
require_authorization "${REAL_UPDATE[@]}"
for FILE in "${CHANGE_FILES[@]}"; do
  require_authorization "$CP_COMMAND" -a -- "$FILE" "${FILE}${BACKUP_SUFFIX}"
  require_authorization "$SED_COMMAND" -Ei "$REPLACEMENT" "$FILE"
done

# Refuse nonstandard source paths rather than checking a different set of
# repositories from the ones the subsequent APT refresh would actually use.
SOURCE_LIST_CONFIG=$(run_privileged "$APT_CONFIG" shell SOURCE_LIST Dir::Etc::sourcelist/f) || fail 'Could not inspect the configured APT source list.'
SOURCE_PARTS_CONFIG=$(run_privileged "$APT_CONFIG" shell SOURCE_PARTS Dir::Etc::sourceparts/d) || fail 'Could not inspect the configured APT source directory.'
[[ "$SOURCE_LIST_CONFIG" == "SOURCE_LIST='${APT_DIR}/sources.list'" ]] || fail 'The configured APT source list is not the standard path; inspect the APT configuration before running this repair.'
[[ "$SOURCE_PARTS_CONFIG" == "SOURCE_PARTS='${APT_DIR}/sources.list.d/'" || "$SOURCE_PARTS_CONFIG" == "SOURCE_PARTS='${APT_DIR}/sources.list.d'" ]] || fail 'The configured APT source directory is not the standard path; inspect the APT configuration before running this repair.'

if mkdir -- "$STAGE"; then
  STAGE_OWNED=1
else
  fail "Could not create a private staging directory at $STAGE."
fi
chmod 711 -- "$STAGE" || fail 'Could not set permissions on the staging directory.'
(umask 077; mkdir -- "$STAGE/sources.list.d") || fail 'Could not create the staged APT source directory.'
mkdir -- "$STAGE/lists" "$STAGE/lists/partial" || fail 'Could not create the staged APT metadata directories.'
chmod 755 -- "$STAGE/lists" "$STAGE/lists/partial" || fail 'Could not set permissions on the staged APT metadata directories.'
(umask 077; : > "$STAGE/sources.list") || fail 'Could not create the staged APT source list.'
(umask 077; printf '%s\n' \
  '#clear APT::Update::Pre-Invoke;' \
  '#clear APT::Update::Post-Invoke;' \
  '#clear APT::Update::Post-Invoke-Success;' > "$STAGE/preflight.conf") || fail 'Could not create the staged APT configuration.'
if [[ -f "${APT_DIR}/sources.list" ]]; then
  sed -E "$REPLACEMENT" "${APT_DIR}/sources.list" > "$STAGE/sources.list" || fail 'Could not stage the main APT source list.'
fi
if [[ -d "${APT_DIR}/sources.list.d" ]]; then
  for FILE in "${APT_DIR}"/sources.list.d/*.list "${APT_DIR}"/sources.list.d/*.sources; do
    [[ -f "$FILE" ]] || continue
    [[ -r "$FILE" ]] || fail "Cannot read APT source file $FILE."
    if [[ -L "$FILE" ]]; then
      (umask 077; cp -- "$FILE" "$STAGE/sources.list.d/${FILE##*/}") || fail "Could not stage $FILE."
    else
      (umask 077; sed -E "$REPLACEMENT" "$FILE" > "$STAGE/sources.list.d/${FILE##*/}") || fail "Could not stage $FILE."
    fi
  done
fi

log 'Checking the staged APT sources and repository metadata...'
if ! run_bounded_update "${STAGED_UPDATE[@]}"; then
  fail 'The staged APT metadata refresh failed or timed out; check the APT diagnostics, configured repositories, credentials, proxy, and support for --error-on=any. No source files were changed.'
fi

for FILE in "${CHANGE_FILES[@]}"; do
  BACKUP="${FILE}${BACKUP_SUFFIX}"
  run_privileged "$CP_COMMAND" -a -- "$FILE" "$BACKUP" || fail "Could not back up $FILE."
  run_privileged "$SED_COMMAND" -Ei "$REPLACEMENT" "$FILE" || fail "Could not update $FILE; its backup is $BACKUP."
  log "Updated: $FILE"
  log "Backup:  $BACKUP"
done

if ((${#CHANGE_FILES[@]} == 0)); then
  log 'No problematic Indonesian or Singapore mirror URLs were found.'
  log 'The mirror configuration is already repaired or uses another mirror.'
else
  log "Changed problematic mirrors to: ${TARGET_MIRROR}"
fi

for FILE in "${SOURCE_FILES[@]}"; do
  if grep -Eq "$MIRROR_PATTERN" "$FILE"; then
    fail "A problematic mirror URL remains in $FILE."
  else
    STATUS=$?
    (( STATUS == 1 )) || fail "Could not verify APT source file $FILE."
  fi
done

log 'Refreshing package indexes...'
if ! run_bounded_update "${REAL_UPDATE[@]}"; then
  fail 'apt-get update failed or timed out. Review the APT messages above; no upgrade was run.'
fi

log 'APT mirror repair completed successfully.'
log 'To upgrade packages later, run: sudo apt full-upgrade'
