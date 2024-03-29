#!/usr/bin/env bash

# set -x

SCRIPT="$0"
ME=$( basename "${SCRIPT}" )
DIR=$( dirname "${SCRIPT}" )
DIR=$( realpath "${DIR}" )

OPTS=()
CONF="${DIR}/${ME%.sh}.conf"
[ ! -f "${CONF}" ] && echo "ERROR: missing conf file ${CONF}" && exit 1
source "${CONF}"

KNOWN_FLAGS="xLl:"
SERVICE=${SERVICE_NAME}.service

#------------------------------------------------------------------------------
remove_service()
{
local rc="/etc/systemd/system/${SERVICE}"

  [ ! -f "$rc" ] && echo "service ${SERVICE} not found, nothing done." && return 0
  echo "removing ${SERVICE}..."
  sudo systemctl is-active ${SERVICE} && sudo systemctl stop ${SERVICE}
  sudo systemctl disable ${SERVICE}
  sudo rm -f ${rc}
  sudo systemctl daemon-reload
}

#------------------------------------------------------------------------------
sudo_shutdown()
{
    local user=$(whoami)
    local cmd=$( command -v "shutdown" )

    sed -E -e "s|[{][{]USER[}][}]|${user}|g;s|[{][{]SHUTDOWN[}][}]|${cmd}|g;s|[{][{][\\^]USER[}][}]|${user^^}|g" "${DIR}/palworld.sudo" | sudo tee /etc/sudoers.d/palworld >/dev/null
    sudo chmod 640 /etc/sudoers.d/palworld
}

#------------------------------------------------------------------------------
ORIGINAL_SERVICE=N
REMOVE_SERVICE=N
PALWORLD_OPTIONS_TOOL=N
HELP=N
SUDO_SHUTDOWN=N
ADDITIONAL_OPTION_ERROR=
SERVICE_ARGS_ERROR=

usage()
{
  echo "" >&2
  echo "usage: ${ME} -R|-O [-- <server-mgr-options>]" >&2
  echo "" >&2
  echo " -h : this help"
  echo " -w : enable palworld-worldoptions"
  echo " -s : allow unattended system poweroff"
  echo " -R : remove ${SERVICE}" >&2
  echo " -O : install original palworld service without server manager" >&2
  echo "" >&2
  echo " Server manager options can be specified following a --" >&2
  echo " See ./palword_server_mgr.sh -h for a list of possible" >&2
  echo " options" >&2
  echo "" >&2
  echo "" >&2
  STATUS=0
  [ -n "$1" ] && echo "$2" >&2 && echo "" && STATUS=99
  exit ${STATUS}
}

check_additional()
{
  [ -z "${ADDITIONAL_OPTION_ERROR}" ] && return 0
  (( COUNT < 2 )) && return 0
  echo "ERROR: ${ADDITIONAL_OPTION_ERROR}"
  exit 1
}

#--------------------------------------------------------------------------
TOOLDIR=${DIR}/tools
[ ! -d "${TOOLDIR}" ] && mkdir "${TOOLDIR}"
git_tool_install()
{
local url="$1"
local tool="${url##*/}"
  tool="${tool%.git}"
  echo "downloading ${tool}..."
local tooldir="${TOOLDIR}/${tool}"
  [ ${tooldir} = "/" ] && echo "DANGEROUS BUG: tooldir=${tooldir}" && exit 50
  X=$( sed -E 's/^.*(.)/\1/' <<<"${tooldir}" )
  [ ${X} = "/" ] && echo "DANGEROUS BUG: tooldir=${tooldir}" && exit 50

  [ -e "${tooldir}" ] && rm -Rf "${tooldir}"
  git -C "${TOOLDIR}" clone "${url}" || exit 1
}

#--------------------------------------------------------------------------
git_tool_update()
{
local tool="$1"
local tooldir="${TOOLDIR}/${tool}"

  [ ! -d "${tooldir}" ] && return 0
  echo "updating ${tool}..."
  git -C "${tooldir}" fetch || exit 1
}

if [ $# -gt 0 ]
then
  MODE=1
  COUNT=0
  while [ $# -gt 0 ]
  do
    PAR="$1"
    shift
    PPAR="$1" # We shift the argument only where needed (later)
    [ ${#PAR} -ne 2 ] && echo "ERROR: invalid option '$PAR'" && exit 1
    FLAG="${PAR:1:1}"
    [ ${FLAG} = "-" ] && OPTS=() && MODE=2 && continue
    if (( MODE == 1))
    then
      # install.sh options
      COUNT=$((COUNT+1))	
      check_additional
      case $PAR in
        -R)
          SERVICE_ARGS_ERROR="service args are not allowed on service removeal (${PAR})"
          ADDITIONAL_OPTION_ERROR="${PAR} install option does not allow for any other option"
	  check_additional
	  REMOVE_SERVICE=Y
	  ;;
	-O)
          SERVICE_ARGS_ERROR="service args are not allowed with original service (${PAR})"
          ADDITIONAL_OPTION_ERROR="${PAR} install option does not allow for any other option"
	  check_additional
	  ORIGINAL_SERVICE=Y
	  ;;
	-h)
          SERVICE_ARGS_ERROR="service args are not allowed with help (${PAR})"
          ADDITIONAL_OPTION_ERROR="${PAR} install option does not allow for any other option"
	  check_additional
	  HELP=Y
	  ;;
	-w) PALWORLD_OPTIONS_TOOL=Y
            ;;
	-s) SUDO_SHUTDOWN=Y
	    ;;
	*) usage "unknwon install option $PAR"
      esac
    else
      [ -n "${SERVICE_ARGS_ERROR}" ] && echo "ERROR: ${SERVICE_ARGS_ERROR}" && exit 1
      # service options
      fgrep -q -v "${FLAG}" <<<"${KNOWN_FLAGS}" && echo "ERROR: unknown service flag $PAR" && exit 1
      OPTS+=( "$PAR" )
      if fgrep -q "${FLAG}:" <<<"${KNOWN_FLAGS}"
      then
	[ -z "${PPAR}" ] && echo "ERROR: ${PAR} flag requires a parameter" && exit 1
        OPTS+=( "$PPAR" ) && shift
      fi
    fi
  done
  NOPTS=""
  for OPT in "${OPTS[@]}"
  do
    NOPTS="${NOPTS} \"${OPT}\""
  done
  echo "updating ${CONF} with OPTS=( ${NOPTS} )"
  sed -E -i.bak -e "s/^[[:space:]]*OPTS[=].*$/OPTS=(${NOPTS} )/" "${CONF}"
fi

[ ${HELP} = Y ] && usage && exit 0

# -R
if [ ${REMOVE_SERVICE} = Y ]
then
  remove_service
  exit 0 
fi

# -s
[ ${SUDO_SHUTDOWN} = Y ] && sudo_shutdown  

echo "passing options '${OPTS[@]}' to the service..."

RCON_VERSION=0.10.3
ARCH=amd64
RCON_DIR=rcon-${RCON_VERSION}-amd64_linux
RCON_ARCHIVE=${RCON_DIR}.tar.gz

LOGS="${DIR}/logs"
RCON="${DIR}/rcon.d"

if [ ! -d "${LOGS}" ]
then
  echo "creating log directory ${LOGS}"
  mkdir "${LOGS}" || exit 1
fi

echo "installing rcon..."
[ ! -d "${RCON}" ] && mkdir "${RCON}"
cd "${RCON}" || exit $?
if [ ! -d "${RCON_DIR}" ]
then
  wget https://github.com/gorcon/rcon-cli/releases/download/v0.10.3/${RCON_ARCHIVE} || exit 1
  tar xvf ${RCON_ARCHIVE} || exit 1
fi
ln -s -f ${RCON}/${RCON_DIR}/rcon ../rcon || exit 1
cd .. || exit $?


EXISTS=N
( systemctl list-units | grep -E "^[[:space:]]*${SERVICE_NAME}[.]service[[:space:]]" ) && EXISTS=Y
if [ ${EXISTS} = Y ]
then
  ACTIVE=N
  systemctl is-active ${SERVICE} &>/dev/null && ACTIVE=Y
  ENABLED=N
  systemctl is-enabled ${SERVICE} &>/dev/null && ENABLED=Y
else
  # Defaults ifor first installation
  ACTIVE=N
  ENABLED=Y
fi

[ ${ACTIVE} = Y ] && echo "shutting down currently active PalServer..." && sudo systemctl stop ${SERVICE}

# palworld-worldoptions
PWWO=palworld-worldoptions

sudo apt install git socat

if [ ${PALWORLD_OPTIONS_TOOL} = Y ]
then
  sudo apt install -y cargo
  git_tool_install https://github.com/trumank/uesave-rs.git
  git_tool_install https://github.com/legoduded/palworld-worldoptions.git
  ( cd "${TOOLDIR}/uesave-rs" && cargo build ) || exit 1  
else
  git_tool_update uesave-rs.git
  git_tool_update palworld-worldoptions.git
fi

SERVICE_FILE=${DIR}/palworld.service
[ ${ORIGINAL_SERVICE} = Y ] && SERVICE_FILE=${DIR}/palworld.orig.service
echo "installing service file ${SERVICE_FILE}..."

sed -e "s|[{]HOME[}]|${HOME}|g;s|[{]DIR[}]|${DIR}|g;s|[{]LOGS[}]|${LOGS}|g;s|[{]OPTIONS[}]|${OPTS[*]}|g" "${SERVICE_FILE}" | sudo tee /etc/systemd/system/${SERVICE} >/dev/null
sudo systemctl daemon-reload

if [ ${ENABLED} = Y ]
then
  echo "enabling ${SERVICE}..."
  sudo systemctl enable ${SERVICE}
fi

if [ ${ACTIVE} = Y ]
then
  echo "starting ${SERVICE}..."
  sudo systemctl start ${SERVICE}  
else
  echo ""
  echo "use 'sudo systemctl start ${SERVICE}' to start the server"
  echo ""
fi
