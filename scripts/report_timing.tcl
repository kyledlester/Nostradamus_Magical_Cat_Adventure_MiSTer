# quartus_sta -t scripts/report_timing.tcl : top failing clk_sys paths -> build/timing_paths.txt
project_open Nostradamus -revision Nostradamus
create_timing_netlist
read_sdc
update_timing_netlist
set clk [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
report_timing -setup -to_clock $clk -npaths 60 -detail summary -file build/timing_paths.txt
project_close
