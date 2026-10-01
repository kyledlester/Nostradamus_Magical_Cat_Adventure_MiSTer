# ModelSim: emulate FPGA power-up zeros for jt10's shift-register pipelines (jt10_sh 'bits' arrays),
# which never leave X in a 4-state simulator (on the FPGA they start at 0 and the reset flush then
# loads their reset values). Only memories are touched. Usage: PRERUN="do sim/tb/zero_regs.do <path>;"
set root $1
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
