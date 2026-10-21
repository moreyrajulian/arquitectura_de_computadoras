# 025 - Filtro de palabras fuera de isa.md en el toolchain

- **Estado:** Aceptada
- **Fecha:** 2026-10-21
- **Autores:** Costamagna, Matías

## Contexto
La decisión [024](024_instrucciones-no-soportadas.md) dejó al hardware decodificando solo por
opcode. Una palabra que no está en [`isa.md`](../spec/isa.md) puede caer en dos casos:

| Caso | Ejemplos | Qué hace el hardware |
|---|---|---|
| Opcode fuera de la tabla de [`pipeline.md`](../spec/pipeline.md) §4.4, o SYSTEM distinta del HALT | `0x0000_0000`, `auipc`, `fence`, `ecall` | NOP |
| Opcode de la tabla con `funct3`/`funct7` fuera de `isa.md` | `blt`, `mul`, `jalr` con `funct3 ≠ 000` | Ejecuta la fila de su opcode; el resultado no está especificado |

La 024 se apoya en que las herramientas no generan esas palabras, pero eso era cierto solo en
parte:
- El ensamblador rechaza los mnemónicos fuera de `isa.md`
  (decisión [017](017_ensamblador.md)), pero `.word` aceptaba cualquier valor de 32 bits. Su
  README decía que lo que está fuera del ISA se ejecuta como NOP, y eso solo vale en el primer
  caso: un `.word` con la codificación de `blt` salta como `beq`.
- La interfaz de la PC carga también `.hex` y `.bin` con `F2`
  ([`interfaz_pc.md`](../spec/interfaz_pc.md) §3), que no pasan por el ensamblador.
- El modelo de referencia (decisión [020](020_modelo-de-referencia.md)) termina con error en el
  segundo caso y ejecuta el primero como NOP, igual que el hardware.

Restricciones:
- El hardware no cambia: la 024 descartó agregar lógica en ID para anular o avisar.
- `imem` y `dmem` son espacios separados ([`memoria.md`](../spec/memoria.md)): los loads leen
  `dmem`, así que una palabra en `imem` solo puede ejecutarse como instrucción. `.word` no
  sirve para datos.
- Ningún programa de `sw/` usa `.word`. El NOP ante un opcode no reconocido ya lo prueba
  `control_unit_tb.v`, que barre los 128 opcodes
  ([`verificacion.md`](../spec/verificacion.md) §3).

## Opciones consideradas
1. **A — Sin filtro en `.word`.** Queda como estaba.
   - Ventajas: no cambia nada; `.word` permite cargar cualquier palabra a propósito.
   - Desventajas: una palabra con resultado no especificado llega al hardware sin aviso, que es
     justo lo que la 024 suponía que no pasaba.
2. **B — Filtrar solo el resultado no especificado.** `.word` acepta las palabras de `isa.md`
   y las que el hardware ejecuta como NOP.
   - Ventajas: todo lo que se acepta tiene comportamiento definido; se puede escribir un
     programa que pruebe el NOP en el pipeline completo.
   - Desventajas: un `auipc` o un `fence` de código ajeno se vuelve NOP sin aviso, y el
     programa no hace lo que su autor esperaba. El uso que habilita no lo necesita ningún
     programa.
3. **C — Filtrar todo lo que no está en `isa.md`.** El toolchain solo produce palabras de
   `isa.md`, también con `.word`.
   - Ventajas: la regla es una sola y fácil de verificar. Cierra el caso de `auipc`. Lo que el
     hardware haga con otra palabra solo importa si alguien carga `imem` sin pasar por el
     toolchain.
   - Desventajas: `.word` queda casi redundante (solo sirve para escribir una instrucción por su
     codificación) y deja de aceptar etiquetas: una dirección está alineada a 4, tiene
     `bits[1:0] = 00` y nunca es un opcode de RV32I. Probar el NOP con un programa necesitaría
     una opción explícita.

## Decisión
**Opción C.** Una sola función, `classify(palabra)` en `tools/assembler/rvasm/isa.py`, separa
las tres clases (`SUPPORTED`, `UNRECOGNIZED`, `UNSPECIFIED`) con la misma regla que la tabla de
§4.4. La usan el ensamblador para `.word`, los chequeos de `sw/` y la interfaz de la PC antes de
`LOAD`. Sale de las tablas de `isa.py`, así que si `isa.md` crece, el filtro crece con ella.

El modelo de referencia no la usa: mantiene su propio decodificador a propósito. Un test barre
opcode × `funct3` × `funct7` y verifica que los dos coinciden. Si compartieran la tabla, un error
en ella pasaría por los dos sin que nadie lo vea.

## Consecuencias
- **Hardware:** sin cambios; la 024 sigue vigente.
- **Ensamblador:** `.word` da error con todo valor fuera de `isa.md`, y el mensaje dice qué
  haría el hardware (NOP o resultado no especificado). Una etiqueta en `.word` da error. Se
  ajustaron `isa_completo.s` (sin el `-1`, con su referencia regenerada con LLVM) y
  `test_syntax.py`, y el README del ensamblador describe las tres clases.
- **`sw/test_programas.py`:** usa `classify` en lugar de su propio decodificador.
- **Modelo de referencia:** no cambia. Sigue ejecutando como NOP los opcodes no reconocidos,
  porque modela el hardware y tiene que reproducir lo que pasa con un `.hex` cargado sin
  filtro.
- **Interfaz de PC (I-50, I-52):** un `.hex` o `.bin` se valida con `classify` antes de
  `LOAD`, y se rechaza si tiene alguna palabra fuera de `isa.md`
  ([`interfaz_pc.md`](../spec/interfaz_pc.md) §3). El desensamblador (I-51) puede usarla para
  mostrar esas palabras como no soportadas.
- **A revisar si cambia un supuesto:** si hace falta cargar a propósito palabras que el
  hardware ejecuta como NOP (por ejemplo, para probar el NOP en el pipeline completo), se
  agrega una opción explícita en el ensamblador, sin cambiar el comportamiento por defecto.
