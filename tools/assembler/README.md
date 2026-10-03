# rvasm: ensamblador del procesador

Traduce programas en ensamblador RISC-V al código máquina del procesador: el subconjunto
RV32I de [`docs/spec/isa.md`](../../docs/spec/isa.md) más `halt`
([decisión 001](../../docs/decisiones/001_instruccion-halt.md)). La salida sirve para
cargar el programa por UART con `LOAD` y para inicializar memorias en simulación, y se puede
verificar sin la FPGA. El porqué de cada elección está en la
[decisión 017](../../docs/decisiones/017_ensamblador.md).

| | |
|---|---|
| **Issue** | I-10 — Ensamblador |
| **Requisitos** | Python ≥ 3.11, sin dependencias. Tests: `pytest`. Validación en vivo (opcional): un ensamblador RISC-V estándar (§7) |
| **Entrada** | Un archivo `.s` |
| **Salida** | `.hex` (por defecto), `.bin`, `.coe`, `.lst` (§4) |

## 1. Uso

```sh
# hex por stdout
python tools/assembler/asm.py sw/programa.s

# uno o varios archivos; el formato sale de la extensión
python tools/assembler/asm.py sw/programa.s -o programa.hex -o programa.coe -o programa.lst

# memoria completa (1024 palabras) rellenada con HALT, como queda después de LOAD
python tools/assembler/asm.py sw/programa.s -o imem.hex --fill
```

| Opción | Qué hace |
|---|---|
| `-o ARCHIVO` | Escribe la salida en `ARCHIVO`; el formato sale de la extensión (`.hex`, `.bin`, `.coe`, `.lst`). Se puede repetir |
| `-f FORMATO` | Fuerza el formato (`hex`, `bin`, `coe`, `lst`) de todas las salidas o de stdout |
| `--fill` | Completa `hex`/`bin`/`coe` hasta 1024 palabras con HALT (`0x00100073`) |
| `-W` | No muestra advertencias |

Códigos de salida: `0` bien, `1` errores de ensamblado (no se escribe ninguna salida),
`2` error de uso (archivo inexistente, extensión desconocida).

También funciona como módulo (`cd tools/assembler && python -m rvasm programa.s`) y como
biblioteca, que es como lo usa la interfaz de la PC:

```python
from rvasm import assemble, AssemblerError

try:
    program = assemble(texto, "programa.s")
except AssemblerError as e:
    for err in e.errors:            # Diagnostic(filename, line, message, source)
        print(err.line, err.message)
else:
    payload = program.to_bytes()    # payload de LOAD (little-endian)
    program.words                   # list[int], una por dirección desde 0
    program.source_map              # dirección -> (línea, texto fuente)
    program.labels                  # etiqueta -> dirección
    program.warnings                # advertencias (no impiden ensamblar)
```

## 2. Sintaxis

Es la sintaxis de GNU as / LLVM para RISC-V, con unas pocas extensiones (§2.7). Un programa
que no usa extensiones se puede ensamblar con un ensamblador estándar y da las mismas palabras
(§7).

```asm
# Suma 1..N en a0
        .equ    N, 10

        li      t0, N           # contador
        li      a0, 0           # acumulador
bucle:  beqz    t0, fin
        add     a0, a0, t0
        addi    t0, t0, -1
        j       bucle           # salto hacia atrás
fin:    sw      a0, 0(zero)     # dmem[0] = 55
        halt
```

### 2.1 Líneas

```
[etiqueta:]... [instrucción | directiva] [# comentario]
```

- Una instrucción por línea. Las líneas vacías y las de solo comentario se ignoran.
- **Comentarios:** desde `#` o `//` hasta el fin de línea (`//` es una extensión: GNU as no
  lo acepta).
- **Mayúsculas:** las instrucciones y los registros no distinguen mayúsculas (`ADDI X1, ZERO, 5`);
  las etiquetas sí (`Loop` ≠ `loop`).
- Los operandos se separan con comas; los espacios son libres.

### 2.2 Instrucciones

Todas las de [`isa.md`](../../docs/spec/isa.md), con los operandos en el orden estándar:

| Forma | Instrucciones | Operandos | Rango del inmediato |
|---|---|---|---|
| R | `add sub sll srl sra and or xor slt sltu` | `rd, rs1, rs2` | — |
| I | `addi andi ori xori slti sltiu` | `rd, rs1, imm` | −2048 … 2047 |
| Shift | `slli srli srai` | `rd, rs1, shamt` | 0 … 31 |
| Load | `lb lh lw lbu lhu` | `rd, offset(rs1)` o `rd, (rs1)` | −2048 … 2047 |
| Store | `sb sh sw` | `rs2, offset(rs1)` o `rs2, (rs1)` | −2048 … 2047 |
| Branch | `beq bne` | `rs1, rs2, destino` | −4096 … 4092, múltiplo de 4 |
| `jal` | `jal` | `rd, destino` o `destino` (`rd = ra`) | −1 048 576 … 1 048 572, múltiplo de 4 |
| `jalr` | `jalr` | `rd, offset(rs1)`, `rd, rs1, offset`, `rd, rs1` o `rs1` (`rd = ra`) | −2048 … 2047 |
| U | `lui` | `rd, imm20` | 0 … 0xFFFFF |
| HALT | `halt` o `ebreak` | — | Las dos dan `0x00100073` |

El inmediato de `lui` son los 20 bits altos, no el valor final: `lui sp, 1` deja `sp = 0x1000`.

### 2.3 Registros

`x0` … `x31` y los nombres ABI: `zero ra sp gp tp t0-t6 s0-s11 a0-a7`, y `fp` (= `s0`).

### 2.4 Inmediatos y constantes

- Decimal (`-5`), hexadecimal (`0x7ff`, `-0x800`) o binario (`0b1010`); `_` como separador
  (`0xF_FFFF`).
- Un número con cero a la izquierda (`010`) es un **error**: GNU as lo lee en octal, y así el
  mismo `.s` no significa cosas distintas según el ensamblador.
- El rango se verifica siempre con signo (como GNU as y LLVM): `andi t0, t1, 0xfff` es un
  error y hay que escribir `-1`.
- Constantes con `.equ NOMBRE, valor` (o `.set`), usables como inmediato, offset o destino
  numérico. Se pueden usar antes de definirlas, salvo en `li` (su tamaño depende del valor).

### 2.5 Etiquetas y saltos

- `nombre:` al comienzo de la línea, sola o antes de una instrucción; puede haber varias
  seguidas. Nombre: letras, dígitos, `_`, `.` y `$`, sin empezar con dígito. No puede ser un
  registro ni una instrucción.
- La etiqueta vale la dirección de la instrucción siguiente. El código empieza en `0x0`
  ([`memoria.md`](../../docs/spec/memoria.md) §2.2).
- **Destino de un salto** (`beq`, `bne`, `jal`, `j`, `beqz`, `bnez`):
  - **etiqueta:** el ensamblador calcula `destino − PC` (hacia adelante o hacia atrás);
  - **número:** es directamente el desplazamiento, `PC += imm` como en `isa.md`
    (`beq x1, x2, -8` salta dos instrucciones atrás). Así lo interpreta LLVM.
- El desplazamiento tiene que ser múltiplo de 4: no hay instrucciones comprimidas.

### 2.6 Pseudo-instrucciones

Solo las que se arman con instrucciones del ISA:

| Pseudo | Se expande a |
|---|---|
| `nop` | `addi x0, x0, 0` |
| `mv rd, rs` | `addi rd, rs, 0` |
| `not rd, rs` | `xori rd, rs, -1` |
| `neg rd, rs` | `sub rd, x0, rs` |
| `li rd, valor` | Entre −2048 y 2047: `addi rd, x0, valor`. Si no: `lui rd, %hi(valor)` + `addi rd, rd, %lo(valor)` (sin el `addi` si `%lo = 0`). `valor` de 32 bits, con o sin signo |
| `j destino` | `jal x0, destino` |
| `jr rs` | `jalr x0, 0(rs)` |
| `ret` | `jalr x0, 0(ra)` |
| `beqz rs, destino` | `beq rs, x0, destino` |
| `bnez rs, destino` | `bne rs, x0, destino` |

`li` puede ocupar 2 palabras; las direcciones de lo que sigue ya lo tienen en cuenta. Las
pseudos que necesitan instrucciones que no están (`la`, `call`, `bgt`, `ble`, `bltz`, …) dan un
error que lo explica.

### 2.7 Directivas

| Directiva | Qué hace |
|---|---|
| `.word v1, v2, …` | Una palabra por valor (número de 32 bits o etiqueta). Sirve para probar palabras que no son instrucciones del ISA (se ejecutan como NOP, `pipeline.md` §4.4) |
| `.equ NOMBRE, valor` / `.set` | Constante (§2.4) |
| `.text`, `.globl`, `.global` | Se aceptan y se ignoran (compatibilidad con GNU as) |
| `.data`, `.byte`, `.section`, … | **Error**: no hay datos inicializados; `LOAD` pone `dmem` en cero y los datos se escriben con stores (`memoria.md` §2.2) |

Extensiones respecto de GNU as/LLVM: `halt`, comentarios `//` y mayúsculas en registros.

## 3. Restricciones del programa

| Regla | Por qué |
|---|---|
| Como máximo **1024 palabras**, contando el HALT y las 2 palabras de cada `li` largo | Tamaño de `imem` (`memoria.md` §2.2) |
| Al menos una palabra | `LOAD` exige `N ≥ 1` |
| Sin `halt` → **advertencia**, no error | Después de la última palabra `LOAD` rellena con HALT, así que el programa igual se detiene (`memoria.md` §6.1) |

## 4. Formatos de salida

Ejemplo: el programa de [`protocolo_debug.md`](../../docs/spec/protocolo_debug.md) §4,
`addi x1, x0, 5` y `halt`.

| Formato | Contenido | Para qué |
|---|---|---|
| `.hex` | Una palabra por línea, 8 dígitos hex, sin prefijo | `$readmemh` en los testbenches; la interfaz de la PC lo carga con F2 |
| `.bin` | Las palabras en **little-endian**, sin encabezado | Es exactamente el payload de `LOAD` |
| `.coe` | Archivo de inicialización de Xilinx | Block Memory Generator de `imem` (`memoria.md` §3.6) |
| `.lst` | Dirección, palabra, línea y fuente, con las etiquetas | Para leer y depurar |

```text
programa.hex          programa.bin (bytes)          programa.coe
00500093              93 00 50 00 73 00 10 00       memory_initialization_radix=16;
00100073                                            memory_initialization_vector=
                                                    00500093,
                                                    00100073;
```

El `.bin` es el payload de la trama `LOAD` del protocolo
(`A5 10 08 00 | 93 00 50 00 73 00 10 00 | B8`); el test `test_output.py` lo verifica.

En un testbench:

```verilog
reg [31:0] imem [0:1023];
initial $readmemh("programa.hex", imem);   // con --fill no quedan posiciones sin inicializar
```

Listado (`.lst`) de `tests/programs/fibonacci.s`:

```text
0x0000  00001137    12 | lui     sp, 1                   # sp = 0x1000 (tope de la pila)
0x0004  00a00513    13 | li      a0, N
0x0008  008000ef    14 | jal     ra, fib_tabla
0x000c  00100073    15 | halt
                    fib_tabla:
0x0010  ffc10113    19 | addi    sp, sp, -4
```

## 5. Errores

Cada error indica archivo, línea y la línea fuente. El ensamblador **no se detiene en el
primero**: los informa todos (en orden de línea) y no genera salida.

```text
malo.s:3: error: registro inexistente 'x33'
    3 | add  x2, x1, x33     # reg malo
malo.s:4: error: instruccion 'blt' no soportada por este procesador (ver docs/spec/isa.md)
    4 | blt  x1, x2, inicio
malo.s:5: error: inmediato de 12 bits fuera de rango: 5000 (permitido -2048 a 2047)
    5 | addi x3, x0, 5000
malo.s:6: error: etiqueta no definida 'fin'
    6 | j    fin
4 errores; no se genero salida
```

| Caso | Mensaje |
|---|---|
| Mnemónico desconocido | `instruccion invalida 'mul'` |
| RV32I que no está en `isa.md` | `instruccion 'blt' no soportada por este procesador` |
| Registro | `registro inexistente 'x32'` |
| Inmediato | `inmediato de 12 bits fuera de rango: 2048 (permitido -2048 a 2047)` (igual para `shamt`, offset, `lui`, `li`, `.word`) |
| Salto | `desplazamiento de branch fuera de rango`, `... no es multiplo de 4` |
| Etiquetas | `etiqueta no definida`, `etiqueta 'a' duplicada (definida en la linea 1)` |
| Operandos | `'add' espera 3 operandos y recibio 2`, `se esperaba 'offset(registro)'`, `operando vacio` |
| Directivas | `directiva desconocida`, `.data` no soportada |
| Programa | más de 1024 palabras, programa vacío |

## 6. Tests

```sh
pip install -r tools/assembler/requirements-dev.txt
python -m pytest tools/assembler                                  # todos
python -m pytest tools/assembler/tests/test_errors.py             # un archivo
python -m pytest tools/assembler/tests/test_errors.py -k rango -v # filtrar por nombre
```

> **No se ejecutan con `python archivo.py`.** Los archivos de `tests/` solo definen
> funciones `test_*`: las descubre y ejecuta **pytest**. Además, el que agrega
> `tools/assembler/` al path para poder importar `rvasm` es `tests/conftest.py`, y ese
> archivo lo carga pytest. Con `python tools/assembler/tests/test_errors.py` falla con
> `ModuleNotFoundError: No module named 'rvasm'`, y aunque importara, no correría ningún test.

En `test_reference.py`, los 2 tests en vivo se saltean (`s`) si no hay un ensamblador
RISC-V estándar instalado (§7); `-rs` muestra el motivo. No es una falla: la comparación
contra la referencia guardada corre igual.

| Archivo | Qué prueba |
|---|---|
| `test_encoding.py` | Cada instrucción de `isa.md` contra su palabra esperada **obtenida con LLVM** (no con rvasm), con inmediatos negativos, extremos de rango y saltos hacia adelante y hacia atrás hasta los límites de los formatos B y J. Verifica además que `isa.py` coincide con la tabla de `isa.md` |
| `test_syntax.py` | Etiquetas, comentarios, mayúsculas, nombres ABI, formas de operandos, `.equ`, `.word`, expansión de pseudos y que `li` reconstruye el valor exacto |
| `test_errors.py` | Cada error, su línea y su mensaje; varios errores juntos; límite de 1024 palabras; advertencia sin HALT |
| `test_output.py` | Los cuatro formatos, `--fill` y la CLI (archivos, stdout, códigos de salida) |
| `test_reference.py` | Los programas de `tests/programs/` contra la salida de un ensamblador estándar (§7) |

## 7. Validación contra un ensamblador estándar

`tests/programs/` tiene programas que solo usan sintaxis estándar:

- `isa_completo.s`: todas las instrucciones y pseudos, extremos de cada formato, saltos en las
  dos direcciones.
- `fibonacci.s`: un programa real con subrutina, pila y bucle.

`validate_reference.py` los ensambla con rvasm y con un ensamblador estándar, y compara palabra
por palabra. La salida del estándar queda guardada en `tests/reference/*.hex`, y contra esos
archivos comparan los tests, así que **no hace falta tener el toolchain para correrlos**.

```sh
pip install ziglang                                  # LLVM empaquetado (Windows y Linux)
python tools/assembler/validate_reference.py         # compara
python tools/assembler/validate_reference.py --update   # regenera tests/reference/
python tools/assembler/validate_reference.py mio.s   # valida un programa propio
```

Busca, en orden: GNU as (`riscv64-unknown-elf-as`, `riscv32-unknown-elf-as`,
`riscv-none-elf-as`), `clang` + `llvm-objcopy`, o `ziglang` (`--tool` fuerza uno). Ensambla con
`-march=rv32i` (en zig, `-mcpu=generic_rv32`: sin extensión C) y `-mno-relax`, y extrae `.text`
con `objcopy`. Antes cambia `halt` por `ebreak` y `//` por `#`.

Resultado actual: con **LLVM (zig 0.16.0)**, `isa_completo.s` (79 palabras) y `fibonacci.s`
(23 palabras) dan **idénticos**.

Diferencias encontradas al validar, que no son errores de rvasm:

- **`li` con algunos valores.** Para `li a1, 2048`, LLVM genera `addi a1, x0, 1` +
  `slli a1, a1, 11` y rvasm `lui a1, 1` + `addi a1, a1, -2048`, como GNU as. Las dos secuencias
  dejan el mismo valor; el test `test_li_values_reconstruct_exactly` lo verifica para rvasm.
  Por eso ese caso no está en `isa_completo.s`.
- **Saltos a símbolos `.globl`.** Un ensamblador estándar no resuelve en el objeto los saltos
  a un símbolo global (deja una relocación para el linker y LLVM además convierte el `beq` en
  `bne` + `jal`). rvasm genera la imagen final sin linker, así que en los programas de
  validación no se marca global ninguna etiqueta destino de un salto.
- **`.word etiqueta`** también deja una relocación en el objeto, así que tampoco está en los
  programas de validación (lo cubre `test_syntax.py`).

## 8. Estructura

```
tools/assembler/
├── asm.py                  Punto de entrada de la CLI
├── validate_reference.py   Validación contra GNU as / LLVM
├── requirements-dev.txt    pytest (y ziglang, opcional)
├── rvasm/
│   ├── isa.py              Tablas de registros e instrucciones (copia de isa.md)
│   ├── assembler.py        Dos pasadas: direcciones y etiquetas, después codificación
│   ├── output.py           Formatos hex, bin, coe, lst
│   └── cli.py
└── tests/
    ├── programs/           Programas de validación (.s)
    ├── reference/          Su salida según LLVM (.hex, no editar a mano)
    └── test_*.py
```

**Si cambia `isa.md`:** se actualiza `rvasm/isa.py` (el test
`test_instruction_table_matches_isa_md` falla hasta que coincidan), se agregan casos en
`test_encoding.py` y en `isa_completo.s`, y se corre `validate_reference.py --update`.
