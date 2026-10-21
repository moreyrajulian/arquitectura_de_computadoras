# 024 - Instrucciones no soportadas: decodificación solo por opcode

- **Estado:** aceptada
- **Fecha:** 2026-10-14
- **Autores:** Moreyra, Julián

## Contexto
La I-24 pide que la unidad de control trate un opcode no soportado como NOP, con la decisión
documentada. La tabla de verdad de [`pipeline.md`](../spec/pipeline.md) §4.4 ya define dos
casos: un opcode que no está en la tabla (por ejemplo `0x0000_0000`, `auipc` o `fence`) y una
palabra SYSTEM distinta del HALT (`ecall`; el HALT se compara contra la palabra completa,
decisión [001](001_instruccion-halt.md)). Los dos salen con todas las señales en 0.

Queda sin definir un tercer caso: una palabra con un **opcode conocido** y `funct3`/`funct7`
que no están en [`isa.md`](../spec/isa.md). Por ejemplo:

| Opcode | Palabras fuera de `isa.md` |
|---|---|
| `BRANCH` | `blt`, `bge`, `bltu`, `bgeu` y los `funct3` reservados `010`, `011` |
| `LOAD` | `funct3` `011`, `110`, `111` |
| `STORE` | `funct3` de `011` a `111` |
| `OP` (tipo R) | `funct7` distinto de `0000000` y `0100000` (por ejemplo `mul`, extensión M); `instr[30] = 1` con un `funct3` que no es `000` ni `101` |
| `OP-IMM` | `slli`/`srli`/`srai` con otros bits de `funct7` |
| `JALR` | `funct3` distinto de `000` |

Ninguna herramienta del proyecto genera esas palabras: el ensamblador las rechaza
(decisión [017](017_ensamblador.md)) y solo pueden aparecer con `.word`, o por un programa
cargado con otra herramienta. El modelo de referencia no las ejecuta: termina con error
(código de salida 3) y dice que el hardware las ejecutaría según su opcode
(decisión [020](020_modelo-de-referencia.md)).

Restricciones:
- La unidad de control está en ID, en el camino que empieza a la salida de la BRAM de
  programa. Por ahí pasan también la detección de load-use (decisión
  [011](011_deteccion-load-use.md)) y la parada por HALT (§3.4).
- La consigna evalúa el camino crítico y la frecuencia, no la robustez ante programas mal
  formados.
- La tabla de §4.4 es la que implementan la unidad de control y el modelo, y contra la que se
  comparan los latches en el banco incremental (decisión [021](021_banco-incremental.md)).

## Opciones consideradas
1. **A — Decodificar solo por opcode.** Cada opcode conocido recibe su fila de la tabla de
   §4.4, sin mirar `funct3` ni `funct7` (salvo `instr[30]` y `funct3` para `alu_ctrl`, §4.5).
   - Ventajas: es la tabla de §4.4 tal como está, y lo que ya supone el modelo. La lógica es la
     más chica: un `case` sobre 7 bits y el comparador del HALT. No agrega nada en el camino de
     ID.
   - Desventajas: una palabra fuera de `isa.md` se ejecuta y tiene efectos (escribe un
     registro, memoria o salta), con un resultado que depende de cómo cada etapa interpreta
     `funct3` y `alu_ctrl`. `blt`, por ejemplo, se comporta como `beq` o `bne` según
     `funct3[0]` (§5.3).
2. **B — Decodificar `funct3` y `funct7` completos y anular lo que no está en `isa.md`.** Toda
   palabra que no sea una fila de `isa.md` sale como NOP.
   - Ventajas: el comportamiento ante cualquier palabra queda definido y sin efectos.
   - Desventajas: comparadores de `funct3` por opcode y de `funct7` en tipo R y en los
     desplazamientos, que se suman a todas las señales de control en ID. Cambia la tabla de
     §4.4 y el modelo de referencia, para un caso que ningún programa del proyecto contiene.
     Además, una instrucción anulada sin aviso sigue siendo un error silencioso: el programa
     no hace lo que su autor esperaba.
3. **C — B más un aviso de instrucción ilegal.** Como B, y además un bit persistente que la
   Debug Unit informa, como `imem_fault` ([`memoria.md`](../spec/memoria.md) §6.2).
   - Ventajas: el error deja de ser silencioso.
   - Desventajas: todo lo de B, más un registro y un bit nuevo en el bloque de estado del
     protocolo ([`protocolo_debug.md`](../spec/protocolo_debug.md)), la interfaz de PC y el
     `.exp`.

## Decisión
**Opción A.** La unidad de control decodifica por opcode y compara la palabra completa solo
para el HALT:

- **Opcode que no está en §4.4, o SYSTEM distinto de `0x0010_0073`:** se comporta como NOP,
  con todas las señales en 0.
- **Opcode conocido con `funct3`/`funct7` fuera de `isa.md`:** recibe el control de la fila de
  su opcode, y **su resultado no está especificado**. Ningún testbench ni programa de prueba
  lo usa como caso esperado.

Es la tabla de §4.4 sin cambios, la misma que implementa el modelo, y no agrega lógica en ID.
B y C protegen contra programas que las herramientas del proyecto no pueden generar.

## Consecuencias
- **`pipeline.md` §4.4** aclara que la decodificación es por opcode y remite a esta nota; §11
  la agrega a la tabla de referencias.
- **`control_unit` (I-24)** implementa exactamente la tabla de §4.4. Su testbench barre los 128
  opcodes con todos los `funct3` y los dos valores de `instr[30]` y comprueba que las
  palabras de opcode conocido reciben la fila de su opcode y que el resto sale como NOP.
- **EX, MEM y WB (I-28, I-29, I-32, I-35)** no tienen que tratar los `funct3` ni los códigos
  de `alu_ctrl` que no están en sus tablas (§4.5, §5.3, §6.2, §7.1). Lo que hagan con ellos no
  está especificado, y no hace falta probarlo.
- **Modelo de referencia:** no cambia. Su error ante estas palabras es lo que mantiene a los
  programas de prueba dentro de `isa.md`.
- **Interfaz de PC (I-51, desensamblador):** puede mostrar estas palabras como no soportadas,
  aunque el hardware las ejecute.
- **A revisar si cambia un supuesto:** si se agregan instrucciones (por ejemplo `blt` o la
  extensión M), se agregan como filas o columnas nuevas de §4.4 y del modelo. Si en la placa
  hace falta detectar programas mal cargados, la opción C es la extensión natural.
