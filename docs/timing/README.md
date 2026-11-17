# docs/timing/

Resultados de síntesis e implementación del diseño `riscv_basys3` en la Basys 3
(`xc7a35tcpg236-1`): timing, utilización y warnings. Cada vez que se mide se agrega una sección
con el tag o el commit. El análisis del camino crítico y el Clock Wizard son de M11 (I-56 e
I-57). Las secciones de abajo son el punto de partida.

## Cómo se mide

Con el proyecto regenerado por `scripts/create_project.tcl`, en la Tcl Console de Vivado:

```tcl
reset_run synth_1
launch_runs impl_1 -jobs 4
wait_on_run impl_1
open_run impl_1
report_timing_summary -max_paths 10 -file build/timing_summary.rpt
report_utilization -file build/utilization.rpt
report_methodology -file build/methodology.rpt
report_drc -file build/drc.rpt
```

Los `.rpt` quedan en `build/`, que no se versiona. Acá se copian solo las cifras y los caminos
que importan. Los warnings críticos se buscan en *Messages* (síntesis e implementación). En
`riscv_basys3` no tiene que haber latches inferidos ni nets con más de un driver (checklist del
PR).

## `debug-v1` (I-49)

### 100 MHz sin Clock Wizard, post-síntesis (2026-11-17, rama `feature/61_top-placa`)

Estimación de Vivado 2026.1 con el diseño sintetizado: las nets están sin ubicar ("unplaced"),
así que el ruteo es una estimación. Falta la implementación.

| | Valor |
|---|---|
| Reloj | `sys_clk_pin`, 10,000 ns (100 MHz) |
| WNS / TNS (setup) | **−5,227 ns** / −540,650 ns, 159 de 5345 endpoints fallan. Camino de unos 15,2 ns: ~65 MHz |
| WHS / THS (hold) | +0,043 ns / 0 |
| LUT / FF / BRAM | 2548 LUT (12 %), 1883 FF (5 %), 0 latches; las BRAM son IP fuera de contexto y no aparecen en el reporte de `synth_1` |
| Warnings | Ninguno crítico. Puertos sin carga (bits que no se usan de `pc`, `funct3` e `instr`) y `led[5:7]` y `led[11:13]` en 0 constante |

**Camino crítico** (14,614 ns de datos, 12 niveles de LUT, 73 % ruteo estimado):

```
dmem_bram DOADO (2,45 ns, sin registro de salida)
  → extensión del load (LUT3) → mux de WB, wb_data (LUT6, fo=35)
  → mux de forwarding (LUT6) → mux de alu_b (LUT3, fo=114)
  → 4 LUT de la ALU (el desplazador: alu_b[4:0] es el shamt) → result[18]
  → 3 LUT de zero → taken → redirect (LUT6, fo=36)
  → R de id_ex_ctrl/id_ex_valid (flush), ENA de imem_bram, CE de if_id_pc
```

Los 30 peores caminos son esta misma familia, con destinos en el flush de ID/EX (−5,227), el
`ena` de `imem` (−5,210) y el enable de IF/ID (−4,714). Ninguno pasa por la Debug Unit.

Es la hipótesis de la decisión [012](../decisiones/012_resolucion-saltos.md), pero el peor
tramo no es la resta: es el **desplazador**. `branch_unit` decide con `zero`, y `zero` es
`alu_out == 0` sobre el resultado ya multiplexado de las 10 operaciones. Síntesis no puede
saber que un salto solo usa la resta, así que el camino de `redirect` pasa por el operando B
como shamt y por el barrel shifter.

Además, las BRAM de IP se sintetizan fuera de contexto con un reloj de 20 ns
(`[Timing 38-316]`, warning no crítico). No cambia nada en una BRAM sin lógica alrededor.

**Qué se hizo:** reloj del sistema con el Clock Wizard (decisión
[042](../decisiones/042_reloj-del-sistema-a-65-mhz.md)). Se probó 50, 70 y 65 MHz, y quedó **65 MHz**.
El comparador de igualdad (medida 1 de la 012) queda para la I-56, que decide si se puede subir.

### 70 MHz, post-implementación (bitstream de las 19:19, descartado)

| | Valor |
|---|---|
| Reloj | `clk_out1`, 14,286 ns (70 MHz) |
| WNS / WHS | +0,083 ns / +0,103 ns, 0 endpoints fallan |
| Warnings críticos | 1: `[Constraints 18-1055]`. El `create_clock` de `basys3.xdc` reemplazaba el reloj de entrada que define el IP y descartaba su input jitter, así que el WNS era optimista. Se sacó el `create_clock` del `.xdc` |
| Placa | 22 de 22 con `placa.py` (RUN y STEP) |

### 65 MHz, post-implementación: `debug-v1` (bitstream de las 19:37)

| | Valor |
|---|---|
| Reloj | `clk_out1_clk_wiz_sys`, 15,385 ns (65 MHz), derivado de `clk` (10 ns, definido por el `.xdc` del IP). MMCM: D = 5, M = 50,375 (VCO 1007,5 MHz), divisor 15,5; jitter de salida 254,9 ps |
| WNS / TNS (setup) | **+0,519 ns** / 0, 0 de 5359 endpoints fallan |
| WHS / THS (hold) | +0,070 ns / 0 |
| Camino crítico | El mismo: `dmem_bram` → WB → forwarding → ALU → `zero` → `redirect` → `ena` de `imem` (14,273 ns de datos, 37 % lógica y 63 % ruteo) |
| LUT / FF / BRAM / MMCM | 2500 LUT (12 %), 1882 FF (5 %), 2 RAMB36 (4 %), 1 MMCME2_ADV |
| Warnings críticos | **0** en síntesis y en implementación |

## Prueba en placa (65 MHz, bitstream de las 19:37)

| | Resultado |
|---|---|
| `python tools/debugger/placa.py COM7` (22 programas, RUN y STEP) | **22 de 22 OK**: `INFO` informa 65000 kHz; RUN contra el `.exp` y el modelo, y STEP con los latches de cada ciclo contra el modelo, en todos |
| `python tools/debugger/placa.py COM7 --nops --sin-paso` | **32 de 32 OK** (los 22 y las 10 variantes `_nops`) |
| Reprogramar sin resintetizar ni resetear la placa | OK: `placa.py` carga los programas uno detrás del otro con `LOAD` |
| btnC en `RUNNING`: vuelve a `NO_PROG` y responde | **OK**. Con un bucle infinito en `RUNNING`, btnC apretado y soltado: `INFO` responde, el estado es `NO_PROG` con `prog_valid = 0`, PC, `cycles` y avisos en 0, `RUN` responde `ERR_STATE`, y después de un `LOAD` vuelve a correr |
