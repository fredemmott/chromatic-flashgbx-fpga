// Primary input clocks - define these first
create_clock -name exclk -period 29.802322 [get_ports {CLK_FPGA}]
create_clock -name sclk -period 25 [get_ports {QSPI_CLK}]
create_clock -name ck24 -period 41.666667 -waveform {0 20.833333} [get_ports {CLK_24MHz}]

// Let Gowin automatically infer PLL generated clocks
// The PLL outputs will be automatically recognized

// Define asynchronous clock groups for different clock domains
set_clock_groups -asynchronous -group [get_clocks {exclk}] -group [get_clocks {sclk}]
set_clock_groups -asynchronous -group [get_clocks {exclk}] -group [get_clocks {ck24}]
set_clock_groups -asynchronous -group [get_clocks {sclk}] -group [get_clocks {ck24}]

// Cartridge interface timing constraints
// These are relaxed constraints for the external cartridge bus
set_max_delay -from [get_ports {CART_D[*]}] 13
set_max_delay -to [get_ports {CART_A[*]}] 14
set_max_delay -to [get_ports {CART_WR}] 14
set_max_delay -to [get_ports {CART_RD}] 14
set_max_delay -to [get_ports {CART_CS}] 14
set_max_delay -to [get_ports {LINK_SD}] 14
set_max_delay -to [get_ports {CART_D[*]}] 14

// Set false paths for asynchronous inputs
set_false_path -from [get_ports {BTN_*}]
set_false_path -from [get_ports {CART_DET}]
set_false_path -from [get_ports {POWER_ON_FPGA}]
set_false_path -from [get_ports {VBUS_DET}]
set_false_path -from [get_ports {USBC_FLIP}]

///// CartIO (FlashGBX support) /////

// Correct (loosen) the timing requirements for resetting the DRAM.
//
// Not logically needed for CartIO, but the added complexity makes the routing harder

report_timing -setup -max_paths 25
report_timing -hold -max_paths 25
report_timing -recovery -max_paths 25
report_timing -removal -max_paths 25

report_timing -setup -max_paths 25 -max_common_paths 1 -mod_ins {u_cartio}
report_timing -hold -max_paths 25 -max_common_paths 1 -mod_ins {u_cartio}
report_timing -recovery -max_paths 25 -max_common_paths 1 -mod_ins {u_cartio}
report_timing -removal -max_paths 25 -max_common_paths 1 -mod_ins {u_cartio}
