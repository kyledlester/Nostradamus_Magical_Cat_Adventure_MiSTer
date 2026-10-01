# ModelSim: emulate FPGA power-up zeros for jt10's shift-register pipelines (jt10_sh 'bits' arrays),
# which never leave X in a 4-state simulator (on the FPGA they start at 0 and the reset flush then
# loads their reset values). Only memories are touched. Usage: PRERUN="do sim/tb/zero_regs.do <path>;"
set root $1
echo "zero_regs: start [clock format [clock seconds] -format %T]"
set m 0
foreach line [split [mem list -r $root] "\n"] {
    if {[regexp {(/\S+)} $line -> path]} {
        if {![catch {mem load -filldata 0 $path}]} { incr m }
    }
}
echo "zero_regs: zero-filled $m memories under $root"
# jt12_reg's operator/channel counter runs during reset and is initialised only under
# `ifdef SIMULATION (which also enables jt10_acc's per-channel dump files): deposit the same
# values here instead.
foreach r [find instances -r $root/*u_reg] {
    set p [lindex $r 0]
    catch { force -deposit $p/cur_op 2'd0 }
    catch { force -deposit $p/cur_ch 3'd0 }
    catch { force -deposit $p/zero 1'b1 }
    catch { force -deposit $p/last 1'b0 }
}
# Any other register still X at time 0 (accumulators that are never reset, e.g. jt10's FM/ADPCM
# sums): deposit FPGA power-up zeros, bit width preserved.
set z 0
foreach s [find signals -r $root/*] {
    if {[catch {set v [examine -radix binary $s]}]} { continue }
    if {[string first "x" [string tolower $v]] < 0} { continue }
    if {[string first "\{" $v] >= 0} { continue }
    set zeros [string repeat 0 [string length $v]]
    if {![catch {force -deposit $s "2#$zeros"}]} { incr z }
}
echo "zero_regs: deposited 0 into $z X signals under $root at [clock format [clock seconds] -format %T]"
