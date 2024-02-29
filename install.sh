#!/usr/bin/env bash

# set -x

KNOWN_FLAGS="xL"
OPTS=( -L )

if [ -n "$1" ]
then
  OPTS=()
  while [ $# -gt 0 ]
  do
    PAR="$1"
    shift
    if [ "${PAR:0:1}" = "-" ]
    then
      FLAG=${PAR:1}
      [ "${FLAG}" = "-" ] && OPTS=() && continue # -- can be used to clear all flags
      [ ${#FLAG} -ne 1 ] && echo "ERROR: unknown service flag $PAR" && exit 1
      fgrep -q -v "${FLAG}" <<<"${KNOWN_FLAGS}" && echo "ERROR: unknown service flag $PAR" && exit 1
      OPTS+=( "$PAR" )
    else
      OPTS+=( "$PAR" )	
    fi
  done  
fi



RCON_VERSION=0.10.3
ARCH=amd64
RCON_DIR=rcon-${RCON_VERSION}-amd64_linux
RCON_ARCHIVE=${RCON_DIR}.tar.gz

DIR=$( dirname "$0")
DIR=$( realpath "$DIR" )

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

echo "installing service palworld.service"
sed -e "s|[{]HOME[}]|${HOME}|g;s|[{]DIR[}]|${DIR}|g;s|[{]LOGS[}]|${LOGS}|g;s|[{]OPTIONS[}]|${OPTS[*]}|g" ${DIR}/palworld.service | sudo tee /etc/systemd/system/palworld.service >/dev/null
sudo systemctl daemon-reload

echo "enabling the server..."
sudo systemctl enable palworld.service

echo ""
echo "use 'sudo systemctl start palworld' to start the server"
echo ""

