# sw: programas de prueba

Programas en ensamblador que ejecuta el procesador en todas las pruebas: por etapa
(nivel 2), core completo (nivel 3), Debug Unit (nivel 4) y placa (nivel 5) de
[`verificacion.md`](../docs/spec/verificacion.md). Cada uno viene con su **estado final
esperado**, calculado a mano desde [`isa.md`](../docs/spec/isa.md). El porqué de estas
convenciones está en la [decisión 019](../docs/decisiones/019_programas-de-prueba.md).

| | |
|---|---|
| **Issue** | I-15 — Programas de prueba |
| **Ensamblador** | [`tools/assembler`](../tools/assembler/README.md) (`rvasm`) |
| **Chequeos** | `python -m pytest sw` (formato y convenciones, no los valores) |

## 1. Archivos

| Archivo | Qué es | Se versiona |
|---|---|---|
| `<nombre>.s` | Programa en ensamblador, sintaxis de `rvasm` | Sí |
| `<nombre>.exp` | Estado final esperado de registros y memoria ([`verificacion.md`](../docs/spec/verificacion.md) §5) | Sí |
| `estado_inicial/regs.hex`, `estado_inicial/dmem.hex` | Estado inicial de los programas `indep_*` (§4) | Sí |
| `<nombre>.hex`, `.bin`, `.coe`, `.lst` | Salida del ensamblador | **No**: se regenera desde el `.s` |
| `test_programas.py` | Chequeos de las convenciones de este README | Sí |

Todo programa tiene su `.exp`: **un programa sin `.exp` no es una prueba**. El `.exp` se
escribe a mano, nunca copiando la salida del modelo de referencia ni del RTL
([`verificacion.md`](../docs/spec/verificacion.md) §2).

## 2. Convención de nombres

`<nombre>` va en minúsculas y con `_`, y dice qué mecanismo prueba: si un programa falla,
el nombre ya dice qué se rompió.

| Patrón | Qué es | Parte de | Cuándo se usa |
|---|---|---|---|
| `indep_<grupo>` | Instrucciones **independientes** de un grupo (§4) | `estado_inicial/` | Por etapa, de IF a MEM, antes de que exista WB (M3 a M6) |
| `<nombre>` | Programa del plan ([`verificacion.md`](../docs/spec/verificacion.md) §4) | Todo en cero | Core completo: M7 si no tiene riesgos, M8 en adelante todos |
| `<nombre>_nops` | Variante con `nop` de un programa de riesgos o de saltos (§5) | Todo en cero | M7: pipeline completo sin forwarding, stall ni flush |

## 3. Reglas para escribir un programa

- **Una cosa por programa**, dicha en un comentario al principio: qué prueba, si tiene
  riesgos (y entonces cuál es su variante `_nops`) y cuál es su `.exp`.
- **Termina en `halt`**. Código desde `0x0`, datos desde `0x000`; no hay `.data`: los
  datos se arman con stores ([`memoria.md`](../docs/spec/memoria.md) §2.2).
- **Registros por número** (`x5`, no `t0`) para que coincidan con el `.exp`. Las etiquetas
  no pueden llamarse como un registro ABI (`t1`, `s1`, `a0`) ni como una instrucción
  (`sub`): `rvasm` lo rechaza.
- **Un comentario por instrucción con el valor que deja**: es la cuenta a mano de la que sale
  el `.exp`, y quien revisa la puede seguir línea por línea.
- **Accesos alineados y dentro de rango**, salvo `mem_avisos`.
- **Lo que no se tiene que ejecutar escribe algo visible.** Detrás de un salto tomado o de
  un HALT van instrucciones que escriben registros que el `.exp` no lista (x20 a x24), y el
  camino equivocado escribe `x31 = -1`: si el flush falla, el estado final no coincide.
- **Direcciones fijas.** `jalr` no acepta etiquetas como desplazamiento: cuando un programa
  salta a una dirección calculada, el comentario de cabecera dice qué instrucción hay que
  corregir si se mueve el código.
- Un programa **sin riesgos** (todas sus dependencias a distancia ≥ 3, sin salto tomado
  seguido de algo que no sea `nop`, sin load seguido de su uso) da el mismo resultado y los
  mismos ciclos en M7 que en M8, así que no necesita variante `_nops`.

Distancia es la cantidad de instrucciones **ejecutadas** entre el productor y el consumidor:
a distancia 1 el dato llega por forwarding desde EX/MEM, a 2 desde MEM/WB, a 3 por el
bypass del banco ([`pipeline.md`](../docs/spec/pipeline.md) §10.1).

## 4. Programas independientes y estado inicial

Antes de que exista WB (M3 a M6) ninguna instrucción puede escribir un registro, así que un
programa normal no puede ni armar sus operandos. Los programas `indep_*` lo resuelven:

- **Parten de un estado inicial** (`estado_inicial/`): registros `x1`–`x9` y algunas palabras
  de `dmem` con valores elegidos para cubrir cada caso (positivo, negativo, mínimo, máximo,
  bytes con bit alto en 0 y en 1).
- **Ninguna instrucción lee un registro que escribe otra.** Solo leen `x1`–`x9` (y `x0`) y
  solo escriben `x11`–`x31`. Así el resultado no depende de WB, del forwarding ni del orden
  entre etapas, y se observa en el registro de segmentación de la etapa: el de la ALU en
  `ex_mem_result`, el del load en MEM/WB, el del store en `dmem`.
- **Cada salto va seguido de dos `nop`**, así el resultado es el mismo con flush o sin él.

| Programa | Grupo |
|---|---|
| `indep_alu_r` | Aritméticas y lógicas de tipo R |
| `indep_alu_i` | Con inmediato, incluidos los desplazamientos |
| `indep_cargas` | `lb lh lw lbu lhu` sobre la `dmem` precargada |
| `indep_stores` | `sb sh sw`, también sobre palabras precargadas (los vecinos no cambian) |
| `indep_saltos` | `beq bne jal jalr`, tomados y no tomados, hacia adelante y hacia atrás |
| `indep_lui` | `lui` |

Su `.exp` es el estado final del core completo partiendo del estado inicial: lista también
`x1`–`x9` y la `dmem` precargada. Con el pipeline completo también se pueden correr.

### Formato del estado inicial

Son dos archivos en el formato de `$readmemh` de Verilog, para que el testbench los cargue
directamente y el modelo de referencia los lea con un parser de pocas líneas:

```
// comentario
@<índice> <valor>    // comentario
```

- `@<índice>` en hex fija la posición: en `regs.hex` es el número de registro; en
  `dmem.hex` es el **índice de palabra** (dirección en bytes / 4), porque `dmem` es un
  arreglo de palabras. El comentario dice la dirección en bytes.
- `<valor>`: 8 dígitos hex.
- **Lo que no aparece vale 0.** `$readmemh` no toca las posiciones que el archivo no
  nombra, así que el testbench tiene que poner en cero los registros y la memoria **antes**
  de leerlo:

```verilog
for (i = 0; i < 32; i = i + 1)   regs[i] = 32'h0;
for (i = 0; i < 1024; i = i + 1) dmem[i] = 32'h0;
$readmemh("sw/estado_inicial/regs.hex", regs);
$readmemh("sw/estado_inicial/dmem.hex", dmem);
```

`regs.hex` no escribe `x0`. Los programas que no empiezan con `indep_` parten de **todo en
cero**, que es como deja el core `LOAD` (decisión
[004](../docs/decisiones/004_carga-y-reprogramacion.md)): no usan el estado inicial.

## 5. Variantes `_nops`

En M7 el pipeline tiene las cinco etapas pero todavía no tiene forwarding, detección de
carga-uso ni flush por saltos (llegan en M8). La variante `_nops` agrega `nop` para que el
mismo programa dé el resultado correcto sin esos mecanismos:

1. **Riesgo de datos:** `nop` entre el productor y el consumidor hasta que queden a
   distancia 3 (dos `nop` para una dependencia consecutiva, uno para distancia 2). Lo
   resuelve el bypass del banco, que existe desde M4.
2. **Carga-uso:** dos `nop` entre el load y el uso.
3. **Saltos:** dos `nop` después de **cada** salto (tomado o no). Sin flush, las dos
   instrucciones que entran detrás de un salto tomado se ejecutan, así que tienen que ser
   `nop`.

La variante deja el mismo estado que el original, salvo los registros que guardan
direcciones (`jal`, `jalr`), porque el código se corre. Y **sus ciclos son los mismos con
el pipeline completo o sin forwarding/stall/flush**: un `nop` detrás de un salto tomado se
ejecuta en M7 y en M8 lo anula el flush, que cobra los mismos 2 ciclos. Por eso tiene un
solo `.exp`, válido en M7 y en M8.

| Original | Variante | Por qué la necesita |
|---|---|---|
| `fwd_exmem`, `fwd_memwb`, `fwd_prioridad` | `_nops` | Forwarding |
| `loaduse_rs1_rs2`, `loaduse_sw_beq` | `_nops` | Stall de carga-uso (y flush en `loaduse_sw_beq`) |
| `load_sin_dep` | `_nops` | Forwarding del dato del load desde MEM/WB |
| `branch_cond`, `jump`, `salto_depende` | `_nops` | Flush (y forwarding en `salto_depende`) |
| `mixto_lazo` | `_nops` | Todo |

No tienen variante:

- **Los que no tienen riesgos** (§3): ya corren en M7. Incluye `fwd_x0` (las lecturas de
  `x0` dan 0 con o sin forwarding), `bypass_banco` (distancia 3, el banco lo resuelve) y
  `mem_avisos` (su único salto ya va seguido de dos `nop`).
- **`halt_stall` y `halt_camino_equivocado`**: prueban la interacción del HALT con el stall
  y con el flush. Con `nop` en el medio no queda nada que probar, así que son solo de M8.

## 6. Lista de programas

### Una cosa por tipo de instrucción ([`verificacion.md`](../docs/spec/verificacion.md) §4.1)

| Programa | Qué ejercita | Riesgos |
|---|---|---|
| `alu_r` | `add sub sll srl sra and or xor slt sltu` con operandos 0, positivos, negativos, mínimo y máximo | No |
| `alu_i` | `addi andi ori xori slti sltiu` con inmediato negativo, máximo y mínimo; `sltiu` contra `-1` | No |
| `shifts` | `slli srli srai` con `shamt` 0, 1 y 31; `sll srl sra` con `rs2 ≥ 32` | No |
| `lui` | `lui` y constantes de 32 bits con `lui` + `addi` (también `addi` negativo) | No |
| `mem_palabra` | `sw`/`lw` en `0x000`, en `0xFFC`, con base distinta de `x0` y desplazamiento negativo | No |
| `mem_byte_media` | `sb sh lb lbu lh lhu` con bit alto en 0 y en 1 en cada posición; little-endian; vecinos | No |
| `branch_cond` | `beq`/`bne` tomados y no tomados, hacia adelante y hacia atrás | Flush → `_nops` |
| `jump` | `jal` con `rd = ra`, otro `rd` y `x0`; `jalr` como `ret` y con el bit 0 en 1 | Flush → `_nops` |
| `halt_basico` | HALT con instrucciones detrás que no se ejecutan | No |
| `mem_avisos` | Accesos desalineados y fuera de rango; los tres avisos quedan activos | No |

### Un programa por caso de riesgo ([`verificacion.md`](../docs/spec/verificacion.md) §4.2)

| Programa | Caso | Variante |
|---|---|---|
| `fwd_exmem` | RAW consecutiva: forwarding desde EX/MEM en `rs1`, `rs2`, dato y base de `sw` | `_nops` |
| `fwd_memwb` | RAW a distancia 2: forwarding desde MEM/WB | `_nops` |
| `fwd_prioridad` | Las dos anteriores escriben el mismo registro: gana EX/MEM | `_nops` |
| `fwd_x0` | Escritura en `x0`: no se reenvía, no pasa por el bypass, un `lw x0` no frena | — |
| `bypass_banco` | RAW a distancia 3: bypass del banco | — |
| `loaduse_rs1_rs2` | Carga-uso en `rs1`, `rs2` y los dos (también para `STEP` en medio de un stall) | `_nops` |
| `loaduse_sw_beq` | Load seguido de `sw` (dato y base), de `beq` tomado y de `bne` no tomado | `_nops` |
| `load_sin_dep` | Load seguido de algo que no depende de él: sin stall | `_nops` |
| `salto_depende` | `beq`, `bne` y `jalr` que usan el resultado de la anterior o de la de hace dos | `_nops` |
| `halt_stall` | Stall con el HALT en ID (falso positivo de la detección conservadora) | — |
| `halt_camino_equivocado` | Un salto tomado pasa por encima de un HALT en ID y de otro en IF | — |
| `mixto_lazo` | Programa realista: arma un arreglo con stores y lo suma con un lazo | `_nops` |

La lista de la issue I-15 queda cubierta así: RAW consecutiva (`fwd_exmem`), RAW a
distancia 2 (`fwd_memwb`), carga-uso (`loaduse_rs1_rs2`, `loaduse_sw_beq`), salto tomado
seguido de instrucciones que no deben ejecutarse (`branch_cond`, `jump`, `salto_depende`) y
escritura en `x0` (`fwd_x0`).

## 7. Uso

```sh
# ensamblar un programa para un testbench (imem completa, rellenada con HALT)
python tools/assembler/asm.py sw/alu_r.s -o build/sw/alu_r.hex --fill

# listado con direcciones, para depurar
python tools/assembler/asm.py sw/alu_r.s -o build/sw/alu_r.lst

# chequeos de este README
python -m pytest sw
```

La salida va en `build/` (ignorada por git) o al lado del `.s`, donde `.gitignore` también
la ignora.

`test_programas.py` verifica que cada `.s` ensambla sin advertencias y termina en HALT,
que tiene su `.exp` con el formato de [`verificacion.md`](../docs/spec/verificacion.md) §5,
que están los 22 programas del plan, los `indep_*` y las variantes `_nops`, que entre los 22
aparece cada instrucción de `isa.md` y que los `indep_*` no leen ningún registro que
escriben. **No verifica los valores del `.exp`**: eso es trabajo del modelo de referencia
(I-16), que tiene que coincidir con todos.

## 8. Agregar un programa

1. Escribir `<nombre>.s` siguiendo §3, con el valor de cada instrucción en un comentario.
2. Escribir `<nombre>.exp` a mano a partir de esos comentarios; los ciclos con
   `n + 4 + stalls + 2 · saltos_tomados` ([`verificacion.md`](../docs/spec/verificacion.md)
   §5), con la cuenta en un comentario.
3. Si tiene riesgos, escribir `<nombre>_nops.s` y su `.exp` (§5) y agregarlo a `NOPS` en
   `test_programas.py`.
4. Si es un mecanismo nuevo, agregarlo a la lista de [`verificacion.md`](../docs/spec/verificacion.md)
   §4 y a `PLAN`.
5. `python -m pytest sw`.
