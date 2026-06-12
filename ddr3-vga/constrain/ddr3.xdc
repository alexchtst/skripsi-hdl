## Clock signal
set_property -dict { PACKAGE_PIN E3 IOSTANDARD LVCMOS33 } [get_ports { CLK100MHZ }]
create_clock -period 10.000 -name sys_clk_pin -waveform {0.000 5.000} [get_ports { CLK100MHZ }]

set_clock_groups -asynchronous \
    -group [get_clocks sys_clk_pin] \
    -group [get_clocks clk_pll_i]

## Reset button
set_property -dict { PACKAGE_PIN C2 IOSTANDARD LVCMOS33 } [get_ports { reset }]

## LEDs
set_property -dict { PACKAGE_PIN H5  IOSTANDARD LVCMOS33 } [get_ports { led4 }]
set_property -dict { PACKAGE_PIN J5  IOSTANDARD LVCMOS33 } [get_ports { led5 }]
set_property -dict { PACKAGE_PIN T9  IOSTANDARD LVCMOS33 } [get_ports { led6 }]
set_property -dict { PACKAGE_PIN T10 IOSTANDARD LVCMOS33 } [get_ports { led7 }]


## ============================================================
## Pmod VGA Digilent
##
## Assumption:
## Pmod VGA J1 -> Arty A7 JC
## Pmod VGA J2 -> Arty A7 JD
##
## Pmod VGA J1:
## Pin 1  R0
## Pin 2  R1
## Pin 3  R2
## Pin 4  R3
## Pin 7  B0
## Pin 8  B1
## Pin 9  B2
## Pin 10 B3
##
## Pmod VGA J2:
## Pin 1  G0
## Pin 2  G1
## Pin 3  G2
## Pin 4  G3
## Pin 7  HS
## Pin 8  VS
## ============================================================


## ------------------------------------------------------------
## Pmod VGA J1 on JC
## ------------------------------------------------------------
## JC1 = R0
## JC2 = R1
## JC3 = R2
## JC4 = R3
## JC7 = B0
## JC8 = B1
## JC9 = B2
## JC10 = B3

set_property -dict { PACKAGE_PIN U12 IOSTANDARD LVCMOS33 } [get_ports { vga_r[0] }]
set_property -dict { PACKAGE_PIN V12 IOSTANDARD LVCMOS33 } [get_ports { vga_r[1] }]
set_property -dict { PACKAGE_PIN V10 IOSTANDARD LVCMOS33 } [get_ports { vga_r[2] }]
set_property -dict { PACKAGE_PIN V11 IOSTANDARD LVCMOS33 } [get_ports { vga_r[3] }]
set_property -dict { PACKAGE_PIN U14 IOSTANDARD LVCMOS33 } [get_ports { vga_b[0] }]
set_property -dict { PACKAGE_PIN V14 IOSTANDARD LVCMOS33 } [get_ports { vga_b[1] }]
set_property -dict { PACKAGE_PIN T13 IOSTANDARD LVCMOS33 } [get_ports { vga_b[2] }]
set_property -dict { PACKAGE_PIN U13 IOSTANDARD LVCMOS33 } [get_ports { vga_b[3] }]


## ------------------------------------------------------------
## Pmod VGA J2 on JD
## ------------------------------------------------------------

## JD1 = G0
## JD2 = G1
## JD3 = G2
## JD4 = G3
## JD7 = HSYNC
## JD8 = VSYNC

set_property -dict { PACKAGE_PIN D4 IOSTANDARD LVCMOS33 } [get_ports { vga_g[0] }]
set_property -dict { PACKAGE_PIN D3 IOSTANDARD LVCMOS33 } [get_ports { vga_g[1] }]
set_property -dict { PACKAGE_PIN F4 IOSTANDARD LVCMOS33 } [get_ports { vga_g[2] }]
set_property -dict { PACKAGE_PIN F3 IOSTANDARD LVCMOS33 } [get_ports { vga_g[3] }]
set_property -dict { PACKAGE_PIN E2 IOSTANDARD LVCMOS33 } [get_ports { vga_hs }]
set_property -dict { PACKAGE_PIN D2 IOSTANDARD LVCMOS33 } [get_ports { vga_vs }]

