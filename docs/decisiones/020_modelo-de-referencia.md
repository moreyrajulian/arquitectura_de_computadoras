# 020 - Modelo de referencia: semántica de la ISA más pipeline ciclo a ciclo

- **Estado:** propuesta
- **Fecha:** 2026-10-05
- **Autores:** Moreyra, Julián

## Contexto
El plan de verificación usa tres fuentes de lo esperado, escritas por separado: el `.exp` a
mano, el modelo de referencia y el RTL ([`verificacion.md`](../spec/verificacion.md) §2). La
I-16 pide un modelo que produzca el estado final y, para cada instrucción, el contenido
esperado de IF/ID, ID/EX, EX/MEM y MEM/WB en archivos que el testbench lea con `$readmemh`.

Restricciones:
- **Nivel 2** (banco de pruebas incremental, I-17): cada registro de segmentación tiene que
  coincidir con la traza del modelo **en todos los ciclos**, incluidos `valid` y el control
  (`verificacion.md` §6).
- **Ciclos:** el modelo tiene que dar el mismo `ciclos` que el `.exp`
  (`n + 4 + stalls + 2 · saltos_tomados`, `verificacion.md` §5).
- **Independencia:** si el modelo copia el diseño del RTL, un error de interpretación queda en
  los dos lados y la prueba pasa igual (`verificacion.md` §2).
- **Etapas intermedias:** hasta M7 el pipeline no tiene forwarding, stall ni flush por saltos,
  y se prueba con los `indep_*` y las variantes `_nops` (decisión 018 de programas de prueba).
- Python, como el ensamblador ([017](017_ensamblador.md)).

El contenido de un latch **no siempre es un valor de la ISA**. En `addi x1, x0, 5` seguido de
`add x2, x1, x1`, cuando el `add` está en ID el `addi` todavía no escribió `x1`: el banco
devuelve 0 y eso queda en `id_ex_rs1_data`; el forwarding lo corrige en EX. Lo mismo pasa con
el resultado de la ALU en un `beq` (la resta), con la palabra que lee la memoria de datos en
un store (`READ_FIRST`) o con el registro que nombran los bits del inmediato en un `addi`.
Para conocer esos valores hay que saber en qué ciclo pasa cada instrucción por cada etapa.

## Opciones consideradas
1. **A — Simulador de la ISA, sin tiempos.** Ejecuta instrucción por instrucción y la traza
   dice qué campos lleva cada instrucción.
   - Ventajas: simple; no depende del diseño del pipeline.
   - Desventajas: no puede calcular los campos que dependen del ciclo (el ejemplo de arriba
     daría 5 en lugar de 0, y el testbench marcaría un error que no existe); no da los ciclos;
     no cumple el nivel 2.
2. **B — Pipeline ciclo a ciclo, solo.** Simula las cinco etapas con las fórmulas de
   `pipeline.md`.
   - Ventajas: da todos los campos en todos los ciclos.
   - Desventajas: es una segunda implementación del mismo diseño. Si una fórmula de
     `pipeline.md` está mal, o si se entendió mal la ISA al escribirla, el modelo y el RTL
     coinciden en el error.
3. **C — Dos capas que se controlan entre sí.** Una capa ejecuta `isa.md` instrucción por
   instrucción; otra simula el pipeline ciclo a ciclo con `pipeline.md`. Cada instrucción que
   llega a WB, y cada store en MEM, se compara con la capa de la ISA; si no coinciden, el
   modelo se detiene.
   - Ventajas: los valores que se escriben en registros y memoria están respaldados por la
     ISA, escrita aparte; la capa del pipeline solo aporta tiempos y contenido de latches, y
     cualquier contradicción entre `isa.md` y `pipeline.md` aparece como un error. Con modos
     sin forwarding, stall o flush, la misma comparación detecta un programa que necesita un
     mecanismo que esa etapa del plan todavía no tiene.
   - Desventajas: más código que A. Las **reglas de tiempos** (un stall por carga-uso, dos
     ciclos por salto tomado, la parada por HALT) siguen saliendo de `pipeline.md`: si una de
     esas reglas estuviera mal, el modelo y el RTL coincidirían.

## Decisión
**Opción C**, en `tools/isasim/` ([README](../../tools/isasim/README.md)).

- **Capa 1 (`isa.py`):** semántica de `isa.md` y de `memoria.md` §5–§6. Decodifica por su
  cuenta, sin las tablas del ensamblador, para no compartir un error de codificación con él.
- **Capa 2 (`pipeline.py`):** las fórmulas de `pipeline.md` §3 a §10 (memorias sincrónicas,
  bypass del banco, forwarding, carga-uso conservadora, saltos en EX, HALT).
- **Modos:** `completo` (M8 en adelante), `sin_riesgos` (M3 a M7) y combinaciones para las
  integraciones intermedias de M8. Sin flush, la capa 1 ejecuta también las dos instrucciones
  que siguen a un salto tomado, como lo hace el hardware.
- **Formato de la traza:** un archivo `$readmemh` por latch con una línea por ciclo, los
  campos de `pipeline.md` §8 en el orden de su tabla y el primero en los bits más altos, y
  otro archivo con la **máscara** de bits a comparar. En una burbuja se comparan solo `valid`
  y el control; el inmediato de una instrucción sin inmediato no se compara. Las reglas de
  comparación quedan en el modelo y el testbench solo hace `(dut ^ ref) & mask`. También se
  genera la traza por instrucción que pide la issue, con el mismo formato.
- **Estado final:** en el formato del `.exp` y como payload de `READ_ALL`.

El riesgo de que una regla de tiempos esté mal lo cubren los `ciclos` de los `.exp`, que se
calcularon a mano con la fórmula de `verificacion.md` §5, y los testbenches unitarios de la
unidad de riesgos (I-41 e I-42). Al cerrar esta nota, el modelo coincide con el `.exp` de los
38 programas de `sw/` en modo completo, ciclos incluidos, y con los 26 de M7 en `sin_riesgos`;
los 12 que necesitan los mecanismos de riesgo fallan en ese modo, como corresponde.

## Consecuencias
- **Banco de pruebas incremental (I-17):** lee `<programa>.ciclo.<latch>.hex` y su `.mask.hex`
  y compara `(dut ^ ref) & mask` en cada ciclo, con las señales del RTL concatenadas en el
  orden de `pipeline.md` §8. Hasta M7 usa `--modo sin_riesgos`. Con el pipeline parcial
  (M3 a M6) compara solo los latches integrados y hasta que el HALT llega al último.
- **Volcado de la Debug Unit (I-48):** el empaquetado de los latches de esta nota es una
  propuesta para cerrar la tabla provisoria de `READ_LATCHES`
  ([`protocolo_debug.md`](../spec/protocolo_debug.md) §3.6): 3 + 6 + 4 + 4 palabras, la
  menos significativa primero. Si el protocolo elige otro, cambia solo `latches.py`.
- **Verificación del modelo:** `verificacion.md` §2 pide que el modelo coincida con todos los
  `.exp` antes de usarlo. Lo hace `tools/isasim/tests/test_programas.py`; un programa nuevo en
  `sw/` queda probado sin cambiar el test.
- **Si cambia `pipeline.md`** (un campo de un latch, el costo de un salto o del stall): se
  actualiza la capa 2 y se recalculan a mano los `.exp` afectados. Los tests dicen cuáles.
- **Si cambia `isa.md`:** se actualiza la capa 1 junto con el ensamblador (`rvasm/isa.py`).
- **Palabras fuera de `isa.md`:** con opcode desconocido se ejecutan como NOP (`pipeline.md`
  §4.4); con opcode conocido y `funct3`/`funct7` no soportados, el modelo da error en lugar de
  adivinar qué haría el hardware.
