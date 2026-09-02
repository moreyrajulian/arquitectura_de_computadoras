## Constraints para Basys3 (Artix-7 XC7A35T-1CPG236C)

## ---------------- Clock 100 MHz ----------------
set_property -dict { PACKAGE_PIN W5  IOSTANDARD LVCMOS33 } [get_ports clk]
create_clock -add -name sys_clk_pin -period 10.00 -waveform {0 5} [get_ports clk]

## ---------------- Switches (datos / opcode) ----------------
set_property -dict { PACKAGE_PIN V17 IOSTANDARD LVCMOS33 } [get_ports {i_sw[0]}]
set_property -dict { PACKAGE_PIN V16 IOSTANDARD LVCMOS33 } [get_ports {i_sw[1]}]
set_property -dict { PACKAGE_PIN W16 IOSTANDARD LVCMOS33 } [get_ports {i_sw[2]}]
set_property -dict { PACKAGE_PIN W17 IOSTANDARD LVCMOS33 } [get_ports {i_sw[3]}]
set_property -dict { PACKAGE_PIN W15 IOSTANDARD LVCMOS33 } [get_ports {i_sw[4]}]
set_property -dict { PACKAGE_PIN V15 IOSTANDARD LVCMOS33 } [get_ports {i_sw[5]}]
set_property -dict { PACKAGE_PIN W14 IOSTANDARD LVCMOS33 } [get_ports {i_sw[6]}]
set_property -dict { PACKAGE_PIN W13 IOSTANDARD LVCMOS33 } [get_ports {i_sw[7]}]

## ---------------- LEDs (resultado) ----------------
set_property -dict { PACKAGE_PIN U16 IOSTANDARD LVCMOS33 } [get_ports {o_led[0]}]
set_property -dict { PACKAGE_PIN E19 IOSTANDARD LVCMOS33 } [get_ports {o_led[1]}]
set_property -dict { PACKAGE_PIN U19 IOSTANDARD LVCMOS33 } [get_ports {o_led[2]}]
set_property -dict { PACKAGE_PIN V19 IOSTANDARD LVCMOS33 } [get_ports {o_led[3]}]
set_property -dict { PACKAGE_PIN W18 IOSTANDARD LVCMOS33 } [get_ports {o_led[4]}]
set_property -dict { PACKAGE_PIN U15 IOSTANDARD LVCMOS33 } [get_ports {o_led[5]}]
set_property -dict { PACKAGE_PIN U14 IOSTANDARD LVCMOS33 } [get_ports {o_led[6]}]
set_property -dict { PACKAGE_PIN V14 IOSTANDARD LVCMOS33 } [get_ports {o_led[7]}]
set_property -dict { PACKAGE_PIN V13  IOSTANDARD LVCMOS33 } [get_ports {o_led[8]}]

## ---------------- Pulsadores ----------------
set_property -dict { PACKAGE_PIN U18 IOSTANDARD LVCMOS33 } [get_ports i_reset]   ;# btnC
set_property -dict { PACKAGE_PIN W19 IOSTANDARD LVCMOS33 } [get_ports i_btn_a]   ;# btnL
set_property -dict { PACKAGE_PIN T17 IOSTANDARD LVCMOS33 } [get_ports i_btn_b]   ;# btnR
set_property -dict { PACKAGE_PIN T18 IOSTANDARD LVCMOS33 } [get_ports i_btn_op]  ;# btnU

## ---------------- Caminos asincronicos ----------------
## Switches y pulsadores no tienen relacion con el clock: si no se declaran,
## Vivado reporta violaciones de I/O que no significan nada. Los switches
## entran directo a registros y los pulsadores pasan por el sincronizador.
set_false_path -from [get_ports {i_sw[*]}]
set_false_path -from [get_ports i_reset]
set_false_path -from [get_ports i_btn_a]
set_false_path -from [get_ports i_btn_b]
set_false_path -from [get_ports i_btn_op]
set_false_path -to   [get_ports {o_led[*]}]
