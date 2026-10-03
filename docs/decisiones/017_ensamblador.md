# 017 - Ensamblador propio, formatos de salida y validación

- **Estado:** propuesta
- **Fecha:** 2026-10-03
- **Autores:** Costamagna, Matías

## Contexto
Los programas de prueba se escriben a mano en ensamblador y hay que traducirlos a palabras
de 32 bits para dos destinos: el comando `LOAD` de la Debug Unit
([`protocolo_debug.md`](../spec/protocolo_debug.md) §3.3, palabras little-endian) y la
inicialización de memorias en simulación (`$readmemh` en los testbenches y `.coe` para el
Block Memory Generator, [`memoria.md`](../spec/memoria.md) §3.6). Todo tiene que poder
verificarse sin la FPGA (I-10).

Restricciones:
- El procesador implementa **un subconjunto** de RV32I ([`isa.md`](../spec/isa.md)) más
  `halt` = `ebreak` ([decisión 001](001_instruccion-halt.md)). Un `blt`, un `auipc` o una
  instrucción comprimida en un programa de prueba se ejecutaría como NOP sin aviso
  (`pipeline.md` §4.4): el error tiene que aparecer al ensamblar.
- Programa de 1024 palabras como máximo, desde la dirección 0, sin datos inicializados
  (`memoria.md` §2.2).
- La interfaz de la PC ensambla el `.s` al cargarlo (F2) y muestra los errores con su línea
  y la fuente al lado de cada dirección ([`interfaz_pc.md`](../spec/interfaz_pc.md)): necesita
  el ensamblador como biblioteca, con un mapa dirección → línea.
- Corre en Windows (PC de los integrantes) y Linux (laboratorio); las herramientas son Python
  ([decisión 008](008_interfaz-pc.md)).

## Opciones consideradas
1. **Toolchain estándar (GNU as o LLVM) + `objcopy` + un script de conversión.**
   - Ventajas: codificación correcta por construcción; sintaxis completa.
   - Desventajas: hay que instalar un toolchain cruzado en cada máquina (en Windows no hay
     paquete simple); acepta todo RV32I y la extensión C, así que **no detecta** las
     instrucciones que el procesador no tiene; los errores no hablan del ISA del proyecto; no se
     puede llamar como biblioteca desde la interfaz; hay que cuidar flags (`-march=rv32i`,
     `-mno-relax`) y relocaciones (saltos a símbolos globales quedan sin resolver sin linker).
2. **Ensamblador propio en Python, solo biblioteca estándar.**
   - Ventajas: acepta exactamente `isa.md` y da errores en términos del proyecto (instrucción
     no soportada, rango, registro); se usa como biblioteca desde la interfaz y como CLI; sin
     dependencias; la tabla de instrucciones se testea contra `isa.md`.
   - Desventajas: es código propio que puede codificar mal un campo. Se mitiga validándolo
     contra un ensamblador estándar (ver decisión).
3. **Biblioteca de terceros en Python (por ejemplo `riscv-assembler` de PyPI).**
   - Ventajas: menos código propio.
   - Desventajas: proyectos chicos y sin mantenimiento claro; tampoco restringen el subconjunto
     ni conocen `halt`; dependencia que hay que auditar igual que código propio.

Formatos de salida considerados: hex plano, binario, `.coe`, Intel HEX, `.mem` de Vivado y ELF.
Intel HEX y ELF necesitan herramientas extra para llegar a `LOAD` o a `$readmemh`; el `.mem`
con direcciones (`@0000`) no aporta nada si el programa siempre empieza en 0.

## Decisión
**Opción 2**: `tools/assembler/` (`rvasm`), Python ≥ 3.11 sin dependencias, de dos pasadas
(direcciones y etiquetas, después codificación), con cuatro salidas:

| Formato | Destino |
|---|---|
| `.hex` (por defecto): una palabra por línea, 8 dígitos | `$readmemh` y la interfaz de la PC |
| `.bin`: palabras little-endian | Payload exacto de `LOAD` |
| `.coe` | Block Memory Generator |
| `.lst`: dirección, palabra, línea fuente | Lectura y depuración |

`--fill` completa hasta 1024 palabras con HALT, que es como queda `imem` después de `LOAD`.

**Validación independiente:** `validate_reference.py` ensambla los programas de
`tools/assembler/tests/programs/` con GNU as o LLVM y compara palabra por palabra. La salida del
estándar se guarda en `tests/reference/` y los tests comparan contra esos archivos, así que
correrlos no exige el toolchain. Como referencia se usó **LLVM empaquetado en `ziglang`**
(`pip install ziglang`, Windows y Linux) con `-mcpu=generic_rv32` (sin extensión C) y
`-mno-relax`. Los valores esperados de los tests por instrucción también salen de LLVM, no de
rvasm.

Criterios de sintaxis (detalle en el [README](../../tools/assembler/README.md)):
- **Sintaxis de GNU as / LLVM**: un `.s` sin extensiones se ensambla también con un ensamblador
  estándar, y con LLVM da las mismas palabras (salvo la secuencia de algunos `li`). Las
  extensiones son `halt`, comentarios `//` y mayúsculas en registros.
- **Destino numérico de un salto = desplazamiento** (`PC += imm`, como `isa.md`; verificado
  igual en LLVM). GNU as lo interpretaría como dirección absoluta (no verificado: no había GNU
  as disponible), así que en los programas conviene usar etiquetas, que valen igual en todos.
- **Números con cero a la izquierda** (`010`) son error, porque GNU as los lee en octal.
- **`li` grande = `lui` + `addi`**, como GNU as. LLVM a veces elige otra secuencia equivalente
  (`addi` + `slli` para 2048).
- **Pseudo-instrucciones** solo si se arman con instrucciones del ISA (`nop`, `mv`, `not`,
  `neg`, `li`, `j`, `jr`, `ret`, `beqz`, `bnez`).
- **Errores**: se informan todos, con archivo, línea y la línea fuente, y no se genera salida.
  Un programa sin `halt` es una advertencia, porque `LOAD` rellena con HALT.

## Consecuencias
- **Interfaz de la PC (I-52):** importa `rvasm.assemble`; usa `Program.to_bytes()` para `LOAD`,
  `source_map` para la pestaña de fuente y `AssemblerError.errors` para mostrar errores.
- **Testbenches (I-22 en adelante):** cargan `.hex` con `$readmemh`; con `--fill` la memoria
  simulada queda igual que después de `LOAD`.
- **Programas de prueba (`sw/`):** se ensamblan con `asm.py`; pueden usar `.equ`, etiquetas y
  las pseudos listadas.
- **Si cambia `isa.md`:** hay que actualizar `rvasm/isa.py`. El test
  `test_instruction_table_matches_isa_md` lee la tabla de `isa.md` y falla hasta que coincidan.
  Después se agregan casos y se regenera la referencia con `validate_reference.py --update`.
- **Si se agrega una instrucción que necesita relocaciones** (por ejemplo `auipc` con `la`),
  los programas de validación tienen que evitar símbolos globales o hay que pasar a validar con
  un ejecutable enlazado.
- **Si HALT se recodifica** (decisión 001, consecuencias), cambia `HALT_WORD` en `isa.py` y
  `validate_reference.py` deja de poder traducir `halt` a `ebreak`.
