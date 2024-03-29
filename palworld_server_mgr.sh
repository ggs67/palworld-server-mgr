#! /usr/bin/env bash

#set -x

ME=$( basename "$0" )
DIR=$( dirname "$0" )
DIR=$( realpath "$DIR" )
CFG="${DIR}/${ME%.sh}.conf"
TOOLSDIR="${DIR}/tools"

[ ! -f "${CFG}" ] && echo "ERROR: no config file ${CFG}" && exit 9
CFG_PROT=$( stat --format %a "${CFG}" )
CFG_UID=$( stat --format %u "${CFG}" )
PROC_UID=$( stat --format %u "/proc/$$" )
PROC_USER=$( stat --format %U "/proc/$$" )

source "${CFG}"

IDLE_TIME=$((IDLE_TIME*60)) # Convert to seconds

LISTENER_CMD="socat"
SERVER_CMD="PalServer-Linux"

STEAM_PALSERVER="${HOME}/Steam/steamapps/common/PalServer/"

SAVEGAMES="Steam/steamapps/common/PalServer/Pal/Saved/SaveGames"
CONFIGS="Steam/steamapps/common/PalServer/Pal/Saved/Config"

SCRIPT="${DIR}/${ME}"
SERVER_LOG="${DIR}/logs/palworld-server.log"
LOGDIR="${DIR}/logs"
LOG="${LOGDIR}/${ME}.log"
BACKUPDIR="${DIR}/backups"
BACKUPFILE="palserver.tar.bz2"
UPDATE_SEMAPHORE="${DIR}/.update"
SHUTDOWN_SEMAPHORE="${DIR}/.shutdown_mgr"
POWERDOWN=N

################################################################################
error()
{
  echo "" >&2
  echo "ERROR: $1" >&2
  echo "" >&2
  exit 1
}

warning()
{
  echo "" >&2
  echo "WARNING: $1" >&2
}

#-------------------------------------------------------------------------------
check_owned_files()
{
local uo=$( find "$2" ! -user $1 | wc -l )
  [[ $uo -eq 0 ]] && return 0
  find "$2" ! -user $1 -exec ls -l {} \;
  warning "files in $2, must be owned by user $1"
  error "please 'chown' files listed above to user $1"
}

#-------------------------------------------------------------------------------
# The script expect a specific user to execute it
check_valid_user()
{
local userinfo=$( grep -E "^[^:]*[:][^:]*[:]${UID}[:]" /etc/passwd | head -1 )
  [ -z "${userinfo}" ] && error "no user record found for uid $UID"
local user=$( cut -d ':' -f 1 <<<"${userinfo}" )
local home=$( cut -d ':' -f 6 <<<"${userinfo}" )

  [ "${HOME}" != "$home" ] && error "we do not accept manipulated HOME variable, pointing to ${HOME} instead of ${home}"
  [ ! -d "${HOME}/Steam" ] && error "we expect Steam to be installed in ${HOME}/Steam"
  [[ $( realpath --relative-base="${HOME}" "${DIR}" ) =~ ^[/] ]] && error "we expect this script to be installed below ${HOME}"
  [ "${user}" != "${STEAM_USER}" ] && warning "user name '${user}' is not the expected '${STEAM_USER}', you may adjust STEAM_USER in the conf file" && error "please use expected user or edit conf file"
  check_owned_files ${STEAM_USER} "${DIR}"
  check_owned_files ${STEAM_USER} "${HOME}/Steam"
}

check_valid_user

#-------------------------------------------------------------------------------
need_dir()
{
  [ -d "$1" ] && return 0
  mkdir "$1"    
}

need_dir "${LOGDIR}"
need_dir "${BACKUPDIR}"

#-------------------------------------------------------------------------------
check_int()
{
  [[ ! "$1" =~ [0-9]+ ]] && error "$2 requires an integer value, got '$1'"
}

timestamp()
{
  if [ -z "$1" ]
  then	
    date +"${TSFMT}"
  else
    date -d "$1" +"${TSFMT}"
  fi
}

#-------------------------------------------------------------------------------
MAXLOGLEVEL=4
LOGLEVEL=${MAXLOGLEVEL}
INTERACTIVE=N
log()
{
  [ $1 -gt $LOGLEVEL ] && return 0
  echo "$2"
}

logT()
{
  log "$1" "$2 ($(timestamp))"
}


log_printf()
{
  local level=$1
  local text    
  shift
  printf -v text "$@"
  log $level "$text"
}

logT_printf()
{
  local level=$1
  local text    
  shift
  printf -v text "$@"
  logT $level "$text"
}

#-------------------------------------------------------------------------------
logI()
{
  [ $INTERACTIVE != Y ] && log $1 "$2" && return 0
  log 0 "$2"
}

logTI()
{
  [ $INTERACTIVE != Y ] && logT $1 "$2" && return 0
  logT 0 "$2"
}

logI_printf()
{
  local level=$1
  local text    
  shift
  printf -v text "$@"
  logI $level "$text"
}

logTI_printf()
{
  local level=$1
  local text    
  shift
  printf -v text "$@"
  logTI $level "$text"
}

# Prevent immediate shutdown again
[ -f "${SHUTDOWN_SEMAPHORE}" ] && rm "${SHUTDOWN_SEMAPHORE}"

[ ${#STOP_TIMES[@]} -ne 7 -a  ${#STOP_TIMES[@]} -ne 0 ] && error "STOP_TIMES must be an array of 0 or 7 entries"

START_NOW=N
START_LOG=N
DEBUG=N
WORLDOPTIONS=N

#----------------------------------------------------------------------
# % 1 var
today_epoch()
{
local e=$( date +%s )

  e=$(( e - e % 86400 - 3600 ))
  eval $1=$e
}

#----------------------------------------------------------------------
file_version()
{
local n=$1
local f="$2"
local vf vfn

  while (( n>=0 ))
  do
    vf="$f.$n"
    [ $n -eq 0 ] && vf="$f"
    vfn="$f.$((n+1))"
    n=$((n-1))
    [ ! -f "$vf" ] && continue
    if [ $n -eq $1 ]
    then
      rm "${vf}"
    else
      mv "${vf}" "${vfn}"
    fi
  done
}


#----------------------------------------------------------------------
backup_palserver()
{
  logTI 1 "backing up PalWorld server..."
  file_version ${SERVER_BACKUP_VERSIONS:-5} "${BACKUPDIR}/${BACKUPFILE}"
  tar --create --auto-compress --directory="${HOME}" --file="${BACKUPDIR}/${BACKUPFILE}" "${SAVEGAMES}" "${CONFIGS}"
  logTI 1 "backup done with status $?"
}

#----------------------------------------------------------------------
BACKUP_TIMESTAMP=0
auto_backup()
{
  [ "${ENABLE_SERVER_BACKUPS}" = "Y" ] && { backup_palserver ; return $? ; }
  [ "${ENABLE_SERVER_BACKUPS}" != "D" ] && return 0
  local t=$( date +%s )
  (( t < (BACKUP_TIMESTAMP+86400) )) && return 0
  today_epoch BACKUP_TIMESTAMP
  backup_palserver
}

#----------------------------------------------------------------------
# %1 : variable
# %2 : time string HH:MM
# %3 : default value if %2 is empty
# %4 : error info
ParseTime()
{
local _H _M
  [ -z "$2" ] && eval $1="$3" && return 0
  [[ ! "$2" =~ ^([0-9]+)[:]([0-9]+)$ ]] && error "invalid time '$2' for $4"
  _H=${BASH_REMATCH[1]}
  _M=${BASH_REMATCH[2]}
  [ ${_H} -lt 0 -o ${_H} -gt 23 ] && error "invalid time '$2' for $4"
  [ ${_M} -lt 0 -o ${_M} -gt 59 ] && error "invalid time '$2' for $4"
  eval $1=$((_H*3600+_M*60))
}

#----------------------------------------------------------------------
RescheduleUpdate()
{
  [ "${SERVER_UPDATE_SCHEDULE}" = "NONE" ] && return 1

  local now=$( date +%s )

  while (( SERVER_UPDATE_SCHEDULE <= now ))
  do
    SERVER_UPDATE_SCHEDULE=$((SERVER_UPDATE_SCHEDULE+86400))
  done
  return 0
}

#----------------------------------------------------------------------
secs_to_time()
{
local d=0 h=0 m s=$1
local t=""
typeset -g TIME

   (( s >= 86400 )) && d=$((s/86400)) && s=$((s-d*86400))
   (( s >= 3600 )) && h=$((s/3600)) && s=$((s-h*3600))
   (( s >= 60 )) && m=$((s/60)) && s=$((s-m*60)) || m=0
   (( d > 0 )) && printf -v TIME "%d %02d:%02d:%02d" $d $h $m $s && return 0
   (( h > 0 )) && printf -v TIME "%02d:%02d:%02d" $h $m $s && return 0
   printf -v TIME "%02d:%02d" $m $s
}

#----------------------------------------------------------------------
# %1 : variable
# %2 : time string HH:MM
# %3 : default value if %2 is empty
# %4 : error info
ParseTodayTime()
{
local _today=$( date +%s)
local _time    
  _today=$( date -d "@${_today}" +%D )
  _today=$( date -d "${_today}" +%s )

  ParseTime "_time" "$2" "@" "$4"
  [ "$_time" = "@" ] && eval $1="$3" && return 0
  eval $1=$((_today+_time))
}

usage()
{
  echo "" >&2
  echo "usage: ${ME} [-L] [-l <n>] [-x] [-N] [-w]  - run server manager interactively" >&2
  echo "       ${ME} [-s|-S|-H <delay>|-U|-u|-p]   - send commands to running manager" >&2
  echo "       ${ME} [-h]                    - to display this help" >&2
  echo "" >&2
  echo " Service flags (can be passed via install.sh)" >&2
  echo " --------------------------------------------" >&2  
  echo " -L : log into log file in logs subdirectory instead of stdout" >&2
  echo "      e.g. system journal" >&2
  echo " -l <n> : set log level (0-4)"
  echo " -x : enable debugging outputting each script line as executed" >&2
  echo "" >&2
  echo " Interactive flags (cannot be passed via install.sh)" >&2
  echo " ---------------------------------------------------" >&2
  echo " -N : start server immediatally without waiting for an incomming" >&2
  echo "      connection" >&2
  echo "" >&2
  echo " -p : list players on server" >&2
  echo " -U : send a request to the server manager to check for a PalWorld server" >&2
  echo "      update. Note that if the PalWorld server is currently running," >&2
  echo "      the update will be deferred until its shutdown" >&2
  echo " -s <delay> : send shutdown request to the server if running." >&2
  echo "              IMPORTANT: this option does NOT shutddown the server manager !" >&2
  echo " -S <delay> : send shutdown request to the server manager. If the server is" >&2
  echo "              curently running a shutdown request with given delay is issued" >&2
  echo "              IMPORTANT: this option also shutds down the server manager !" >&2
  echo " -P <delay> : like -S but powers system down after the server is down " >&2
  echo " -B : interactively backup server (only if not running)"
  echo " -c : edit config" >&2
  echo "      NODE: config can only be edited when server is down, because otherwise" >&2
  echo "            it will be overwritten by the server" >&2
  echo " -w : save world-options as save file (see github legoduded/palworld-worldoptions" >&2
  echo "      for details." >&2
  echo "      IMPORTANT: install.sh must have been run with the -w option !" >&2
  echo "" >&2
  [ -n "$1" ] && error "$1"
  exit 0
}

#----------------------------------------------------------------------
# Check server which is not owned by our process
CheckOtherServer()
{
local _socket=$( ss -u -a -n -p|grep -E "[[:space:]][0-9.]+[:]${PORT}[[:space:]]+[0-9.]+[:][*]" )

  [ -z "${_socket}" ] && return 2 # Socket not in use

  # UNCONN 0      0                                 0.0.0.0:8211       0.0.0.0:*     users:(("socat",pid=2144987,fd=5))
  typeset -g SOCKET_PID=""
  [[ "${_socket}" =~ users\:\(.+\,pid\=([0-9]+) ]] && typeset -g SOCKET_PID=${BASH_REMATCH[1]}
  grep -q -E "users[:][(][(][\"]${LISTENER_CMD}[\"]" <<<"${_socket}" && return 1 # Currently waiting for connection
  grep -q -E "users[:][(][(][\"]${SERVER_CMD}[\"]" <<<"${_socket}" && return 0 # Server running
  return 3 # Unknown user
}

#----------------------------------------------------------------------
ShowPlayers()
{    
  # We check plaer list including heading, this allows to detect errors (if header not present)

  echo ""
  echo "Users on PalWorld server:"
  echo ""
  ${DIR}/rcon -a 127.0.0.1:${RCON_PORT} -p "${RCON_PASS}" "ShowPlayers"
  echo ""
}

#----------------------------------------------------------------------
CheckPlayersOnline()
{
    # If command fails, we assume no users
    local players=$( ${DIR}/rcon -a 127.0.0.1:${RCON_PORT} -p "${RCON_PASS}" "ShowPlayers" 2>/dev/null | wc -l ; exit ${PIPESTATUS[0]} ) ||
	{ typeset -g ONLINE_PLAYERS=0 ; return 1; }
  [ -z "${players}" ] && error "unexpected empty ShowPlayers output"
  players=$((players-1))
  typeset -g ONLINE_PLAYERS=${players}
  [ ${players} -gt 0 ] # 1 is header
}

#----------------------------------------------------------------------
Shutdown()
{
local count
local delay=$1
local sleep=15
local pstatus

  [ -z "${delay}" ] && delay=${SHUTDOWN_DELAY} 
  if CheckServer
  then
    CheckPlayersOnline || { logI 1 "no users online, shutting down immediatally..." ; delay=1 ; }
    logI 1 "scheduling shutdown for in ${delay} seconds..."
    ${DIR}/rcon -a 127.0.0.1:${RCON_PORT} -p "${RCON_PASS}" "ShutDown ${delay}" || break
    # Wait for shutdown while checking for users
    while (( delay > 0 ))
    do
      (( delay < sleep )) && sleep=5
      sleep ${sleep}
      (( sleep <= delay )) && delay=$((delay-sleep)) || delay=0
      # We consider everything below 30 seconds to be fast enough not to require
      # rescheduling
      if (( delay >= 30 ))
      then
	CheckServer || break
        CheckPlayersOnline
	pstatus=$?
	secs_to_time ${delay}
	logI_printf 2 "%8s remaining, still ${ONLINE_PLAYERS} players online\n" "${TIME}"
	(( pstatus == 0 )) && continue # Still players online
        delay=1
        logI 1 "all players left, re-scheduling shutdown for in ${delay} seconds..."
        ${DIR}/rcon -a 127.0.0.1:${RCON_PORT} -p "${RCON_PASS}" "ShutDown ${delay}" || break
      fi
    done
    # Allow 2 minutes for server to shutdown
    count=12
    while (( count > 0 ))
    do
      logI 2 "  waiting for server exit..."
      count=$((count-1))
      CheckServer || break
      sleep 10
    done
    ((count==0)) && logI 0 "ERROR: server shutdown failed !" 
    Cleanup
  else
    Cleanup
  fi  
}

#----------------------------------------------------------------------
SigTerm()
{
  log 1 "SIGTERM received, shutting down"
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
    logI 3 "  sending SIGHUP to $pid"
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
      logI 1 "Failed to HUP palserver process $pid, foricng by SIGKILL"
      kill -KILL ${pid}
      count=3
      while ((count > 0))
      do
        count=$((count-1))
        CheckProc $pid || break	
        sleep 5
      done
      ((count==0)) && logI 0 " SIGKILL also failed, exiting server manager. Need admin!" && exit 1
    fi
  done  
}

#----------------------------------------------------------------------
CheckServer()
{
  [ -z "${SERVER_PID}" ] && return 1
  [ ! -d /proc/${SERVER_PID} ] && return 1
  fgrep -q "PalServer.sh" /proc/${SERVER_PID}/cmdline >/dev/null 2>&1 && return 0 # Will also fail if process just killed
  fgrep -q "${SERVER_CMD}" /proc/${SERVER_PID}/cmdline >/dev/null 2>&1 # Will also fail if process just killed
}

#----------------------------------------------------------------------
INIFILE=${HOME}/Steam/steamapps/common/PalServer/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini
edit_config()
{
  CheckOtherServer && echo "server must be shutdown prior to editing the copnfig file !" && return 1
  ${EDITOR} "${INIFILE}"
  worldoptions -o
}

#----------------------------------------------------------------------
checkdir()
{
local optional=N
  [ "$1" = "-o" ] && optional=Y && shift
  [ -d "$1" ] && return 0
  [ ${optional} = Y ] && return 1
  echo "ERROR: missing directory $1"    
  echo "ERROR: $2" >&2
  exit 1
}

#----------------------------------------------------------------------
checkexe()
{
local optional=N
  [ "$1" = "-o" ] && optional=Y && shift
  [ -x "$1" ] && return 0
  [ ${optional} = Y ] && return 1
  echo "ERROR: $1 is not en executable"    
  echo "ERROR: $2" >&2
  exit 1
}

#----------------------------------------------------------------------
checkfile()
{
local optional=N
  [ "$1" = "-o" ] && optional=Y && shift
  [ -f "$1" ] && return 0
  [ ${optional} = Y ] && return 1
  echo "ERROR: missing file $1"    
  echo "ERROR: $2" >&2
  exit 1
}

#----------------------------------------------------------------------
# accepts -o option: optional
worldoptions()
{
local PWWODIR="${TOOLSDIR}/palworld-worldoptions"
local UESAVEDIR="${TOOLSDIR}/uesave-rs"
local UESAVE=("${UESAVEDIR}/target/"*"/uesave")
local PWWO="${PWWODIR}/src/main.py"
local target

  UESAVE="${UESAVE[0]}"
  checkdir $1 "${PWWODIR}" "palworld-worldoptions not installed, please run ./install.sh -w" || return 1
  checkdir $1 "${UESAVEDIR}" "palworld-worldoptions requires uesave-rs, please run ./install.sh -w" || return 1
  checkexe $1 "${UESAVE}" "looks like uesave-rs was not compiled, please run ./install.sh -w" || return 1
  checkfile $1 "${PWWO}" "palworld-worldoptions main.py missing" || return 1

  echo "generating WorldOption.sav..."
  python3 "${PWWO}" --uesave "${UESAVE}" --output "${DIR}/" "${INIFILE}" || exit 1
  echo "distributing WorldOption.sav..."
  while read target
  do
    target=$( dirname "${target}" )
    echo "  ...to ${target}"      
    cp "${DIR}/WorldOption.sav" "${target}" && exit 1
  done < <( find "${STEAM_PALSERVER}" -name "LevelMeta.sav" )
  echo "done"
}


while [ -n "$1" ]
do
  OPT="$1"
  shift
  case $OPT in
    -c) edit_config
        exit $?
	;;
    -N) START_NOW=Y
        ;;
    -L) START_LOG=Y
	;;
    -l) LOGLEVEL=$1
	shift
	check_int "${LOGLEVEL}" "-l option"
	;;
    -w) worldoptions
	exit $?
	;;
    -x) DEBUG=Y
	;;
    -B) CheckOtherServer && error "palserver must be shutdown prior to backup. nothing done"
	backup_palserver
	exit $?
	;;
    -P) echo "powering down system in ${1} seconds"
	POWERDOWN=Y
	;&
    -S) shut_mgr=Y
	;&
    -s) [ -z "${shut_mgr}" ] && shut_mgr=N
	INTERACTIVE=Y
	SHUTDOWN_DELAY=$1
	shift
	[[ ! "${SHUTDOWN_DELAY}" =~ [0-9]+ ]] && error "-s|-S|-P options require integer delay in seconds, got ${SHUTDOWN_DELAY}"
	CheckOtherServer
        _status=$?
	echo ""
	case ${_status} in
	    0) [ ${shut_mgr} = Y ] && echo "setting shutdown semaphore for server manager..." && touch "${SHUTDOWN_SEMAPHORE}"
	       SERVER_PID=${SOCKET_PID} # Set SERVER_PID to allow for CheckServer and use ShutDown
	       [ -z "${SERVER_PID}" ] && error "BUG: we do not expect SOCKET_PID to be empty"
	       Shutdown ${SHUTDOWN_DELAY}
	       ;;
	    1) echo "server currently not running, e.g. no players connected."
	       if [ ${shut_mgr} = Y ]
	       then
                 echo "sending immediate shutdown request..."
	         socat STDIN,readbytes=8 UDP4-SENDTO:127.0.0.1:${PORT} <<<"SHUTDOWN"
	       else
		 echo "nothing done."
	       fi
	       ;;
	    2) echo "looks like palworld server manager is currently down, nothing done"
	       ;;
	    3) echo "looks like port ${PORT} is currently used by another user, nothing done"
	       ;;
        esac
	[ "${POWERDOWN}" = Y ] && sudo shutdown -h now
	exit 0
	;;
    -U) INTERACTIVE=Y
	echo "sending update request..."
	touch "${UPDATE_SEMAPHORE}" || exit 9
	chmod 777 "${UPDATE_SEMAPHORE}"
	CheckOtherServer || socat STDIN,readbytes=8 UDP4-SENDTO:127.0.0.1:${PORT} <<<"UPDATE  "
	exit 0
	;;
    -p) INTERACTIVE=Y
	CheckOtherServer
        _status=$?
	echo ""
	case ${_status} in
	    0) CheckPlayersOnline || { echo "currently no player online" ; exit 0; }
	       ShowPlayers
	       ;;
	    1) echo "server currently not running, e.g. no players connected."
	       ;;
	    2) echo "looks like palworl server manager is currently down, e.g. no server, e.g. no players"
	       ;;
	    3) echo "looks like port ${PORT} is currently used by another user, e.g. server manager down, e.g. no server, e.g. no players"
	       ;;
        esac
	exit 0
	;;
    -h) usage
	;;
     *) usage "unknown option $OPT"
	exit 99
	;;
  esac  
done

 # We moved the security tests to this point to allow any user (including root) to use -S and -U
(( PROC_UID == 0 )) && echo "ERROR: $ME cannot run from root except for -U or -S" && exit 9
(( PROC_UID != CFG_UID )) && echo "ERROR: config file $CFG MUST be owned by ${PROC_USER}" && exit 9
[ "${CFG_PROT}" != 600 ] && echo "ERROR: config file MUST be protected with mask 600" && exit 9

[ $( ss -4 -u -a -n|fgrep "0.0.0.0:${PORT}"|wc -l ) -gt 0 ] && error "port ${PORT} already in use. aborting..." && exit 1

[ $START_LOG = Y ] && log 1 "start logging..." && exec  >${LOG} 2>&1
[ $DEBUG = Y ] && log 0 "debugging (-x) requested..." && LOGLEVEL=${MAXLOGLEVEL} && set -x

ParseTodayTime SERVER_UPDATE_SCHEDULE "${SERVER_UPDATE_TIME}" "NONE" "SERVER_UPDATE_TIME"
RescheduleUpdate # Make sure schedule is in the future

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
# %1 : variable
GetNow()
{
  eval $1=$( date +%s )
}

#----------------------------------------------------------------------
UpdateServer()
{
  logTI 2 "checking for updates..."  
  RescheduleUpdate
  [ -f "${UPDATE_SEMAPHORE}" ] && rm "${UPDATE_SEMAPHORE}"
  /usr/games/steamcmd +force_install_dir "${HOME}/Steam/steamapps/common/PalServer" +login anonymous +app_update 2394010 +quit
}

#----------------------------------------------------------------------
IDLE_LIMIT=0
PLAYERS=0
CheckIdle()
{
local now=$( date +%s )
    
# We check plaer list including heading, this allows to detect errors (if header not present)
local players=$( ${DIR}/rcon -a 127.0.0.1:${RCON_PORT} -p "${RCON_PASS}" "ShowPlayers" | wc -l )

  players=$((players-1))
  if (( players == 0 ))
  then
    # No player connected
    (( PLAYERS > 0 )) && PLAYERS=0 && logTI 3 "server started ideling"
    (( IDLE_LIMIT == 0 )) && IDLE_LIMIT=$((now+IDLE_TIME)) && return 1
    (( now >= IDLE_LIMIT )) && return 0
  else
    # Player connected (or rcon failed)
    (( players != PLAYERS )) && PLAYERS=${players} && logTI 3 "${players} players now online"
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
    local sleep_time=$( timestamp "@${sdepoch}" )
    log 2 "waiting for ${sleep} seconds until ${sleep_time}"
  fi
  local wait=60
  local override=""
  local players=0
  while true
  do
    sleep $wait &
    wait $!
    now=$( date +%s )      
    [ ${HAVE_STOP_TIME} = Y ] && (( now >= sdepoch )) && break
    CheckServer || break
    if (( LOGLEVEL >=4 ))
    then
      CheckPlayersOnline
      (( players != ONLINE_PLAYERS )) && logT 4 "online payers ${players} -> ${ONLINE_PLAYERS}" && players=${ONLINE_PLAYERS}
    fi
    [ ${IDLE_TIME} -gt 0 ] && CheckIdle ${IDLE_TIME} && log 2 "Server ideling for ${IDLE_TIME} seconds. Shutting down..." && override=1 && break
    if [ ${HAVE_STOP_TIME} = Y ]
    then
      sleep=$((sdepoch-now))
      (( sleep < 60 )) && wait=5
    fi
  done
  logT 1 "woke up to shutdown server (or beacuse it is missing)"
  Shutdown ${override}
}

SERVER_PID=""
FORCE_UPDATE=N

while true
do
  SERVER_PID=""

  # Update schedule reached ?
  now=$( date +%s )
  # Updateserver is potentially called 3 times below but a maximum of 1 call will
  # actually be done as UpdateServer resets the schedule and semaphore
  [ ${FORCE_UPDATE} = Y ] && FORCE_UPDATE=N && UpdateServer 
  [ -f "${UPDATE_SEMAPHORE}" ] && UpdateServer
  [ ${SERVER_UPDATE_SCHEDULE} != NONE ] && (( SERVER_UPDATE_SCHEDULE <= now )) && UpdateServer
  log 1 "waiting for incomming connection..."    
  if [ ${START_NOW} != Y ]
  then
    if RescheduleUpdate
    then
      GetNow NOW
      TMO="-T $((SERVER_UPDATE_SCHEDULE-NOW+1))"
      log 2 "  scheduling update check for $( timestamp "@${SERVER_UPDATE_SCHEDULE}" )"
    else
      TMO=""
    fi
    CMD=$( socat -u $TMO UDP4-RECV:${PORT},readbytes=8 STDOUT 2>/dev/null | cut -c 1-8 | cat -t )
    [ "$CMD" = "SHUTDOWN" ] && log 2 "shutdown requested via packet. gracefully exiting..." && exit 0
    [ "$CMD" = "UPDATE  " ] && log 2 "update requested via packet." && FORCE_UPDATE=Y && continue
    [ -z "$CMD" ] && continue # This case was timeout, i.e. scheduled update
  fi
  START_NOW=N
  logT 1 "connection sensed, starting server..."
  IDLE_LIMIT=0 # reset ideling
  /home/steam/Steam/steamapps/common/PalServer/PalServer.sh -useperfthreads -NoAsyncLoadingThread -UseMultithreadForDS -RCONPort=${RCON_PORT} BaseCampWorkerMaxNum=60 >${SERVER_LOG} 2>&1 &
  SERVER_PID="$!"
  log 3 "server pid=${SERVER_PID}"
  wait_for_shutdown_time
  auto_backup
  if [ -f "${SHUTDOWN_SEMAPHORE}" ]
  then
    rm -f "${SHUTDOWN_SEMAPHORE}"
    log 1 "shutdown requested via semaphorre. gracefully exiting..."
    exit 0
  fi  
done
