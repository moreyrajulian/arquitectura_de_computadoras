# ---------------------------------------------------------------------------
# clk_wiz_sys: reloj del sistema (decisiones 042 y 045).
#
# Clocking Wizard con un MMCM: entra el reloj de la Basys 3 (100 MHz, pin W5) y
# sale clk_out1 a 92 MHz, que es el único reloj del procesador, la Debug Unit y
# la UART (un solo dominio, sin clock gating: decisión 018).
#   clk_in1  : reloj de la placa, desde el puerto clk del top
#   clk_out1 : reloj del sistema, 92 MHz, por un BUFG
#   locked   : el MMCM enganchó. Mientras vale 0, el top mantiene el reset del
#              sistema (reset_sync, decisión 041)
# Sin entrada de reset: el MMCM arranca solo al configurar la FPGA.
#
# Si cambia la frecuencia de salida, CLK_FREQ_HZ del top y F_SYS de tb/unit/top_tb.v
# tienen que cambiar igual (divisor de la UART, clk_khz de INFO, timeout de la Debug
# Unit). Después hay que regenerar el IP (decisión 042).
#
# Lo ejecuta scripts/create_project.tcl con el proyecto ya abierto.
# El IP trae su propio .xdc con el reloj de entrada (y su jitter); Vivado deriva el
# de salida. basys3.xdc no tiene que redefinirlo.
# ---------------------------------------------------------------------------
create_ip -name clk_wiz -vendor xilinx.com -library ip -module_name clk_wiz_sys
set_property -dict [list \
    CONFIG.PRIMITIVE {MMCM} \
    CONFIG.PRIM_SOURCE {Single_ended_clock_capable_pin} \
    CONFIG.PRIM_IN_FREQ {100.000} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {92.000} \
    CONFIG.CLK_OUT1_PORT {clk_out1} \
    CONFIG.USE_LOCKED {true} \
    CONFIG.USE_RESET {false} \
] [get_ips clk_wiz_sys]
