# 034 - Desensamblador: `rvasm` envuelve el del modelo de referencia

- **Estado:** propuesta
- **Fecha:** 2026-11-10
- **Autores:** Costamagna, Matías

## Contexto
La interfaz de la PC muestra instrucciones legibles: el programa cargado con su desensamblado
y la instrucción de cada etapa ([`interfaz_pc.md`](../spec/interfaz_pc.md) §2). La I-51 pide
traducir a texto todas las instrucciones de [`isa.md`](../spec/isa.md) y que ensamblar →
desensamblar → ensamblar dé el mismo código.

Lo que ya había:
- **El modelo de referencia** (decisión [020](020_modelo-de-referencia.md)) tiene `decode` y
  `disassemble` en `tools/isasim/isasim/isa.py`, con tablas propias escritas desde `isa.md`
  (`verificacion.md` §2). Los usa para la traza. Su texto ya lo acepta `rvasm`: los 39
  programas de `sw/` vuelven a ensamblar igual.
- **`decode` termina con error** ante una palabra con opcode de la tabla y `funct3`/`funct7`
  fuera de `isa.md`, y así tiene que seguir: ese error es lo que mantiene a los programas de
  prueba dentro de `isa.md` (decisión [024](024_instrucciones-no-soportadas.md)). La interfaz,
  en cambio, no puede caerse por una palabra rara: tiene que mostrarla como no soportada.
- **`classify`** (decisión [025](025_filtro-de-palabras-en-el-toolchain.md)) ya separa las
  palabras de `isa.md`, las que el hardware ejecuta como NOP y las de resultado no
  especificado, y `tools/isasim/tests/test_isa.py` verifica que coincide con `decode` en todo
  opcode × `funct3` × `funct7`.
- **El cliente del protocolo** (`tools/debugger/rvdebug`, I-50) todavía no está en `master`.

## Opciones consideradas
1. **A — Un desensamblador nuevo en `rvasm`, con sus tablas.** Es la función inversa del
   codificador.
   - Ventajas: `rvasm` no depende de nada.
   - Desventajas: sería el tercer decodificador del proyecto. La ida y vuelta solo probaría que
     el codificador y el decodificador usan la misma tabla: un error en ella pasaría por los
     dos sin que nadie lo vea, que es lo que `verificacion.md` §2 quiere evitar.
2. **B — En la capa `model` de `rvdebug`.** Es donde lo va a usar la interfaz (`interfaz_pc.md`
   §1).
   - Ventajas: queda junto al resto de lo que decodifica la interfaz (los latches).
   - Desventajas: depende de un PR sin mergear (I-50). Los tests sin FPGA de `isasim` y de
     `sw/` no tendrían por qué importar el debugger.
3. **C — `rvasm.disassemble` envuelve el del modelo.** `classify` decide primero qué es la
   palabra; solo las de `isa.md` pasan por `decode` y `disassemble` de `isasim`.
   - Ventajas: un solo decodificador para el texto, el del modelo, independiente de las tablas
     de `rvasm`. Así la ida y vuelta cruza dos implementaciones escritas por separado. La
     interfaz ya importa `rvasm` (`assemble`, `classify`).
   - Desventajas: `rvasm` pasa a depender del modelo, y el formato del texto del modelo deja de
     ser solo de la traza: ahora lo ve la interfaz.

## Decisión
**Opción C.** `disassemble(palabra)` está en `tools/assembler/rvasm/disasm.py`:

| Palabra | Texto | Ejemplo |
|---|---|---|
| De `isa.md` | El de `isasim`: registros `x0`…`x31`, inmediatos en decimal, `lui` con los 20 bits altos en hex y saltos con el desplazamiento relativo al PC | `beq x1, x2, -8` |
| `0x00000013` | `nop`, como en `objdump`: los programas `_nops` de `sw/` están llenos | `nop` |
| Salto de `isa.md` con desplazamiento no múltiplo de 4 | `.word` con la instrucción en el comentario | `.word 0xDEADBEEF  # jal x29, -150038: desplazamiento no multiplo de 4` |
| Fuera de `isa.md` | `.word` con el motivo de `classify` y qué hace el hardware | `.word 0x0020C063  # fuera de isa.md: branch con funct3 = 100; resultado no especificado` |

Los saltos con desplazamiento no múltiplo de 4 son palabras de `isa.md` (el hardware las ejecuta
y salta a un PC desalineado, [`memoria.md`](../spec/memoria.md) §6.1), pero `rvasm` no acepta
ese desplazamiento en la fuente porque no hay instrucciones comprimidas. El `.word 0xdeadbeef`
de `tools/assembler/tests/programs/isa_completo.s` es uno. Como `.word` sí los acepta, la ida y
vuelta vale para **toda** palabra de `isa.md`, sin excepciones.

`isasim` se importa recién cuando se desensambla: `import rvasm` no carga el modelo, y el
ensamblador (la CLI, `validate_reference.py`, los tests de `sw/`) sigue sin depender de él. No hay ciclo:
`isasim` importa `rvasm` solo dentro de `load_program`.

## Consecuencias
- **`isasim`:** cambiar el texto de `disassemble` cambia lo que muestra la interfaz.
  `tools/assembler/tests/test_disasm.py` falla si el texto cambia o si `rvasm` deja de
  aceptarlo. El código de `decode` no cambia.
- **Tests:** `test_disasm.py` tiene el texto esperado de cada instrucción de `isa.md`, escrito
  a mano. La ida y vuelta corre sobre los programas de `sw/` y de `tests/programs/`, y sobre
  10 000 palabras de `isa.md` armadas al azar desde sus campos, con semilla fija.
- **Interfaz de PC (I-52, I-53):** usa `rvasm.disassemble` para el panel Programa y para la
  instrucción de cada etapa (que sale de la palabra cargada en el `pc` de cada latch).
- **A revisar si cambia un supuesto:** si la interfaz necesita nombres ABI o el destino
  absoluto de los saltos (o su etiqueta, con `Program.labels`), se agregan como opciones de
  `disassemble` sin cambiar el texto por defecto, que es el que vuelve a ensamblar.
