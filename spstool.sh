#!/usr/bin/env bash
#
# spstool.sh  (installed as /usr/local/bin/spstool)
# System summary and simple network checks for Ubuntu servers.
# Runs as ANY user and never needs sudo (least privilege).
#
# Install / update / uninstall:
#   curl -fsSL https://raw.githubusercontent.com/myspsolution/ubuntu-scripts/main/install-spstool.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/myspsolution/ubuntu-scripts/main/install-spstool.sh | bash -s -- --uninstall
#
# Optional settings: /etc/spstool.conf (KEY=value, see the file for examples)
#
# Prepared by dicky.dwijanto@myspsolution.com
# Last update: 2026-11-11

SPSTOOL_VERSION='2.1.0'
set -u
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

CONFIG_FILE='/etc/spstool.conf'

#-------------------------------------------------------------------------------
# Defaults (override them in /etc/spstool.conf)
#-------------------------------------------------------------------------------
RED_THRESHOLD=80          # CPU, RAM and disk usage (%) above this value is shown in red
MINIMUM_CPU_CORES=2       # fewer cores than this is shown in red
SERVER_ENVIRONMENT=''     # e.g. PRODUCTION, STAGING, TRAINING
EXTRA_SERVICES=''         # extra service names to show, separated by spaces
REMOTE_PORTS=''           # host:port pairs to check in sysinfo, separated by spaces

# Services shown in sysinfo when installed. Any php*-fpm service is detected automatically.
DEFAULT_SERVICES=(
  ssh cron ufw fail2ban unattended-upgrades
  nginx apache2 httpd
  mariadb mysql mysqld postgresql mssql-server
  docker supervisor supervisord
  minio apibilling apibilling-nodejs php-fpm
)

#-------------------------------------------------------------------------------
# Helpers
#-------------------------------------------------------------------------------
RED='' BLU='' YLW='' BLD='' STD=''
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != 'dumb' ]; then
  RED='\033[1;41;37m'; BLU='\033[1;94m'; YLW='\033[1;33m'; BLD='\033[1;97m'; STD='\033[0m'
fi

has() { command -v "$1" >/dev/null 2>&1; }

# Read KEY=value lines without executing the file (safe even when run as root).
read_config() {
  local file="$1" key value
  [ -r "$file" ] || return 0
  while IFS='=' read -r key value || [ -n "$key" ]; do
    key="${key#export }"
    key="${key//[[:space:]]/}"
    case "$key" in ''|\#*) continue ;; esac
    value="${value%$'\r'}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    value="${value#\"}"; value="${value%\"}"
    value="${value#\'}"; value="${value%\'}"
    case "$key" in
      RED_THRESHOLD|MINIMUM_CPU_CORES)
        [[ "$value" =~ ^[0-9]+$ ]] && printf -v "$key" '%s' "$value" ;;
      SERVER_ENVIRONMENT|EXTRA_SERVICES|REMOTE_PORTS)
        printf -v "$key" '%s' "$value" ;;
    esac
  done < "$file"
}

# check_port HOST PORT [TIMEOUT] -> exit code 0 when the port accepts connections
check_port() {
  local host="$1" port="$2" wait="${3:-5}"
  if has nc; then
    nc -z -w "$wait" "$host" "$port" >/dev/null 2>&1
  elif has ncat; then
    ncat -z -w "$wait" "$host" "$port" >/dev/null 2>&1
  else
    timeout "$wait" bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$host" "$port" >/dev/null 2>&1
  fi
}

valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

first_version() { grep -m1 -oE '[0-9]+(\.[0-9]+)+' ; }

show_help() {
  echo -e "${BLD}spstool${STD} ${SPSTOOL_VERSION} - server tools (no sudo needed)"
  echo ""
  echo -e "display system summary info:"
  echo -e "  ${BLD}spstool sysinfo${STD}"
  echo -e "display system summary info with clearing screen:"
  echo -e "  ${BLD}spstool sysinfo clear${STD}"
  echo -e "check internet connection and public IP:"
  echo -e "  ${BLD}spstool internet${STD}"
  echo -e "check local or remote port connection:"
  echo -e "  ${BLD}spstool port ${YLW}(host or ip)${STD} ${YLW}(port number)${STD}"
  echo -e "  examples: spstool port localhost 8080"
  echo -e "            spstool port 172.16.0.3 3306"
  echo -e "show version:"
  echo -e "  ${BLD}spstool version${STD}"
  echo ""
  echo -e "settings file: ${CONFIG_FILE}"
  echo ""
}

#-------------------------------------------------------------------------------
# Commands
#-------------------------------------------------------------------------------
cmd_internet() {
  echo ""
  if ! has curl; then
    echo -e "${RED}curl is not installed${STD}. Install it with: ${BLD}sudo apt install curl${STD}"
    echo ""
    return 1
  fi
  local public_ip
  public_ip=$(curl -fsS -4 -m 8 https://icanhazip.com 2>/dev/null | tr -d '[:space:]')
  if [ -n "$public_ip" ]; then
    echo -e "${BLU}internet access OK${STD}"
    echo -e "Public IP: ${BLD}${public_ip}${STD}"
    echo ""
    return 0
  fi
  if getent hosts icanhazip.com >/dev/null 2>&1; then
    echo -e "${RED}no internet access${STD} (DNS works, but HTTPS to ${BLD}icanhazip.com${STD} failed; check firewall or proxy)"
  else
    echo -e "${RED}no internet access${STD} (cannot resolve ${BLD}icanhazip.com${STD}; check DNS)"
  fi
  echo ""
  return 1
}

cmd_port() {
  local host="${1:-}" port="${2:-}"
  if [ -z "$host" ] || [ -z "$port" ] || ! valid_port "$port"; then
    echo -e "syntax   : ${BLD}spstool port ${YLW}(host or ip)${STD} ${YLW}(port number 1-65535)${STD}"
    echo -e "examples : spstool port localhost 8080"
    echo -e "           spstool port 172.16.0.31 3306"
    return 2
  fi
  if check_port "$host" "$port" 5; then
    echo -e "host:port ${BLD}${host}${STD}:${BLD}${port}${STD} ${BLU}listening${STD}"
    echo ""
    return 0
  fi
  echo -e "host:port ${BLD}${host}${STD}:${BLD}${port}${STD} ${RED}not listening${STD}"
  echo ""
  return 1
}

cmd_sysinfo() {
  local hostname_ local_ip os_info kernel user_login user_label
  hostname_=$(hostname)
  local_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  os_info=$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")
  kernel=$(uname -r)
  user_login=$(id -un)

  # Who am I? Decided from group membership only: no sudo call, no password prompt.
  if [ "$(id -u)" -eq 0 ]; then
    user_label="(super admin) ${RED}please switch to a sudoer user for security reasons"
  elif id -nG | tr ' ' '\n' | grep -qxE 'sudo|admin|wheel'; then
    user_label="(sudoer user, ideal for server administration)"
  else
    user_label="(regular user, not a sudoer)"
  fi

  local env_label='(undefined)'
  [ -n "$SERVER_ENVIRONMENT" ] && env_label="${BLD}${YLW}${SERVER_ENVIRONMENT}${STD}"

  # CPU: cores and current usage (two /proc/stat samples, 0.5 s apart)
  local cpu_cores cpu_pct cpu_pct_int cpu_label cpu_warn=''
  cpu_cores=$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo)
  cpu_pct=$( { head -1 /proc/stat; sleep 0.5; head -1 /proc/stat; } | awk '
    { idle = $5 + $6; total = 0; for (i = 2; i <= NF; i++) total += $i
      if (NR == 1) { i1 = idle; t1 = total } else { i2 = idle; t2 = total } }
    END { dt = t2 - t1; printf "%.1f", (dt > 0) ? (dt - (i2 - i1)) * 100 / dt : 0 }')
  cpu_pct_int=${cpu_pct%.*}
  if [ "$cpu_cores" -lt "$MINIMUM_CPU_CORES" ]; then
    cpu_warn=" ${RED}please add more CPU cores, minimum ${MINIMUM_CPU_CORES} cores"
  fi
  if [ "$cpu_pct_int" -gt "$RED_THRESHOLD" ]; then
    cpu_label="${RED} ${cpu_pct}% "
  else
    cpu_label="${cpu_pct}%"
  fi

  # RAM
  local ram_total ram_used ram_avail ram_pct ram_label
  read -r ram_total ram_used ram_avail ram_pct < <(free -m | awk '/^Mem:/ {
    printf "%.1f %.1f %.1f %.1f", $2/1024, $3/1024, $7/1024, ($2 > 0) ? $3*100/$2 : 0 }')
  if [ "${ram_pct%.*}" -gt "$RED_THRESHOLD" ]; then
    ram_label="${RED}(${ram_pct}%)${STD}"
  else
    ram_label="(${ram_pct}%)"
  fi

  # Disk: the root file system
  local disk_total disk_used disk_avail disk_pct disk_label
  read -r disk_total disk_used disk_avail disk_pct < <(df -hP / | awk 'NR == 2 {print $2, $3, $4, $5}')
  if [ "${disk_pct%\%}" -gt "$RED_THRESHOLD" ]; then
    disk_label="${RED}(${disk_pct})"
  else
    disk_label="(${disk_pct})"
  fi

  # Installed components (only those present)
  local components=() v
  if has php; then
    v=$(php -v 2>/dev/null | head -1 | first_version)
    components+=("${BLD}php ${v}${STD}")
    php -m 2>/dev/null | grep -qix grpc && components+=("${BLD}php-grpc${STD}")
  fi
  if has composer; then
    v=$(COMPOSER_ALLOW_SUPERUSER=1 composer --version --no-ansi 2>/dev/null | first_version)
    components+=("${BLD}composer ${v}${STD}")
  fi
  if has node; then
    v=$(node -v 2>/dev/null | first_version)
    components+=("${BLD}node ${v}${STD}")
  fi
  if has npm; then
    v=$(npm -v 2>/dev/null | first_version)
    components+=("${BLD}npm ${v}${STD}")
  fi
  if has mysql; then
    v=$(mysql -V 2>/dev/null | first_version)
    components+=("${BLD}mysql ${v}${STD}")
  fi

  # Installed services (one systemctl call to list them, then their state)
  local services=() service_note='' installed='' name state
  if has systemctl && installed=$(systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null) \
     && [ -n "$installed" ]; then
    installed=$(awk '{sub(/\.service$/, "", $1); print $1}' <<<"$installed")
    local wanted=("${DEFAULT_SERVICES[@]}")
    # shellcheck disable=SC2206
    wanted+=($EXTRA_SERVICES)
    while read -r name; do
      [ -n "$name" ] && wanted+=("$name")
    done < <(grep -E '^php[0-9.]*-fpm$' <<<"$installed" | grep -vx 'php-fpm')
    local seen=' '
    for name in "${wanted[@]}"; do
      case "$seen" in *" $name "*) continue ;; esac
      seen+="$name "
      grep -qx -- "$name" <<<"$installed" || continue
      state=$(systemctl is-active "$name" 2>/dev/null)
      if [ "$state" = 'active' ]; then
        services+=("${BLD}${name} ${BLU}(${state})${STD}")
      else
        services+=("${BLD}${name} ${RED}(${state:-unknown})${STD}")
      fi
    done
  else
    service_note='(systemd not available)'
  fi

  # Remote ports from the settings file, if any
  local ports=() hp
  for hp in $REMOTE_PORTS; do
    if valid_port "${hp##*:}" && check_port "${hp%:*}" "${hp##*:}" 2; then
      ports+=("${BLD}${hp}${STD} ${BLU}(listening)${STD}")
    else
      ports+=("${BLD}${hp}${STD} ${RED}(not listening)${STD}")
    fi
  done

  # Latest run of ubuntu-update.sh and pending reboot
  local latest_update='N/A'
  if [ -r /var/log/daily-update.log ]; then
    v=$(awk '/^Finished update steps at: / { value = substr($0, 27) } END { print value }' /var/log/daily-update.log 2>/dev/null)
    [ -n "$v" ] && latest_update="$v"
  fi
  local reboot_label="${BLU}no${STD}"
  [ -f /var/run/reboot-required ] && reboot_label="${YLW}yes${STD}, run ${BLD}sudo reboot${STD} when convenient"

  join() { local IFS=','; local s="$*"; echo "${s//,/, }"; }

  [ "${1:-}" = 'clear' ] && [ -t 1 ] && clear

  echo -e "${BLD}System Info Summary${STD}"
  echo -e "${BLD}----------------------------------------------------------------------------------${STD}"
  echo -e "Hostname               : ${BLD}${hostname_}${STD}"
  echo -e "Local IP address       : ${BLD}${local_ip:-N/A}${STD}"
  echo -e "Server Environment     : ${env_label}"
  echo -e "Operating System       : ${BLD}${os_info}${STD}, Kernel Version: ${BLD}${kernel}${STD}"
  echo -e "Current User Login     : ${BLD}${user_login}${STD} ${user_label}${STD}"
  echo -e "CPU Core(s)            : ${YLW}${cpu_cores}${STD}, Used: ${BLD}${cpu_label}${STD}${cpu_warn}${STD}"
  echo -e "Memory (RAM)           : Total ${YLW}${ram_total}GB${STD}, Used: ${BLD}${ram_used}GB ${ram_label}${STD}, Available: ${BLD}${ram_avail}GB${STD}"
  echo -e "Disk Usage (/)         : Total ${YLW}${disk_total}B${STD}, Used: ${BLD}${disk_used}B ${disk_label}${STD}, Available: ${BLD}${disk_avail}B${STD}"
  if [ "${#components[@]}" -gt 0 ]; then
    echo -e "Installed Component(s) : $(join "${components[@]}")"
  else
    echo -e "Installed Component(s) : (none from listed components)"
  fi
  if [ -n "$service_note" ]; then
    echo -e "Installed Service(s)   : ${service_note}"
  elif [ "${#services[@]}" -gt 0 ]; then
    echo -e "Installed Service(s)   : $(join "${services[@]}")"
  else
    echo -e "Installed Service(s)   : (none from listed services)"
  fi
  [ "${#ports[@]}" -gt 0 ] && echo -e "Remote Port(s)         : $(join "${ports[@]}")"
  echo -e "Latest Update          : ${latest_update}"
  echo -e "Reboot Required        : ${reboot_label}"
  echo ""
  echo -e "${BLD}spstool version ${YLW}${SPSTOOL_VERSION}${STD}"
  echo -e "type ${BLD}spstool${STD} for more linux tools, and follow instructions syntax"
  echo ""
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
read_config "$CONFIG_FILE"

case "${1:-}" in
  sysinfo)            cmd_sysinfo "${2:-}" ;;
  internet)           cmd_internet ;;
  port)               cmd_port "${2:-}" "${3:-}" ;;
  version|--version)  echo "spstool ${SPSTOOL_VERSION}" ;;
  ''|help|-h|--help)  show_help ;;
  *)                  echo -e "${RED}unknown command:${STD} $1"; echo ""; show_help; exit 2 ;;
esac
