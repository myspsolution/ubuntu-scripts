#!/usr/bin/env bash
#
# create-new-user.sh
# Create a Linux user that logs in with an SSH key (Ed25519), optionally as a sudoer.
# If the user already exists, offer to create an additional keypair instead.
#
# Revised : 2026-11-11
# Based on: create-new-sudoer.sh (2026-10-29)
# Prepared by dicky.dwijanto@myspsolution.com
# PT Strategic Partner Solution - 2026
#
# Usage (any of these):
#   curl -fsSL <raw-url>/create-new-user.sh | bash
#   bash <(curl -fsSL <raw-url>/create-new-user.sh)
#   bash create-new-user.sh
#
# Safe to run more than once:
#   - Nothing is changed until you confirm.
#   - An existing user is never modified, except for adding a new public key (only if you say yes).
#   - The private key is shown once, then deleted from this server.
#
# The whole script is wrapped in main(), which runs on the last line.
# If the download is cut off halfway, nothing runs at all.

main() {
  if [ -z "${BASH_VERSION:-}" ]; then
    printf '%s\n' 'Error: run this script with bash, not sh.' >&2
    exit 1
  fi

  set -Eeuo pipefail
  umask 077
  # Admin tools (useradd, visudo, ...) live in sbin; some sessions leave it out of PATH.
  PATH="${PATH}:/usr/local/sbin:/usr/sbin:/sbin"

  # ---------- Appearance ----------
  local RED='' GRN='' YLW='' CYN='' BLD='' STD=''
  if [[ -t 1 && "${TERM:-dumb}" != 'dumb' && -z "${NO_COLOR:-}" ]]; then
    RED=$'\033[1;31m'; GRN=$'\033[1;32m'; YLW=$'\033[1;33m'
    CYN=$'\033[1;36m'; BLD=$'\033[1m';    STD=$'\033[0m'
  fi

  step()  { printf '\n%s[%s]%s %s\n' "$CYN" "$1" "$STD" "$2"; }
  ok()    { printf '  %s✔%s %s\n' "$GRN" "$STD" "$*"; }
  note()  { printf '  %s\n' "$*"; }
  warn()  { printf '  %s! %s%s\n' "$YLW" "$*" "$STD" >&2; }
  fail()  { printf '\n%sERROR:%s %s\n' "$RED" "$STD" "$*" >&2; exit 1; }

  # ---------- Keyboard input ----------
  # When started with "curl ... | bash", standard input is the download itself.
  # Read the answers from the keyboard (/dev/tty) instead.
  if [[ ! -t 0 ]]; then
    if (exec </dev/tty) 2>/dev/null; then
      exec </dev/tty
    else
      fail 'No keyboard available. Run this script from an interactive terminal.'
    fi
  fi

  # ask "Question" default(y|n) -> returns 0 for yes, 1 for no. Enter = default.
  ask() {
    local question="$1" default="$2" hint answer
    [[ "$default" == y ]] && hint='Y/n' || hint='y/N'
    while true; do
      printf '\n%s? %s [%s]:%s ' "$BLD" "$question" "$hint" "$STD"
      IFS= read -r answer || { printf '\n'; fail 'Input cancelled. Nothing was changed.'; }
      answer="${answer//[[:space:]]/}"
      [[ -z "$answer" ]] && answer="$default"
      case "${answer,,}" in
        y|yes) return 0 ;;
        n|no)  return 1 ;;
        *)     warn 'Please type y or n.' ;;
      esac
    done
  }

  # ---------- Privileges ----------
  as_root() {
    if (( EUID == 0 )); then "$@"; else sudo -- "$@"; fi
  }
  as_user() {
    local target="$1"; shift
    as_root runuser -u "$target" -- "$@"
  }

  # ---------- Temporary workspace (removed on exit, even after Ctrl+C) ----------
  local WORKDIR=''
  cleanup() {
    local dir="${WORKDIR:-}"
    if [[ -n "$dir" && -d "$dir" ]]; then
      if command -v shred >/dev/null 2>&1 && [[ -f "$dir/key" ]]; then shred -u -- "$dir/key" || true; fi
      rm -rf -- "$dir"
    fi
    return 0
  }
  trap cleanup EXIT
  trap 'printf "\n"; warn "Stopped. You can safely run this script again."; exit 130' INT TERM
  trap 'fail "Unexpected problem at line $LINENO. You can safely run this script again."' ERR

  # ================================================================
  [[ -t 1 && "${TERM:-dumb}" != 'dumb' ]] && clear
  printf '%s\n' "${BLD}=================================================${STD}"
  printf '%s\n' "${BLD}  Create a new user with SSH key login${STD}"
  printf '%s\n' "${BLD}=================================================${STD}"
  note 'This script will:'
  note '  1. create a Linux user (or use an existing one),'
  note '  2. optionally make the user a sudoer (administrator),'
  note '  3. create an SSH keypair so the user logs in without a password.'
  note 'Nothing is changed until you confirm.'

  # ---------- [1/4] Checks ----------
  step '1/4' 'Checking this server'

  local os_name=''
  os_name=$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-}") || true
  [[ "${os_name,,}" == *ubuntu* ]] || fail "This script supports Ubuntu only. Detected: ${os_name:-unknown}"
  ok "Operating system: ${os_name}"

  local cmd
  for cmd in useradd usermod chpasswd getent runuser ssh-keygen visudo install mktemp base64; do
    command -v "$cmd" >/dev/null 2>&1 || fail "Required command not found: ${cmd}"
  done

  if (( EUID == 0 )); then
    ok 'Running as root'
  else
    command -v sudo >/dev/null 2>&1 || fail 'This script needs root or sudo access.'
    note "Your password may be asked, to confirm that ${USER:-you} can use sudo."
    sudo -v || fail 'sudo access is required. Nothing was changed.'
    ok "sudo access confirmed for ${USER:-current user}"
  fi

  local ssh_port='' sshd_conf='' allow_users=''
  if command -v sshd >/dev/null 2>&1 || [[ -x /usr/sbin/sshd ]]; then
    sshd_conf=$(as_root sshd -T 2>/dev/null) || true
    ssh_port=$(awk '$1 == "port" {print $2; exit}' <<<"$sshd_conf")
    allow_users=$(awk '$1 == "allowusers" {printf "%s ", $2}' <<<"$sshd_conf")
    allow_users="${allow_users% }"
    ok "SSH server installed (port ${ssh_port:-22})"
    [[ -z "$allow_users" ]] || note "SSH login is limited to (AllowUsers): ${allow_users}"
  else
    warn 'SSH server (openssh-server) is not installed. Install it with: sudo apt install openssh-server'
  fi
  ssh_port="${ssh_port:-22}"

  # ---------- [2/4] Username ----------
  step '2/4' 'Choose the username'
  note 'Rules: lowercase letters, digits, - or _, start with a letter (max 32).'

  local username='' input=''
  while [[ -z "$username" ]]; do
    printf '\n%s? Username:%s ' "$BLD" "$STD"
    IFS= read -r input || { printf '\n'; fail 'Input cancelled. Nothing was changed.'; }
    input="${input#"${input%%[![:space:]]*}"}"
    input="${input%"${input##*[![:space:]]}"}"
    if [[ -z "$input" ]]; then
      warn 'A username is required.'
    elif [[ "$input" != "${input,,}" && "${input,,}" =~ ^[a-z][a-z0-9_-]{0,31}$ ]]; then
      warn "Linux usernames are lowercase. Using '${input,,}' instead."
      username="${input,,}"
    elif [[ "$input" =~ ^[a-z][a-z0-9_-]{0,31}$ ]]; then
      username="$input"
    else
      warn "'${input}' is not a valid username. Please try again."
    fi
  done

  local mode='' make_sudoer='no' user_entry='' uid='' home=''
  if user_entry=$(getent passwd "$username"); then
    uid=$(cut -d: -f3 <<<"$user_entry")
    home=$(cut -d: -f6 <<<"$user_entry")
    if [[ "$username" == root || "$uid" -lt 1000 || "$uid" -ge 60000 ]]; then
      fail "'${username}' is a system account. This script only manages regular users."
    fi
    case "$(cut -d: -f7 <<<"$user_entry")" in
      */nologin|*/false) warn "'${username}' has no login shell, so SSH login will not work for this user." ;;
    esac
    local is_sudoer='no'
    id -nG "$username" | tr ' ' '\n' | grep -qx sudo && is_sudoer='yes'
    printf '\n'
    warn "The user '${username}' already exists (sudoer: ${is_sudoer})."
    if ask "Do you want to create an additional keypair for '${username}'" n; then
      mode='add-key'
      make_sudoer="$is_sudoer"
    else
      printf '\n'
      ok 'Nothing was changed. Bye!'
      exit 0
    fi
    [[ -d "$home" ]] || fail "Home folder ${home} of '${username}' does not exist."
  else
    if getent group "$username" >/dev/null; then
      fail "A group named '${username}' already exists. Please choose another username."
    fi
    mode='new-user'
    note "'${username}' is available."
    note 'A sudoer can run administrator commands (sudo) without a password.'
    if ask "Make '${username}' a sudoer" n; then make_sudoer='yes'; fi
  fi

  # ---------- Summary ----------
  printf '\n%s\n' "${BLD}Summary${STD}"
  if [[ "$mode" == new-user ]]; then
    note "Create user   : ${username}"
    note "Sudoer        : ${make_sudoer}"
  else
    note "Existing user : ${username} (no other changes)"
  fi
  note 'SSH keypair   : new Ed25519 key (the private key will be shown ONCE)'
  warn 'Get ready to copy text from this screen into Termius.'
  if ! ask 'Continue' n; then
    printf '\n'
    ok 'Nothing was changed. Bye!'
    exit 0
  fi

  # ---------- [3/4] Create user ----------
  local host_name='' created=''
  host_name=$(hostname)
  created=$(date '+%Y-%m-%d %H:%M %Z')

  if [[ "$mode" == new-user ]]; then
    step '3/4' "Creating user ${username}"
    as_root useradd --create-home --shell /bin/bash \
      --comment "created by create-new-user.sh $(date +%F)" "$username"
    home=$(getent passwd "$username" | cut -d: -f6)
    ok "User ${username} created (home: ${home})"

    # A long random password nobody knows: login is by SSH key only.
    local random_pw=''
    random_pw=$(head -c 48 /dev/urandom | base64 -w0)
    printf '%s:%s\n' "$username" "$random_pw" | as_root chpasswd
    random_pw=''
    ok 'Random password set (not needed: login uses the SSH key)'

    if [[ "$make_sudoer" == yes ]]; then
      WORKDIR=$(mktemp -d)
      printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$username" > "$WORKDIR/sudoers"
      as_root visudo -cqf "$WORKDIR/sudoers" >/dev/null || fail 'Sudoers rule check failed. Sudo was not configured.'
      as_root usermod -aG sudo "$username"
      as_root install -m 0440 -o root -g root "$WORKDIR/sudoers" "/etc/sudoers.d/${username}"
      rm -f -- "$WORKDIR/sudoers"
      ok "${username} is now a sudoer (sudo without password)"
    else
      ok "${username} is a regular user (no sudo)"
    fi
  else
    step '3/4' "Using existing user ${username}"
    ok 'No changes to the account itself'
  fi

  # ---------- [4/4] SSH keypair ----------
  step '4/4' 'Creating the SSH keypair'
  [[ -n "$WORKDIR" ]] || WORKDIR=$(mktemp -d)
  local key_label="${username}@${host_name}"
  ssh-keygen -q -t ed25519 -a 100 -N '' -C "${key_label} $(date +%F)" -f "$WORKDIR/key"

  # Install the public key as the user (never as root inside the user's home).
  as_user "$username" bash -c '
    umask 077
    mkdir -p -- "$1/.ssh"
    chmod 700 -- "$1/.ssh"
    cat >> "$1/.ssh/authorized_keys"
    chmod 600 -- "$1/.ssh/authorized_keys"
  ' _ "$home" < "$WORKDIR/key.pub"
  ok "Public key added to ${home}/.ssh/authorized_keys"

  local fingerprint='' ip_addr='' key_count=''
  fingerprint=$(ssh-keygen -lf "$WORKDIR/key.pub" | awk '{print $2}')
  ip_addr=$(hostname -I 2>/dev/null | awk '{print $1}')
  ip_addr="${ip_addr:-<server-ip>}"
  key_count=$(as_root grep -c '^ssh-' "${home}/.ssh/authorized_keys" 2>/dev/null) || key_count='?'

  # ---------- Login information ----------
  show_info() {
    printf '\n%s\n' "${YLW}=============== SAVE THIS: SHOWN ONLY ONCE ===============${STD}"
    printf '  Server      : %s (%s), port %s\n' "$host_name" "$ip_addr" "$ssh_port"
    printf '  Username    : %s\n' "$username"
    printf '  Sudoer      : %s\n' "$make_sudoer"
    printf '  Key type    : ED25519\n'
    printf '  Key label   : %s\n' "$key_label"
    printf '  Fingerprint : %s\n' "$fingerprint"
    printf '  Created     : %s\n' "$created"
    printf '\n%s\n' "${BLD}  PRIVATE KEY (secret!) - copy ALL lines, from BEGIN to END:${STD}"
    cat "$WORKDIR/key"
    printf '\n%s\n' "${BLD}  PUBLIC KEY (already installed on this server):${STD}"
    cat "$WORKDIR/key.pub"
    printf '\n%s\n' "${BLD}  HOW TO USE IT IN TERMIUS${STD}"
    printf '  1. Keychain > Key > paste the PRIVATE KEY. Label: %s\n' "$key_label"
    printf '  2. New Host > Address: %s, Port: %s, Username: %s\n' "$ip_addr" "$ssh_port" "$username"
    printf '     Credentials: choose key %s, leave Password empty.\n' "$key_label"
    printf '  3. Connect. No password needed.\n'
    printf '%s\n' "${YLW}===========================================================${STD}"
  }
  show_info

  while ! ask 'Have you copied and saved the PRIVATE KEY' n; do
    if ask 'Show the information again' y; then show_info; fi
  done

  cleanup
  WORKDIR=''
  printf '\n'
  ok 'Private key deleted from this server.'
  ok "Done. ${username} now has ${key_count} key(s) in authorized_keys."
  note 'Lost the key? Run this script again and create an additional keypair.'
  note 'To remove an old key, delete its line from:'
  note "  ${home}/.ssh/authorized_keys"
  if [[ -n "$allow_users" && " ${allow_users} " != *" ${username} "* ]]; then
    printf '\n'
    warn "SSH only allows these users (AllowUsers): ${allow_users}"
    warn "Add '${username}' to AllowUsers, or ${username} cannot log in."
    warn 'Find the setting with: grep -r AllowUsers /etc/ssh/'
  fi
  printf '\n'
}

main "$@"; exit $?
