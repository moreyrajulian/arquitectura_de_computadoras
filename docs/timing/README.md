# docs/timing/

Resultados de síntesis e implementación del diseño `riscv_basys3` en la Basys 3
(`xc7a35tcpg236-1`): timing, utilización y warnings. Cada vez que se mide se agrega una sección
con el tag o el commit. Las secciones de la I-49 son el punto de partida; el análisis del camino
crítico y del skew, con y sin el comparador de saltos, está en [I-56](#i-56-camino-crítico-y-skew-a-65-mhz),
y el barrido de frecuencias y el reloj final de **92 MHz** en [I-57](#i-57-barrido-de-frecuencias-y-reloj-final-a-92-mhz).

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
red de reloj y un `resumen.txt` con una línea por grupo. Implementa con el proyecto regenerado,
para que el reloj sea el de `ip/clk_wiz.tcl` del working tree (los IP se configuran solo al crear
el proyecto).

Desde la I-57, `scripts/barrido.tcl` implementa el diseño a una lista de frecuencias y deja una
línea por frecuencia en `build/timing/barrido/barrido.csv` (el detalle en su cabecera):

```sh
vivado -mode batch -source scripts/barrido.tcl -tclargs 65 70 74 80 92
```

Para cada una cambia la salida del Clock Wizard y el `CLK_FREQ_HZ` del top solo en el proyecto,
no en los archivos versionados, que regenera desde cero (conviene correrlo en una copia del
repo). De cada medición de la I-56 se versionan
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
ruteo. La I-57 eligió la frecuencia con un barrido (ver [I-57](#i-57-barrido-de-frecuencias-y-reloj-final-a-92-mhz)).

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
de la BRAM. La tercera, bajar el reloj, ya la hizo la 042 a 65 MHz; la frecuencia final la eligió la
I-57: 92 MHz (decisión [045](../decisiones/045_reloj-del-sistema-a-92-mhz.md)).

## I-57: barrido de frecuencias y reloj final a 92 MHz

El diseño de la I-56, con el comparador (decisión
[044](../decisiones/044_comparador-de-igualdad-en-saltos.md)), implementado a 16 frecuencias con
`scripts/barrido.tcl` en Vivado 2024.2, post-implementación y con la estrategia por defecto
(2026-11-20 a 22). La frecuencia elegida es **92 MHz**, la máxima que cumple timing (decisión
[045](../decisiones/045_reloj-del-sistema-a-92-mhz.md)).

### Barrido

Todas las columnas, con los divisores del MMCM, la utilización, el consumo y el divisor de la UART,
están en [`i57_barrido/barrido.csv`](i57_barrido/barrido.csv).

| MHz | MMCM (D, M, O) | WNS (ns) | TNS (ns) | Endpoints que fallan | WHS (ns) | Incertidumbre (ns) | Datos del peor camino (ns) | LUT | UART |
|---|---|---|---|---|---|---|---|---|---|
| 65 | 5, 50,375, 15,5 | +1,418 | 0 | 0 | +0,066 | 0,132 | 13,151 | 2813 | +0,76 % |
| 68 | 5, 51, 15 | +1,077 | 0 | 0 | +0,095 | 0,130 | 12,802 | 2805 | −0,29 % |
| 70 | 5, 49,875, 14,25 | +1,111 | 0 | 0 | +0,037 | 0,132 | 12,991 | 2815 | −0,06 % |
| 72 | 5, 49,5, 13,75 | +1,118 | 0 | 0 | +0,094 | 0,133 | 12,361 | 2822 | +0,16 % |
| 74 | 5, 50,875, 13,75 | +1,078 | 0 | 0 | +0,037 | 0,128 | 11,498 | 2819 | +0,37 % |
| 76 | 5, 49,875, 13,125 | +0,229 | 0 | 0 | +0,045 | 0,130 | 12,438 | 2806 | +0,57 % |
| 78 | 1, 9,75, 12,5 | +0,274 | 0 | 0 | +0,104 | 0,077 | 12,481 | 2818 | +0,76 % |
| 80 | 1, 10, 12,5 | +0,412 | 0 | 0 | +0,046 | 0,077 | 11,711 | 2818 | +0,94 % |
| 82 | 1, 10,25, 12,5 | +0,486 | 0 | 0 | +0,046 | 0,076 | 11,381 | 2828 | +1,11 % |
| 84 | 5, 49,875, 11,875 | +0,359 | 0 | 0 | +0,055 | 0,128 | 11,172 | 2867 | −0,93 % |
| 86 | 5, 48,375, 11,25 | +0,409 | 0 | 0 | +0,051 | 0,132 | 11,031 | 2898 | −0,73 % |
| 88 | 5, 49,5, 11,25 | +0,381 | 0 | 0 | +0,024 | 0,129 | 10,846 | 2912 | −0,54 % |
| 90 | 5, 49,5, 11 | +0,288 | 0 | 0 | +0,098 | 0,129 | 10,650 | 2910 | −0,35 % |
| **92** | **5, 48,875, 10,625** | **+0,026** | 0 | 0 | +0,037 | 0,129 | 10,117 | 2907 | −0,17 % |
| 95 | 5, 49,875, 10,5 | **−0,449** | −5,893 | 42 | +0,037 | 0,126 | 10,720 | 2927 | −0,88 % |
| 100 | 1, 10, 10 | **−0,714** | −30,251 | 122 | +0,075 | 0,074 | 10,598 | 2938 | +0,47 % |

En todas: 1883 ± 1 FF, 2 RAMB36, 1 MMCM y 0,18 a 0,20 W estimados. La columna UART es el error
del baudrate con `DVSR = round(f / (16 × 115200))` ([`protocolo_debug.md`](../spec/protocolo_debug.md) §1).

Qué muestra:
- **La cota de ~71,6 MHz de la I-56 era pesimista.** Suponía el mismo ruteo con otro reloj. Con un
  reloj más exigente, la colocación y el ruteo guiados por timing acortan el camino: el retardo de
  datos del peor camino baja de 13,15 ns a 65 MHz a 10,12 ns a 92 MHz.
- **El margen no baja parejo.** Hasta 74 MHz queda en ~1,1 ns (8 % del período); a 76 MHz cae a
  +0,23 ns y el crítico pasa a la Debug Unit (`cmd_reg` → `u_debug_dump/u_used_map/ptr_reg`,
  15 niveles). De 76 a 90 MHz el WNS sube y baja entre +0,23 y +0,49 ns: el resultado no es
  monótono con la frecuencia.
- **El wizard no siempre elige igual.** A 78, 80, 82 y 100 MHz usa D = 1 y la incertidumbre del
  reloj baja de ~0,13 a ~0,077 ns, por el menor jitter. Por eso 80 MHz cierra con más margen que
  76 MHz.
- **El flujo es determinista.** 82 a 90 MHz se midió dos veces con números idénticos, y 92 MHz tres
  veces (barrido, `scripts/timing.tcl` y la GUI) con el mismo +0,026 ns.
- **La frecuencia real** de la segunda columna del `.csv` sale del período que redondea Vivado
  (10,870 ns a 92 MHz); el MMCM da 100 × 48,875 / (5 × 10,625) = 92,000 MHz exactos.

### Antes y después

| | Antes: 65 MHz (042, comparador de la 044) | Después: **92 MHz** (045) |
|---|---|---|
| Período | 15,385 ns | 10,870 ns |
| MMCM | D = 5, M = 50,375, O = 15,5 (VCO 1007,5 MHz) | D = 5, M = 48,875, O = 10,625 (VCO 977,5 MHz); jitter 248,4 ps pico a pico |
| WNS / TNS (setup) | +1,418 ns / 0 | **+0,026 ns** / 0 |
| WHS / THS (hold) | +0,066 ns / 0 | +0,037 ns / 0 |
| Endpoints que fallan | 0 de 5357 | 0 de 5360 |
| Peor camino | `dmem_bram` → … → `ena` de `imem_bram`, 13,151 ns, 11 niveles | `dmem_bram` → … → `R` de `id_ex_ctrl` (flush de ID/EX), 10,117 ns, 9 niveles |
| LUT / LUTRAM / FF | 2813 / 22 / 1882 | 2907 (14 %) / 22 / 1884 (5 %) |
| BRAM / MMCM / IO | 2 RAMB36 / 1 / 20 | 2 RAMB36 (4 %) / 1 (20 %) / 20 (19 %) |
| Consumo estimado | 0,200 W (0,128 dinámico + 0,072 estático) | 0,200 W (0,128 dinámico + 0,072 estático) |
| UART | `DVSR = 35`, 116 071 baud (+0,76 %) | `DVSR = 50`, 115 000 baud (−0,17 %) |
| Regresión en simulación | 39 de 39 y 27 de 27 | 39 de 39 y 27 de 27 |
| Placa | 22 de 22 y 32 de 32 (I-55) | **22 de 22 y 32 de 32** |

El antes es la medición `comparador` de la I-56 ([`i56_comparador/`](i56_comparador/)), que el
barrido repite al milésimo. Los recursos del antes salen de la fila de 65 MHz del barrido.

**El consumo no cambia con la frecuencia** porque lo domina el MMCM: de los 0,128 W dinámicos,
0,120 W (94 %) son del MMCM, y relojes, señales, lógica y BRAM suman unos 7 mW. Es la estimación de
`report_power` sin vectores de simulación (*vectorless*, confianza *Medium*), sobre la red
implementada.

### 92 MHz, post-implementación

Reportes de `scripts/timing.tcl` en [`i57_92mhz/`](i57_92mhz/) (`timing_summary.rpt` y
`resumen.txt`, sin el nombre del equipo ni la ruta absoluta, como en la I-56).

| Grupo de destino | Slack de setup | Peor camino |
|---|---|---|
| ID/EX | **+0,026 ns** | `dmem_bram` → WB → forwarding → comparador → `redirect` → flush de ID/EX (9 niveles) |
| EX/MEM | +0,114 ns | `dmem_bram` → forwarding → ALU → `ex_mem_data` (11 niveles) |
| IF: `pc_reg` | +0,171 ns | `dmem_bram` → … → `redirect` → PC |
| IF: `imem_bram` | +0,428 ns | `dmem_bram` → … → `ena` de `imem` |
| Debug Unit | +0,541 ns | `cmd_reg` → `u_used_map/ptr_reg` (14 niveles) |
| IF/ID | +0,636 ns | `dmem_bram` → … → enable de IF/ID |
| WB: banco | +1,875 ns | `halted` → `enable` → CE del banco (decisiones 018/037) |
| UART, MEM/WB, `reset_sync` | +3,3 a +8,1 ns | |

A 92 MHz varias etapas quedan en el límite y empiezan todas en el *clock-to-out* de `dmem_bram`:
no hay un único camino que, acortado, permita subir mucho más. Por eso 95 MHz falla con
42 endpoints y destinos distintos. El hold más ajustado es +0,037 ns, dentro de la FIFO de
recepción de la UART.

**Síntesis contra implementación.** La estimación post-síntesis da WNS = −0,465 ns (21 endpoints,
[`vivado_timing_sintesis.png`](i57_92mhz/vivado_timing_sintesis.png)). Sin colocación ni ruteo,
Vivado estima el retardo de los cables, que son el 60 a 70 % del camino crítico. Vale el resultado
post-route (`Design State : Routed`).

**DRC.** La implementación tiene 2 warnings, PDRC-132 y PDRC-134, en `SLICE_X53Y10`
([`vivado_drc.png`](i57_92mhz/vivado_drc.png)): las dos mitades de una LUT6 (A6/A5 y B6/B5) se
usan con funciones distintas sin la entrada A6 atada a 1. No son críticos y el bitstream se genera. En *Messages* hay 0 warnings críticos y 0 errores en
síntesis e implementación, y la utilización da `Register as Latch = 0`.

Capturas de Vivado de la implementación que generó el bitstream:

| Captura | Qué muestra |
|---|---|
| [`vivado_clk_wiz_salidas.png`](i57_92mhz/vivado_clk_wiz_salidas.png) | Clocking Wizard: `clk_out1` pedida 92,000 MHz, real 92,00000 MHz |
| [`vivado_clk_wiz_mmcm.png`](i57_92mhz/vivado_clk_wiz_mmcm.png) | MMCM: D = 5, M = 48,875, O = 10,625; jitter y error de fase |
| [`vivado_relojes.png`](i57_92mhz/vivado_relojes.png) | *Clock Summary*: `clk_out1_clk_wiz_sys`, 10,870 ns, 92,000 MHz |
| [`vivado_timing.png`](i57_92mhz/vivado_timing.png) | *Design Timing Summary* post-implementación: "All user specified timing constraints are met" |
| [`vivado_timing_sintesis.png`](i57_92mhz/vivado_timing_sintesis.png) | La estimación post-síntesis, para comparar |
| [`vivado_utilizacion.png`](i57_92mhz/vivado_utilizacion.png) | Utilización post-implementación |
| [`vivado_consumo.png`](i57_92mhz/vivado_consumo.png) | Consumo estimado, con el MMCM como 94 % del dinámico |
| [`vivado_drc.png`](i57_92mhz/vivado_drc.png) | Los 2 warnings de DRC |

### Prueba en placa a 92 MHz

Con el bitstream de esa implementación, 2026-11-22:

| | Resultado |
|---|---|
| `python tools/debugger/placa.py COM8` (22 programas, RUN y STEP) | **22 de 22 OK**; `INFO` informa 92000 kHz ([`placa.txt`](i57_92mhz/placa.txt)) |
| `python tools/debugger/placa.py COM8 --nops --sin-paso` | **32 de 32 OK** ([`placa_nops.txt`](i57_92mhz/placa_nops.txt)) |

Los ciclos de `RUN` son los mismos que a 65 MHz: el reloj cambia el tiempo de cada ciclo, no
cuántos ciclos tarda cada programa.
