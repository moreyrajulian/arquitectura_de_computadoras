# Preguntas de la consigna

Respuestas a las preguntas del enunciado (I-59), con el diseño final: reloj de 92 MHz (decisión
[045](045_reloj-del-sistema-a-92-mhz.md)) y saltos con comparador de igualdad (decisión
[044](044_comparador-de-igualdad-en-saltos.md)). 

| Pregunta del enunciado | Respuesta corta |
|---|---|
| [1a. ¿Es necesario vaciar la memoria?](#1-vaciar-al-cargar-un-programa-nuevo) | Sí: `LOAD` pone en cero la memoria de datos |
| [1b. ¿Y los registros?](#1-vaciar-al-cargar-un-programa-nuevo) | Sí: en cero, con el reset del core |
| [1c. ¿Se necesita vaciar el pipeline?](#1-vaciar-al-cargar-un-programa-nuevo) | Sí: el reset del core lo deja vacío (todos los `valid` en 0) |
| [1d. ¿Y la memoria de programa?](#1-vaciar-al-cargar-un-programa-nuevo) | No se vacía: se sobrescribe con el programa nuevo y lo que sobra se llena con HALT |
| [2. ¿Qué sucede si en mi memoria no se encuentra una instrucción de parada?](#2-si-no-hay-instrucción-de-parada) | No puede faltar al final de un programa: `LOAD` rellena con HALT. Un bucle infinito no termina nunca y se corta con `STOP` |
| [3. ¿Cuál es el camino crítico de mi sistema?](#3-camino-crítico) | `dmem` → forwarding desde MEM/WB → comparador del salto → `redirect` → flush de ID/EX: 10,117 ns de datos, 9 niveles, slack +0,026 ns a 92 MHz |
| [4. ¿Este camino crítico genera skew en mi sistema? ¿Qué consecuencias tiene?](#4-skew) | Muy poco: un solo reloj por un BUFG. −73 ps en el camino crítico, menos que el jitter (129 ps); no limita la frecuencia ni rompe el hold |
| [5. De encontrarse skew: frecuencia óptima, métricas de Vivado y aplicarla](#5-frecuencia-de-funcionamiento) | Barrido de 65 a 100 MHz: la óptima es 92 MHz, medida con `timing.tcl` y aplicada en el Clock Wizard (I-57, decisión 045) |

## 1. Vaciar al cargar un programa nuevo

**Hay que vaciar la memoria de datos, los registros y el pipeline; la memoria de programa se
sobrescribe. Todo lo hace un solo comando.** `LOAD` detiene el core, escribe el programa nuevo y,
con el checksum correcto, limpia lo que depende del programa anterior antes de soltar el reset
(decisiones [004](004_carga-y-reprogramacion.md) y
[038](038_carga-de-programa-en-la-debug-unit.md), [`protocolo_debug.md`](../spec/protocolo_debug.md)
§3.3, [`memoria.md`](../spec/memoria.md) §4.1):

| Pregunta | Qué hace `LOAD` | Por qué hace falta |
|---|---|---|
| a. Memoria (de datos) | La pone en cero (las 1024 palabras), junto con el mapa de palabras usadas | Si no, el programa nuevo lee datos del anterior y "memoria usada" mezcla los dos |
| b. Registros | En cero, con el reset del core | El resultado dependería del historial: el mismo programa daría distinto según qué se corrió antes |
| c. Pipeline | Vacío, con el reset del core (todos los `valid` en 0) | Las instrucciones del programa viejo que estaban en vuelo llegarían a MEM y WB y escribirían memoria o registros del programa nuevo |
| d. Memoria de programa | No la vacía: escribe `imem[0 … N−1]` y llena `imem[N … 1023]` con HALT | Vaciarla a cero no alcanza (`0x00000000` se ejecuta como NOP, decisión [024](024_instrucciones-no-soportadas.md), y el PC seguiría de largo) y no hace falta; lo que importa es que, si el programa nuevo es más corto, no ejecute la cola del anterior |

Detalles:
- `LOAD` se acepta en cualquier estado, también con el core corriendo un bucle infinito: primero
  lo detiene (`enable = 0`, `core_rst = 1`) y recién después escribe (decisión 038).
- `RESET` hace lo mismo sin tocar la memoria de programa, para volver a correr el mismo programa.
- Si la carga falla (checksum o timeout), el core queda en reset en `NO_PROG` y no se puede
  ejecutar hasta repetir el `LOAD` completo: un programa a medio escribir nunca corre.
- Limpiar recorre cada BRAM una vez por el puerto B, un ciclo por palabra: ~11 µs por memoria a 92 MHz,
  nada frente a los ~0,4 s que tarda en llegar un programa de 1 K palabras por la UART.

**Lo prueban:**
- [`tb/unit/debug_load_tb.v`](../../tb/unit/debug_load_tb.v) (I-46): reprogramar en `HALTED`,
  `RUNNING` (bucle infinito), `READY` y `PAUSED`. Comprueba que registros, `dmem` y pipeline del
  programa anterior quedan en cero, que `imem[N … 1023]` queda en HALT con cada dirección escrita
  una sola vez, que toda escritura llega con el core en reset y que una carga fallida deja
  `NO_PROG`.
- [`tb/unit/top_tb.v`](../../tb/unit/top_tb.v) (I-49): un segundo `LOAD` borra los avisos del
  programa anterior.
- La placa ([`placa.py`](../../tools/debugger/placa.py), I-55 e I-57): carga los 22 programas del
  plan uno tras otro, cada uno con un `LOAD` sin resetear la placa, y todos dan su `.exp`
  (22 de 22 a 92 MHz, [`docs/timing/`](../timing/README.md#prueba-en-placa-a-92-mhz)). Si quedara
  algo del programa anterior, fallarían los registros o la memoria usada.

## 2. Si no hay instrucción de parada

**Al final de un programa no puede faltar el HALT**, porque `LOAD` llena con HALT
(`0x00100073`) todo lo que el programa no ocupa (respuesta 1d). Un programa que "se olvida" el
`halt` igual se detiene en la palabra siguiente a la última.

Quedan dos casos en que el procesador no se detiene solo:
- **Un bucle infinito** (por ejemplo `bne` hacia atrás que siempre se toma): el HALT nunca llega
  a ID, `stop_fetch` no se activa y el core corre para siempre. Para eso existe `STOP`
  ([`protocolo_debug.md`](../spec/protocolo_debug.md) §3.5): baja `enable`, el estado pasa a
  `PAUSED` y se puede inspeccionar, seguir con `RUN`/`STEP` o terminar con `RESET`/`LOAD`. En
  `PAUSED` el pipeline puede no estar vacío, porque es una pausa de depuración y no el final.
  También sirven el botón de reset de la placa (decisión [041](041_reset-del-sistema-en-la-placa.md))
  y un `LOAD` nuevo.
- **Un programa de exactamente 1024 palabras sin HALT**: no hay dónde rellenar. El PC llega a
  `0x1000` y, como `imem` solo mira `pc[11:2]`, vuelve a `imem[0]` y el programa se repite en
  bucle. El core levanta `imem_fault`, que se ve en el bloque de estado y en un LED
  ([`memoria.md`](../spec/memoria.md) §6.1, decisión [015](015_accesos-desalineados-y-fuera-de-rango.md),
  [`pipeline.md`](../spec/pipeline.md) §3.4). Se corta con `STOP` como cualquier bucle.

En ningún caso se ejecuta basura de un programa anterior ni memoria sin inicializar: la
memoria de programa siempre tiene el programa actual o HALT.

**Esta respuesta reemplaza la de la decisión [001](001_instruccion-halt.md).** La 001 se
escribió antes de definir la carga y contemplaba memoria en cero o con restos de otro programa;
la 004 ya pedía actualizarla. Las decisiones no se editan, así que la respuesta vigente es esta.

**Lo prueban:**
- [`tb/unit/debug_load_tb.v`](../../tb/unit/debug_load_tb.v): el relleno con HALT y el caso
  `N = 1024` sin relleno.
- [`tb/unit/debug_run_tb.v`](../../tb/unit/debug_run_tb.v) (I-47): `STOP` en el medio de un lazo
  (`PAUSED`, `enable` baja y `cycles` se congela) y en los demás estados.
- [`tb/unit/top_tb.v`](../../tb/unit/top_tb.v): el botón de reset con el core corriendo un bucle
  infinito.
- [`tb/unit/imem_tb.v`](../../tb/unit/imem_tb.v): el alias de `imem` (`0x1000` lee `imem[0]`).
- `sw/halt_basico.s`, `sw/halt_stall.s` y `sw/halt_camino_equivocado.s`, en la regresión y en la
  placa: el HALT detiene el core con el pipeline vacío, y un HALT en el camino equivocado no lo
  detiene.

## 3. Camino crítico

Medido post-implementación a 92 MHz (período 10,870 ns) con `scripts/timing.tcl`
([`docs/timing/`](../timing/README.md#92-mhz-post-implementación), reportes en
[`i57_92mhz/`](../timing/i57_92mhz/)):

```
dmem_bram (clock-to-out de la BRAM, un load en MEM)
  → mux de WB → forwarding desde MEM/WB (operando del salto en EX)
  → comparador de igualdad rs1_val == rs2_val (decisión 044)
  → taken → redirect
  → flush de ID/EX (reset síncrono de id_ex_ctrl_reg)
slack +0,026 ns · datos 10,117 ns · 9 niveles de lógica · skew −0,073 ns · incertidumbre 0,129 ns
```

Es el caso de un `beq`/`bne` que compara un registro recién cargado por un `lw` (después del
stall, el dato llega por MEM/WB): el salto se resuelve en EX y en el mismo ciclo tiene que
redirigir el PC y anular IF/ID e ID/EX (decisión [012](012_resolucion-saltos.md),
[`pipeline.md`](../spec/pipeline.md) §10.5).

- **No es un único camino.** A 92 MHz varias etapas quedan en el límite y todas salen del
  *clock-to-out* de `dmem_bram`: EX/MEM +0,114 ns (forwarding → ALU), `pc_reg` +0,171 ns
  (`redirect` → PC), `imem` +0,428 ns. Por eso a 95 MHz fallan 42 endpoints con destinos
  distintos, y acortar uno solo no permitiría subir mucho.
- **El ruteo pesa más que la lógica**: el 60 a 70 % del retardo son cables. Por eso la estimación
  post-síntesis (−0,465 ns) no sirve para decidir y vale el resultado post-route.
- **Cómo se llegó a 92 MHz.** Sin Clock Wizard, a 100 MHz, el diseño no cerraba. La I-56 midió el
  camino crítico a 65 MHz y, con el comparador de igualdad en lugar de la resta de la ALU, el
  slack pasó de +0,435 a +1,418 ns (decisión 044). La I-57 barrió de 65 a 100 MHz: hasta 92 MHz
  cierra todo; 95 y 100 MHz no (decisión 045,
  [`barrido.csv`](../timing/i57_barrido/barrido.csv)).

**Lo prueban:** el reporte [`timing_summary.rpt`](../timing/i57_92mhz/timing_summary.rpt) y
[`resumen.txt`](../timing/i57_92mhz/resumen.txt), las capturas de Vivado de la implementación que
generó el bitstream (en [`i57_92mhz/`](../timing/i57_92mhz/)), y la regresión (39 de 39 y 27 de
27) y la placa (22 de 22 y 32 de 32) a 92 MHz.

## 4. Skew

**Hay, pero es chico y no limita nada.** El camino crítico de la respuesta 3 tiene −73 ps de skew entre la BRAM de origen e ID/EX. El diseño tiene un solo reloj (`clk_out1_clk_wiz_sys`,
92 MHz) que sale del MMCM por un único BUFG y llega por el árbol global a todos los elementos
sincrónicos. No hay *clock gating*, divisores ni relojes generados con lógica: el paso a paso se
hace con `enable` sobre los CE de los flip-flops, con el reloj siempre corriendo (decisión
[018](018_paso-a-paso-sin-clock.md)), y el reset de la placa espera a que el MMCM enganche
(decisiones [041](041_reset-del-sistema-en-la-placa.md) y [042](042_reloj-del-sistema-a-65-mhz.md)).

A 92 MHz ([`resumen.txt`](../timing/i57_92mhz/resumen.txt)):

| | Skew | Comparación |
|---|---|---|
| Camino crítico de setup | −0,073 ns | 0,7 % del período; el jitter del MMCM (incertidumbre 0,129 ns) pesa más |
| Peores de setup por etapa | de −0,116 a +0,029 ns | |
| Peores de hold por etapa | de 0 a +0,265 ns | El mayor, de MEM/WB al banco, con 0,772 ns de datos: slack +0,455 ns |
| Hold de todo el diseño | WHS +0,037 ns | En la FIFO de la UART (LUTRAM), con skew +0,013 ns |

Consecuencias:
- **Setup:** un skew negativo (el reloj llega antes al destino) le quita tiempo al dato. Con
  73 ps de 10,870 ns no es lo que limita la frecuencia: la limita el camino de datos de la
  respuesta 3.
- **Hold:** el peligro es el skew positivo (el reloj llega después al destino), porque el dato
  nuevo puede pisar al viejo antes de que se capture. El mayor es +0,265 ns y todos los caminos
  tienen slack positivo. El hold no depende de la frecuencia: un WHS negativo no se arreglaría
  bajando el reloj.
- **Por qué es chico:** el árbol global de la FPGA está balanceado y el MMCM compensa el retardo
  de inserción con su realimentación (por eso Vivado muestra los retardos de reloj negativos). Si
  el paso a paso se hubiera hecho gateando el reloj, ese reloj saldría por ruteo común, con skew
  del orden de los ns, violaciones de hold que Vivado no puede corregir, y cada BRAM con sus dos
  puertos en redes distintas. Es la razón de la decisión 018, y lo que la consigna pide evitar al
  prohibir intervenir el reloj.

**Lo prueban:** la sección de skew de [`docs/timing/`](../timing/README.md#skew) (I-56, a 65 MHz,
con el desglose del retardo de reloj y `report_clock_utilization`), los números a 92 MHz de
[`resumen.txt`](../timing/i57_92mhz/resumen.txt) y la captura
[`vivado_relojes.png`](../timing/i57_92mhz/vivado_relojes.png) con el único reloj del diseño.

## 5. Frecuencia de funcionamiento

El enunciado pide, de encontrarse skew, encontrar la frecuencia óptima, generar métricas con
las herramientas de Vivado y aplicarla. El skew resultó despreciable (respuesta 4), pero igual se
hizo, porque lo que limita la frecuencia es el camino crítico (respuesta 3). Es la I-57, decisión
[045](045_reloj-del-sistema-a-92-mhz.md); detalle en
[`docs/timing/`](../timing/README.md#i-57-barrido-de-frecuencias-y-reloj-final-a-92-mhz).

- **Frecuencia óptima.** `scripts/barrido.tcl` implementa el diseño desde cero a 16 frecuencias,
  de 65 a 100 MHz, con el Clock Wizard y el divisor de la UART ajustados a cada una
  ([`barrido.csv`](../timing/i57_barrido/barrido.csv)). Cierran todas hasta 92 MHz
  (WNS +0,026 ns); 95 MHz da −0,449 ns y 100 MHz −0,714 ns. Se eligió **92 MHz**, la máxima: el
  análisis estático ya usa el peor caso de proceso, tensión y temperatura, así que con WNS ≥ 0 el
  diseño funciona en la placa (decisión 045, con las opciones de más margen que se descartaron).
- **Métricas de Vivado.** `scripts/timing.tcl` (`report_timing_summary`, `report_utilization`,
  `report_power`, `report_clock_utilization`) a 65 y a 92 MHz, con las capturas de la
  implementación que generó el bitstream ([`i57_92mhz/`](../timing/i57_92mhz/)):

  | | 65 MHz (antes) | 92 MHz (después) |
  |---|---|---|
  | WNS / WHS | +1,418 / +0,066 ns | +0,026 / +0,037 ns |
  | LUT / FF / BRAM | 2813 / 1882 / 2 | 2907 / 1884 / 2 |
  | Consumo estimado | 0,200 W | 0,200 W (el MMCM es 0,120 W de 0,128 W dinámicos) |
  | UART (DVSR, baud real) | 35, 116 071 baud (+0,76 %) | 50, 115 000 baud (−0,17 %) |

- **Aplicada.** `ip/clk_wiz.tcl` pide 92 MHz (MMCM D = 5, M = 48,875, O = 10,625: 92 000 000 Hz
  exactos) y `CLK_FREQ_HZ` del top vale 92 000 000, del que salen el divisor de la UART y el
  timeout de la Debug Unit. Lo confirman la regresión (39 de 39 corridas de `pipeline_tb` y 27 de
  27 testbenches) y la placa (22 de 22 programas con RUN y STEP, 32 de 32 con las `_nops`), con
  `INFO` informando `clk_khz = 92000`.
