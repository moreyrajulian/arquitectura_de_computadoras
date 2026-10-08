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
| Banco de registros (`regfile`) | I-23 | `regfile_tb.v` | `x0` siempre 0 (se lee 0 aunque se escriba); escribir y leer los 31 registros; dos lecturas simultáneas; **bypass WB→ID**: leer el registro que se escribe en el mismo ciclo entrega el dato nuevo ([007](../decisiones/007_banco-registros.md)); tercer puerto de lectura de la Debug Unit |
| Unidad de control (`control_unit`) | I-24 | `control_unit_tb.v` | **Exhaustivo**: para cada fila de la tabla de verdad de §4.4 (R, I aritmética, load, store, branch, `jal`, `jalr`, `lui`, HALT, no reconocida, burbuja) verifica las 12 señales; `halt` solo con `valid = 1`; `0x0000_0000` y `ecall` se comportan como NOP |
| Generador de inmediatos (`imm_gen`) | I-25 | `imm_gen_tb.v` | Los cinco formatos de `isa.md` con inmediato positivo, negativo, máximo y mínimo; el bit de signo siempre es `instr[31]`; comparado contra las fórmulas de `isa.md` |
| Registro ID/EX | I-26 | `id_ex_reg_tb.v` | Igual que IF/ID; además, los 161 bits se conservan intactos con `en = 1` |
| ALU y control de ALU (`alu`, `alu_control`) | I-28 | `alu_tb.v` (existente, ampliado) y `alu_control_tb.v` | Las 10 operaciones; `slt` contra `sltu` con operandos negativos; desplazamientos con `shamt` 0, 1 y 31 y usando solo los 5 bits bajos de `rs2`; `alu_control`: `{instr[30], funct3}` en R; en I aritmética el bit 30 solo cuenta con `funct3 = 101` (un `addi` con inmediato negativo **no** es una resta) |
| Lógica de saltos (`branch_unit`) | I-29 | `branch_unit_tb.v` | `taken = branch & (zero ^ funct3[0])` para `beq` y `bne` con `zero` en 0 y en 1; `jal` y `jalr` siempre `redirect`; destino `pc + imm` y `(rs1 + imm) & ~1` (con bit 0 en 1 a la entrada); no salto → `redirect = 0` |
| Registro EX/MEM | I-30 | `ex_mem_reg_tb.v` | Igual que ID/EX (109 bits) |
| Memoria de datos (`dmem`) | I-32 | `dmem_tb.v` | `sb`, `sh`, `sw` con sus *byte enables* en cada alineación válida; little-endian; los bytes no escritos no cambian; accesos desalineados y fuera de rango con el comportamiento y los avisos de `memoria.md` §6.1 y §6.2; mapa de palabras usadas (`memoria.md` §7); latencia de lectura de un ciclo |
| Registro MEM/WB | I-33 | `mem_wb_reg_tb.v` | Igual que ID/EX (110 bits) |
| Write back (`write_back`) | I-35 | `write_back_tb.v` | Extensión de `lb`, `lbu`, `lh`, `lhu`, `lw` con bit de signo 0 y 1 y en cada posición del byte; elección entre resultado de EX y dato de memoria; `reg_write = 0` no escribe; registro `halted` (se activa solo con `valid & halt` y no se desactiva hasta el reset, `pipeline.md` §7.3) |

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
| Carga de programa | I-46 | `debug_load_tb.v` | `LOAD` escribe `imem` y rellena el resto con HALT; deja `dmem` en cero (decisión [004](../decisiones/004_carga-y-reprogramacion.md)); reprogramar con un programa ya cargado y en cualquier estado; error durante la carga (`memoria.md` §4.3) |
| Modos de ejecución | I-47 | `debug_run_tb.v` | `RUN` hasta el HALT con `EVT_HALTED`; `STEP` avanza exactamente un ciclo; `STOP` detiene sin perder estado; **`STEP` en medio de un stall** continúa donde quedó; `RUN` y `STEP` repetido dan el mismo estado final |
| Volcado de estado | I-48 | `debug_dump_tb.v` | `READ_REGS`, `READ_LATCHES`, `READ_DMEM` (rango válido y `ERR_ADDR`), `READ_DMEM_USED`, `READ_ALL`: orden, tamaños y endianness del protocolo; los latches coinciden con los registros de segmentación del core, bit a bit, según `pipeline.md` §8 |


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
| Destino `x0` en la instrucción anterior (no se reenvía) | `fwd_x0` |
| Dependencia a distancia 3 (bypass del banco) | `bypass_banco` |
| Load-use en `rs1` y en `rs2` | `loaduse_rs1_rs2` |
| Load seguido de `sw` que guarda el dato; load seguido de `beq` | `loaduse_sw_beq` |
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
| `indep_alu_r`, `indep_alu_i`, `indep_cargas`, `indep_stores`, `indep_saltos`, `indep_lui` | 2, de IF a MEM (M3 a M6), antes de que exista WB | Ninguna instrucción lee un registro que escribe otra: parten de un **estado inicial** de registros y de `dmem` (`sw/estado_inicial/`, en formato `$readmemh`) y cada resultado se ve en el registro de segmentación de su etapa |
| `<nombre>_nops`, de los programas de riesgos y de saltos | 3 sin riesgos (I-38, M7): pipeline completo sin forwarding, stall ni flush | Llevan `nop` para que toda dependencia quede a distancia 3 y detrás de cada salto haya dos `nop`. Mismo estado final que el original y los mismos ciclos en M7 y en M8 |

En I-38 se corren los programas sin riesgos de §4.1 y §4.2 y las variantes `_nops`; en M8
(I-40 e I-43), todos. `halt_stall` y `halt_camino_equivocado` no tienen variante: lo que prueban
es la interacción del HALT con el stall y el flush.

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
| 2. Por etapa | Para todos los programas de `sw/` que la etapa ya puede ejecutar, cada registro de segmentación de las etapas integradas coincide con la traza del modelo en **todos** los ciclos (campos de `pipeline.md` §8, incluidos `valid` y las señales de control), comparando los bits que marca la máscara del modelo: en una burbuja, solo `valid` y el control ([`tools/isasim`](../../tools/isasim/README.md) §3). Hasta M7 el modelo corre en modo `sin_riesgos` |
| 3. Core completo | Para los 22 programas, el estado final coincide con el `.exp` en todos los campos de §5, incluido `ciclos` |
| 4. Debug Unit | Imprime `TEST PASSED` y cada programa da el mismo estado final con `RUN` que con `STEP` repetido |
| 5. Placa | Para los 22 programas cargados con `LOAD`, el volcado de `READ_ALL` coincide con el `.exp` |

**Regresión.** La regresión (I-43) corre todos los testbenches y todos los programas y la
aprobación es única: ningún `TEST FAILED` (el timeout también lo imprime). Se corre completa antes de integrar a
`master` un cambio de RTL. Los testbenches se corren en modo por lotes de `xsim` y el resultado se
decide leyendo la línea final, que es lo que permite automatizarlo.

**Que la prueba pueda fallar.** Para cada mecanismo de riesgo (forwarding, bypass del banco,
stall, flush de saltos, parada por HALT), al menos una vez se lo desactiva a propósito en el RTL y
se comprueba que algún programa pasa a `TEST FAILED`. Si nada falla, los programas no cubren ese
mecanismo y hay que agregar uno. I-40 lo hace para el forwarding; I-43 para el resto.

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
python scripts/prep_tb.py sw/indep_alu_r.s                  # --modo sin_riesgos (M3 a M7)
python scripts/prep_tb.py sw/fwd_exmem.s --modo completo    # M8 en adelante
```

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
| `DIR=<ruta>` | Obligatorio: directorio de `prep_tb.py` |
| `FINAL` | Al terminar la traza, sigue hasta `halted` y compara el estado final (necesita `STAGE_WB`) |

Parámetro `MAX_CYCLES` (por defecto 2000): watchdog sobre los ciclos con `enable = 1`. La
carga y la lectura final no cuentan.

### 8.2 Etapas integradas

Cada integración agrega su define al principio de `pipeline_tb.v` (o con `-d` en xvlog). Son
acumulativos: definir uno define los anteriores.

| Define | Issue | Qué agrega al banco |
|---|---|---|
| `STAGE_IF` | I-22 | Compara IF/ID; carga `imem` por el puerto B |
| `STAGE_ID` | I-27 | Compara ID/EX; carga el banco de registros por jerarquía (`` `REGFILE ``) al soltar el reset |
| `STAGE_EX` | I-31 | Compara EX/MEM |
| `STAGE_MEM` | I-34 | Compara MEM/WB; carga `dmem` por el puerto B |
| `STAGE_WB` | I-35 | Habilita `+FINAL` (registros, `halted`, avisos) |
| `STAGE_REDIRECT` | I-36 | Sin corte por saltos (§8.3) |
| `STAGE_HALT` | I-37 | Sin corte por HALT: se comparan todas las líneas, foto final incluida |

### 8.3 Hasta qué ciclo se compara

El modelo simula siempre el pipeline completo. Mientras falte una parte, el RTL se aparta de
la traza por una razón conocida, y el banco deja de comparar **ese latch** en ese punto:

- **Sin `STAGE_HALT`** no hay parada por HALT (`pipeline.md` §3.4): cada latch se compara
  hasta el ciclo en que el HALT llega a él. Después el modelo carga burbujas y el RTL sigue
  buscando.
- **Sin `STAGE_REDIRECT`** el salto tomado no cambia el PC (I-19 deja la entrada en 0 hasta
  I-36): con `r` el ciclo en que el primer salto tomado está en EX, el latch `k` (0 = IF/ID)
  se compara hasta el ciclo `r + 1 + k`. El banco lo avisa con una línea `INFO:`. De M3 a M6
  afecta solo a `indep_saltos`, que se compara completo recién en I-36.

El ciclo 1 es el primero después del reset (latches en burbuja, PC = 0), como la línea 1 de
la traza. Se compara en el flanco de bajada.

### 8.4 Qué informa

- Ante la primera discrepancia, una línea por campo distinto en ese ciclo, y termina:
  `[<tiempo>] ERROR ciclo <t> <latch>.<campo> | dut=0x<…> esperado=0x<…>`.
- Con `STAGE_ID`, en el ciclo 2 compara el banco de registros con el estado inicial: el
  primer flanco sin reset ya pasó y WB todavía no escribe. Detecta una carga que borró el
  reset o un camino de `` `REGFILE `` equivocado. Una línea por registro distinto
  (`ciclo 2 banco x<n>`), y termina.
- Con `+FINAL`, una línea `ERROR` por cada valor distinto (`halted`, `pipeline_vacio`,
  avisos, `ciclos`, `x1`…`x31`, `dmem 0x<dirección>`).
- La línea final de §6: `TEST PASSED` / `TEST FAILED`.

### 8.5 Interfaz que espera de `riscv_core`

La define este banco y la implementa I-22. Los nombres siguen `memoria.md` §3.3:

| Desde | Puertos |
|---|---|
| `STAGE_IF` | `i_clk`, `i_rst`, `i_enable`, `i_imem_b_en`, `i_imem_b_we`, `i_imem_b_addr[9:0]`, `i_imem_b_din[31:0]`, `o_halted` |
| `STAGE_MEM` | `i_dmem_b_en`, `i_dmem_b_we[3:0]`, `i_dmem_b_addr[9:0]`, `i_dmem_b_din[31:0]`, `o_dmem_b_dout[31:0]` |
| `STAGE_WB` | `o_imem_fault`, `o_dmem_oob`, `o_dmem_misaligned` |

Los campos de los latches se leen por jerarquía: tienen que ser señales del módulo superior
del core, con el nombre `<latch>_<campo>` de `pipeline.md` §8. Las señales de control también
llevan el prefijo del latch: `u_dut.id_ex_alu_ctrl`, `u_dut.ex_mem_reg_write`,
`u_dut.mem_wb_mem_to_reg`. El banco de registros se lee y se escribe por el camino de
`` `REGFILE `` (por defecto `u_dut.u_regfile.regs`, a ajustar en I-27).

### 8.6 Probar el banco sin el core

`tb/integration/_riscv_core_stub.v` es un `riscv_core` falso que reproduce la traza del modelo
(el `_` lo deja fuera del proyecto de Vivado). Toma `if_id_instr` de la `imem` que cargó el
banco, así que también prueba la carga. Se compila a mano con el banco:

```sh
xvlog [-d STAGE_...] tb/integration/_riscv_core_stub.v tb/integration/pipeline_tb.v
xelab -debug off pipeline_tb -s pipeline_stub
xsim pipeline_stub --runall -testplusarg "DIR=..." [-testplusarg FINAL]
```

El stub tiene el banco de registros en `u_dut.u_regfile.regs`, el camino por defecto de
`` `REGFILE ``, así que no hace falta pasar ningún `-d REGFILE=...`. Como el banco real, el
reset lo pone en cero (decisión 007). En Windows, `xvlog.bat`,
`xelab.bat` y `xsim.bat` parten los argumentos en el `=`: el plusarg va entre
comillas dobles (`-testplusarg "DIR=..."`), y PowerShell las pierde antes de llegar al `.bat`: desde ahí se envuelve el comando en `cmd /c '...'`. En Linux no hace falta nada de esto.

Con `-testplusarg STUB_ERROR=<ciclo>` invierte un bit de `if_id_pc` en ese ciclo, y con
`STUB_SIN_HALT` nunca activa `halted`: sirven para ver que el banco falla cuando debe.
