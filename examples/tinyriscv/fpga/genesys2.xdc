# SPDX-License-Identifier: Apache-2.0
# Copyright 2025-2026 the FIawase authors
# Genesys2 (xc7k325tffg900-2) pins and clocks for fpga_top.v.
# Pins from the Digilent Genesys2 master XDC (Rev. H).

set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CFGBVS VCCO [current_design]

# 200 MHz LVDS oscillator
set_property -dict {PACKAGE_PIN AD12 IOSTANDARD LVDS} [get_ports sys_clk_p]
set_property -dict {PACKAGE_PIN AD11 IOSTANDARD LVDS} [get_ports sys_clk_n]
create_clock -period 5.000 -name sys_clk [get_ports sys_clk_p]

# CPU RESET button (active low)
set_property -dict {PACKAGE_PIN R19 IOSTANDARD LVCMOS33} [get_ports cpu_resetn]

# Host JTAG: J17's FT2232H, the port wired to PROG_D0..3 (MPSSE TCK, TDI, TDO, TMS).
# PROG_D4 (Y29) is the next MPSSE pin, which OpenOCD's layout drives low: no TRST on it.
set_property -dict {PACKAGE_PIN AD27 IOSTANDARD LVCMOS33} [get_ports jtag_tck]
set_property -dict {PACKAGE_PIN W27  IOSTANDARD LVCMOS33} [get_ports jtag_tdi]
set_property -dict {PACKAGE_PIN W28  IOSTANDARD LVCMOS33} [get_ports jtag_tdo]
set_property -dict {PACKAGE_PIN W29  IOSTANDARD LVCMOS33} [get_ports jtag_tms]
create_clock -period 100.000 -name tck [get_ports jtag_tck]

# UART to J15's FT232R: FPGA TX = uart_rx_out (Y23), FPGA RX = uart_tx_in (Y20)
set_property -dict {PACKAGE_PIN Y23 IOSTANDARD LVCMOS33} [get_ports uart_tx]
set_property -dict {PACKAGE_PIN Y20 IOSTANDARD LVCMOS33} [get_ports uart_rx]

# LEDs 0..7
set_property -dict {PACKAGE_PIN T28 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN V19 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN U30 IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN U29 IOSTANDARD LVCMOS33} [get_ports {led[3]}]
set_property -dict {PACKAGE_PIN V20 IOSTANDARD LVCMOS33} [get_ports {led[4]}]
set_property -dict {PACKAGE_PIN V26 IOSTANDARD LVCMOS33} [get_ports {led[5]}]
set_property -dict {PACKAGE_PIN W24 IOSTANDARD LVCMOS33} [get_ports {led[6]}]
set_property -dict {PACKAGE_PIN W23 IOSTANDARD LVCMOS33} [get_ports {led[7]}]

# The host JTAG clock is asynchronous to the functional clock; the wrapper crosses between them
# with its own CDC (fi_cdc_2phase_v6).
set_clock_groups -asynchronous -group [get_clocks -include_generated_clocks sys_clk] -group [get_clocks tck]

# Slow, asynchronous I/O: the JTAG data pins change half a TCK period (500 ns at 1 MHz) away from
# the edge that samples them; reset, UART and LEDs are asynchronous.
set_false_path -from [get_ports {jtag_tms jtag_tdi cpu_resetn uart_rx}]
set_false_path -to   [get_ports {jtag_tdo uart_tx led[*]}]
