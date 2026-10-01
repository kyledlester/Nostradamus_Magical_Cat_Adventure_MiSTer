#!/bin/sh
# Render a list of captured MAME frames through tb_render in parallel (one compiled library).
# Usage: scripts/render_batch.sh <frame dir>...   (P=<jobs>, default 8)
ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$ROOT"
MS=${MODELSIM:-/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem}
SIM_COMPILE_ONLY=1 TAG=batch scripts/sim.sh render >/dev/null || exit 1
for f in "$@"; do echo "$f"; done | xargs -P ${P:-8} -I{} sh -c '
  n=$(echo {} | tr "/" "_"); log=build/sim/rb_$n.log
  "'"$MS"'/vsim.exe" -c -suppress 8315,8360 -L altera_mf_ver -L altera_ver -lib build/sim/lib_render_batch tb_render +FRAME={} -do "run -all; quit -f" > $log 2>&1
  grep -E "^# (PASS|FAIL) " $log | sed "s/^# //" || echo "FAIL {}: no verdict"'
