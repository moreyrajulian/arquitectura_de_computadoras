# fpga/

Un subdirectorio por **diseño sintetizable** para la Basys 3. Cada uno contiene su
módulo superior (`top.v`), los módulos que solo ese diseño necesita y su archivo de
constraints (`basys3.xdc`). Los bloques reutilizables no están acá: viven en `../rtl/`.

| Diseño | Estado | Qué es |
|---|---|---|
| `riscv_basys3/` | **vigente** | Trabajo final: procesador RISC-V segmentado + Debug Unit + UART + Clock Wizard (65 MHz), con reset por botón y LEDs de estado (I-49) |
| `tp2_uart/` | histórico | TP2: ALU operada a través de UART (`top.v` + `alu_top.v`) |
| `tp1_alu/` | histórico | TP1: ALU con entradas por switches/botones y antirrebote |

Los diseños históricos se conservan como referencia y para poder reproducir lo entregado.
No se modifican salvo para corregir errores.

Cada diseño histórico tiene su propia copia de la ALU que entregó (`tp1_alu/alu_tp1.v` y
`tp2_uart/alu_tp2.v`). `rtl/common/alu.v` es la ALU RV32I del procesador (I-28), con otra
interfaz, y el script de proyecto agrega `rtl/` a todos los diseños. Por eso las copias llevan
otro nombre de módulo.

## Abrir un diseño en Vivado

En Vivado, *Tools > Run Tcl Script...* con `scripts/create_project.tcl` (crea `riscv_basys3`).
Para otro diseño, en la Tcl Console:

```tcl
set DESIGN tp2_uart
source <ruta-al-repo>/scripts/create_project.tcl
```

El proyecto se genera en `build/vivado_<diseño>/` (ignorado por git). El nombre de
`DESIGN` es el de la carpeta de este directorio.

## `riscv_basys3` en la placa

| Pin | Uso |
|---|---|
| `clk` (W5) | Reloj de 100 MHz de la placa. Solo entra al Clock Wizard (`ip/clk_wiz.tcl`), que da el reloj del sistema de 65 MHz (decisión [042](../docs/decisiones/042_reloj-del-sistema-a-65-mhz.md)). `CLK_FREQ_HZ` del top (y `F_SYS` de `tb/unit/top_tb.v`) tiene que coincidir con la salida del IP: de ahí salen el divisor de la UART, `clk_khz` de `INFO` y el timeout de la Debug Unit |
| `reset` (btnC) | Reset del sistema, sincronizado y alargado por `rtl/common/reset_sync.v` (decisión [041](../docs/decisiones/041_reset-del-sistema-en-la-placa.md)). También queda activo hasta que el MMCM engancha. Deja la Debug Unit en `NO_PROG`: después hay que volver a mandar `LOAD` |
| `rx`, `tx` (B18, A18) | UART por el USB de programación, 115200 8N1 ([`protocolo_debug.md`](../docs/spec/protocolo_debug.md) §1) |
| `led[4:0]` (LD0 a LD4) | Estado de ejecución, uno encendido: `NO_PROG`, `READY`, `RUNNING`, `PAUSED`, `HALTED` |
| `led[10:8]` (LD8 a LD10) | Avisos: `imem_fault`, `dmem_oob`, `dmem_misaligned` |
| `led[14]` (LD14) | Reset del sistema activo |
| `led[15]` (LD15) | Latido de 2 Hz. Si está quieto, no hay reloj o el reset está apretado |

La prueba en placa la corre `tools/debugger/placa.py` (ver su [README](../tools/debugger/README.md) §4).
Los resultados de síntesis e implementación están en [`docs/timing/`](../docs/timing/README.md).

## Convenciones para agregar un diseño

- El módulo superior se llama `top` (el script de proyecto lo asume).
- Un solo `basys3.xdc` por diseño, con los pines usados y las constraints de clock.
- Si un módulo lo van a usar dos diseños, va en `rtl/`, no acá.
