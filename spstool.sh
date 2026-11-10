#!/bin/bash
# prepared by dicky.dwijanto@myspsolution.com
export SPSTOOL_VERSION=2.0.11

#-------------------------------------------------------------------------------------
# change these values according to environment
# todo: read from related config files instead of hard-coded values:
#-------------------------------------------------------------------------------------

# threshold for CPU,RAM and storage (in %), will show red alert when percentage value exceeds RED_THRESHOLD value
RED_THRESHOLD=80

# minimum cpu core(s), below this value will show red alert
MINIMUM_CPU_CORES=2

#-------------------------------------------------------------------------------------
# change these values according to environment to check remote server port connection
#-------------------------------------------------------------------------------------

CHECK_SERVICE_LIST=()
CHECK_SERVICE_LIST+=("minio")
CHECK_SERVICE_LIST+=("apibilling")
CHECK_SERVICE_LIST+=("apibilling-nodejs")
CHECK_SERVICE_LIST+=("php-fpm")
CHECK_SERVICE_LIST+=("php7.4-fpm")
CHECK_SERVICE_LIST+=("php8-fpm")
CHECK_SERVICE_LIST+=("php8.0-fpm")
CHECK_SERVICE_LIST+=("php8.1-fpm")
CHECK_SERVICE_LIST+=("php8.2-fpm")
CHECK_SERVICE_LIST+=("php8.3-fpm")
CHECK_SERVICE_LIST+=("php8.4-fpm")
CHECK_SERVICE_LIST+=("php8.5-fpm")
CHECK_SERVICE_LIST+=("php8.6-fpm")
CHECK_SERVICE_LIST+=("php8.7-fpm")
CHECK_SERVICE_LIST+=("php8.8-fpm")
CHECK_SERVICE_LIST+=("php9-fpm")
CHECK_SERVICE_LIST+=("php9.0-fpm")
CHECK_SERVICE_LIST+=("php9.1-fpm")
CHECK_SERVICE_LIST+=("php9.2-fpm")
CHECK_SERVICE_LIST+=("php9.3-fpm")
CHECK_SERVICE_LIST+=("php9.4-fpm")
CHECK_SERVICE_LIST+=("php9.5-fpm")
CHECK_SERVICE_LIST+=("apache")
CHECK_SERVICE_LIST+=("apache2")
CHECK_SERVICE_LIST+=("httpd")
CHECK_SERVICE_LIST+=("mariadb")
CHECK_SERVICE_LIST+=("mysql")
CHECK_SERVICE_LIST+=("mysqld")
CHECK_SERVICE_LIST+=("mssql-server")
CHECK_SERVICE_LIST+=("postgresql")
CHECK_SERVICE_LIST+=("nginx")
CHECK_SERVICE_LIST+=("docker")
#CHECK_SERVICE_LIST+=("firewalld")
CHECK_SERVICE_LIST+=("ufw")
CHECK_SERVICE_LIST+=("supervisor")
CHECK_SERVICE_LIST+=("supervisord")
CHECK_SERVICE_LIST+=("fail2ban")
CHECK_SERVICE_LIST+=("unattended-upgrades")

#CHECK_SERVICE_LIST+=("servicename1")
#CHECK_SERVICE_LIST+=("servicename2")
#CHECK_SERVICE_LIST+=("servicename3")
#CHECK_SERVICE_LIST+=("servicename4")
#CHECK_SERVICE_LIST+=("servicename5")

CHECK_REMOTE_PORTS=()
#CHECK_REMOTE_PORTS+=("172.x.x.x:9042")
#CHECK_REMOTE_PORTS+=("172.x.x.x:3306")

# do not change commands below unless you know what you're doing
#-------------------------------------------------------------------------------------

PARAM1=""
PARAM2=""
PARAM3=""

if [ ! -z "$1" ]; then
  PARAM1="$1"
fi

if [ ! -z "$2" ]; then
  PARAM2="$2"
fi

if [ ! -z "$3" ]; then
  PARAM3="$3"
fi

# predefined console font color/style
RED='\033[1;41;37m'
BLU='\033[1;94m'
YLW='\033[1;33m'
STD='\033[0m'
BLD='\033[1;97m'

HOSTNAME=$(hostname)
# LOCAL_IP=$(hostname -I | awk '{print $NF}')
LOCAL_IP=$(hostname -I | awk '{print $1}')

if [ -f /home/orangt/server.env ]; then
. /home/orangt/server.env
fi

if [ -z "${SERVER_ENVIRONMENT}" ]; then
  SERVER_ENVIRONMENT="(undefined)"
else
  SERVER_ENVIRONMENT="${BLD}${YLW}${SERVER_ENVIRONMENT}${STD}"
fi

# function to check local/remote host:port connection
CheckPort() {
  PORT_STATUS="not listening"
  CLR="${RED}"

  if [ ! -z "$1" ] && [ ! -z "$2" ]; then
    HOST="$1"
    PORT="$2"
    CHECKPORT=$(ncat -zvw10 "${HOST}" "${PORT}" &> /dev/null)
    if [ "$?" -eq 0 ]; then
      PORT_STATUS="listening"
      CLR="${BLU}"
    fi
    echo -e "${HOST}${YLW}:${PORT}${STD} : ${CLR}${PORT_STATUS}${STD}"
    echo ""
  fi
}

# function to check internet connection
CheckInternet() {
  echo ""
  if ping -q -c 1 -W 1 google.com > /dev/null; then
    echo -e "${BLU}internet access OK${STD}"
    PUBLIC_IP=$(curl -s icanhazip.com)
    echo -e "Public IP: ${BLD}${PUBLIC_IP}${STD}"
  else
    echo -e "${RED}no internet access${STD} (can not connect to ${BLD}google.com${STD})"
  fi
  echo ""
}

# function to check service is available or not, and its status
ServiceStatus() {
  if [ ! -z "$1" ]; then
    SRV_NAME="$1"

    SRV_NAME_SHORT="${SRV_NAME/\.service/}"

    echo -e "${BLD}${SRV_NAME_SHORT}${STD}"
    echo -e "${BLD}--------------------------------------------------------------------${STD}"

    SERVICE_EXISTS=$(systemctl list-units --type=service --all | grep -w "${SRV_NAME}")

    if [ "$?" -eq 0 ]; then
      SRV_DESC="-"
    if [ -f "/usr/lib/systemd/system/${SRV_NAME}" ]; then
        SRV_DESC=$(grep "^Description=" /usr/lib/systemd/system/${SRV_NAME} | awk -F"=" '{ print $2 }')
    fi

    echo -e "description          : ${BLD}${SRV_DESC}${STD}"

    SERVICE_STATUS=$(systemctl is-active "${SRV_NAME}")
    if [ "${SERVICE_STATUS}" == "active" ]; then
      echo -e "status               : ${BLU}${SERVICE_STATUS}${STD}"
    else
      echo -e "status               : ${RED}${SERVICE_STATUS}${STD}"
    fi

    SERVICE_ENABLED=$(systemctl is-enabled "${SRV_NAME}")
    if [ "${SERVICE_ENABLED}" == "enabled" ]; then
      SERVICE_ENABLED="${SERVICE_ENABLED} (run automatically on server restart)"
         echo -e "autorun              : ${BLU}${SERVICE_ENABLED}${STD}"
      else
        SERVICE_ENABLED="${SERVICE_ENABLED} (must be run manually after server restart)"
        echo -e "autorun              : ${RED}${SERVICE_ENABLED}${STD}"
      fi
    else
      echo -e "status               : ${RED}not found${STD}"
    fi
  fi
}

ServiceStatusShort() {
  STRING_RETURN=""
  if [ ! -z "$1" ]; then
    SRV_NAME="$1"

    SRV_NAME_SHORT="${SRV_NAME/\.service/}"

    SERVICE_EXISTS=$(systemctl list-units --type=service --all | grep -w "${SRV_NAME}")

    if [ "$?" -eq 0 ]; then
      STRING_RETURN="${BLD}${SRV_NAME_SHORT}"

      SERVICE_STATUS=$(systemctl is-active "${SRV_NAME}")

      if [ "${SERVICE_STATUS}" == "active" ]; then
        STRING_RETURN="${STRING_RETURN} ${BLU}(${SERVICE_STATUS})${STD}"
      else
        STRING_RETURN="${STRING_RETURN} ${RED}(${SERVICE_STATUS})${STD}"
      fi
    fi
  fi

  echo "${STRING_RETURN}"
}

if [ "${PARAM1}" != "internet" ] && [ "${PARAM1}" != "sysinfo" ] && [ "${PARAM1}" != "port" ] ; then
   echo -e "spstool syntax:"
   echo ""
   echo -e "display system summary info:"
   echo -e "${BLD}spstool sysinfo${STD}"
   echo ""
   echo -e "display system summary info with clearing screen:"
   echo -e "${BLD}spstool sysinfo clear${STD}"
   echo ""
   echo -e "check internet connetion:"
   echo -e "${BLD}spstool internet${STD}"
   echo ""
   echo -e "check local or remote port connection:"
   echo -e "${BLD}spstool port ${YLW}(host or ip)${STD} ${YLW}(port number)${STD}"
   echo -e "examples:"
   echo -e "spstool port localhost 8080"
   echo -e "spstool port 172.16.0.3 3306"
   echo ""
   exit 0
fi
#end of help command

if [ "${PARAM1}" == "internet" ]; then
  CheckInternet
fi

if [ "${PARAM1}" == "port" ]; then
  NCAT_AVAILABLE=$(which ncat &> /dev/null)
  if [ "$?" -ne 0 ]; then
    echo ""
    echo -e "this spstool command requires ${BLD}ncat${STD} to be installed."
    echo -e "please install ncat first using:"
    echo -e "${BLD}sudo apt install ncat -y${STD}"
    echo ""
    exit 0
  fi

  if [ -z "${PARAM2}" ] || [ -z "${PARAM3}" ]; then
    echo -e "syntax   : ${BLD}spstool port ${YLW}(host or ip)${STD} ${YLW}(port number)${STD}"
    echo -e "examples : spstool port localhost 8080"
    echo -e "           spstool port 172.16.0.31 3306"
    exit 0
  else
    CHECK_HOST="${PARAM2}"
    CHECK_PORT="${PARAM3}"
    PORT_CONNECTED=$(ncat -zvw5 "${CHECK_HOST}" "${CHECK_PORT}")

    EXIT_CODE="$?"
    if [ $EXIT_CODE -eq 0 ]; then
    PORT_STATUS="${BLU}listening${STD}"
  else
    PORT_STATUS="${RED}not listening${STD}"
  fi

  echo -e "host:port ${BLD}$CHECK_HOST${STD}:${BLD}${CHECK_PORT} ${PORT_STATUS}"
  echo ""

  exit $EXIT_CODE
  fi
fi
# end of port command

if [ "${PARAM1}" == "sysinfo" ]; then
  OS_INFO=$(cat /etc/os-release | grep '^PRETTY_NAME=')
  OS_INFO="${OS_INFO/PRETTY_NAME=/}"
  OS_INFO=$(echo $OS_INFO | tr -d '"')

  OS_KERNEL=$(uname -r)

  CURRENT_USER_LOGIN=$(whoami)

  if [ $(id -u) -eq 0 ]; then
    CURRENT_USER_LABEL="(super admin) ${RED}please switch to sudoer user for security reason"
  else
    NOT_SUDOER=$(sudo -l -U $USER 2>&1 | egrep -c -i "not allowed to run sudo|unknown user")
    if [ "$NOT_SUDOER" -ne 0 ]; then
      CURRENT_USER_LABEL="(reguler user, non admin or sudoer) ${RED}please consider switch to sudoer user for server administration"
    else
      CURRENT_USER_LABEL="(sudoer user, ideal for server administration)"
    fi
  fi

  CPU_CORE=$(lscpu | grep '^CPU(s):' | awk '{print $2}')
  CPU_USAGE_PERCENTAGE=$(grep 'cpu ' /proc/stat | awk '{usage=($2+$4)*100/($2+$4+$5)} END {print usage}')
  CPU_USAGE_PERCENTAGE_INT=$(echo ${CPU_USAGE_PERCENTAGE} | awk '{print int($1+0.55)}')

  CPU_WARNING_LABEL=""
  if [ "${CPU_CORE}" -lt "${MINIMUM_CPU_CORES}" ]; then
    CPU_WARNING_LABEL=" ${BLD}${RED}please add more CPU cores, minimum ${MINIMUM_CPU_CORES} cores"
  fi

  if [ "${CPU_USAGE_PERCENTAGE_INT}" -gt "${RED_THRESHOLD}" ]; then
    CPU_USAGE_PERCENTAGE_LABEL="${RED} ${CPU_USAGE_PERCENTAGE}% "
  else
    CPU_USAGE_PERCENTAGE_LABEL="${CPU_USAGE_PERCENTAGE}%"
  fi

  RAM_TOTAL_MB=$(free -m | grep '^Mem:' | awk '{print $2}')
  RAM_TOTAL_USABLE_GB=$(awk "BEGIN {printf \"%.1f\",${RAM_TOTAL_MB}/1024}")

  RAM_TOTAL_GB=$(echo ${RAM_TOTAL_USABLE_GB} | awk '{print int($1+0.55)}')

  RAM_USED_MB=$(free -m | grep '^Mem:' | awk '{print $3}')
  RAM_USED_GB=$(awk "BEGIN {printf \"%.1f\",${RAM_USED_MB}/1024}")

  RAM_AVAILABLE_MB=$(free -m | grep '^Mem:' | awk '{print $7}')
  RAM_AVAILABLE_GB=$(awk "BEGIN {printf \"%.1f\",${RAM_AVAILABLE_MB}/1024}")

  RAM_USAGE_PERCENTAGE=$(echo "scale=2; $RAM_USED_MB / $RAM_TOTAL_MB * 100" | bc)
  RAM_USAGE_PERCENTAGE_INT=$(echo ${RAM_USAGE_PERCENTAGE} | awk '{print int($1+0.45)}')

  if [ "${RAM_USAGE_PERCENTAGE_INT}" -gt "${RED_THRESHOLD}" ]; then
    RAM_USAGE_PERCENTAGE_LABEL="${RED}(${RAM_USAGE_PERCENTAGE}%)${STD}"
  else
    RAM_USAGE_PERCENTAGE_LABEL="(${RAM_USAGE_PERCENTAGE}%)${STD}"
  fi

  DISK_TOTAL_GB=$(df -h | grep '^/dev.*/$' | awk '{print $2}')
  DISK_USED_GB=$(df -h | grep '^/dev.*/$' | awk '{print $3}')
  DISK_USED_PERCENTAGE=$(df -h | grep '^/dev.*/$' | awk '{print $5}')

  DISK_USED_PERCENTAGE_INT="${DISK_USED_PERCENTAGE/\%/}"
  DISK_USED_PERCENTAGE_INT=$(echo ${DISK_USED_PERCENTAGE_INT} | awk '{print $1}')

  if [ "${DISK_USED_PERCENTAGE_INT}" -gt "${RED_THRESHOLD}" ]; then
    DISK_USAGE_PERCENTAGE_LABEL="${RED}(${DISK_USED_PERCENTAGE})"
  else
    DISK_USAGE_PERCENTAGE_LABEL="(${DISK_USED_PERCENTAGE})"
  fi

  RAM_TOTAL_GB=$(echo ${RAM_TOTAL_USABLE_GB} | awk '{print int($1+0.45)}')

  DISK_AVAILABLE_GB=$(df -h | grep '^/dev.*/$' | awk '{print $4}')

  COMPONENTS=""

  # check php, if any
  PHP_AVAILABLE=$(which php &> /dev/null)
  if [ "$?" -eq 0 ]; then
    PHP_VERSION=$(php -v | head -1 | egrep -o "\s([0-9\.])+" | head -1)
    COMPONENTS="${BLD}php${PHP_VERSION}${STD}"

    PHP_GRPC=$(php -m | grep -c -i "^grpc$")
    if [ "${PHP_GRPC}" -gt 0 ]; then
      COMPONENTS="${COMPONENTS}, ${BLD}php-grpc${STD}"
    fi
  fi

  COMPOSER_AVAILABLE=$(which composer &> /dev/null)
  if [ "$?" -eq 0 ]; then
    #COMPOSER_VERSION=$(composer -V | head -1 | egrep -o "\s([0-9\.])+" | head -1)
    COMPOSER_VERSION=$(composer --version 2>&1 | grep -m 1 -oP '(?<=version\s)[0-9]+\.[0-9]+\.[0-9]+')

    if [ -z "${COMPONENTS}" ]; then
      COMPONENTS="${BLD}composer ${COMPOSER_VERSION}${STD}"
    else
      COMPONENTS="${COMPONENTS}, ${BLD}composer ${COMPOSER_VERSION}${STD}"
    fi
  fi

  NODEJS_AVAILABLE=$(which node &> /dev/null)
  if [ "$?" -eq 0 ]; then
    NODEJS_VERSION=$(node -v | head -1 | egrep -o "([0-9\.])+" | head -1)
    if [ -z "${COMPONENTS}" ]; then
      COMPONENTS="node ${NODEJS_VERSION}"
    else
      COMPONENTS="${COMPONENTS}, ${BLD}node ${NODEJS_VERSION}${STD}"
    fi
  fi

  NPM_AVAILABLE=$(which npm &> /dev/null)
  if [ "$?" -eq 0 ]; then
    NPM_VERSION=$(npm -v | head -1 | egrep -o "([0-9\.])+" | head -1)
    if [ -z "${COMPONENTS}" ]; then
      COMPONENTS="${BLD}npm$ ${NPM_VERSION}${STD}"
    else
      COMPONENTS="${COMPONENTS}, ${BLD}npm ${NPM_VERSION}${STD}"
    fi
  fi

  MYSQL_AVAILABLE=$(which mysql &> /dev/null)
  if [ "$?" -eq 0 ]; then
    MYSQL_VERSION=$(mysql -V | head -1 | egrep -o "\s([0-9\.])+" | head -1)
    if [ -z "${COMPONENTS}" ]; then
      COMPONENTS="${BLD}mysql${MYSQL_VERSION}${STD}"
    else
      COMPONENTS="${COMPONENTS}, ${BLD}mysql${MYSQL_VERSION}${STD}"
    fi
  fi

  SERVICES=""
  SRV1=""

# check services status, if any
  if [ ${#CHECK_SERVICE_LIST[@]} -gt 0 ]; then

    for i in "${CHECK_SERVICE_LIST[@]}"
      do
        SRV1=$(ServiceStatusShort "$i")

        if [ ! -z "${SRV1}" ]; then
          if [ -z "${SERVICES}" ]; then
            SERVICES="${SRV1}"
          else
            SERVICES="${SERVICES}, ${SRV1}"
          fi
        fi
      done
  fi

  if [ "${PARAM2}" == "clear" ]; then
    clear
  fi

  echo -e "${BLD}System Info Summary${STD}"
  echo -e "${BLD}----------------------------------------------------------------------------------${STD}"
  echo -e "Hostname               : ${BLD}${HOSTNAME}${STD}"
  echo -e "Local IP address       : ${BLD}${LOCAL_IP}${STD}"
  echo -e "Server Environment     : ${SERVER_ENVIRONMENT}"
  echo -e "Operating System       : ${BLD}${OS_INFO}${STD}, Kernel Version: ${BLD}${OS_KERNEL}${STD}"
  echo -e "Current User Login     : ${BLD}${CURRENT_USER_LOGIN}${STD} $CURRENT_USER_LABEL${STD}"
  echo -e "CPU Core(s)            : ${YLW}${CPU_CORE}${STD}, Used: ${BLD}${CPU_USAGE_PERCENTAGE_LABEL}${STD}${CPU_WARNING_LABEL}${STD}"
  echo -e "Memory (RAM)           : Total ${YLW}${RAM_TOTAL_USABLE_GB}GB${STD}, Used: ${BLD}${RAM_USED_GB}GB ${RAM_USAGE_PERCENTAGE_LABEL}${STD}, Available: ${BLD}${RAM_AVAILABLE_GB}GB${STD}"
  echo -e "Disk Usage             : Total ${YLW}${DISK_TOTAL_GB}B${STD}, Used: ${BLD}${DISK_USED_GB}B ${DISK_USAGE_PERCENTAGE_LABEL}${STD}, Available: ${BLD}${DISK_AVAILABLE_GB}B${STD}"

  if [ -z "${COMPONENTS}" ]; then
    echo -e "Installed Component(s) : (none from listed components)"
  else
    echo -e "Installed Component(s) : ${COMPONENTS}"
  fi

  if [ -z "${SERVICES}" ]; then
    echo -e "Installed Service(s)   : (none from listed services)"
  else
    echo -e "Installed Service(s)   : ${SERVICES}"
  fi

  LATEST_UPDATE="N/A"
  if [ -r /var/log/daily-update.log ]; then
    UPDATE_DATE=$(awk '/^Finished update steps at: / { value = substr($0, length("Finished update steps at: ") + 1) } END { print value }' /var/log/daily-update.log 2>/dev/null)
    if [ -n "${UPDATE_DATE}" ]; then
      LATEST_UPDATE="${UPDATE_DATE}"
    fi
  fi
  printf 'Latest Update          : %s\n' "${LATEST_UPDATE}"

  echo ""
  echo -e "${BLD}spstool version ${YLW}${SPSTOOL_VERSION}${STD}"
  echo -e "type ${BLD}spstool${STD} for more linux tools, and follow instructions syntax"
  echo ""

  exit 0
fi
# end of sysinfo command
