#! /usr/bin/env bash

#set -x

ME=$( basename "$0" )
DIR=$( dirname "$0" )
DIR=$( realpath "$DIR" )
CFG="${DIR}/${ME%.sh}.conf"

[ ! -f "${CFG}" ] && echo "ERROR: no config file ${CFG}" && exit 9
CFG_PROT=$( stat --format %a "${CFG}" )
CFG_UID=$( stat --format %u "${CFG}" )
PROC_UID=$( stat --format %u "/proc/$$" )
PROC_USER=$( stat --format %U "/proc/$$" )

(( PROC_UID == 0 )) && echo "ERROR: $ME cannot run from root" && exit 9
(( PROC_UID != CFG_UID )) && echo "ERROR: config file $CFG MUST be owned by ${PROC_USER}" && exit 9
[ "${CFG_PROT}" != 600 ] && echo "ERROR: config file MUST be protected with mask 600" && exit 9

source "${CFG}"

STOP_SECONDS=()

################################################################################

ME=$( basename "$0" )
SCRIPT="${DIR}/${ME}"
SERVER_LOG="${DIR}/logs/palworld-server.log"
LOG="${DIR}/logs/${ME}.log"

START_NOW=N
START_LOG=N
DEBUG=N

while [ -n "$1" ]
do
  OPT="$1"
  shift
  case $OPT in
    -s) START_NOW=Y
        ;;
    -L) START_LOG=Y
	;;
    -x) DEBUG=Y
	;;
    -S) echo "sending shutdown request..."
	nc -u -w 5 127.0.0.1 $PORT <<<"SHUTDOWN"
	exit 0
	;;
    *) echo "ERROR: unknown option $OPT"
  esac  
done

[ $START_LOG = Y ] && echo "start logging..." && exec  >${LOG} 2>&1
[ $DEBUG = Y ] && echo "debugging (-x) requested..." && set -x

for X in ${STOP_TIMES[@]}
do
  [[ ! "$X" =~ ^([0-9]+)[:]([0-9]+)$ ]] && echo "ERROR: invalid STOP_TIME $X" && exit 0
  H=${BASH_REMATCH[1]}
  M=${BASH_REMATCH[2]}
  [ $H -lt 0 -o $H -gt 23 ] && echo "ERROR: invalid STOP_TIME $X" && exit 0
  [ $M -lt 0 -o $M -gt 59 ] && echo "ERROR: invalid STOP_TIME $X" && exit 0
  STOP_SECONDS+=( $((H*3600+M*60)) )
done

#----------------------------------------------------------------------
CheckServer()
{
  [ -z "${SERVER_PID}" ] && return 1
  [ ! -d /proc/${SERVER_PID} ] && return 1
  fgrep -q "PalServer.sh" /proc/${SERVER_PID}/cmdline >/dev/null 2>&1 # Will also fail if process just killed
}

#----------------------------------------------------------------------
Shutdown()
{
local count
local delay=$1

  [ -z "${delay}" ] && delay=${SHUTDOWN_DELAY} 
  if CheckServer
  then
    echo "scheduling shutdown for in ${SHUTDOWN_DELAY} seconds..."
    ${DIR}/rcon -a 127.0.0.1:${RCON_PORT} -p "${RCON_PASS}" "ShutDown ${delay}" || break
    sleep ${delay}
    # Allow 2 minutes for server to shutdown
    count=12
    while (( count > 0 ))
    do
      echo "  waiting for server exit..."
      count=$((count-1))
      CheckServer || break
      sleep 10
    done
    ((count==0)) && echo "ERROR: server shutdown failed !" 
    Cleanup
  else
    Cleanup
  fi  
}

#----------------------------------------------------------------------
SigTerm()
{
  echo "SIGTERM received, shutting down"
  Shutdown 10
  exit 0
}

trap SigTerm TERM

#----------------------------------------------------------------------
CheckProc()
{
  [ -d /proc/$1 ]
}

#----------------------------------------------------------------------
Cleanup()
{
local pids=()
local pid=
local count=0

  while read LINE
  do
    [[ "$LINE" =~ ^[^[:space:]]+[[:space:]]+([0-9]+).+[/]PalServer ]] || continue
    pid=${BASH_REMATCH[1]}
    pids=( $pid ${pids[@]} )
  done < <( ps --no-headers -efH|fgrep PalServer )

  for pid in ${pids[@]}
  do
    CheckProc $pid || continue # Already exited
    echo "  sending SIGHUP to $pid"
    kill -HUP ${pid}
    count=9
    while ((count > 0))
    do
      count=$((count-1))
      CheckProc $pid || break	
      sleep 5
    done

    if ((count==0))
    then
      echo "Failed to HUP palserver process $pid, foricng by SIGKILL"
      kill -KILL ${pid}
      count=3
      while ((count > 0))
      do
        count=$((count-1))
        CheckProc $pid || break	
        sleep 5
      done
      ((count==0)) && echo " SIGKILL also failed, exiting server manager. Need admin!" && exit 1
    fi
  done  
}


#----------------------------------------------------------------------
wait_for_shutdown_time()
{
local now=$( date +%s)
local date=$( date -d "@${now}" +%D )
local depoch=$( date -d "${date}" +%s )
local wd=$( date -d "@${now}" +%w)
local sdtime=${STOP_TIME[$wd]}
local sdsecs=${STOP_SECONDS[$wd]}
local sdepoch=$((depoch+sdsecs))

  if (( sdepoch < now ))
  then
    # Get next day
    depoch=$((depoch+86400))
    wd=$( date -d "@${depoch}" +%w)
    sdtime=${STOP_TIME[$wd]}
    sdsecs=${STOP_SECONDS[$wd]}
    sdepoch=$((depoch+sdsecs))
  fi
  local sleep=$((sdepoch-now))
  local sleep_time=$( date -d "@${sdepoch}" )
  echo "waiting for ${sleep} seconds until ${sleep_time}"
  wait=60
  while (( now < sdepoch ))
  do
    sleep $wait
    now=$( date +%s )      
    (( now >= sdepoch )) && break
    CheckServer || break
    sleep=$((sdepoch-now))
    (( sleep < 60 )) && wait=5 
  done
  echo "$( date ): woke up to shutdown server (or beacuse it is missing)"
  Shutdown
}

SERVER_PID=""

while true
do
  SERVER_PID=""
  echo "waiting for incomming connection..."    
  if [ ${START_NOW} != Y ]
  then
    CMD=$( nc -l -u -p $PORT -W 1 2>/dev/null | cut -c 1-8 | fgrep "SHUTDOWN" )
    [ "$CMD" = "SHUTDOWN" ] && echo "shutdown requested via packet. gracefully exiting..." && exit 0
  fi
  START_NOW=N
  echo "connection sensed, starting server..."    
  /home/steam/Steam/steamapps/common/PalServer/PalServer.sh -useperfthreads -NoAsyncLoadingThread -UseMultithreadForDS -RCONPort=${RCON_PORT} >${SERVER_LOG} 2>&1 &
  SERVER_PID="$!"
  echo "server pid=${SERVER_PID}"
  wait_for_shutdown_time
done
