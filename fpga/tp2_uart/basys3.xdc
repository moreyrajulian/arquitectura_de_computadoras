## Constraints para Basys3 (Artix-7 XC7A35T-1CPG236C)
## Verificar contra el master XDC oficial de Digilent si usas otra placa.
##
## El top ahora solo expone clk, reset, rx, tx: toda la entrada de datos
## (opcode + operandos) y la salida del resultado viajan serializadas por
## UART, ya no por switches/LEDs. Por eso se quitan los constraints de
## i_sw/o_led/i_btn_a/i_btn_b/i_btn_op del XDC anterior.

## ---------------- Clock 100 MHz ----------------
set_property -dict { PACKAGE_PIN W5  IOSTANDARD LVCMOS33 } [get_ports clk]
create_clock -add -name sys_clk_pin -period 10.00 -waveform {0 5} [get_ports clk]

## ---------------- Reset ----------------
set_property -dict { PACKAGE_PIN U18 IOSTANDARD LVCMOS33 } [get_ports reset]   ;# btnC

## ---------------- UART (bridge USB-UART integrado en la Basys3) ----------------
## rx de la FPGA = RsRx = pin de la placa conectado a la salida TX del FTDI
## tx de la FPGA = RsTx = pin de la placa conectado a la entrada RX del FTDI
set_property -dict { PACKAGE_PIN B18 IOSTANDARD LVCMOS33 } [get_ports rx]      ;# RsRx
set_property -dict { PACKAGE_PIN A18 IOSTANDARD LVCMOS33 } [get_ports tx]      ;# RsTx

## ---------------- Caminos asincronicos ----------------
## reset no tiene relacion con el clock: sin esto Vivado reporta violaciones
## de I/O que no significan nada, ya que btnC entra directo como reset async.
set_false_path -from [get_ports reset]
