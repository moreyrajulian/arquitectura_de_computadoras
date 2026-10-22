# 026 - Control de la ALU en ID, sin módulo aparte

- **Estado:** Aceptada
- **Fecha:** 2026-10-21
- **Autores:** Costamagna, Matías

## Contexto
La issue I-28 (#40) pide un módulo `rtl/control/alu_control.v` que traduzca
`(ALUOp, funct3, funct7)` a la operación de la ALU, y [`verificacion.md`](../spec/verificacion.md)
§3.1 le asigna un testbench `alu_control_tb.v`. Es el esquema de dos niveles de Patterson y
Hennessy: la unidad de control principal genera un ALUOp corto según el tipo de instrucción, y
un segundo bloque, junto a la ALU en EX, lo combina con `funct3` y `funct7`.

El proyecto ya lo había resuelto de otra forma:
- [`pipeline.md`](../spec/pipeline.md) §4.5: la operación se decide completa en ID y a EX solo
  viajan los 4 bits de `alu_ctrl = {instr[30], funct3}`. En las I aritméticas `instr[30]` solo
  cuenta con `funct3 = 101`, porque en las demás es un bit del inmediato.
- `control_unit` (I-24, #36) implementa esa regla, y `control_unit_tb.v` la barre de forma
  exhaustiva (128 opcodes × 8 `funct3` × 2 valores de `instr[30]`), con `addi` de inmediato
  negativo y `srli`/`srai`.
- ID/EX (§8) lleva `alu_ctrl`. El banco incremental compara `id_ex_alu_ctrl` contra la traza
  del modelo desde M4 (decisión [021](021_banco-incremental.md), tag `etapa-id`), y el bus de
  latch de la Debug Unit lo incluye (decisión [023](023_interfaz-debug-del-core.md)).

Restricciones:
- La decisión [012](012_resolucion-saltos.md) marca como candidato a camino crítico el que
  atraviesa EX: forwarding → ALU (resta) → `zero` → `redirect` → mux del PC.
- De `funct7` solo se mira `instr[30]`. Una palabra con otro `funct7` tiene resultado no
  especificado (decisión [024](024_instrucciones-no-soportadas.md)), así que un control de ALU
  que mire `funct7` completo no tiene nada más que decodificar.

## Opciones consideradas
1. **A — Sin módulo aparte: el control de la ALU queda en `control_unit`**, como está.
   - Ventajas: una sola implementación de la tabla de §4.5, ya probada. No cambia ninguna
     interfaz, ni ID/EX, ni el modelo. La decodificación ocurre en ID, fuera del camino de EX.
   - Desventajas: no hay un bloque "control de ALU" separado como en el libro, y quien lo
     busque tiene que saber que está en la unidad de control. Hay que corregir la issue y
     `verificacion.md`.
2. **B — `alu_control` como submódulo de `control_unit`, en ID.** La unidad principal genera
   un ALUOp interno de 2 bits (ADD, SUB, R, I aritmética) y `alu_control` lo traduce a
   `alu_ctrl`.
   - Ventajas: cumple la letra de la issue y muestra el bloque del libro, sin cambiar la
     interfaz de `control_unit` ni ID/EX.
   - Desventajas: la misma lógica repartida en dos módulos, códigos ALUOp nuevos en
     `riscv_defs.vh`, cobertura duplicada entre `control_unit_tb` y `alu_control_tb`, y
     cambios en §4.4 y §4.5, todo sin cambiar el comportamiento. Toca un módulo ya integrado
     y validado (I-24, I-27).
3. **C — `alu_control` en EX, como en el libro.** ALUOp, `funct3` e `instr[30]` viajan por
   ID/EX y la operación se decide en EX.
   - Ventajas: el esquema del libro tal cual.
   - Desventajas: cambia ID/EX (§4.6, §8), el bus de latch, la traza del modelo y los
     testbenches de M4, ya validados. Además pone la decodificación delante de la ALU, en el
     camino que la 012 marca como crítico.

## Decisión
**Opción A.** El control de la ALU es la regla de §4.5 dentro de `control_unit`, y no hay un
módulo `alu_control`. La spec ya lo fijaba así: B agrega un módulo y pruebas sin cambiar el
comportamiento, y C cambia interfaces validadas y alarga el camino crítico.

## Consecuencias
- **`verificacion.md` §3.1, fila I-28:** cubre solo `alu`, con `alu_tb.v`. Los casos del
  control de ALU (`{instr[30], funct3}` en R; en I aritmética el bit 30 solo con
  `funct3 = 101`) quedan a cargo de `control_unit_tb.v` (fila I-24), que ya los prueba.
- **`pipeline.md`:** §4.5 remite a esta nota y §11 la agrega a la tabla de referencias. La
  regla y los códigos no cambian.
- **I-28 (#40):** el criterio de `alu_control.v` se cumple con `control_unit` (§4.5).
- **A revisar si cambia un supuesto:** si se agregan operaciones que no entran en
  `{instr[30], funct3}` (por ejemplo la extensión M, que se distingue por `funct7 = 0000001`),
  `alu_ctrl` crece y la regla se amplía en `control_unit`. Recién entonces podría convenir
  separarla en un submódulo como el de B.
