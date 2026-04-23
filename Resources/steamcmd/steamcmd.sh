#!/usr/bin/env bash

# verbose
#set -x

set -o pipefail
shopt -s failglob
set -u

log () {
  echo "steamcmd.sh[$$]: $*" >&2 || :
}
# This version interprets backslash escapes like echo -e
log_e () {
  echo -e "steamcmd.sh[$$]: $*" >&2 || :
}

STEAMROOT="$(cd "$(dirname "$0")" && echo $PWD)"
if [ -z "${STEAMROOT}" ]; then
  log $"Couldn't find Steam root directory from "$0", aborting!"
  exit 1
fi
STEAMCMD=`basename "$0" .sh`

UNAME=`uname`
if [ "$UNAME" == "Linux" ]; then
  STEAMEXE="${STEAMROOT}/linux32/${STEAMCMD}"
  PLATFORM="linux32"
  export LD_LIBRARY_PATH="$STEAMROOT/$PLATFORM:${LD_LIBRARY_PATH-}"
else # if [ "$UNAME" == "Darwin" ]; then
  STEAMEXE="${STEAMROOT}/${STEAMCMD}"
  if [ ! -x ${STEAMEXE} ]; then
    STEAMEXE="${STEAMROOT}/Steam.AppBundle/Steam/Contents/MacOS/${STEAMCMD}"
  fi
  export DYLD_LIBRARY_PATH="$STEAMROOT:${DYLD_LIBRARY_PATH-}"
  export DYLD_FRAMEWORK_PATH="$STEAMROOT:${DYLD_FRAMEWORK_PATH-}"
fi

MAGIC_RESTART_EXITCODE=42

: "${DEBUGGER=}"
if [ "$DEBUGGER" == "gdb" ] || [ "$DEBUGGER" == "cgdb" ]; then
  ARGSFILE=$(mktemp $USER.steam.gdb.XXXX)

  # Set the LD_PRELOAD varname in the debugger, and unset the global version.
  : "${LD_PRELOAD=}"
  if [ "$LD_PRELOAD" ]; then
    echo set env LD_PRELOAD=$LD_PRELOAD >> "$ARGSFILE"
    echo show env LD_PRELOAD >> "$ARGSFILE"
    unset LD_PRELOAD
  fi

  # Ditto with LD_LIBRARY_PATH, avoids this below:
  # gdb: /home/plagman/src/valve/Steam/main/client/ubuntu12_32/steam-runtime/pinned_libs_64/libcurl.so.4: version `CURL_OPENSSL_4' not found (required by /usr/lib/libdebuginfod.so.1)
  : "${LD_LIBRARY_PATH=}"
  if [ "$LD_LIBRARY_PATH" ]; then
    echo set env LD_LIBRARY_PATH=$LD_LIBRARY_PATH >> "$ARGSFILE"
    echo show env LD_LIBRARY_PATH >> "$ARGSFILE"
    unset LD_LIBRARY_PATH
  fi

  # Enable index file caching for reasonable launch time under gdb
  echo set index-cache enabled on >> "$ARGSFILE"
  echo show index-cache stats >> "$ARGSFILE"

  : "${DEBUGGER_ARGS=}"
  log "gdb/cgdb launch with ARGSFILE: $ARGSFILE"
  log $DEBUGGER -x "$ARGSFILE" $DEBUGGER_ARGS --args "$STEAMEXE" "$@"

  $DEBUGGER -x "$ARGSFILE" $DEBUGGER_ARGS --args "$STEAMEXE" "$@"
  rm "$ARGSFILE"
else
  $DEBUGGER "$STEAMEXE" "$@"
fi

STATUS=$?

if [ $STATUS -eq $MAGIC_RESTART_EXITCODE ]; then
  log "Restarting steamcmd by request..."
  exec "$0" "$@"
fi
exit $STATUS
