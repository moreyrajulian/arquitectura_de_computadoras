# Plan de verificación

Este documento fija **qué se prueba, contra qué se compara y cuándo una prueba se considera
aprobada**, antes de escribir el RTL. Los mecanismos a cubrir salen de
[`pipeline.md`](pipeline.md) (en especial §10.7), la codificación de [`isa.md`](isa.md), el
comportamiento de las memorias de [`memoria.md`](memoria.md) y los comandos de
[`protocolo_debug.md`](protocolo_debug.md).

---

## 1. Niveles de prueba

| Nivel | Qué prueba | Dónde | Quién la escribe|
|---|---|---|---|
| **1. Unitario** | Un módulo aislado, con estímulos propios | `tb/unit/` | quien escribe el módulo |
| **2. Por etapa** | El pipeline construido hasta la etapa N, ejecutando programas de `sw/` y comparando los registros de segmentación contra la traza del modelo de referencia | `tb/integration/` | I-17 (banco incremental), una integración por etapa |
| **3. Core completo** | El procesador ejecutando cada programa hasta el HALT, comparando el estado final con el esperado | `tb/integration/` | I-38 (sin riesgos) y I-43 (regresión completa) |
| **4. Debug Unit** | Protocolo, carga de programa, modos de ejecución y volcado de estado, desde una trama UART | `tb/unit/` y `tb/integration/` | I-44 a I-48 |
| **5. Placa** | Los mismos programas, cargados desde la PC con el cliente del protocolo | Basys 3 | I-49 e I-55 |

Los niveles 2 y 3 comparten los programas de `sw/` (§4) y el mismo formato de estado esperado
(§5). Eso permite correr cada programa en cada nivel y detectar en cuál empieza a fallar.

**Por qué por etapa y no solo el core completo.** Con cinco etapas y tres mecanismos de riesgo
interactuando, un error en el core completo puede venir de cualquier lado. El plan construye el
pipeline etapa por etapa ([`planificación`](../planificacion.md)) y compara los registros de
segmentación en cada integración: cada error queda acotado a la última etapa agregada. Los
riesgos (forwarding, stall, flush) se prueban recién cuando las cinco etapas funcionan sin
ellos (I-38), porque involucran a varias etapas a la vez.

---

## 2. De dónde sale lo esperado

Una prueba es tan buena como su resultado esperado. Hay tres fuentes, escritas por separado:

| Oráculo | Qué es | Quién lo produce |
|---|---|---|
| **Estado esperado a mano** (`sw/<programa>.exp`, §5) | El estado final del programa, calculado leyendo `isa.md`, sin ejecutar nada | Quien escribe el programa |
| **Modelo de referencia** (I-16, [`tools/isasim`](../../tools/isasim/README.md)) | Un programa que ejecuta `isa.md` instrucción por instrucción y, con las reglas de `pipeline.md`, calcula en qué ciclo pasa cada instrucción por cada etapa: produce el estado final, los ciclos y la traza de los registros de segmentación (decisión [020](../decisiones/020_modelo-de-referencia.md)) | Quien escribe el modelo |
| **RTL** | El procesador | Quien escribe los módulos |

Reglas:

1. El modelo tiene que coincidir con el `.exp` de **todos** los programas. Así se verifica el
   modelo antes de usarlo para verificar el RTL.
2. El RTL tiene que coincidir con el `.exp` y con la traza del modelo.
3. El `.exp` no se genera con el modelo ni con el RTL: se escribe a mano. Si saliera de alguno
   de los dos, un error de interpretación de la ISA estaría en los dos lados y la prueba pasaría
   igual.

**Por qué independientes.** Es el mismo criterio que sigue `alu_tb.v`, que usa un modelo escrito
aparte del RTL "para que el modelo documente la especificación en vez de repetir el diseño".
Cuando dos fuentes escritas por separado coinciden, es poco probable que compartan el mismo error;
cuando difieren, la discrepancia señala algo que revisar en `isa.md`, en el modelo o en el RTL.

---

## 3. Tabla módulo → testbench (nivel 1)

Convención: el testbench de `rtl/<carpeta>/<módulo>.v` es `tb/unit/<módulo>_tb.v` y su módulo
superior se llama `<módulo>_tb`, a partir de `tb/unit/_plantilla_tb.v` (decisión
[010](../decisiones/010_convenciones-rtl.md)). Los casos son el **mínimo** exigido: se pueden
agregar más, no quitar.

### 3.1 Pipeline (M3 a M7)

| Módulo | Issue | Testbench | Casos mínimos |
|---|---|---|---|
| Definiciones de la ISA | I-18 | — (se prueban a través de los demás) | Los códigos de `alu_ctrl` y los opcodes coinciden con `pipeline.md` §4.4 y §4.5 |
| PC y próxima dirección (`pc_logic`) | I-19 | `pc_logic_tb.v` | Reset a `0x0000_0000`; `pc + 4`; `redirect` gana sobre todo; `stop_fetch` retiene; `en_pc = 0` retiene; prioridad `redirect` > `stop_fetch` (§3.1) |
| Memoria de programa (`imem`) | I-20 | `imem_tb.v` | Latencia de lectura de un ciclo; el dato de la dirección *a* aparece un ciclo después; `ena` en 0 conserva la salida; escritura por el puerto B (`LOAD`) y lectura posterior; contenido inicial HALT (`memoria.md` §3.2, §3.6); alias de direcciones fuera de rango (`memoria.md` §6.1) |
| Registro IF/ID | I-21 | `if_id_reg_tb.v` | Prioridad `rst` > `en` > `flush` (`pipeline.md` §2); `flush` carga burbuja (`valid = 0`); `en = 0` conserva aunque `flush = 1` |
| Etapa IF (`if_stage`) | I-22 | `if_stage_tb.v` | Carga por el puerto B y arranque (`memoria.md` §4.4): el primer ciclo habilitado trae `instr(0)` con `if_id_pc = 0`; secuencia `pc`, `pc + 4`; `en = 0` conserva PC e IF/ID bit a bit, también con `flush = 1`; `flush` deja burbuja; salto tomado (`redirect` + `flush`) y destino; `stop_fetch` retiene el PC y solo entran burbujas; `redirect` > `stop_fetch`; aleatorio con semilla fija contra un modelo de §3 |
| Banco de registros (`regfile`) | I-23 | `regfile_tb.v` | `x0` siempre 0 (se lee 0 aunque se escriba); escribir y leer los 31 registros; dos lecturas simultáneas; **bypass WB→ID**: leer el registro que se escribe en el mismo ciclo entrega el dato nuevo ([007](../decisiones/007_banco-registros.md)); tercer puerto de lectura de la Debug Unit |
| Unidad de control (`control_unit`) | I-24 | `control_unit_tb.v` | **Exhaustivo**: para cada fila de la tabla de verdad de §4.4 (R, I aritmética, load, store, branch, `jal`, `jalr`, `lui`, HALT, no reconocida, burbuja) verifica las 12 señales; `halt` solo con `valid = 1`; `0x0000_0000` y `ecall` se comportan como NOP |
| Generador de inmediatos (`imm_gen`) | I-25 | `imm_gen_tb.v` | Los cinco formatos de `isa.md` con inmediato positivo, negativo, máximo y mínimo; el bit de signo siempre es `instr[31]`; un código de `imm_sel` sin formato da 0. Oráculos independientes del RTL (§2): palabras generadas por el ensamblador con el inmediato escrito en la fuente, y un codificador propio del testbench (la función inversa) para lo que el ensamblador no genera: sus saltos son múltiplos de 4, así que nunca ponen en 1 el bit 1 de B y J ni llegan a sus máximos (4094 y 1048574) |
| Registro ID/EX | I-26 | `id_ex_reg_tb.v` | Igual que IF/ID; además, los 161 bits se conservan intactos con `en = 1` |
| Etapa ID (`id_stage`) | I-27 | `id_stage_tb.v` | El cableado entre los módulos de ID, sobre todo lo que la traza no ve en M4: una palabra del ensamblador por fila de la tabla de verdad de `pipeline.md` §4.4, con los 20 campos de ID/EX; `id_is_halt` solo con HALT y `valid = 1`; escritura de WB con bypass en `rs1` y en `rs2`, `rd = 0` y `enable = 0` sin escritura, `enable` y `en_id_ex` independientes; puerto de debug sin bypass y `x0` leído como 0; `en = 0` conserva los 161 bits también con `flush = 1`; `flush` deja burbuja; reset con el core detenido; el bus `o_id_ex_latch` igual a los campos; aleatorio con semilla fija contra un modelo de §2 y §4.2 |
| ALU (`alu`) | I-28 | `alu_tb.v` | Las 10 operaciones; `zero` en 1 y en 0, mirando los 32 bits; `slt` contra `sltu` con operandos negativos; desplazamientos con `shamt` 0, 1 y 31 y usando solo los 5 bits bajos de `rs2`. El control de la ALU no es un módulo aparte (decisión [026](../decisiones/026_control-de-alu-en-id.md)): sus casos (`{instr[30], funct3}` en R; en I aritmética el bit 30 solo cuenta con `funct3 = 101`, así que un `addi` con inmediato negativo **no** es una resta) los cubre `control_unit_tb.v` (I-24) |
| Lógica de saltos (`branch_unit`) | I-29 | `branch_unit_tb.v` | `taken = branch & (zero ^ funct3[0])` para `beq` y `bne` con `zero` en 0 y en 1; `jal` y `jalr` siempre `redirect`; destino `pc + imm` y `(rs1 + imm) & ~1` (con bit 0 en 1 a la entrada); no salto → `redirect = 0` |
| Registro EX/MEM | I-30 | `ex_mem_reg_tb.v` | Igual que ID/EX (109 bits) |
| Memoria de datos (`dmem`) | I-32 | `dmem_tb.v` | `sb`, `sh`, `sw` con sus *byte enables* en cada alineación válida; little-endian; los bytes no escritos no cambian; accesos desalineados y fuera de rango con el comportamiento y los avisos `dmem_oob` y `dmem_misaligned` de `memoria.md` §6.1 y §6.2 (persisten, una burbuja o `enable = 0` no los levantan, el reset los borra); `READ_FIRST` en el ciclo de un store (`memoria.md` §3.2); un load entrega la palabra completa, porque la extensión es de I-35; `ena = 0` no lee ni escribe; carga y volcado por el puerto B; latencia de lectura de un ciclo en los dos puertos. El mapa de palabras usadas es de la Debug Unit (I-46, I-48; decisión [027](../decisiones/027_logica-de-mem-en-dmem.md)) |
| Etapa EX (`ex_stage`) | I-31 | `ex_stage_tb.v` | El cableado entre los módulos de EX, sobre todo lo que la traza no ve en M5: las 10 operaciones con operandos de registro, `addi` con inmediato negativo, `lui` (`alu_a = 0`), dirección de `lw` y `sw` con `store_data = rs2_val`; `beq` y `bne` tomados y no tomados, `jal` y `jalr` con `result = pc + 4`, y `redirect` / `redirect_pc` en todos los casos (no son campos de EX/MEM); forwarding `10` y `01` en A, en B, en los dos a la vez, en `store_data`, en el operando que el control descarta y en los saltos, y `11` como `00` (`pipeline.md` §5.6); `en = 0` conserva los 109 bits también con `flush = 1`; `flush` deja burbuja; reset con el core detenido; el bus `o_ex_mem_latch` igual a los campos; aleatorio con semilla fija contra un modelo de §5 y §2, con filas de la tabla de §4.4 |
| Registro MEM/WB | I-33 | `mem_wb_reg_tb.v` | Igual que ID/EX (110 bits) |
| Etapa MEM (`mem_stage`) | I-34 | `mem_stage_tb.v` | El cableado entre `dmem` y `mem_wb_reg` (`pipeline.md` §6.7), sobre todo lo que la traza no ve en M6: `mem_wb_read_data` llega con el resto de MEM/WB en el mismo flanco; `offset = result[1:0]`; un store seguido de un load a la misma dirección devuelve el dato escrito, también en `sb` y `sh` sobre una palabra con datos; `en = 0` conserva los 110 bits, `read_data` incluido, y no escribe; `flush` deja burbuja sin impedir el store; reset con el core detenido; avisos `dmem_oob` y `dmem_misaligned` a la salida; puerto B; el bus `o_mem_wb_latch` igual a los campos; aleatorio con semilla fija contra un modelo de memoria por bytes y de §2. Usa el IP: corre en xsim |
| Etapa WB (`wb_stage`) | I-35 | `wb_stage_tb.v` | Extensión de `lb`, `lbu`, `lh`, `lhu`, `lw` con bit de signo 0 y 1 y en cada posición del byte; elección entre resultado de EX y dato de memoria; `reg_write = 0` no escribe (`wb_reg_write` y `wb_rd` son copia de MEM/WB); registro `halted` (se activa solo con `valid & halt`, una burbuja con `halt = 1` o `enable = 0` no lo activan y no se desactiva hasta el reset, `pipeline.md` §7.3); aviso `imem_fault` con `pc ≥ 0x1000` y con `pc[1:0] ≠ 0` (persiste, una burbuja o `enable = 0` no lo levantan, el reset lo borra, `memoria.md` §6.2); reset con el core detenido; aleatorio con semilla fija contra un modelo de §7. El nombre sigue al de las otras etapas (`pipeline.md` §7.4); la decisión [027](../decisiones/027_logica-de-mem-en-dmem.md) lo llamaba `write_back` |

### 3.2 Riesgos (M8)

| Módulo | Issue | Testbench | Casos mínimos |
|---|---|---|---|
| Unidad de forwarding (`forwarding_unit`) | I-39 | `forwarding_unit_tb.v` | **Exhaustivo** sobre las condiciones de `pipeline.md` §10.2: cada combinación de `ex_mem_reg_write`, `mem_wb_reg_write`, coincidencia de `rd` con `rs1`/`rs2`; `rd = 0` nunca se reenvía; EX/MEM tiene prioridad sobre MEM/WB; `fwd_a` y `fwd_b` son independientes |
| Detección de carga-uso (`hazard_unit`) | I-41 | `hazard_unit_tb.v` | Coincidencia con `rs1` y con `rs2`; `rd = 0` no frena; `mem_read = 0` no frena; `if_id_valid = 0` no frena; falso positivo conocido: una palabra con el número de registro en el campo del inmediato (HALT, `lui`, `jal`) frena y es correcto ([011](../decisiones/011_deteccion-load-use.md)) |
| Enables y flush (`hazard_unit`) | I-42 | el mismo | Cada fila de la tabla de `pipeline.md` §10.4; **`en` gana sobre `flush`** (stall con HALT en ID); `stall = load_use & ~redirect` |

### 3.3 Debug Unit (M9)

| Módulo | Issue | Testbench | Casos mínimos |
|---|---|---|---|
| UART para debug | I-44 | `uart_tb.v` (existente, ampliado) | Los bytes de ida y vuelta con el divisor calculado como fija [003](../decisiones/003_baudrate-uart.md) (115200 baud, `DVSR` a partir de `CLK_FREQ_HZ`); recepción de tramas seguidas sin perder bytes |
| FSM de comandos | I-45 | `debug_cmd_fsm_tb.v` | Las tramas de ejemplo de `protocolo_debug.md` §4; checksum incorrecto; comando desconocido; **cada celda ✗ de la tabla de §3.7** responde `ERR_STATE` sin efectos; timeouts de la FPGA (§5); `LOAD` con `LEN` no múltiplo de 4 o fuera de `1…1024` → `ERR_LENGTH` |
| Carga de programa | I-46 | `debug_load_tb.v` | `LOAD` escribe `imem` y rellena el resto con HALT; deja `dmem` en cero y el mapa de palabras usadas vacío, con `dmem_used = 0` (decisión [004](../decisiones/004_carga-y-reprogramacion.md), `memoria.md` §7); reprogramar con un programa ya cargado y en cualquier estado; error durante la carga (`memoria.md` §4.3) |
| Modos de ejecución | I-47 | `debug_run_tb.v` | `RUN` hasta el HALT con `EVT_HALTED`; `STEP` avanza exactamente un ciclo; `STOP` detiene sin perder estado; **`STEP` en medio de un stall** continúa donde quedó; `RUN` y `STEP` repetido dan el mismo estado final |
| Volcado de estado | I-48 | `debug_dump_tb.v` | `READ_REGS`, `READ_LATCHES`, `READ_DMEM` (rango válido y `ERR_ADDR`), `READ_DMEM_USED`, `READ_ALL`: orden, tamaños y endianness del protocolo; mapa de palabras usadas (`memoria.md` §7): un `sb`/`sh` marca la palabra completa, un store fuera de rango marca la de su alias y un load no marca nada; los latches coinciden con los registros de segmentación del core, bit a bit, según `pipeline.md` §8 |


## 4. Programas de prueba (`sw/`)

Cada programa es un archivo `sw/<nombre>.s` con su `sw/<nombre>.exp` al lado (§5). La
extensión es `.s` porque es la que usan el ensamblador ([017](../decisiones/017_ensamblador.md))
y la interfaz de la PC. Las convenciones completas, la lista con el detalle de cada programa
y cómo agregar uno están en [`sw/README.md`](../../sw/README.md) (decisión
[019](../decisiones/019_programas-de-prueba.md)).

Reglas para todos:

- Terminan en HALT. Código desde `0x0000_0000`, datos desde `0x000`, como fija
  [`memoria.md`](memoria.md) §2.2.
- Los datos se arman con stores en tiempo de ejecución: no hay sección `.data`.
- Cada programa prueba **una cosa**, y lo dice en un comentario inicial. Un programa que falla
  tiene que decir qué mecanismo se rompió.
- Usan accesos alineados y dentro de rango, salvo `mem_avisos`, que existe para lo contrario.

### 4.1 Una cosa por tipo de instrucción

| Programa | Qué ejercita |
|---|---|
| `alu_r` | `add sub sll srl sra and or xor slt sltu` con operandos 0, positivos, negativos y el máximo |
| `alu_i` | `addi andi ori xori slti sltiu` con inmediato negativo; `sltiu` contra `-1` (se extiende con signo y se compara sin signo) |
| `shifts` | `slli srli srai` con `shamt` 0, 1 y 31; `sll srl sra` con `rs2 ≥ 32` (cuenta solo los 5 bits bajos) |
| `lui` | `lui` y la composición de una constante de 32 bits con `lui` + `addi` (incluido `addi` con inmediato negativo) |
| `mem_palabra` | `sw` y `lw` en `0x000`, en `0xFFC` y con base distinta de `x0` y desplazamiento negativo |
| `mem_byte_media` | `sb sh lb lbu lh lhu` con datos de bit alto en 0 y en 1, en cada posición del byte; orden little-endian; los bytes vecinos no se tocan |
| `branch_cond` | `beq` y `bne`, tomados y no tomados, hacia adelante y hacia atrás |
| `jump` | `jal` con `rd ≠ x0` y con `rd = x0`; `jalr` como retorno de función; `jalr` con el bit 0 de la dirección en 1 (se pone en 0) |
| `halt_basico` | HALT con instrucciones detrás que **no** deben ejecutarse |
| `mem_avisos` | Accesos desalineados y fuera de rango; el programa termina y los avisos quedan activos (`memoria.md` §6) |

### 4.2 Un programa por caso de riesgo

Es la lista de `pipeline.md` §10.7. Cada línea de esa lista tiene su programa:

| Caso de §10.7 | Programa |
|---|---|
| Forwarding desde EX/MEM (distancia 1), en `rs1` y en `rs2` | `fwd_exmem` |
| Forwarding desde MEM/WB (distancia 2), en `rs1` y en `rs2` | `fwd_memwb` |
| Las dos instrucciones anteriores escriben el mismo registro (gana EX/MEM) | `fwd_prioridad` |
| Destino `x0` en la instrucción anterior (no se reenvía). Además, una instrucción que no escribe (`reg_write = 0`) tampoco se reenvía (§10.2) | `fwd_x0` |
| Dependencia a distancia 3 (bypass del banco) | `bypass_banco` |
| Load-use en `rs1` y en `rs2` | `loaduse_rs1_rs2` |
| Load seguido de `sw` que guarda el dato; load seguido de `beq` y de `jalr` | `loaduse_sw_beq` |
| Load seguido de una instrucción que no depende de él (sin stall) | `load_sin_dep` |
| Salto tomado y no tomado, `jal` y `jalr`; salto que depende de la instrucción anterior | `branch_cond`, `jump`, `salto_depende` |
| Stall con un HALT en ID | `halt_stall` |
| `STEP` en medio de un stall | `loaduse_rs1_rs2` ejecutado en modo `STEP` (nivel 4, §3.3) |

Además:

| Programa | Qué ejercita |
|---|---|
| `halt_camino_equivocado` | Un salto tomado que pasa por encima de un HALT: ese HALT estaba en el camino equivocado y no debe detener el procesador (`pipeline.md` §3.4) |
| `mixto_lazo` | Un programa corto realista (por ejemplo, sumar un arreglo armado con stores) que mezcla lazo, loads, stores y dependencias. Es la prueba de humo de la regresión |

Son 22 programas. Para saber si falta alguno: **toda instrucción de `isa.md` aparece en al menos
un programa** (la lista de §4.1 cubre las 32 más HALT) y **toda línea de §10.7 tiene su programa**
(la tabla de §4.2). Si se agrega un mecanismo nuevo, se agrega su programa en el mismo cambio.
`python -m pytest sw` comprueba las dos condiciones y que cada programa tenga su `.exp`.

### 4.3 Programas para las etapas intermedias

Los 22 programas necesitan el pipeline completo. Para las etapas anteriores hay dos grupos más
(detalle en [`sw/README.md`](../../sw/README.md) §4 y §5):

| Programas | Para qué nivel | Qué tienen de distinto |
|---|---|---|
| `indep_alu_r`, `indep_alu_i`, `indep_cargas`, `indep_stores`, `indep_store_load`, `indep_saltos`, `indep_lui` | 2, de IF a MEM (M3 a M6), antes de que exista WB | Ninguna instrucción lee un registro que escribe otra: parten de un **estado inicial** de registros y de `dmem` (`sw/estado_inicial/`, en formato `$readmemh`) y cada resultado se ve en el registro de segmentación de su etapa |
| `<nombre>_nops`, de los programas de riesgos y de saltos | 3 sin riesgos (I-38, M7): pipeline completo sin forwarding, stall ni flush | Llevan `nop` para que toda dependencia quede a distancia 3 y detrás de cada salto haya dos `nop`. Mismo estado final que el original y los mismos ciclos en M7 y en M8 |

En I-38 se corren los programas sin riesgos de §4.1 y §4.2 y las variantes `_nops`; desde I-42,
todos (I-43 suma los mutantes del resto de los mecanismos, §6). Entre medio, cada integración de M8 compara contra el modelo con los
mecanismos que ya tiene el RTL (decisión [029](../decisiones/029_modo-del-modelo-en-m8.md)):
desde I-39, `--modo forwarding` (forwarding sin stall ni flush), con los 27 de M7 y los
originales que solo necesitan forwarding: `fwd_exmem`, `fwd_memwb`, `fwd_prioridad` y
`load_sin_dep` (lista `FORWARDING` de `sw/programas.py`). Ninguno de esos 31 tiene un salto
que lea un registro escrito por una de las dos instrucciones anteriores: el forwarding hacia
`beq`, `bne` y `jalr` lo prueba `salto_depende`. Como sus saltos se toman, hasta el flush (I-42)
se compara solo su traza, sin `+FINAL` (§8.2): está en la regresión `forwarding` por la lista
`SOLO_TRAZA_FORWARDING` (decisión [030](../decisiones/030_corridas-solo-traza.md)). Con `+FINAL`
entra junto con el flush (decisión 029). Con esa regresión, I-40 cierra el forwarding. Los demás
originales también usan forwarding, pero además necesitan el stall o el flush.
Desde I-41 la traza sale de `--modo forwarding_stall` (forwarding y stall, sin flush): la lista
`FORWARDING_STALL` suma a esos 31 los que solo necesitan el stall, `loaduse_rs1_rs2` y
`halt_stall` (`SOLO_STALL`), y `loaduse_sw_beq` se compara solo contra la traza, como
`salto_depende` (`SOLO_TRAZA_FORWARDING_STALL`): es el único load seguido de un salto que usa el
dato, y su `beq` se toma. Quedan para el flush `branch_cond`, `jump`, `mixto_lazo` y
`halt_camino_equivocado`.
Desde I-42 (flush por saltos) el RTL tiene los tres mecanismos y la traza sale de
`--modo completo`: la lista `COMPLETO` son los 39 programas de `sw/`, todos con `+FINAL`. Suma
a `FORWARDING_STALL` los que solo esperaban el flush (`SOLO_FLUSH`: `branch_cond`, `jump`,
`mixto_lazo` y `halt_camino_equivocado`) y pasa `salto_depende` y `loaduse_sw_beq` a `+FINAL`,
porque con el flush el camino equivocado ya no se ejecuta. Así la regresión de `master` ya
corre todos los programas; I-43 la cierra con los mutantes del resto de los mecanismos (§6),
los testbenches unitarios (decisión [032](../decisiones/032_testbenches-unitarios-en-la-regresion.md))
y la tabla de ciclos por programa (§8.8).
`halt_stall` y `halt_camino_equivocado` no tienen variante: lo que prueban es la interacción
del HALT con el stall y el flush.

---

## 5. Estado final esperado (`.exp`)

**Todo programa de `sw/` tiene que venir con su estado final esperado de registros y memoria**,
en un archivo `sw/<nombre>.exp` al lado del `.s`. Un programa sin `.exp` no cuenta como prueba:
se puede ejecutar, pero no hay contra qué compararlo.

Este documento fija **qué** tiene que decir cada `.exp` y **en qué formato**, no el valor concreto
de cada programa. Los valores se escriben junto con cada programa, en la I-15 (programas de
prueba), porque dependen de las instrucciones exactas que se elijan; calcularlos antes de que los
programas existan sería adivinar. La regla de §2 se mantiene: el `.exp` se calcula a mano desde
`isa.md`, no copiando la salida del modelo ni del RTL.

Ejemplo del formato, con una versión reducida de `loaduse_rs1_rs2` (un `lw` seguido de un uso
inmediato):

```
# ejemplo: fragmento de sw/loaduse_rs1_rs2.s
#   addi x1, x0, 42
#   sw   x1, 8(x0)
#   lw   x5, 8(x0)
#   add  x6, x5, x5      <- usa x5 enseguida: 1 stall
#   halt
regs:
  x1 = 0x0000002A
  x5 = 0x0000002A
  x6 = 0x00000054
dmem:
  0x008 = 0x0000002A
halted = 1
pipeline_vacio = 1
avisos = ninguno
ciclos = 10          # n = 5, + 4 de llenado, + 1 stall
```

Qué se compara y cómo:

| Campo | Se compara | Regla |
|---|---|---|
| `regs` | Los 32 registros | Los que no se listan **valen 0**. Así un registro escrito por error hace fallar la prueba |
| `dmem` | Toda la memoria de datos | Las palabras que no se listan **valen 0** (`LOAD` deja `dmem` en cero, decisión [004](../decisiones/004_carga-y-reprogramacion.md)). Dirección en bytes, siempre alineada |
| `halted` | El registro `halted` | Siempre 1 |
| `pipeline_vacio` | Los cuatro `valid` | Siempre 1: en el primer ciclo con `halted = 1` los cuatro `valid` valen 0 (`pipeline.md` §7.3). Es el requisito de la consigna de que el pipeline termine vacío |
| `avisos` | `imem_fault`, `dmem_oob`, `dmem_misaligned` | `ninguno` o la lista de los que quedan activos |
| `ciclos` | Ciclos con `enable = 1` | Fórmula de abajo |

### Cuántos ciclos tarda un programa

```
ciclos = n + 4 + stalls + 2 · saltos_tomados
```

- **`n`** es la cantidad de instrucciones **ejecutadas** (no escritas), con el HALT incluido. Un
  lazo de 3 vueltas cuenta sus instrucciones 3 veces; lo que se saltó no cuenta.
- **`+ 4`** es el llenado del pipeline: la última instrucción (el HALT) entra a IF en el ciclo
  `n` y llega a WB 4 ciclos después.
- **`stalls`** es la cantidad de load-use detectados, uno por cada uno (`pipeline.md` §10.3).
  Cuentan también los falsos positivos de la comparación conservadora: un `lw x1, …` justo antes
  del HALT frena un ciclo porque la palabra del HALT tiene un 1 en el campo `rs2`.
- **`saltos_tomados`** son los `beq`/`bne` tomados más los `jal` y `jalr`, 2 ciclos cada uno
  (`pipeline.md` §10.5). Un salto no tomado cuesta 0.

El conteo termina en el ciclo en que el HALT está en WB, que es el último con `enable = 1`. Es el
campo `cycles` del bloque de estado de la Debug Unit (`protocolo_debug.md` §3.1), así que la misma
cifra sirve en simulación y en la placa. Para que coincida, la Debug Unit tiene que dejar de
contar cuando `halted` pasa a 1 (I-47).

**Por qué verificar los ciclos.** Los resultados de un programa son los mismos con o sin
forwarding bien hecho si el procesador frena de más: solo cambia el tiempo. Contar ciclos es la
única forma de comprobar que el stall dura un ciclo, que un salto cuesta 2 y que el forwarding
evita frenar. Un procesador "correcto pero lento" pasa las pruebas de estado y falla estas.

El valor `ciclos` se calcula a mano contando `n`, los stalls y los saltos del programa, y el
modelo de referencia tiene que dar el mismo número (§2).

---

## 6. Criterio de aprobación

Todo testbench es **autoverificable**: dice solo si pasó o falló, sin que nadie mire ondas. Mirar
las ondas sirve para depurar un fallo, no para aprobar.

**`$error` o contador.** El esquema habitual para esto es llamar a `$error` en cada fallo y a
`$finish` al terminar. Pero `$error` es una tarea de **SystemVerilog** (IEEE 1800), y los
testbenches del proyecto están en **Verilog** (`.v`): `scripts/create_project.tcl` solo agrega
`tb/unit/*.v` y `tb/integration/*.v`. Por eso se usa el mismo mecanismo que ya tienen
`alu_tb.v` y `uart_tb.v`: un **contador de errores** y una **línea final `TEST PASSED` /
`TEST FAILED`**, seguida de `$finish`, como fija la decisión
[010](../decisiones/010_convenciones-rtl.md) (sección *Testbenches*). Cumple la misma función que `$error`: cada fallo queda
registrado en la consola y el veredicto no depende de mirar ondas. Si algún día los testbenches
pasan a `.sv`, la `task` de la regla 1 puede llamar además a `$error` sin cambiar nada más.

Reglas (las de la decisión 010 y `tb/unit/_plantilla_tb.v`):

1. **Cada comparación** entre lo obtenido y lo esperado pasa por la `task` `chk` de la plantilla:
   suma 1 a `checks`, y si difieren suma 1 a `errors` e imprime una línea con `ERROR`, el nombre
   del caso, lo obtenido y lo esperado:
   `[<tiempo>] ERROR <caso> | dut=0x<…> esperado=0x<…>`.
2. **Al final**, el testbench imprime exactamente una de estas dos líneas con `$display` y llama a
   `$finish`:

   ```
   TEST PASSED: <n> chequeos, 0 errores
   TEST FAILED: <e> errores sobre <n> chequeos
   ```

3. **Un watchdog** corta la simulación si no termina en una cantidad máxima de ciclos
   (`MAX_CYCLES`) e imprime `TEST FAILED: timeout de <N> ciclos`. Un procesador que no llega al HALT no puede
   dejar la simulación colgada.
4. Los estímulos aleatorios usan **semilla fija**, así un fallo se puede repetir.
5. Un testbench de módulo con una interfaz que admite barrido exhaustivo (el decodificador de
   control, la unidad de forwarding) **lo hace**: se prueban todas las combinaciones, no una
   muestra.

Cuándo se considera aprobado cada nivel:

| Nivel | Aprobado cuando |
|---|---|
| 1. Unitario | Imprime `TEST PASSED` y cubre todos los casos mínimos de §3 |
| 2. Por etapa | Para todos los programas de `sw/` que la etapa ya puede ejecutar, cada registro de segmentación de las etapas integradas coincide con la traza del modelo en **todos** los ciclos (campos de `pipeline.md` §8, incluidos `valid` y las señales de control), comparando los bits que marca la máscara del modelo: en una burbuja, solo `valid` y el control ([`tools/isasim`](../../tools/isasim/README.md) §3). Hasta M7 el modelo corre en modo `sin_riesgos`; en M8, en el modo con los mecanismos ya integrados (§4.3) |
| 3. Core completo | Para los 22 programas, el estado final coincide con el `.exp` en todos los campos de §5, incluido `ciclos` |
| 4. Debug Unit | Imprime `TEST PASSED` y cada programa da el mismo estado final con `RUN` que con `STEP` repetido |
| 5. Placa | Para los 22 programas cargados con `LOAD`, el volcado de `READ_ALL` coincide con el `.exp` |

**Regresión.** La regresión (I-43) corre todos los testbenches y todos los programas y la
aprobación es única: ningún `TEST FAILED` (el timeout también lo imprime). Se corre completa antes de integrar a
`master` un cambio de RTL. Los testbenches se corren en modo por lotes de `xsim` y el resultado se
decide leyendo la línea final, que es lo que permite automatizarlo. Lo hace `scripts/regresion.tcl`
(§8.7): `pipeline_tb` con cada programa y, en la regresión normal, cada testbench de `tb/unit/`
(decisión [032](../decisiones/032_testbenches-unitarios-en-la-regresion.md)).

**Que la prueba pueda fallar.** Para cada mecanismo de riesgo (forwarding, bypass del banco,
stall, flush de saltos, parada por HALT), al menos una vez se lo desactiva a propósito en el RTL y
se comprueba que algún programa pasa a `TEST FAILED`. Si nada falla, los programas no cubren ese
mecanismo y hay que agregar uno. Los mutantes están en `scripts/mutantes.py` y se corren con
`regresion.py --mutante` (§8.7, decisión [031](../decisiones/031_mutantes-de-la-regresion.md)).
I-40 lo hace para el forwarding (§8.2); I-43, para el resto y con todos los programas (§8.2,
*Regresión completa*).

---

## 7. Convenciones de nombres

**Archivos**

| Qué | Nombre | Ejemplo |
|---|---|---|
| Testbench de un módulo | `tb/unit/<módulo>_tb.v`, módulo superior `<módulo>_tb` | `tb/unit/regfile_tb.v` |
| Banco de pruebas incremental (niveles 2 y 3) | `tb/integration/pipeline_tb.v`, un único testbench para todas las etapas; el programa se elige con `+DIR` (§8) | — |
| Archivos que lee el banco | `build/tb/<nombre>/`, generados por `scripts/prep_tb.py`; **no se versionan** | `build/tb/indep_alu_r/` |
| Programa de prueba | `sw/<nombre>.s`, en minúsculas y `_` | `fwd_exmem.s` |
| Programa con instrucciones independientes (§4.3) | `sw/indep_<grupo>.s` | `indep_cargas.s` |
| Variante con `nop` para M7 (§4.3) | `sw/<nombre>_nops.s` | `fwd_exmem_nops.s` |
| Estado esperado | `sw/<nombre>.exp` | `fwd_exmem.exp` |
| Estado inicial de los `indep_*` | `sw/estado_inicial/regs.hex` y `dmem.hex` | — |
| Memoria generada por el ensamblador | `sw/<nombre>.hex`, `.bin`, `.coe`, `.lst`; **no se versiona** (se regenera desde el `.s`) | — |

Las salidas del ensamblador no entran al repositorio porque se generan: versionarlas
duplicaría el programa y podrían quedar desactualizadas respecto del `.s`.

**Señales dentro de un testbench**

| Qué | Prefijo o nombre | Ejemplo |
|---|---|---|
| Instancia del módulo bajo prueba | `u_dut` | — |
| Señal que maneja una entrada del DUT | `tb_` + nombre del puerto sin `i_` | `tb_flush` → `.i_flush` |
| Señal conectada a una salida del DUT | `tb_` + nombre del puerto con `o_` | `tb_o_fwd_a` ← `.o_fwd_a` |
| Reloj y reset | `tb_clk`, `tb_rst` (a `.i_clk`, `.i_rst`) | — |
| Valor esperado | `exp_` + nombre | `exp_fwd_a` |
| Valor del modelo de referencia | `ref_` + nombre | `ref_if_id_instr` |
| Contadores | `errors`, `checks` | — |
| Señal interna del core que el testbench mira | con el nombre de `pipeline.md` §2 y referencia jerárquica | `u_dut.if_id_valid`, `u_dut.ex_mem_result` |

**Por qué los mismos nombres que `pipeline.md`.** Los registros de segmentación se comparan por
nombre contra la traza del modelo y contra el volcado de `READ_LATCHES`. Si el testbench
renombrara las señales, cada comparación necesitaría una tabla de traducción que se desactualiza.

**Formato común**

- Se parte de `tb/unit/_plantilla_tb.v`: `` `timescale 1ns / 1ps``, reloj de 10 ns (`T_CLK`,
  100 MHz, el oscilador de la Basys 3), `task chk`, watchdog y línea final.
- Los mensajes `ERROR` y la línea final de §6 son iguales en todos los testbenches, porque es lo
  que se busca en el log de xsim.
- Un encabezado de comentario que dice qué módulo prueba, contra qué se compara y qué casos
  cubre.
- `exp_` y `ref_` no están en la plantilla: se agregan acá para los testbenches que comparan
  contra un valor calculado o contra el modelo de referencia.

---

## 8. Banco de pruebas incremental (`pipeline_tb`)

Un único testbench, `tb/integration/pipeline_tb.v` (I-17), valida cada etapa al integrarla y
queda como regresión de las siguientes. Compara los registros de segmentación contra la
traza del modelo de referencia (nivel 2) y, con `+FINAL`, el estado final contra el `.exp`
escrito a mano (nivel 3). El porqué de cada elección está en la decisión
[021](../decisiones/021_banco-incremental.md).

### 8.1 Uso

```sh
# 1. Preparar el programa: ensambla, corre el modelo y convierte el .exp
python scripts/prep_tb.py sw/indep_alu_r.s --modo sin_riesgos   # RTL de M3 a M7
python scripts/prep_tb.py sw/fwd_exmem.s --modo forwarding       # RTL de I-39 e I-40
python scripts/prep_tb.py sw/fwd_exmem.s --modo forwarding_stall # RTL de I-41
python scripts/prep_tb.py sw/fwd_exmem.s                         # --modo completo, desde I-42
```

Cada modo describe el RTL de una integración (§4.3, decisión
[029](../decisiones/029_modo-del-modelo-en-m8.md)), y desde I-42 el de `master` es `completo`.
Los otros sirven con el commit de su integración (§8.7).

`prep_tb.py` escribe en `build/tb/<nombre>/` los archivos de la tabla y, al final, la línea
para pasarle el directorio a xsim:

| Archivo | Contenido |
|---|---|
| `imem.hex` | El programa, 1024 palabras rellenas con HALT (como `LOAD`) |
| `regs_init.hex`, `dmem_init.hex` | Estado inicial: `sw/estado_inicial/` para los `indep_*`, ceros para el resto |
| `modelo.ciclo.<latch>.hex`, `.mask.hex` | Traza por ciclo del modelo y su máscara (decisión [020](../decisiones/020_modelo-de-referencia.md)) |
| `modelo.traza.txt` | La misma traza, legible: sirve para depurar un fallo |
| `corte.hex` | Líneas de la traza, ciclo en que el HALT llega a cada latch y ciclo del primer salto tomado (§8.3) |
| `exp_regs.hex`, `exp_dmem.hex`, `exp_misc.hex` | El `.exp` **escrito a mano**, convertido a `$readmemh` (no la salida del modelo, §2) |

```sh
# 2. Simular: el directorio va por plusarg, con ruta absoluta
xsim <snapshot> --runall -testplusarg "DIR=C:/.../build/tb/indep_alu_r"
xsim <snapshot> --runall -testplusarg "DIR=..." -testplusarg FINAL     # + estado final (desde M7)
```

En el proyecto de Vivado, el plusarg va en *Simulation Settings → xsim.simulate.xsim.more_options*
(`prep_tb.py` imprime el `set_property` listo para la consola Tcl). La ruta es absoluta porque
xsim corre en `build/vivado_<diseño>/…/xsim`.

| Plusarg | Efecto |
|---|---|
| `DIR=<ruta>` | Directorio de `prep_tb.py`: una corrida. Obligatorio si no hay `LISTA` |
| `LISTA=<archivo>` | Varias corridas en la misma simulación (decisión [033](../decisiones/033_varias-corridas-por-simulacion.md)), una por línea: etiqueta, directorio (ruta absoluta, sin espacios), `final` y `pausas` (0 o 1) y semilla. Antes de cada una imprime `CORRIDA <etiqueta>`, la corre como si fuera con `DIR` (vuelve a cargar todo con el core en reset, como `LOAD`, y pone en cero los contadores, el watchdog y la semilla) y termina con su línea `TEST`. Al final imprime `LISTA: n de m corridas con TEST PASSED`. La escribe `regresion.tcl` (§8.7) |
| `FINAL` | Al terminar la traza, sigue hasta `halted` y compara el estado final (necesita `STAGE_WB`) |
| `PAUSAS=<semilla>` | Entre ciclos de la traza baja `enable` de 1 a 3 ciclos al azar (en promedio una pausa cada 4 ciclos) y comprueba que ningún latch integrado cambia, ni `halted` ni los avisos (con `STAGE_WB`). Después la traza tiene que seguir coincidiendo, y así se detecta un elemento con estado que no respeta `enable` (decisión [018](../decisiones/018_paso-a-paso-sin-clock.md)). Las pausas no cuentan para el watchdog ni para `ciclos` |

Parámetro `MAX_CYCLES` (por defecto 2000): watchdog sobre los ciclos con `enable = 1` de cada
corrida. La carga y la lectura final no cuentan. Un timeout, o un archivo de `prep_tb.py` que
falta, terminan la corrida con `TEST FAILED`. Con `LISTA`, la simulación sigue con la próxima.

### 8.2 Etapas integradas

Cada integración agrega su define al principio de `pipeline_tb.v` (o con `-d` en xvlog). Son
acumulativos: definir uno define los anteriores. `STAGE_IF` está siempre.

| Define | Issue | Qué agrega al banco |
|---|---|---|
| `STAGE_IF` | I-22 | Compara IF/ID; carga `imem` por el puerto B |
| `STAGE_ID` | I-27 | Compara ID/EX; carga el banco de registros por jerarquía (`` `REGFILE ``) al soltar el reset y lo lee por el puerto de la Debug Unit antes del ciclo 1 |
| `STAGE_EX` | I-31 | Compara EX/MEM |
| `STAGE_MEM` | I-34 | Compara MEM/WB; carga `dmem` por el puerto B y, al terminar la traza, la compara con el `.exp` (§8.3) |
| `STAGE_WB` | I-35 | Habilita `+FINAL` (registros, `dmem`, `halted`, avisos y ciclos; `pipeline_vacio` recién con `STAGE_HALT`, §8.3) |
| `STAGE_REDIRECT` | I-36 | Sin corte por saltos (§8.3) |
| `STAGE_HALT` | I-37 | Sin corte por HALT: se comparan todas las líneas, foto final incluida. Con `+FINAL` compara `pipeline_vacio` y `pc_reg`, y sigue unos ciclos después de `halted` |

**Correr un nivel anterior.** Con `-d STAGES_CLI` el banco ignora los defines del archivo y las
etapas salen solo de la línea de comandos (`-d STAGES_CLI` solo es IF; `-d STAGES_CLI -d STAGE_ID`
es hasta ID). Sirve para la regresión de las etapas ya integradas con los programas que la etapa
nueva todavía no puede ejecutar, sin editar el archivo. Por ejemplo, con `STAGE_ID` y sin WB,
ID/EX solo coincide con la traza en los `indep_*`, `halt_basico` y `jump_nops`. En los demás,
alguna instrucción lee un registro que escribió otra, y sin WB el banco no cambia: fallan en
`id_ex.rs1_data` o `id_ex.rs2_data` hasta I-35. Su IF/ID se sigue comparando con
`-d STAGES_CLI`. Con `STAGE_EX` y con `STAGE_MEM` pasan los mismos programas: EX/MEM sale de
ID/EX, y sin forwarding (I-39) ni WB no tiene otra fuente. Desde I-34 la lista incluye
`indep_store_load`.

**Con `STAGE_WB`** el banco de registros cambia y ID/EX coincide con la traza en todos los
programas que el modelo acepta en `--modo sin_riesgos` (`prep_tb.py` no da error): los que no
tienen riesgos a distancia menor que 3 y las variantes `_nops`. Sin `STAGE_REDIRECT`, `+FINAL`
solo sirve para los que no tienen un salto tomado (`corte.hex` con `redirect = 0`): `alu_i`,
`alu_r`, `bypass_banco`, `fwd_exmem_nops`, `fwd_memwb_nops`, `fwd_prioridad_nops`, `fwd_x0`,
`halt_basico`, `indep_alu_i`, `indep_alu_r`, `indep_cargas`, `indep_lui`, `indep_store_load`,
`indep_stores`, `load_sin_dep_nops`, `loaduse_rs1_rs2_nops`, `lui`, `mem_byte_media`,
`mem_palabra` y `shifts`. `halt_stall` coincide con la traza pero no con el `.exp` hasta I-41:
su `ciclos` cuenta el stall del `lw x1` antes del HALT (§5). Ninguno de estos programas levanta
`imem_fault`: hasta I-36 ese aviso lo cubre solo `wb_stage_tb`.

**Con `STAGE_REDIRECT`** el salto tomado cambia el PC, pero sin flush hasta I-42: las dos
instrucciones que entraron detrás se ejecutan, como en `--modo sin_riesgos`. Se comparan
completos los programas con saltos tomados y `+FINAL` suma `branch_cond_nops`, `indep_saltos`,
`jump_nops`, `loaduse_sw_beq_nops`, `mem_avisos`, `mixto_lazo_nops` y `salto_depende_nops`.
`mem_avisos` es el que levanta `imem_fault`: su `jalr` salta a `0x1030`. `branch_cond` y
`halt_camino_equivocado` coinciden con la traza pero no con el `.exp` hasta I-42: sin flush
ejecutan el camino equivocado.

**Con `STAGE_HALT`** detrás del HALT solo entran burbujas, y la traza se compara entera: pasan
los 30 programas que prepara `prep_tb.py`, con saltos tomados o sin ellos. Con `+FINAL` pasan
los 20 de la lista de arriba y los 7 de `STAGE_REDIRECT`, ahora también en `pipeline_vacio`, y
`halt_stall` sigue fallando solo en `ciclos`. Además, con `+FINAL`:

- **`pc_reg`** (`o_pc`) tiene que valer la dirección del HALT + 4 (`pipeline.md` §3.4). La
  dirección del HALT es el `pc` de MEM/WB en la traza, en el primer ciclo con el HALT ahí.
- **`halted` sostiene la parada.** El banco sigue 5 ciclos con `enable = 1` después de
  `halted`: en cada uno los cuatro `valid` tienen que seguir en 0 y `pc_reg` no puede cambiar.
  Los registros y `dmem` se comparan después, así que tampoco se escribió nada. Sin el término
  `halted` de `stop_fetch`, el PC vuelve a avanzar en cuanto el HALT sale de WB. Así el core no
  depende de en qué ciclo baje `enable` la Debug Unit.

**Con la unidad de forwarding (I-39)** el banco no cambia y no hay define nuevo: lo que cambia
es el modo de la traza. El RTL ya no coincide con `--modo sin_riesgos` en 10 de los 27
programas de M7, aunque el estado final es el mismo. La unidad compara `rs1` y `rs2` aunque la
instrucción no los use (`pipeline.md` §10.2), así que un `addi` o el HALT (`rs2 = 1`) reciben
un valor reenviado en `ex_mem_store_data` o en `result`, que nadie usa, y la máscara compara
esos campos en toda instrucción válida. Por eso desde I-39 la traza sale de `--modo forwarding`
(decisión [029](../decisiones/029_modo-del-modelo-en-m8.md)). Con `+FINAL` pasan los 31 programas
de la lista `FORWARDING`, entre ellos `fwd_exmem`, `fwd_memwb`, `fwd_prioridad` y
`load_sin_dep` sin `nop`.

**Forwarding hacia los saltos (I-40).** `salto_depende` corre en `--modo forwarding` **sin**
`+FINAL`, como `branch_cond` desde `STAGE_REDIRECT`: sin flush, el RTL y el modelo ejecutan las
dos instrucciones del camino equivocado (`x20`, `x21` y `x22` quedan en 2), así que la traza
coincide, pero el `.exp` no hasta I-42. `regresion.py` lo suma a la regresión `forwarding` sin
`FINAL` (lista `SOLO_TRAZA_FORWARDING`, decisión [030](../decisiones/030_corridas-solo-traza.md)),
y pasa los 24 ciclos de la traza, con y sin `+PAUSAS=47`.

**Que la prueba pueda fallar (I-40, §6).** Los mutantes son los de `scripts/mutantes.py`
(decisión [031](../decisiones/031_mutantes-de-la-regresion.md)). Con `sin_forwarding`
(`fwd_a = fwd_b = FWD_ID_EX` en `riscv_core`), `python scripts/regresion.py --pausas 47
--mutante sin_forwarding` y `regresion.tcl` dan en xsim `fallan 30 de 64 corridas`: 15 programas,
con y sin `+PAUSAS`. Diez son de M7 (`alu_r`, `shifts`, `mem_palabra`, `halt_basico`, `fwd_x0`,
`bypass_banco`, `fwd_memwb_nops`, `loaduse_rs1_rs2_nops`, `branch_cond_nops` y
`mixto_lazo_nops`), por los campos sin usar (decisión
[029](../decisiones/029_modo-del-modelo-en-m8.md)). Los otros cinco fallan por un resultado
equivocado. Son los cuatro de `SOLO_FORWARDING` (en `fwd_exmem`, el `addi x2, x1, 5` deja `0x5`
en vez de `0xF`) y `salto_depende`, que falla en el ciclo 8: el `beq x3, x2` compara sin el `x3`
de EX/MEM y `ex_mem.result` da `0xFFFFFFFA` en vez de `0x0`.

Los otros 15 mutantes rompen de a una las reglas de `pipeline.md` §10.2 en `forwarding_unit`,
por separado en `fwd_a` y en `fwd_b` cuando la regla es de una sola salida. Con
`--mutante` de cada uno, sin `--pausas` (32 corridas), todos hacen fallar al menos una:

| Mutante | Fallan | Programas que lo detectan |
|---|---|---|
| `fwd_prioridad` (MEM/WB antes que EX/MEM) | 1 | `fwd_prioridad` |
| `fwd_rd0_ex_mem`, `fwd_rd0_mem_wb` (se reenvía con `rd = x0`) | 3 | `fwd_x0`, `mem_avisos`, `jump_nops` |
| `fwd_reg_write_ex_mem` (se reenvía sin `reg_write`) | 4 | `fwd_x0`, `bypass_banco`, `mem_byte_media`, `indep_store_load` |
| `fwd_reg_write_mem_wb` | 5 | `fwd_x0`, `mem_byte_media`, `mem_avisos`, `loaduse_rs1_rs2_nops`, `indep_stores` |
| `fwd_a_ex_mem_con_rs2`, `fwd_b_ex_mem_con_rs1` | 12 | `fwd_exmem`, `fwd_memwb`, `fwd_prioridad`, `salto_depende` y 8 más |
| `fwd_a_mem_wb_con_rs2` | 5 | `fwd_memwb`, `fwd_prioridad`, `load_sin_dep`, `salto_depende`, `halt_basico` |
| `fwd_b_mem_wb_con_rs1` | 6 | los mismos y `mem_palabra` |
| `fwd_a_sin_mem_wb`, `fwd_a_codigo_mem_wb` | 3 | `fwd_memwb`, `load_sin_dep`, `salto_depende` |
| `fwd_b_sin_mem_wb`, `fwd_b_codigo_mem_wb` | 4 | `fwd_memwb`, `load_sin_dep`, `mem_palabra`, `halt_basico` |
| `fwd_a_codigo_ex_mem` (`FWD_WB` cuando coincide EX/MEM) | 3 | `fwd_exmem`, `fwd_prioridad`, `salto_depende` |
| `fwd_b_codigo_ex_mem` | 12 | `fwd_exmem`, `fwd_memwb`, `fwd_prioridad`, `salto_depende` y 8 más |

La prioridad la detecta solo `fwd_prioridad`, que es el programa que existe para eso (§4.2).
`reg_write` lo detecta `fwd_x0`: su `sw` del final tiene en el campo `rd` el mismo registro que
leen las dos instrucciones siguientes (§4.2). Antes de agregarlo, ese mutante lo detectaban solo
programas que no se escribieron para eso, y bastaba con cambiarles los registros para perderlo.

**Con el stall de carga-uso (I-41)** el banco no cambia y no hay define nuevo: la traza sale de
`--modo forwarding_stall` (§4.3). `hazard_unit` (`pipeline.md` §10.3) frena un ciclo a la
instrucción que usa el dato de un load, y el dato le llega después desde MEM/WB. Con `+FINAL`
pasan los 33 programas de la lista `FORWARDING_STALL`, entre ellos `loaduse_rs1_rs2` y
`halt_stall`, que ahora coincide también en `ciclos`. `loaduse_sw_beq` corre sin `+FINAL`, como
`salto_depende`. Su `beq` se toma y, sin flush, el RTL y el modelo ejecutan el `addi x20` del camino
equivocado: la traza coincide, pero el `.exp` difiere en `x20` hasta I-42 (decisión
[030](../decisiones/030_corridas-solo-traza.md)). La regresión `forwarding_stall` pasa las 70
corridas, con y sin `+PAUSAS=47`.

**Pausas en medio de un stall.** Con `enable = 0` nada cambia, y al volver a 1 el stall se
recalcula igual (`pipeline.md` §10.4). Para que `+PAUSAS` lo pruebe, alguna pausa tiene que caer en
un ciclo de stall, y eso depende de la semilla. Con la semilla 47 cae en el ciclo 11 de
`loaduse_rs1_rs2` (el `sub x8, x0, x7`, uso en `rs2`) y en los ciclos 11 y 19 de `loaduse_sw_beq`
(el `sw` que usa el dato como base y el `bne`). Los ciclos son los de `modelo.traza.txt`, donde
el stall está marcado. En `halt_stall` la semilla 47 no deja ninguna pausa en el stall del
ciclo 7 (el HALT retenido en ID), y la 2 sí: `+FINAL +PAUSAS=2` pasa, así que IF/ID conserva el
HALT también con el core detenido. Esa corrida se hace a mano, porque la regresión usa una sola
semilla para todos los programas. De la 1 a la 12, también sirven la 5 y la 8. Si se cambia
la semilla de la regresión, hay que volver a comprobarlo, por ejemplo con
`add_condition {/pipeline_tb/tb_clk == 0}` en xsim, leyendo `u_dut.stall` y `tb_enable`. El
`STEP` real en medio de un stall, desde una trama UART, es de I-47 (§3.3).

**Con el flush por saltos (I-42)** el banco no cambia y no hay define nuevo: la traza sale de
`--modo completo` (§4.3). `hazard_unit` calcula el stall y todos los enables y flush de
`pipeline.md` §10.4, y el salto tomado convierte en burbuja las dos instrucciones que entraron
detrás (§10.5). Con `+FINAL` pasan los 39 programas de la lista `COMPLETO`. Los que suma el flush
coinciden también en `ciclos`, que cuentan 2 por salto tomado (§5): `branch_cond` (48 ciclos,
7 saltos tomados), `jump` (27, 5 saltos), `mixto_lazo` (83, 8 saltos y 5 stalls) y
`halt_camino_equivocado` (16, 2 saltos): el HALT que entra detrás de cada salto se anula y el
core sigue hasta el HALT del final. `salto_depende` y `loaduse_sw_beq` pasan con `+FINAL`: los
registros del camino equivocado quedan en 0. La regresión `completo` pasa las 78 corridas, con y
sin `+PAUSAS=47`. `hazard_unit_tb` suma las filas de la tabla de §10.4 y el barrido de las
1.048.576 combinaciones de entradas (§3.2): `TEST PASSED` con 7.340.247 chequeos.

**Regresión completa (I-43).** Lo que compara el banco no cambia, y la traza sigue saliendo de
`--modo completo`. Cambia cómo se corre: con `+LISTA`, varias corridas en una simulación (§8.1 y
§8.7, decisión [033](../decisiones/033_varias-corridas-por-simulacion.md)).
`loaduse_sw_beq` suma un load seguido de un `jalr` que salta a la dirección cargada (§4.2), como un
retorno que recupera la dirección de la memoria: frena un ciclo y el destino sale del dato
reenviado desde MEM/WB. Hasta ahí ningún `jalr` tomaba `rs1` de un load (`salto_depende` lo trae
desde EX/MEM y `jump` lo lee del banco). Pasa a 32 ciclos (5 stalls y 2 saltos tomados) y su
`_nops`, a 41. `python scripts/regresion.py --pausas 47` y `regresion.tcl` pasan las 78 corridas
(los 39 programas, con y sin `+PAUSAS=47`) y los 19 testbenches unitarios del procesador
(decisión [032](../decisiones/032_testbenches-unitarios-en-la-regresion.md); `uart_tb`, del TP2,
queda afuera). Las 78 corridas pasan con una simulación por corrida y también con `+LISTA`, con
la misma cantidad de chequeos en cada una.

**Mutantes de la I-43 (§6).** `python scripts/regresion.py --mutante todos` y `regresion.tcl`
corren en `--modo completo` y sin `--pausas`, 39 corridas por pasada. La pasada sin mutante pasa
las 39, y cada uno de los 39 mutantes de `scripts/mutantes.py` hace fallar al menos una. Los de
forwarding se vuelven a correr porque, respecto de la I-40, `completo` tiene más programas y el
flush. Las 42 pasadas tardan 920 s (decisión
[033](../decisiones/033_varias-corridas-por-simulacion.md)).

| Mutante | Fallan | Programas que lo detectan |
|---|---|---|
| **Forwarding** (`forwarding_unit.v`, §10.2) | | |
| `sin_forwarding` | 20 | `fwd_exmem`, `fwd_memwb`, `fwd_prioridad`, `salto_depende` y 16 más |
| `fwd_prioridad` | 1 | `fwd_prioridad` |
| `fwd_rd0_ex_mem`, `fwd_rd0_mem_wb` | 1 | `fwd_x0` |
| `fwd_reg_write_ex_mem` | 8 | `fwd_x0`, `bypass_banco`, `mem_byte_media`, `indep_store_load`, `branch_cond`, `loaduse_sw_beq`, `loaduse_sw_beq_nops`, `mixto_lazo` |
| `fwd_reg_write_mem_wb` | 8 | `fwd_x0`, `mem_byte_media`, `mem_avisos`, `indep_stores`, `branch_cond`, `loaduse_rs1_rs2`, `loaduse_rs1_rs2_nops`, `mixto_lazo` |
| `fwd_a_ex_mem_con_rs2`, `fwd_b_ex_mem_con_rs1`, `fwd_b_codigo_ex_mem` | 16 | `fwd_exmem`, `fwd_memwb`, `fwd_prioridad`, `salto_depende` y 12 más |
| `fwd_a_mem_wb_con_rs2` | 9 | `fwd_memwb`, `fwd_prioridad`, `load_sin_dep`, `salto_depende`, `halt_basico`, `halt_stall`, `loaduse_rs1_rs2`, `loaduse_sw_beq`, `mixto_lazo` |
| `fwd_b_mem_wb_con_rs1` | 10 | los mismos y `mem_palabra` |
| `fwd_a_sin_mem_wb`, `fwd_a_codigo_mem_wb` | 5 | `fwd_memwb`, `load_sin_dep`, `salto_depende`, `loaduse_rs1_rs2`, `loaduse_sw_beq` |
| `fwd_b_sin_mem_wb`, `fwd_b_codigo_mem_wb` | 8 | `fwd_memwb`, `load_sin_dep`, `mem_palabra`, `halt_basico`, `halt_stall`, `loaduse_rs1_rs2`, `loaduse_sw_beq`, `mixto_lazo` |
| `fwd_a_codigo_ex_mem` | 4 | `fwd_exmem`, `fwd_prioridad`, `salto_depende`, `mixto_lazo` |
| **Bypass del banco** (`regfile.v`) | | |
| `sin_bypass` | 28 | todos menos `fwd_exmem`, `fwd_memwb`, `halt_basico`, `halt_camino_equivocado` y los 7 `indep_*` |
| `sin_bypass_rs1` | 24 | todos menos esos 11, `halt_stall`, `load_sin_dep`, `loaduse_rs1_rs2` y `loaduse_sw_beq` |
| `sin_bypass_rs2` | 20 | `bypass_banco`, `fwd_prioridad`, `loaduse_rs1_rs2`, `mem_palabra` y 16 más |
| `bypass_sin_we` (bypass aunque WB no escriba) | 3 | `mem_palabra`, `mem_byte_media`, `mixto_lazo_nops` (ver más abajo) |
| `bypass_x0` (`x0` pasa por el bypass) | 5 | `fwd_x0`, `jump`, `jump_nops`, `mem_avisos`, `halt_camino_equivocado` |
| **Stall de carga-uso** (`hazard_unit.v`, §10.3 y §10.4) | | |
| `sin_stall`, `stall_solo_rs1`, `stall_sin_burbuja`, `stall_sin_en_if_id` | 4 | `loaduse_rs1_rs2`, `loaduse_sw_beq`, `halt_stall`, `mixto_lazo` |
| `stall_sin_en_pc` | 3 | `loaduse_rs1_rs2`, `loaduse_sw_beq`, `mixto_lazo` |
| `stall_solo_rs2` | 2 | `loaduse_rs1_rs2`, `loaduse_sw_beq` |
| `stall_rd0` (frena con un load a `x0`) | 1 | `fwd_x0` |
| `stall_sin_mem_read` (frena aunque en EX no haya un load) | 19 | `fwd_exmem`, `fwd_x0`, `alu_r`, `shifts` y 15 más |
| **Flush** (`hazard_unit.v`, §10.5) | | |
| `sin_flush`, `flush_sin_if_id`, `flush_sin_id_ex` | 13 | `branch_cond`, `jump`, `salto_depende`, `halt_camino_equivocado` y 9 más |
| **Parada por HALT** (§3.4) | | |
| `sin_stop_fetch`, `stop_fetch_solo_id`, `stop_fetch_sin_halted`, `stop_fetch_sin_flush`, `stop_fetch_sin_pc` | 39 | todos |
| `stop_fetch_gana_a_redirect` | 1 | `halt_camino_equivocado` |
| `if_id_flush_gana_a_en` | 1 | `halt_stall` |

Cada mutante que detecta un solo programa es un caso que tiene su programa en §4.2:
- la prioridad del forwarding, `fwd_prioridad`;
- el destino `x0`, en el forwarding y en el stall, `fwd_x0`;
- el HALT en el camino equivocado, `halt_camino_equivocado`;
- el HALT retenido por un stall, `halt_stall`.

En `--modo forwarding` (I-40), a `fwd_rd0_ex_mem` y `fwd_rd0_mem_wb` también los detectaban
`mem_avisos` y `jump_nops`; en `completo`, solo `fwd_x0`.

**Estado que el reset no borra.** El reset pone en cero el control, los `valid` y el PC, pero no
los caminos de datos (decisión [010](../decisiones/010_convenciones-rtl.md)). En el core correcto
eso no se ve, porque el control de la burbuja anula esos datos. `bypass_sin_we` y
`stall_sin_mem_read` sacan justamente esa condición: mientras la burbuja del reset recorre el
pipeline, ven el `rd` y el dato que quedaron. En la primera corrida de la simulación son X; en
las siguientes, lo que dejó la anterior, como en la placa cuando se carga un programa después de
otro (decisión 033).
- **`bypass_sin_we`.** Además de los 3 de la tabla, falla en el ciclo 3 en `alu_i`, que es la
  primera corrida, con X, y en `salto_depende`, con el `0x4` que dejó `mixto_lazo_nops`. Con la
  lista invertida esas dos pasan, falla `shifts` (que ahora es la primera), y los 3 de la tabla
  fallan en los mismos ciclos, el 16, el 25 y el 66. Por eso la tabla cuenta 3 y no las 5 del
  resumen. Con una simulación por corrida, la X hacía fallar las 39 en el ciclo 3 o 4, y no se
  veía qué programas lo detectan.
- **`stall_sin_mem_read`.** En `loaduse_rs1_rs2_nops` falla en el ciclo 3, por el `rd` que dejó
  `loaduse_rs1_rs2`. Con la lista invertida falla en el ciclo 16, por un frenado del propio
  programa: las 19 corridas son las mismas en los dos órdenes.

Un mutante que falla en los primeros 4 ciclos, con X o con un valor que no sale del programa,
hay que mirarlo en el log antes de contar ese programa como detector.

**Equivalentes.** `stall_sin_redirect` (el stall sin `~redirect`) y `stall_sin_valid` (la
carga-uso sin `if_id_valid`) dan `NO DETECTADO`, con las 39 corridas en `TEST PASSED`, como se
espera. Ningún programa puede activar esos términos en el core:
- un stall y un salto tomado no coinciden nunca (párrafo siguiente);
- cuando IF/ID es una burbuja (después del reset, de un flush o del HALT), en ID/EX no hay un
  load válido.

Los dos términos los prueba `hazard_unit_tb`, con las entradas sueltas (§3.2).

**Salto y carga-uso a la vez.** Con los saltos resueltos en EX un stall y un salto tomado no
coinciden nunca: la instrucción en EX es un load o un salto (decisión
[012](../decisiones/012_resolucion-saltos.md), `pipeline.md` §10.4). En el core, la combinación es
un load seguido de un salto que usa el dato: 1 ciclo de stall y después 2 de flush. La cubre
`loaduse_sw_beq` con un `beq` tomado, un `bne` no tomado y el `jalr`. La regla
`stall = load_use & ~redirect`, para el caso que no ocurre, la prueba `hazard_unit_tb` (§3.2).

### 8.3 Hasta qué ciclo se compara

El modelo simula siempre el pipeline completo. Mientras falte una parte, el RTL se aparta de
la traza por una razón conocida, y el banco deja de comparar **ese latch** en ese punto:

- **Sin `STAGE_HALT`** no hay parada por HALT (`pipeline.md` §3.4): cada latch se compara
  hasta el ciclo en que el HALT llega a él. Después el modelo carga burbujas y el RTL sigue
  buscando.
- **Sin `STAGE_REDIRECT`** el salto tomado no cambia el PC (I-19 deja la entrada en 0 hasta
  I-36): con `r` el ciclo en que el primer salto tomado está en EX, el latch `k` (0 = IF/ID)
  se compara hasta el ciclo `r + 1 + k`. El banco lo avisa con una línea `INFO:`. De M3 a M6,
  entre los programas que pasan, afecta a `indep_saltos` y `jump_nops`, que se comparan
  completos desde I-36 (§8.2).
- **Memoria de datos con `STAGE_MEM`.** Sin `+FINAL`, al terminar la traza el banco detiene
  el core y lee `dmem` por el puerto B (como `READ_DMEM`) para compararla con la del `.exp`.
  En ese ciclo el HALT está en MEM/WB (sin `STAGE_HALT`) o ya pasó por WB (con `STAGE_HALT`,
  la foto final): ya escribieron todos los stores anteriores y ninguno posterior. Sin
  `STAGE_REDIRECT`, si hubo un salto tomado no se compara (el RTL siguió por el
  camino equivocado) y lo avisa con una línea `INFO:`. Con `+FINAL` la compara el estado
  final (§8.4).
- **`pipeline_vacio` con `+FINAL` y sin `STAGE_HALT`.** Sin `stop_fetch`, detrás del HALT
  siguen entrando instrucciones válidas (las palabras HALT del relleno), así que cuando sube
  `halted` los `valid` no están en 0. El banco no compara `pipeline_vacio` y lo avisa con una
  línea `INFO:`; el resto del estado final sí se compara. Los registros no cambian, porque
  ninguna de esas instrucciones llegó a WB, y `dmem` tampoco salvo que la instrucción siguiente
  al HALT sea un store. Lo mismo con los avisos: un load o un store con dirección inválida
  justo después del HALT levantaría `dmem_oob` o `dmem_misaligned`. Ningún programa de la
  lista de §8.2 tiene ninguno de los dos casos.

El ciclo 1 es el primero después del reset (latches en burbuja, PC = 0), como la línea 1 de
la traza. Se compara en el flanco de bajada.

### 8.4 Qué informa

- Ante la primera discrepancia, una línea por campo distinto en ese ciclo, y termina:
  `[<tiempo>] ERROR ciclo <t> <latch>.<campo> | dut=0x<…> esperado=0x<…>`.
- Con `STAGE_ID`, antes del ciclo 1 y con `enable = 0`, lee `x0`…`x31` por el puerto de la
  Debug Unit (`i_dbg_reg_addr` / `o_dbg_reg_data`, como `READ_REGS`) y los compara con el
  estado inicial (`x0` = 0). Una línea por registro distinto (`puerto debug x<n>`), y
  termina. Como nada cambia con `enable = 0`, el ciclo 1 es el mismo.
- Con `STAGE_ID`, en el ciclo 2 compara el banco de registros con el estado inicial: el
  primer flanco sin reset ya pasó y WB todavía no escribe. Detecta una carga que borró el
  reset o un camino de `` `REGFILE `` equivocado. Una línea por registro distinto
  (`ciclo 2 banco x<n>`), y termina.
- Con `STAGE_MEM` y sin `+FINAL`, una línea `ERROR` por palabra distinta de `dmem`
  (`dmem 0x<dirección>`), o una `INFO:` si no se compara por un salto (§8.3).
- Con `+FINAL`, una línea `ERROR` por cada valor distinto (`halted`, `pipeline_vacio`,
  avisos, `ciclos`, `x1`…`x31`, `dmem 0x<dirección>`). Con `STAGE_HALT`, también `pc` y, en
  los ciclos después de `halted`, `pipeline_vacio, halted + <n>` y `pc, halted + <n>`.
- Con `+PAUSAS`, una línea por cada latch que cambió con `enable = 0`
  (`<latch> cambió con enable = 0`), y lo mismo para `{halted, imem_fault, dmem_oob,
  dmem_misaligned}` con `STAGE_WB`, y termina.
- La línea final de §6: `TEST PASSED` / `TEST FAILED`.

### 8.5 Interfaz que espera de `riscv_core`

La define este banco y la implementa I-22. Los nombres siguen `memoria.md` §3.3:

| Desde | Puertos |
|---|---|
| `STAGE_IF` | `i_clk`, `i_rst`, `i_enable`, `i_imem_b_en`, `i_imem_b_we`, `i_imem_b_addr[9:0]`, `i_imem_b_din[31:0]`, `o_halted` |
| `STAGE_ID` | `i_dbg_reg_addr[4:0]`, `o_dbg_reg_data[31:0]` (puerto de lectura del banco para la Debug Unit). El core los tiene desde I-27 y el banco los conecta siempre, también con `-d STAGES_CLI`, para no dejar la entrada flotante; los lee solo con `STAGE_ID` |
| `STAGE_MEM` | `i_dmem_b_en`, `i_dmem_b_we[3:0]`, `i_dmem_b_addr[9:0]`, `i_dmem_b_din[31:0]`, `o_dmem_b_dout[31:0]` |
| `STAGE_WB` | `o_imem_fault`, `o_dmem_oob`, `o_dmem_misaligned` |
| `STAGE_HALT` | `o_pc[31:0]` (`pc_reg`, para comparar el PC después de la parada) |

Además, el core tiene salidas para la Debug Unit que el banco no conecta: un bus por latch,
`o_<latch>_latch`, con todo su contenido en el orden de `pipeline.md` §8
(decisión [023](../decisiones/023_interfaz-debug-del-core.md)).

Los campos de los latches se leen por jerarquía: tienen que ser señales del módulo superior
del core, con el nombre `<latch>_<campo>` de `pipeline.md` §8. Las señales de control también
llevan el prefijo del latch: `u_dut.id_ex_alu_ctrl`, `u_dut.ex_mem_reg_write`,
`u_dut.mem_wb_mem_to_reg`. El banco de registros se lee y se escribe por el camino de
`` `REGFILE `` (por defecto `u_dut.u_id_stage.u_regfile.regs`: el banco está dentro de
`id_stage`, como `imem` dentro de `if_stage`).

### 8.6 Probar el banco sin el core

`tb/integration/_riscv_core_stub.v` es un `riscv_core` falso que reproduce la traza del modelo
(el `_` lo deja fuera del proyecto de Vivado). Toma `if_id_instr` de la `imem` que cargó el
banco, así que también prueba la carga. Se compila a mano con el banco:

```sh
xvlog [-d STAGE_...] tb/integration/_riscv_core_stub.v tb/integration/pipeline_tb.v
xelab -debug off pipeline_tb -s pipeline_stub
xsim pipeline_stub --runall -testplusarg "DIR=..." [-testplusarg FINAL]
```

El stub tiene el banco de registros en `u_dut.u_id_stage.u_regfile.regs`, el camino por defecto de
`` `REGFILE ``, así que no hace falta pasar ningún `-d REGFILE=...`. Como el banco real, el
reset lo pone en cero (decisión 007). En Windows, `xvlog.bat`,
`xelab.bat` y `xsim.bat` parten los argumentos en el `=`: el plusarg va entre
comillas dobles (`-testplusarg "DIR=..."`), y PowerShell las pierde antes de llegar al `.bat`: desde ahí se envuelve el comando en `cmd /c '...'`. En Linux no hace falta nada de esto,
pero en Ubuntu, y en otras distribuciones con rutas multiarch, `xelab` enlaza la simulación con el
gcc que trae Vivado, que no encuentra `crt1.o` ni `crti.o` (`Failed to link the design`). Se
resuelve exportando `LIBRARY_PATH=/usr/lib/x86_64-linux-gnu` antes de abrir Vivado, también para
`regresion.tcl` en batch.

Con `-testplusarg STUB_ERROR=<ciclo>` invierte un bit de `if_id_pc` en ese ciclo, y con
`STUB_SIN_HALT` nunca activa `halted`: sirven para ver que el banco falla cuando debe. Con
`STAGE_HALT`, `STUB_SIN_HALT` falla en la última línea de la traza, porque el stub no llega a
la foto final. Para ver el watchdog de `+FINAL` se compila con `-d STAGES_CLI -d STAGE_WB`.
`o_pc` vale siempre la dirección del HALT + 4, que es lo único que el banco le compara.

### 8.7 Regresión por lotes

`scripts/regresion.py` y `scripts/regresion.tcl` corren `pipeline_tb` con `+FINAL` para una
lista de programas, uno detrás del otro (decisión [028](../decisiones/028_regresion-por-lotes.md)),
y después los testbenches de `tb/unit/` (decisión
[032](../decisiones/032_testbenches-unitarios-en-la-regresion.md)).
Los programas que en el modo se comparan solo contra la traza corren sin `+FINAL` (decisión
[030](../decisiones/030_corridas-solo-traza.md)):

```sh
python scripts/regresion.py                        # completo: los 39 de sw/, todos con +FINAL, y los 19 de tb/unit/ (master)
python scripts/regresion.py --modo forwarding_stall # RTL de I-41: los 33 y 2 sin +FINAL
python scripts/regresion.py --modo forwarding      # RTL de I-39 e I-40: los 31 y salto_depende sin +FINAL
python scripts/regresion.py --modo sin_riesgos     # RTL de M7: los 27 programas (I-38)
python scripts/regresion.py alu_r fwd_x0       # solo esos
python scripts/regresion.py --pausas 47        # además, cada uno con +PAUSAS=47
python scripts/regresion.py --mutante sin_forwarding   # con un mutante del RTL (§6)
python scripts/regresion.py --mutante todos            # con cada uno de scripts/mutantes.py
python scripts/regresion.py --mutante stall_sin_valid  # un equivalente, a mano: NO DETECTADO (§8.2)
python scripts/regresion.py --sin-unitarios            # sin los testbenches de tb/unit/
```

```tcl
source <ruta-al-repo>/scripts/regresion.tcl    ;# en la Tcl Console de Vivado, o con -mode batch
```

`regresion.py` prepara cada programa con `prep_tb.py` en el modo elegido y escribe la lista en
`build/regresion/corridas.txt`. Las listas por modo están en `sw/programas.py`. `sin_riesgos`
son los 10 programas del plan sin riesgos (§4.3), las 10 variantes `_nops` y los 7 `indep_*`.
Quedan afuera `halt_stall` y `halt_camino_equivocado`. `forwarding` son esos 27 y los 4
originales que solo necesitan forwarding (§4.3, decisión [029](../decisiones/029_modo-del-modelo-en-m8.md)),
con `+FINAL`, más `salto_depende` sin `+FINAL` (lista `SOLO_TRAZA_FORWARDING`, §8.2): 32
corridas, 64 con `--pausas`. `forwarding_stall` (desde I-41) son esos 31, `loaduse_rs1_rs2` y
`halt_stall` (lista `SOLO_STALL`) con `+FINAL`, más `salto_depende` y `loaduse_sw_beq` sin
`+FINAL` (lista `SOLO_TRAZA_FORWARDING_STALL`, §8.2): 35 corridas, 70 con `--pausas`. `completo`
(desde I-42) son los 39 programas de `sw/`, todos con `+FINAL` (lista `COMPLETO`, §4.3): 39
corridas, 78 con `--pausas`. Cada línea de `corridas.txt` es la etiqueta, el programa y los
plusargs además de `DIR` (por ejemplo, `salto_depende_pausas salto_depende FINAL PAUSAS=47`, o
sin `FINAL` en los modos con solo traza). El modo por defecto es el que corresponde al RTL de
`master`. Los otros describen el RTL de una integración anterior y sirven con su commit, por
ejemplo para repetir la regresión de una PR vieja: con el RTL de `master`, que siempre hace
flush, los programas con saltos tomados (las variantes `_nops`, `indep_saltos`, `mem_avisos`)
no coinciden con esas trazas, que dejan válidas las dos instrucciones de detrás del salto.

`regresion.tcl` usa el proyecto abierto o lo crea con `create_project.tcl`. Un proyecto creado
antes de que se agregara un `.v` a `rtl/` o a `tb/` no lo tiene: hay que volver a crearlo (o
agregar el archivo) antes de correr la regresión. Cada pasada es una sola simulación (decisión
[033](../decisiones/033_varias-corridas-por-simulacion.md)): el script escribe
`build/regresion/lista_tb.txt` desde `corridas.txt`, con las rutas absolutas, y `pipeline_tb`,
con `+LISTA`, corre las corridas una tras otra, con el core en reset entre una y otra (§8.1).
Después parte el log en las líneas `CORRIDA <etiqueta>` y guarda la parte de cada corrida en
`build/regresion/logs/<etiqueta>.log`; el log entero queda en `pipeline_tb.log`. Una corrida pasa
si la última línea de su parte que empieza con `TEST ` es `TEST PASSED...`. Antes de cada pasada
borra el `simulate.log` de la anterior. Si Vivado da error, xsim no deja log, o el log no tiene
la parte de una corrida o su línea `TEST`, esa corrida queda como `ERROR` y cuenta como falla,
así que nunca se decide con el log de otra. El resumen sale por consola y queda en
`build/regresion/resumen.txt`. Si alguna corrida falla, el script termina con error: en batch,
Vivado sale con código 1. Con `--pausas 47 --sin-unitarios`, las 78 corridas tardan 32 s en
Vivado 2026.1 (Linux), contando abrir el proyecto y compilar. Con un arranque de xsim por
corrida, como hasta la I-43, tardaban unos 5 minutos: casi todo ese tiempo era cargar el
snapshot (~3,8 s por corrida). La ruta del repositorio no puede tener espacios, porque
`pipeline_tb` lee cada campo de la lista hasta el próximo espacio. `regresion.tcl` lo comprueba
antes de empezar.

**Testbenches unitarios** (decisión [032](../decisiones/032_testbenches-unitarios-en-la-regresion.md)).
En la regresión normal (sin nombres de programas, sin `--mutante` y sin `--sin-unitarios`),
`regresion.py` escribe en `build/regresion/unitarios.txt` los testbenches de `tb/unit/`, menos la
plantilla y los de otro diseño (lista `OTRO_DISENO`: hoy `uart_tb`, el del sistema del TP2, cuyo
DUT `fpga/tp2_uart/top.v` no está en el proyecto `riscv_basys3`); en cualquier otro caso borra la
lista. `regresion.tcl` los corre después de los
programas, cada uno con su `top` y compilando desde cero, deja el log en
`build/regresion/logs/unit/<tb>.log` y los decide igual, por la última línea `TEST`. El resumen
suma `UNITARIOS: n de m testbenches con TEST PASSED`, y una falla de un unitario hace fallar la
regresión.

**Con mutantes** (decisión [031](../decisiones/031_mutantes-de-la-regresion.md)), `regresion.py`
escribe cada copia mutada en `build/mutantes/<nombre>/` y la lista en
`build/regresion/mutantes.txt`. Sin `--mutante` la lista se borra, así que una regresión normal
nunca corre con un mutante que quedó de antes. `regresion.tcl` corre primero todas las corridas
sin mutante, como referencia: si alguna falla, los mutantes no se corren y el script termina con
error. Después las corre una vez por mutante, con la copia en lugar del archivo de `rtl/`, que no
se toca, y compila desde cero en cada pasada. Los logs quedan en `build/regresion/logs/<mutante>/`.
El resumen tiene una línea por mutante: `MUTANTE <nombre>: detectado, fallan N de M corridas: ...`
si alguna corrida termina en `TEST FAILED`, `NO DETECTADO` si pasan todas, o `ERROR` si alguna
quedó sin resultado (por ejemplo, la copia mutada no compila). En ese caso no se sabe si el mutante
se detecta, y el resumen muestra el mensaje de Vivado. El script termina con error si algún
mutante no se detecta o queda en `ERROR`. Al terminar, o si algo falla en el medio, el
proyecto queda como estaba. `python scripts/mutantes.py` lista los mutantes y comprueba que se
pueden aplicar al RTL actual. Los dos **equivalentes** (§8.2, *Regresión completa*) están en una
tabla aparte: `--mutante todos` no los incluye y se corren por nombre, esperando `NO DETECTADO`.

`scripts/ondas.tcl` es para mirar, no para aprobar (§6). Lanza un programa (por defecto
`load_sin_dep_nops`) en la GUI con el PC, los campos principales de cada registro de
segmentación, la escritura del banco y `halted`, agrupados por etapa y sin el prefijo del
latch (`id_ex_rs1_data` se ve como `rs1_data` bajo el divisor ID/EX). Para 1 ciclo después de
`halted` y pone marcadores en el ciclo 1 y en el final. De ahí sale
`docs/diagramas/ondas_load_sin_dep_nops.png`: dos capturas de la ventana de ondas (de Banco a
MEM/WB y de ID/EX a WB), unidas y sin la columna Value, desde el ciclo 2 hasta que sube `halted`.

### 8.8 Ciclos por programa (I-43)

Cuánto cuestan los riesgos en los 22 programas del plan (§4.1 y §4.2), con el pipeline completo.
La tabla la genera `python scripts/ciclos.py` (`--todos` para los 39 de `sw/`): corre cada
programa en el modelo de referencia, en `--modo completo`, y cuenta en la traza

- **`n`**: las instrucciones que llegan válidas a WB, el HALT incluido;
- **Stalls**: los ciclos de stall de carga-uso; entre paréntesis, los falsos positivos de la
  comparación conservadora (decisión [011](../decisiones/011_deteccion-load-use.md)), en los que la
  instrucción frenada no usa el registro del load;
- **Saltos tomados**: `beq`/`bne` tomados, `jal` y `jalr`, 2 ciclos de flush cada uno (§10.5 de
  `pipeline.md`).

El script comprueba que `ciclos = n + 4 + stalls + 2 · saltos_tomados` (§5) y que coincide con el
`ciclos` del `.exp`, escrito a mano; el test `test_cycles_follow_formula` de `tools/isasim` hace la
misma cuenta con `n` y los saltos de la capa ISA. El RTL lo compara `pipeline_tb` con `+FINAL`, así
que con la regresión aprobada los tres dan el mismo número, que es también el campo `cycles` del
bloque de estado de la Debug Unit. CPI es `ciclos / n`, con los 4 de llenado incluidos. Stalls y
Flush son la parte de los ciclos que se va en cada uno. *Con `_nops`* son los ciclos de la variante
que resuelve los riesgos en software, con `nop` (§4.3), y entre paréntesis lo que cuesta de más.

| Programa | `n` | Stalls | Saltos tomados | Ciclos | CPI | Stalls | Flush | Con `_nops` |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `alu_r` | 24 | 0 | 0 | 28 | 1.17 | — | — | — |
| `alu_i` | 19 | 0 | 0 | 23 | 1.21 | — | — | — |
| `shifts` | 20 | 0 | 0 | 24 | 1.20 | — | — | — |
| `lui` | 14 | 0 | 0 | 18 | 1.29 | — | — | — |
| `mem_palabra` | 15 | 0 | 0 | 19 | 1.27 | — | — | — |
| `mem_byte_media` | 54 | 0 | 0 | 58 | 1.07 | — | — | — |
| `branch_cond` | 30 | 0 | 7 | 48 | 1.60 | — | 29 % | 54 (+6) |
| `jump` | 13 | 0 | 5 | 27 | 2.08 | — | 37 % | 29 (+2) |
| `halt_basico` | 3 | 0 | 0 | 7 | 2.33 | — | — | — |
| `mem_avisos` | 11 | 0 | 1 | 17 | 1.55 | — | 12 % | — |
| `fwd_exmem` | 8 | 0 | 0 | 12 | 1.50 | — | — | 22 (+10) |
| `fwd_memwb` | 10 | 0 | 0 | 14 | 1.40 | — | — | 18 (+4) |
| `fwd_prioridad` | 11 | 0 | 0 | 15 | 1.36 | — | — | 21 (+6) |
| `fwd_x0` | 17 | 0 | 0 | 21 | 1.24 | — | — | — |
| `bypass_banco` | 18 | 0 | 0 | 22 | 1.22 | — | — | — |
| `loaduse_rs1_rs2` | 12 | 3 | 0 | 19 | 1.58 | 16 % | — | 22 (+3) |
| `loaduse_sw_beq` | 19 | 5 | 2 | 32 | 1.68 | 16 % | 12 % | 41 (+9) |
| `load_sin_dep` | 11 | 0 | 0 | 15 | 1.36 | — | — | 17 (+2) |
| `salto_depende` | 13 | 0 | 3 | 23 | 1.77 | — | 26 % | 32 (+9) |
| `halt_stall` | 6 | 1 (1 falso) | 0 | 11 | 1.83 | 9 % | — | — |
| `halt_camino_equivocado` | 8 | 0 | 2 | 16 | 2.00 | — | 25 % | — |
| `mixto_lazo` | 58 | 5 | 8 | 83 | 1.43 | 6 % | 19 % | 113 (+30) |
| **Total** | 394 | 14 (1 falso) | 28 | 552 | 1.40 | 3 % | 10 % | |

Lo que muestra:

- **El flush cuesta más que el stall:** 56 ciclos (28 saltos tomados) contra 14, un 10 % y un 3 %
  del total. El llenado, 4 ciclos por programa, es otro 16 %: son programas cortos. Sin contar el
  llenado, el CPI de los 22 es (552 − 88) / 394 = 1,18.
- **El lazo de `mixto_lazo`** (`lw`, `add`, `addi`, `addi`, `bne`) tarda 8 ciclos por vuelta: 5
  instrucciones, 1 stall y 2 de flush, lo que la decisión [012](../decisiones/012_resolucion-saltos.md)
  calculó para la suma de un arreglo con los saltos en EX.
- **Un solo falso positivo** en 14 stalls, y es el de `halt_stall`, que existe para provocarlo. La
  decisión 011 deja abierto revisar la detección si los programas mostraran muchos; no es el caso.
- **El forwarding y el stall en hardware ahorran ciclos frente a los `nop`:** las variantes `_nops`
  tardan entre 2 y 30 ciclos más (`mixto_lazo`, 113 contra 83: un 36 % más). La diferencia es lo
  que cuestan en software las dependencias que el forwarding resuelve gratis y los dos `nop` en
  lugar del ciclo de stall. Detrás de un salto la variante no pierde nada: sus dos `nop` cuestan lo
  mismo que el flush.
