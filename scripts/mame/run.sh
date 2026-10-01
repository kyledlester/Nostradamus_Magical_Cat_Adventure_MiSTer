#!/bin/sh
# Run MAME 0.289 with a capture script and a FRESH configuration directory, so DIP switch or input
# settings from earlier runs (MAME saves them to cfg/nost.cfg on exit) can never leak into a capture.
# Usage: scripts/mame/run.sh <script.lua> [extra mame args...]   (NOST_* variables as the script needs)
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
MAMEDIR=${MAMEDIR:-/c/Users/klest/Downloads/mame}
CFG=$(mktemp -d)
script=$1; shift
case "$script" in /*|?:*) ;; *) script="$ROOT/$script" ;; esac
cd "$MAMEDIR" && ./mame.exe nost -rompath roms -cfg_directory "$CFG" -nvram_directory "$CFG" \
  -autoboot_script "$script" -nothrottle -video none -sound none -skip_gameinfo "$@" 2>&1 | grep -v "doesn't make much sense"
r=$?; rm -rf "$CFG"; exit $r
