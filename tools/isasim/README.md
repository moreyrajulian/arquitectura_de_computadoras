# isasim: modelo de referencia del procesador

Ejecuta un programa y calcula **lo que el procesador tiene que hacer**: el estado final de
registros y memoria, la cantidad de ciclos y el contenido de los cuatro registros de
segmentación **en cada ciclo**. Es el segundo oráculo de
[`verificacion.md`](../../docs/spec/verificacion.md) §2: el RTL se compara contra él en el
banco de pruebas incremental (nivel 2) y contra el `.exp` escrito a mano (nivel 3). El porqué
del diseño está en la [decisión 0NN](../../docs/decisiones/0NN_modelo-de-referencia.md).

| | |
|---|---|
| **Issue** | I-16 — Modelo de referencia con traza por etapa |
| **Requisitos** | Python ≥ 3.11, sin dependencias. Tests: `pytest`. Usa el ensamblador de [`tools/assembler`](../assembler/README.md) para leer `.s` |
| **Entrada** | Un programa `.s` o `.hex`, y opcionalmente un estado inicial (`regs.hex`, `dmem.hex`) |
| **Salida** | Estado final (formato `.exp`), volcado `READ_ALL`, traza por ciclo y por instrucción (`$readmemh`) |

## 1. Uso

```sh
# estado final por pantalla, en el formato del .exp
python tools/isasim/sim.py sw/fwd_exmem.s

# comparar con el .exp que está al lado del programa (código de salida 1 si difiere)
python tools/isasim/sim.py sw/fwd_exmem.s --exp auto

# generar las trazas para el banco de pruebas
python tools/isasim/sim.py sw/fwd_exmem.s -o build/isasim

# M7 (I-38): pipeline completo sin forwarding, stall ni flush por saltos
python tools/isasim/sim.py sw/fwd_exmem_nops.s --modo sin_riesgos --exp auto
```

| Opción | Qué hace |
|---|---|
| `--modo completo` | Por defecto. Pipeline con forwarding, stall de carga-uso y flush por saltos (M8 en adelante) |
| `--modo sin_riesgos` | Sin los tres mecanismos, como el pipeline de M3 a M7 |
| `--sin-forwarding`, `--sin-stall`, `--sin-flush` | Saca un mecanismo por vez, para las integraciones intermedias de M8 (I-40 a I-42) |
| `--estado-inicial DIR` | Lee `DIR/regs.hex` y `DIR/dmem.hex`. Si no se da, los programas `indep_*` usan `estado_inicial/` junto al programa ([`sw/README.md`](../../sw/README.md) §4) y el resto parte de todo en cero, como después de `LOAD` |
| `--exp ARCHIVO` | Compara con un `.exp`; `auto` usa el que está junto al programa |
| `-o DIR` | Escribe los archivos de §3 en `DIR` |
| `--max-ciclos N` | Corta un programa sin HALT (por defecto 100000) |

Códigos de salida: `0` bien, `1` difiere del `.exp`, `2` error de uso, `3` el programa no se
puede modelar (§4).

Como biblioteca:

```python
from isasim import simulate, load_program, COMPLETO
r = simulate(load_program("sw/fwd_exmem.s"), mode=COMPLETO)
r.regs, r.dmem, r.cycles, r.halted
r.snapshots[t - 1].values["id_ex"]["rs1_data"]   # contenido de ID/EX durante el ciclo t
```

## 2. Cómo funciona

Son dos capas que se controlan entre sí:

| Capa | Archivo | Qué calcula | Según |
|---|---|---|---|
| **1. ISA** | `isasim/isa.py` | El efecto de cada instrucción, una por vez: registro escrito, acceso a memoria, próximo PC | [`isa.md`](../../docs/spec/isa.md) y [`memoria.md`](../../docs/spec/memoria.md) §5–§6 |
| **2. Pipeline** | `isasim/pipeline.py` | En qué etapa está cada instrucción en cada ciclo y qué tiene cada registro de segmentación | [`pipeline.md`](../../docs/spec/pipeline.md) §3–§10 |

Cada instrucción que llega a WB (y cada store en MEM) se compara con lo que dice la capa 1.
Si no coinciden, el modelo se detiene y explica qué instrucción, en qué ciclo y qué valor.
Así, los **valores** que se escriben en registros y memoria salen de la ISA, y la capa 2 solo
puede aportar los **tiempos** y el contenido de los latches.

La capa 1 decodifica las instrucciones por su cuenta, desde `isa.md`; no usa las tablas del
ensamblador. Si `rvasm` codificara mal un campo, el modelo no lo repetiría.

**Por qué hace falta la capa 2.** El contenido de un latch no siempre es un valor de la ISA.
En `addi x1, x0, 5` seguido de `add x2, x1, x1`, cuando el `add` está en ID el `addi` todavía
no escribió `x1`: el banco devuelve 0 y eso queda en `id_ex_rs1_data`. El forwarding lo
corrige recién en EX. Para saber que ese campo vale 0 hay que saber en qué ciclo pasa cada
instrucción por cada etapa.

## 3. Archivos de salida

Con `-o DIR`, para un programa `<p>`:

| Archivo | Contenido |
|---|---|
| `<p>.exp` | Estado final en el formato de [`verificacion.md`](../../docs/spec/verificacion.md) §5 |
| `<p>.read_all.bin` | Payload de `READ_ALL` ([`protocolo_debug.md`](../../docs/spec/protocolo_debug.md) §3): bloque de estado, 32 registros, latches y memoria usada, little-endian |
| `<p>.ciclo.<latch>.hex` | **Traza por ciclo**: una línea por ciclo con el latch empaquetado |
| `<p>.ciclo.<latch>.mask.hex` | Qué bits de esa línea se comparan (1 = comparar) |
| `<p>.instr.<latch>.hex` / `.mask.hex` | **Traza por instrucción**: una línea por cada instrucción válida que entró al latch, en orden |
| `<p>.traza.txt` | La misma traza, legible: qué instrucción hay en cada etapa, stalls, saltos y escrituras |

`<latch>` es `if_id`, `id_ex`, `ex_mem` o `mem_wb`.

### Ciclos

La línea `t` (empezando en 1) es el contenido del latch **durante el ciclo `t`**. El ciclo 1
es el primero después del reset: todos los latches son burbuja y el PC busca `0x0`. La última
línea es la **foto final**, después del flanco en que el HALT está en WB: es lo que muestra
`READ_LATCHES` después de `EVT_HALTED` (todos los `valid` en 0). Los archivos por ciclo tienen
`ciclos + 1` líneas, con `ciclos` el valor del `.exp`.

### Empaquetado

Cada línea tiene los campos de [`pipeline.md`](../../docs/spec/pipeline.md) §8 **en el orden
de su tabla, el primero en los bits más altos**:

| Latch | Bits | Dígitos hex | Campos (del bit más alto al más bajo) |
|---|---|---|---|
| IF/ID | 65 | 17 | `valid, pc, instr` |
| ID/EX | 161 | 41 | `valid, pc, rs1_data, rs2_data, imm, rs1, rs2, rd, funct3, alu_ctrl, alu_src_a, alu_src_b, branch, jal, jalr, mem_read, mem_write, reg_write, mem_to_reg, halt` |
| EX/MEM | 109 | 28 | `valid, pc, result, store_data, rd, funct3, mem_write, reg_write, mem_to_reg, halt` |
| MEM/WB | 110 | 28 | `valid, pc, result, read_data, rd, funct3, offset, reg_write, mem_to_reg, halt` |

En el testbench:

```verilog
reg [160:0] ref_id_ex      [0:MAX_CYCLES];
reg [160:0] ref_id_ex_mask [0:MAX_CYCLES];
initial $readmemh("build/isasim/fwd_exmem.ciclo.id_ex.hex",      ref_id_ex);
initial $readmemh("build/isasim/fwd_exmem.ciclo.id_ex.mask.hex", ref_id_ex_mask);
// en cada ciclo t:
chk("id_ex", (dut_id_ex ^ ref_id_ex[t]) & ref_id_ex_mask[t], 0);
```

`dut_id_ex` es la concatenación de los campos del RTL en el mismo orden
(`{u_dut.id_ex_valid, u_dut.id_ex_pc, ...}`).

### Qué se compara (máscara)

- **Burbuja** (`valid = 0`): solo `valid` y las señales de control. Los datos de una burbuja
  "no importan" ([`pipeline.md`](../../docs/spec/pipeline.md) §2) y el RTL no los limpia.
- **`id_ex_imm` de tipo R, HALT y no reconocidas**: no se compara, porque `imm_sel` vale "x"
  en la tabla de verdad (§4.4) y el valor depende de la implementación.
- **Todo lo demás se compara**, incluidos los campos que la instrucción no usa (por ejemplo
  `id_ex_rs2_data` de un `addi`, que es el registro que nombran los bits del inmediato) y
  `mem_wb_read_data` de cualquier instrucción válida (la memoria de datos es `READ_FIRST`,
  [`memoria.md`](../../docs/spec/memoria.md) §3.2). Están definidos por el diseño.

## 4. Modos y límites

| Modo | Mecanismos | Para |
|---|---|---|
| `completo` | forwarding, stall, flush | M8 (I-43) en adelante, nivel 3 y 4 |
| `sin_riesgos` | ninguno | M3 a M7 (I-17, I-38) |
| `--sin-*` | combinaciones | integraciones intermedias de M8 |

En un modo sin un mecanismo, un programa que lo necesita **no da un resultado equivocado: da
un error** que dice qué instrucción falló (código de salida 3). Por ejemplo, `fwd_exmem.s` en
`sin_riesgos`:

```text
error: ciclo 6: pc 0x00000004 (addi x2, x1, 5) escribe x2 = 0x00000005 y según la ISA
escribe x2 = 0x0000000F. Causa probable: el modo sin_riesgos no tiene forwarding, stall
ni flush y el programa lo necesita (o no tiene `nop` suficientes)
```

Sin flush, las dos instrucciones que siguen a un salto tomado se ejecutan: la capa 1 las
ejecuta igual antes del destino. Un salto tomado dentro de esas dos posiciones da error.

**Pipeline parcial (M3 a M6).** El modelo simula siempre las cinco etapas. Antes de que
existan todas, el banco de pruebas compara solo los latches ya integrados y solo hasta que el
HALT llega al último de ellos: sin las etapas siguientes, `stop_fetch` no mira los bits `halt`
que todavía no existen y la búsqueda sigue.

**Palabras fuera de `isa.md`.** Una palabra con opcode desconocido (o `ecall`) se ejecuta
como NOP, igual que en el hardware ([`pipeline.md`](../../docs/spec/pipeline.md) §4.4). Una
con opcode conocido y `funct3`/`funct7` fuera de `isa.md` (por ejemplo un `blt` escrito con
`.word`) es un error: el hardware la ejecutaría según su opcode, no como NOP.

## 5. Tests

```sh
pip install -r tools/isasim/requirements-dev.txt
python -m pytest tools/isasim
```

| Archivo | Qué prueba |
|---|---|
| `test_isa.py` | Capa 1 con valores calculados a mano: `x0`, desbordes, `sra`/`srl` con negativos, `slt` frente a `sltu`, `sltiu`, `lb` frente a `lbu` (ejemplos de `memoria.md` §5), stores parciales, saltos hacia atrás, `jal`/`jalr`, alias y desalineados |
| `test_pipeline.py` | Capa 2: anchos de §8, la fórmula de ciclos, el valor viejo en `id_ex_rs1_data`, bypass del banco, burbuja del stall, flush de saltos, HALT, máscaras y modos |
| `test_programas.py` | **Los programas de `sw/` contra su `.exp` escrito a mano**: todos en modo completo, los de M7 en `sin_riesgos`, y que los originales con riesgos no pasan sin los mecanismos. También el bloque de estado del ejemplo de `protocolo_debug.md` §4 |

Resultado actual: 118 tests; los 38 programas de `sw/` coinciden con su `.exp` en modo
completo, ciclos incluidos, y los 26 de M7 en `sin_riesgos`.

## 6. Estructura

```
tools/isasim/
├── sim.py                Punto de entrada de la CLI
├── requirements-dev.txt  pytest
├── isasim/
│   ├── isa.py            Capa 1: decodificación y semántica de isa.md
│   ├── pipeline.py       Capa 2: pipeline ciclo a ciclo y comparación con la capa 1
│   ├── latches.py        Campos de pipeline.md §8, empaquetado y máscaras
│   ├── files.py          Lectura de .s/.hex/estado inicial; .exp, READ_ALL y trazas
│   └── cli.py
└── tests/
```

**Si cambia `isa.md`:** se actualizan las tablas de `isa.py` y se agregan casos a
`test_isa.py`. **Si cambia `pipeline.md`** (campos de un latch, costo de un salto o del
stall): `latches.py` o `pipeline.py`, y se recalculan a mano los `.exp` afectados; los tests
de `test_programas.py` dicen cuáles.
