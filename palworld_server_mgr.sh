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

IDLE_TIME=$((IDLE_TIME*60)) # Convert to seconds

################################################################################
error()
{
  echo "$1" >&2
  exit 1
}

ME=$( basename "$0" )
SCRIPT="${DIR}/${ME}"
SERVER_LOG="${DIR}/logs/palworld-server.log"
LOG="${DIR}/logs/${ME}.log"

[ ${#STOP_TIMES[@]} -ne 7 -a  ${#STOP_TIMES[@]} -ne 0 ] && error "STOP_TIMES must be an array of 0 or 7 entries"

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

STOP_SECONDS=()
HAVE_STOP_TIME=N
for X in ${STOP_TIMES[@]}
do
  # We set -1 for disabled entries, this requires no special handling for the first iteration (today)
  # as today 00:00 -1 second will always lie before "now" and thus 
  [ "${X:0:1}" = "-" ] && STOP_SECONDS+=( -1 ) && continue
  [[ ! "$X" =~ ^([0-9]+)[:]([0-9]+)$ ]] && echo "ERROR: invalid STOP_TIME $X" && exit 0
  H=${BASH_REMATCH[1]}
  M=${BASH_REMATCH[2]}
  [ $H -lt 0 -o $H -gt 23 ] && echo "ERROR: invalid STOP_TIME $X" && exit 0
  [ $M -lt 0 -o $M -gt 59 ] && echo "ERROR: invalid STOP_TIME $X" && exit 0
  STOP_SECONDS+=( $((H*3600+M*60)) )
  HAVE_STOP_TIME=Y
done

[ ${HAVE_STOP_TIME} = N ] && STOP_SECONDS=() # Handle case where all times are disabled

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
    echo "scheduling shutdown for in ${delay} seconds..."
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
IDLE_LIMIT=0
CheckIdle()
{
local now=$( date +%s )
    
# We check plaer list including heading, this allows to detect errors (if header not present)
local players=$( ${DIR}/rcon -a 127.0.0.1:${RCON_PORT} -p "${RCON_PASS}" "ShowPlayers" | wc -l )

  if (( players == 1 ))
  then
    # No player connected 
    (( IDLE_LIMIT == 0 )) && IDLE_LIMIT=$((now+IDLE_TIME)) && return 1
    (( now >= IDLE_LIMIT )) && return 0
  else
   # Player connected (or rcon failed)
   IDLE_LIMIT=$((now+IDLE_TIME))
  fi
  return 1
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
local sdepoch

  if [ ${HAVE_STOP_TIME} = Y ]
  then
    sdepoch=$((depoch+sdsecs))
    # Preparation of STOP_SECONDS makes sure that we have at least one valid entry, or HAVE_STOP_TIME=N
    while true
    do
      ((sdepoch > now)) && break # we are set
      # Get next day
      depoch=$((depoch+86400))
      wd=$( date -d "@${depoch}" +%w)
      sdtime=${STOP_TIME[$wd]}
      sdsecs=${STOP_SECONDS[$wd]}
      (( sdsecs < 0 )) && continue # Do not update sdepoch and force next day for disabled days
      sdepoch=$((depoch+sdsecs))
    done
  else
    # Disable sdepoch if we have no stop times
    sdepoch=0
  fi
  
  if [ ${HAVE_STOP_TIME} = Y ]
  then
    local sleep=$((sdepoch-now))
    local sleep_time=$( date -d "@${sdepoch}" )
    echo "waiting for ${sleep} seconds until ${sleep_time}"
  fi
  local wait=60
  local override=""
  while true
  do
    sleep $wait &
    wait $!
    now=$( date +%s )      
    [ ${HAVE_STOP_TIME} = Y ] && (( now >= sdepoch )) && break
    CheckServer || break
    [ ${IDLE_TIME} -gt 0 ] && CheckIdle ${IDLE_TIME} && echo "Server ideling for ${IDLE_TIME} seconds. Shutting down..." && override=1 && break
    if [ ${HAVE_STOP_TIME} = Y ]
    then
      sleep=$((sdepoch-now))
      (( sleep < 60 )) && wait=5
    fi
  done
  echo "$( date ): woke up to shutdown server (or beacuse it is missing)"
  Shutdown ${override}
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
  IDLE_LIMIT=0 # reset ideling
  /home/steam/Steam/steamapps/common/PalServer/PalServer.sh -useperfthreads -NoAsyncLoadingThread -UseMultithreadForDS -RCONPort=${RCON_PORT} >${SERVER_LOG} 2>&1 &
  SERVER_PID="$!"
  echo "server pid=${SERVER_PID}"
  wait_for_shutdown_time
done
