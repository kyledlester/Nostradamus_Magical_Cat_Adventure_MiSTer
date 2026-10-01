#!/bin/sh
# Nostradamus core -- simulation runner (ModelSim-Intel FPGA Starter 10.5b from the Quartus 17.0 install).
# Usage: scripts/sim.sh <test> [vsim plusargs...]     scripts/sim.sh all   (regression list)
# Each bench prints "PASS <NAME>: ..." or "FAIL <NAME>: ..."; the runner greps for the verdict.
# Logs: build/sim/<test>.log (or <test>_$TAG.log). Benches that need ROM data read local/ images made
# by scripts/romtool.py and MAME captures from scripts/mame/*.lua (never committed).
# Environment: VLOGDEFS (extra vlog defines), VSIMARGS, TAG (log/library suffix for parallel runs).
set -u
# run from a private copy: sh reads scripts lazily, so editing this file during a long run would
# corrupt the running instance
if [ -z "${SIM_SH_COPY:-}" ]; then
  mkdir -p "$(dirname "$0")/../build/sim"
  c="$(dirname "$0")/../build/sim/.sim_$$.sh"; cp "$0" "$c"
  SIM_SH_COPY=1 SIM_SH_ROOT="$(cd "$(dirname "$0")/.." && pwd)" sh "$c" "$@"; r=$?; rm -f "$c"; exit $r
fi
MS=${MODELSIM:-/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem}
ROOT=${SIM_SH_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
cd "$ROOT" || exit 1
mkdir -p build/sim

FX68K="rtl/vendor/fx68k/fx68k.sv rtl/vendor/fx68k/fx68kAlu.sv rtl/vendor/fx68k/uaddrPla.sv"
T80="rtl/vendor/t80/T80_Pack.vhd rtl/vendor/t80/T80_ALU.vhd rtl/vendor/t80/T80_Reg.vhd rtl/vendor/t80/T80_MCode.vhd rtl/vendor/t80/T80.vhd rtl/vendor/t80/T80s.vhd"
JT10=$(ls rtl/vendor/jt10/*.v | tr '\n' ' ')
N=rtl/nost
MAIN="$N/nost_ram.sv $N/nost_cpu_bus.sv $N/nost_cpu68k.sv $N/nost_rom_cache.sv $N/nost_main.sv"
CLK="$N/nost_clocks.sv $N/nost_video_timing.sv"
VIDEO="$N/nost_tilemap.sv $N/nost_sprites.sv $N/nost_video.sv"
SOUND="$N/nost_sound.sv"

# test -> "top|vhdl files|fx68k?|vlog defines|sv files"
spec() {
  case "$1" in
    boot)  echo "tb_boot||cpu|+define+NOST_SIM_ROM|$CLK $MAIN sim/tb/tb_boot.sv" ;;
    bootc) echo "tb_boot||cpu||$CLK $MAIN sim/tb/tb_boot.sv" ;;
    sound) echo "tb_sound|$T80|||rtl/nost/nost_ram.sv $SOUND $JT10 sim/tb/tb_sound.sv" ;;
    loader) python scripts/mk_sdram_sim.py build/sim/sdram_sim.sv
         echo "tb_loader||||rtl/nost/nost_loader.sv rtl/nost/nost_sdram_arb.sv build/sim/sdram_sim.sv sim/models/sdr_sdram_model.sv sim/tb/tb_loader.sv" ;;
    system) python scripts/mk_sdram_sim.py build/sim/sdram_sim.sv; mkdir -p build/sim/frames
         echo "tb_system|$T80|cpu||$CLK $MAIN $VIDEO $SOUND rtl/nost/nost_loader.sv rtl/nost/nost_sdram_arb.sv rtl/nost/nost_overlay.sv rtl/nost/nost_core.sv $JT10 build/sim/sdram_sim.sv sim/models/sdr_sdram_model.sv sim/tb/tb_system.sv" ;;
    systemf) python scripts/mk_sdram_sim.py build/sim/sdram_sim.sv; mkdir -p build/sim/frames
         echo "tb_system|$T80|cpu|+define+NOST_SIM_SND16|$CLK $MAIN $VIDEO $SOUND rtl/nost/nost_loader.sv rtl/nost/nost_sdram_arb.sv rtl/nost/nost_overlay.sv rtl/nost/nost_core.sv $JT10 build/sim/sdram_sim.sv sim/models/sdr_sdram_model.sv sim/tb/tb_system.sv" ;;
    systemns) python scripts/mk_sdram_sim.py build/sim/sdram_sim.sv; mkdir -p build/sim/frames
         echo "tb_system||cpu|+define+NOST_SIM_NO_SOUND|$CLK $MAIN $VIDEO rtl/nost/nost_loader.sv rtl/nost/nost_sdram_arb.sv rtl/nost/nost_overlay.sv rtl/nost/nost_core.sv build/sim/sdram_sim.sv sim/models/sdr_sdram_model.sv sim/tb/tb_system.sv" ;;
    inputs) echo "tb_inputs||cpu|+define+NOST_SIM_NO_SOUND|$CLK $MAIN $VIDEO rtl/nost/nost_loader.sv rtl/nost/nost_sdram_arb.sv rtl/nost/nost_overlay.sv rtl/nost/nost_core.sv sim/tb/tb_inputs.sv" ;;
    render) python scripts/mk_sdram_sim.py build/sim/sdram_sim.sv
         echo "tb_render||||$CLK rtl/nost/nost_ram.sv $VIDEO rtl/nost/nost_sdram_arb.sv build/sim/sdram_sim.sv sim/models/sdr_sdram_model.sv sim/tb/tb_render.sv" ;;
    *) echo "" ;;
  esac
}

run() {
  t=$1; shift
  s=$(spec "$t")
  [ -z "$s" ] && { echo "unknown test $t"; return 2; }
  top=${s%%|*}; rest=${s#*|}; vhd=${rest%%|*}; rest=${rest#*|}; cpu=${rest%%|*}; rest=${rest#*|}
  defs=${rest%%|*}; sv=${rest#*|}
  name=$t${TAG:+_$TAG}
  lib=build/sim/lib_$name
  rm -rf "$lib"; "$MS/vlib.exe" "$lib" >/dev/null
  log=build/sim/$name.log
  : > "$log"
  if [ -n "$vhd" ]; then "$MS/vcom.exe" -2008 -quiet -work "$lib" $vhd >> "$log" 2>&1 || { echo "FAIL $t: vcom (see $log)"; tail -20 "$log"; return 1; }; fi
  # FX68K mixes initial and always_ff writes to register arrays (ModelSim check 7061); suppress
  # only for the imported CPU (see rtl/vendor/fx68k/ORIGIN.md).
  if [ -n "$cpu" ]; then "$MS/vlog.exe" -sv -quiet -suppress 7061 -work "$lib" $FX68K >> "$log" 2>&1 || { echo "FAIL $t: vlog fx68k (see $log)"; return 1; }; fi
  "$MS/vlog.exe" -sv -quiet -work "$lib" $defs ${VLOGDEFS:-} +incdir+sim/tb +incdir+rtl/vendor/jt10 $sv >> "$log" 2>&1 || { echo "FAIL $t: vlog (see $log)"; grep -E "Error|error" "$log" | head -20; return 1; }
  [ -n "${SIM_COMPILE_ONLY:-}" ] && { echo "COMPILED $t ($lib)"; return 0; }
  "$MS/vsim.exe" -c -suppress 8315,8360 ${VSIMARGS:-} -L altera_mf_ver -L altera_ver -lib "$lib" "$top" "$@" -do "${PRERUN:-} run -all; quit -f" >> "$log" 2>&1
  r=$(grep -E "^# (PASS|FAIL) " "$log" | tail -1 | sed 's/^# //')
  if [ -z "$r" ]; then echo "FAIL $t: no verdict (see $log)"; grep -E "Error|Fatal" "$log" | head -10; return 1; fi
  echo "$r"
  case "$r" in PASS*) return 0 ;; *) return 1 ;; esac
}

run "$@"
