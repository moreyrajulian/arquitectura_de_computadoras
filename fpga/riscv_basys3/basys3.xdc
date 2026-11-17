## Constraints del trabajo final (I-49) para la Basys 3 (Artix-7 xc7a35tcpg236-1).
## Pines verificados contra el master XDC de Digilent y los de tp1_alu y tp2_uart.
## Los nombres de los puertos son los de fpga/riscv_basys3/top.v (decisión 010).

## ---------------- Configuración ----------------
## Bancos de configuración a 3,3 V: sin esto Vivado avisa en el DRC del bitstream
set_property CFGBVS VCCO        [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

## ---------------- Clock 100 MHz de la placa ----------------
## Entra al Clock Wizard (ip/clk_wiz.tcl, decisión 042), que da el reloj del
## sistema. Acá NO va create_clock: el .xdc del IP ya crea el reloj de entrada
## (clk, 10 ns, por PRIM_IN_FREQ) con su input jitter, y Vivado deriva el de salida
## del MMCM. Un create_clock propio sobre el mismo puerto lo reemplaza y descarta el
## jitter del IP (CRITICAL WARNING [Constraints 18-1055]).
set_property -dict { PACKAGE_PIN W5  IOSTANDARD LVCMOS33 } [get_ports clk]

## ---------------- Reset (btnC) ----------------
set_property -dict { PACKAGE_PIN U18 IOSTANDARD LVCMOS33 } [get_ports reset]

## ---------------- UART (bridge USB-UART de la Basys 3) ----------------
## rx de la FPGA = RsRx: la salida TX del FT2232
## tx de la FPGA = RsTx: la entrada RX del FT2232
set_property -dict { PACKAGE_PIN B18 IOSTANDARD LVCMOS33 } [get_ports rx]
set_property -dict { PACKAGE_PIN A18 IOSTANDARD LVCMOS33 } [get_ports tx]

## ---------------- LEDs de estado (ver el encabezado de top.v) ----------------
set_property -dict { PACKAGE_PIN U16 IOSTANDARD LVCMOS33 } [get_ports {led[0]}]
set_property -dict { PACKAGE_PIN E19 IOSTANDARD LVCMOS33 } [get_ports {led[1]}]
set_property -dict { PACKAGE_PIN U19 IOSTANDARD LVCMOS33 } [get_ports {led[2]}]
set_property -dict { PACKAGE_PIN V19 IOSTANDARD LVCMOS33 } [get_ports {led[3]}]
set_property -dict { PACKAGE_PIN W18 IOSTANDARD LVCMOS33 } [get_ports {led[4]}]
set_property -dict { PACKAGE_PIN U15 IOSTANDARD LVCMOS33 } [get_ports {led[5]}]
set_property -dict { PACKAGE_PIN U14 IOSTANDARD LVCMOS33 } [get_ports {led[6]}]
set_property -dict { PACKAGE_PIN V14 IOSTANDARD LVCMOS33 } [get_ports {led[7]}]
set_property -dict { PACKAGE_PIN V13 IOSTANDARD LVCMOS33 } [get_ports {led[8]}]
set_property -dict { PACKAGE_PIN V3  IOSTANDARD LVCMOS33 } [get_ports {led[9]}]
set_property -dict { PACKAGE_PIN W3  IOSTANDARD LVCMOS33 } [get_ports {led[10]}]
set_property -dict { PACKAGE_PIN U3  IOSTANDARD LVCMOS33 } [get_ports {led[11]}]
set_property -dict { PACKAGE_PIN P3  IOSTANDARD LVCMOS33 } [get_ports {led[12]}]
set_property -dict { PACKAGE_PIN N3  IOSTANDARD LVCMOS33 } [get_ports {led[13]}]
set_property -dict { PACKAGE_PIN P1  IOSTANDARD LVCMOS33 } [get_ports {led[14]}]
set_property -dict { PACKAGE_PIN L1  IOSTANDARD LVCMOS33 } [get_ports {led[15]}]

## ---------------- Caminos asíncronos ----------------
## reset, locked del MMCM y rx no tienen relación de fase con el clock: los toma un
## sincronizador de dos flip-flops (reset_sync y uart, decisiones 041, 042 y 035).
## tx y los LEDs los mira un humano o el FT2232 a 115200 baud: no hay un requisito
## de tiempo contra el clock. Sin esto, el análisis de timing los reporta como I/O
## sin restricción.
set_false_path -from [get_ports {reset rx}]
set_false_path -to   [get_ports {tx led[*]}]
set_false_path -to   [get_cells -hierarchical -filter {NAME =~ *u_reset_sync/req_meta_reg*}]
