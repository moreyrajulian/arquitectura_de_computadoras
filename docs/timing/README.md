# docs/timing/

Resultados de síntesis e implementación del diseño `riscv_basys3` en la Basys 3
(`xc7a35tcpg236-1`): timing, utilización y warnings. Cada vez que se mide se agrega una sección
con el tag o el commit. Las secciones de la I-49 son el punto de partida; el análisis del camino
crítico y del skew, con y sin el comparador de saltos, está en [I-56](#i-56-camino-crítico-y-skew-a-65-mhz).
El Clock Wizard y la frecuencia final son de la I-57.

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
que importan.

Desde la I-56 hay un script que hace todo lo anterior en batch y saca los reportes de timing que
usa el análisis (`scripts/timing.tcl`, el detalle en su cabecera):

```sh
vivado -mode batch -source scripts/timing.tcl -tclargs <etiqueta>   # o desde la Tcl Console
```

Escribe en `build/timing/<etiqueta>/` el `report_timing_summary` (con el peor camino de setup y de
hold detallados), los 30 peores caminos de setup (como en la I-49), los 10 peores de hold, el peor
camino que termina en cada etapa, los caminos que piden revisar las decisiones 018/037 y 014, la
red de reloj y un `resumen.txt` con una línea por grupo. De cada medición de la I-56 se versionan
`timing_summary.rpt` y `resumen.txt` en `docs/timing/i56_<etiqueta>/`; en el encabezado del `.rpt`
se reemplazaron el nombre del equipo y la ruta absoluta de salida. Los warnings críticos se buscan en *Messages* (síntesis e implementación). En
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

## I-56: camino crítico y skew a 65 MHz

Dos implementaciones del mismo diseño (`riscv_basys3`, Clock Wizard a 65 MHz, decisión
[042](../decisiones/042_reloj-del-sistema-a-65-mhz.md)), medidas igual: `scripts/timing.tcl` en
Vivado 2024.2, post-implementación, 2026-11-18. Lo único que cambia entre las dos es cómo decide
`beq`/`bne`:

| Medición | RTL | Salto | Reportes |
|---|---|---|---|
| **Base** | `master` en `be7c76c` | `zero` de la ALU: resta → `zero` → `taken` | [`i56_base/`](i56_base/) |
| **Comparador** | esta rama | comparador de igualdad `rs1_val == rs2_val`, sin pasar por la ALU (decisión [044](../decisiones/044_comparador-de-igualdad-en-saltos.md)) | [`i56_comparador/`](i56_comparador/) |

El camino de datos de cada una está en [`datapath_sin_comparador.png`](../diagramas/datapath_sin_comparador.png)
y [`datapath.png`](../diagramas/datapath.png).

La base es el mismo RTL que `debug-v1`, pero no da el mismo número (+0,435 contra +0,519 ns): la
colocación y el ruteo cambian de una corrida a otra y el camino crítico es 63 a 71 % ruteo.
Diferencias de alrededor de 0,1 ns entre corridas son ruido; las dos mediciones de esta sección
salen del mismo flujo para que se puedan comparar.

### Antes y después

| | Base | Comparador |
|---|---|---|
| WNS / TNS (setup) | +0,435 ns / 0 | **+1,418 ns** / 0 |
| WHS / THS (hold) | +0,086 ns / 0 | +0,066 ns / 0 |
| Endpoints que fallan | 0 de 5357 | 0 de 5357 |
| Datos del peor camino | 14,212 ns (29 % lógica, 71 % ruteo) | 13,151 ns (36 % lógica, 64 % ruteo) |
| Niveles de lógica | 12 (8 LUT6) | 11 (2 CARRY4) |
| ¿Pasa por la ALU? | sí: mux de `alu_b` → desplazador → mux de resultado → `zero` | no |
| Destino | `R` de `id_ex_ctrl` (flush de ID/EX) | `ENARDEN` de `imem_bram` (enable de IF) |
| Frecuencia estimada, 1 / (15,385 ns − WNS) | ~66,9 MHz | **~71,6 MHz** |

La frecuencia estimada es una cota: al implementar con otro reloj cambian la colocación y el
ruteo. Elegir la frecuencia, con un barrido, es de la I-57.

### Camino crítico, base

Del puerto A de `dmem_bram` (el dato de un load) al reset síncrono de `id_ex_ctrl` (el flush de
ID/EX). Cruza cuatro etapas en un solo ciclo, porque el forwarding WB → EX y la redirección
EX → IF son combinacionales (decisión [012](../decisiones/012_resolucion-saltos.md)): es el costo
de que un salto que depende de un load no pierda más ciclos.

| Tramo | Etapa | Retardo | % |
|---|---|---:|---:|
| `dmem_bram` `CLKARDCLK` → `DOADO` (*clock-to-out*, 2,454 ns) y ruteo | MEM → WB | 3,537 ns | 24,9 |
| Extensión del load (LUT3) y mux de `wb_data` (LUT6, fanout 35) | WB | 1,608 ns | 11,3 |
| Mux de forwarding (LUT6) | EX | 0,964 ns | 6,8 |
| Mux de `alu_b` (LUT3, fanout 105) | EX | 1,378 ns | 9,7 |
| ALU: 4 LUT desde `alu_b[4]`, el `shamt` del desplazador, hasta `result[14]` | EX | 4,012 ns | 28,2 |
| `zero` sobre el resultado multiplexado (LUT4, LUT6) | EX | 1,470 ns | 10,3 |
| `taken` y `redirect` (LUT6, fanout 37) | EX | 0,570 ns | 4,0 |
| Flush de ID/EX en `hazard_unit` (LUT6) | ID | 0,675 ns | 4,7 |
| **Total** | | **14,212 ns** | |

Los 30 peores caminos son esta familia: 13 terminan en el flush de ID/EX (de +0,435 a +0,547 ns),
16 en el `CE` de `pc_reg` (de +0,662 a +0,803 ns) y uno en el `ena` de `imem` (+0,686 ns). La
mitad del retardo (mux de `alu_b`, ALU y `zero`, 6,86 ns) está ahí solo porque `zero` sale del
resultado ya multiplexado de las 10 operaciones: síntesis no puede saber que un salto solo usa la
resta, y el camino más largo de la ALU es el desplazador.

### Camino crítico, con el comparador

Del mismo origen al enable de `imem_bram` (`ENARDEN`), que es `en_if_id = enable & ~stall`, con
`stall = load_use & ~redirect` ([`pipeline.md`](../spec/pipeline.md) §10.4).

| Tramo | Etapa | Retardo | % |
|---|---|---:|---:|
| `dmem_bram` → `DOADO` y ruteo | MEM → WB | 3,885 ns | 29,5 |
| Extensión del load y mux de `wb_data` (3 LUT) | WB | 2,642 ns | 20,1 |
| Mux de forwarding (LUT6) | EX | 0,846 ns | 6,4 |
| Comparador `rs1_val == rs2_val` (LUT6, LUT4, 2 CARRY4) | EX | 2,681 ns | 20,4 |
| `taken` y `redirect` (LUT5, fanout 37) | EX | 1,081 ns | 8,2 |
| `stall` en `hazard_unit` (LUT4) | IF | 0,690 ns | 5,2 |
| `en_if_id = enable & ~stall` (LUT2, fanout 33) y ruteo al `ENARDEN` | IF | 1,326 ns | 10,1 |
| **Total** | | **13,151 ns** | |

El comparador reemplaza 6,86 ns (mux de `alu_b`, ALU y `zero`) por 2,68 ns. La mejora neta es
menor (1,06 ns de datos, +0,983 ns de WNS) porque esta corrida colocó `dmem_bram` en otro sitio
(`RAMB36_X1Y5` contra `X1Y2`) y el WB salió más largo. Sigue siendo la familia del salto: los 30
peores caminos (de +1,418 a +2,247 ns) terminan en el `ena` de `imem` (1), el `CE` de IF/ID (23) y
el flush de ID/EX (6). Ahora lo que pesa es la BRAM (29,5 %) y el WB.

### Peor slack de setup por etapa

El peor camino que termina en cada grupo de registros (`resumen.txt`):

| Destino | Base | Comparador |
|---|---:|---:|
| IF: `pc_reg` | +0,662 | +2,260 |
| IF: `imem_bram` | +0,686 | **+1,418** |
| IF/ID | +0,907 | +1,914 |
| ID/EX | **+0,435** | +1,934 |
| EX/MEM | +3,428 | +2,718 |
| MEM: `dmem_bram` | +5,647 | +6,033 |
| MEM/WB | +8,792 | +8,322 |
| WB: banco de registros | +4,241 | +4,214 |
| Debug Unit | +3,839 | +3,932 |
| UART | +8,115 | +7,470 |

Con el comparador, los destinos de la redirección (PC, `imem`, IF/ID, ID/EX) quedan entre +1,4 y
+2,3 ns. El que sigue es EX/MEM (+2,7 ns): el camino del dato de un load reenviado hasta el
resultado de la ALU, que ya no es de saltos. Ninguno de los caminos de la Debug Unit ni de la UART
se acerca.

### Skew

Un solo reloj (`clk_out1_clk_wiz_sys`, 15,385 ns) por un único BUFG a los 1914 elementos
sincrónicos; el otro BUFG es la realimentación del MMCM (`report_clock_utilization`). No hay
`BUFGCE`, divisores ni relojes generados por lógica: el paso a paso es con `enable` sobre los `CE`
(decisión [018](../decisiones/018_paso-a-paso-sin-clock.md)).

Cada camino del reporte trae el retardo de reloj hasta el origen (SCD) y hasta el destino (DCD).
En el crítico de la base:

```
pin W5 → IBUF (1,458) → ruteo (1,233) → MMCM (−6,961) → ruteo (1,661) → BUFG (0,096) → red (1,608)
SCD = −0,904 ns   DCD = −1,549 ns   CPR = +0,564 ns   skew = DCD − SCD + CPR = −0,081 ns
uncertainty = 0,132 ns  (jitter: TSJ 0,071 ns, DJ del MMCM 0,255 ns)
```

- **El MMCM compensa el retardo de inserción.** Los −6,961 ns no son un error: el MMCM alinea su
  salida con la entrada a través de la realimentación, así que el retardo del BUFG y del árbol de
  reloj se descuenta. Por eso SCD y DCD salen negativos.
- **El CPR** (*clock pessimism removal*) saca el pesimismo del tramo común del reloj (IBUF, MMCM,
  BUFG), que el análisis cuenta con retardo máximo en un extremo y mínimo en el otro.

| | Base | Comparador |
|---|---|---|
| Skew del peor camino de setup | −0,081 ns | −0,038 ns |
| Skew en los 30 peores de setup | de −0,081 a −0,021 ns | de −0,077 a −0,001 ns |
| Skew del peor camino de setup por etapa | de −0,114 a −0,001 ns | de −0,103 a −0,001 ns |
| Skew del peor camino de hold por etapa | de 0 a +0,263 ns | de 0 a +0,261 ns |
| Uncertainty (jitter) | 0,132 ns | 0,132 ns |

**Consecuencias.**
- **Setup:** un skew negativo (el reloj llega antes al destino) le quita tiempo al dato. En el
  peor camino son 81 ps, el 0,5 % del período; el jitter del MMCM (132 ps) pesa más. Ninguno de
  los dos limita la frecuencia: lo que la limita es el camino de datos de arriba.
- **Hold:** el peligro es el skew positivo (el reloj llega después al destino), porque el dato
  nuevo puede pisar al viejo antes de que se capture. El mayor es +0,263 ns, de MEM/WB al banco
  de registros, y ese camino tiene 0,70 ns de datos: slack +0,367 ns. El peor hold de todo el
  diseño es +0,086 ns (la FIFO de la UART, LUTRAM). **El hold no depende de la frecuencia**: un
  WHS negativo no se arreglaría bajando el reloj.
- **Por qué es chico:** el árbol global de la FPGA está balanceado y el MMCM lo compensa. Un
  reloj gateado o dividido con lógica saldría por ruteo común, con skew del orden de los ns y
  violaciones de hold que Vivado no puede corregir. Es la razón de la decisión 018.

### Compromisos de otras decisiones

- **`halted` → `enable` → `CE` (decisiones [018](../decisiones/018_paso-a-paso-sin-clock.md) y
  [037](../decisiones/037_fsm-de-ejecucion-de-la-debug-unit.md)).** El peor camino que sale de
  `halted` termina en el `CE` del banco de registros: +4,241 ns (base) y +4,214 ns (comparador),
  10,7 ns de datos con solo 2 o 3 niveles: casi todo es el ruteo del fanout de `enable`. No limita
  la frecuencia, así que `enable` sigue combinacional y no se registra. `enable` sí aparece como
  la última compuerta del camino crítico con el comparador, pero ahí el camino empieza en la BRAM
  de datos, no en `halted`.
- **Registro de salida de las BRAM (decisión [014](../decisiones/014_bram-y-escritura-de-programa.md),
  [`memoria.md`](../spec/memoria.md) §3.4).** El *clock-to-out* de `dmem_bram` es 2,454 ns, el
  16 % del período, y es el comienzo del camino crítico en las dos versiones. El registro de
  salida lo sacaría del camino, pero suma un ciclo a cada load y a cada búsqueda (2 stalls por
  load-use y 3 ciclos por salto tomado) y cambia el modelo y todos los `.exp`. No se activa: la
  consigna evalúa la frecuencia y el análisis del camino, no los ciclos, y con el comparador el
  diseño ya cumple con +1,4 ns. El peor camino que sale de `imem_bram` tiene +3,094 ns (base) y
  +2,615 ns (comparador): la memoria de programa no limita.

### Hipótesis de la decisión 012

La [012](../decisiones/012_resolucion-saltos.md) supuso que el camino crítico sería la decisión de
salto, con el dato de un load reenviado desde WB:

```
BRAM de datos → extensión → mux de WB → forwarding → ALU (resta) → zero → taken → redirect → mux del PC → pc_reg
```

**Confirmada en el qué, corregida en el cómo.**
- Es esa familia: empieza en `dmem_bram` y pasa por WB, forwarding, la ALU, `zero` y `redirect`.
- El tramo largo no es la resta sino el **desplazador** y el mux de resultado de la ALU, porque
  `zero` sale del resultado ya multiplexado.
- No termina en `pc_reg` sino en lo que `redirect` maneja a través de `hazard_unit`: el flush de
  ID/EX, el `ena` de `imem` y los enables de IF/ID y del PC. `pc_reg` está a +0,662 ns.

La 012 proponía tres medidas en orden de costo. Se aplicó la primera, el comparador de igualdad
(decisión 044): +0,983 ns de WNS sin cambiar ciclos, modelo ni `.exp`. La segunda (registrar
`redirect`, 3 ciclos por salto tomado) no se aplica, por la misma razón que el registro de salida
de la BRAM. La tercera, bajar el reloj, ya la hizo la 042 a 65 MHz; elegir la frecuencia final es
de la I-57.
