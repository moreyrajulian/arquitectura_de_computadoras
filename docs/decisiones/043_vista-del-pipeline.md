# 043 - Vista del pipeline: instrucción de cada etapa, riesgos inferidos, historial y F4

- **Estado:** propuesta
- **Fecha:** 2026-11-18
- **Autores:** Costamagna, Matías

## Contexto
La I-53 completa la interfaz de la PC (decisión [040](040_interfaz-de-usuario.md)). Tiene
que mostrar la instrucción de cada etapa a partir de los latches, resaltar lo que cambió en
cada paso, hacer visibles los stalls, las burbujas y los flushes, y (opcional) guardar un
historial. [`interfaz_pc.md`](../spec/interfaz_pc.md) §2 a §4 tiene el boceto y las reglas,
pero al revisarlas contra [`pipeline.md`](../spec/pipeline.md) §3.4, §8 y §10 aparecieron
cuatro problemas:

1. **Solo IF/ID lleva la palabra** (`if_id_instr`). ID/EX, EX/MEM y MEM/WB tienen `pc` y
   `valid`, pero no la instrucción (pipeline.md §8).
2. **La regla «Stall ocurrido» de §4.3 da falsos positivos.** Pide «PC e IF/ID no cambiaron,
   `ID/EX.valid = 0` y `cycles` +1». Eso también pasa mientras se vacía el pipeline después
   de un HALT: `stop_fetch` retiene el PC, IF/ID se recarga con la misma burbuja y a ID/EX le
   llegan burbujas.
3. **Las burbujas de ID/EX conservan `rs1` y `rs2`** de la instrucción anulada, porque el
   flush solo pone en 0 `valid` y el control. Si el forwarding se infiere sin mirar `valid`,
   aparecen flechas hacia burbujas.
4. **F4 («correr hasta cursor») se contradice.** §3 dice que usa el bloque de estado de cada
   `STEP`, pero ese bloque trae el PC de IF. El PC de WB está en MEM/WB.

Además faltaba decidir de dónde salen los campos de cada latch en Python, contra qué volcado
se compara el resaltado y cómo se prueba la inferencia sin escribir a mano lo que pasa en
cada ciclo.

## Opciones consideradas

**Instrucción de cada etapa**
1. **El `pc` del latch indexa las palabras que se mandaron con `LOAD`.**
   - Es exacto: imem solo se escribe con `LOAD`, y `LOAD` llena el resto con HALT.
   - Usa el mismo índice `addr[11:2]` del core ([`memoria.md`](../spec/memoria.md) §6).
   - En IF/ID se usa la palabra del latch y se compara con la cargada.
   - Desventaja: si la PC se conecta a una placa con un programa que no cargó ella, no sabe
     las palabras.
2. **Reconstruir la instrucción con los campos de ID/EX** (control, `rd`, `imm`, …).
   - Desventajas: es ambiguo y no sirve para EX/MEM y MEM/WB, que ya no tienen esos campos.

**Tabla de campos de los latches**
1. **Importar `isasim.latches.LAYOUT`.** Ya es la tabla de pipeline.md §8 en el orden del
   empaquetado. `rvasm` y `placa.py` ya importan `isasim`.
2. **Copiarla en `model`.** Sería una tercera copia, además de `isasim` y `pipeline_tb.v`.

**Inferencia de riesgos**
1. **Solo comparar dos volcados seguidos** (las reglas de §4.3). Tiene el falso positivo del
   punto 2 y no sirve después de Paso×N.
2. **Deducir de un solo volcado y usar el anterior para verificar.**
   - De un volcado se sacan lo que pasa en el ciclo (forwarding, load-use, salto tomado en
     EX, HALT en vuelo) y lo que ya pasó.
   - Un load en MEM, una burbuja en EX y la instrucción que lo usa en ID es un stall; un
     salto en MEM con IF/ID e ID/EX en burbuja es un flush.
   - Con el volcado del ciclo anterior se compara lo previsto con lo observado.

**Correr hasta cursor**
1. **STEP + `READ_LATCHES` por ciclo hasta que la instrucción llega a WB.** Respeta el
   significado de la spec. Cuesta unos 100 B por ciclo.
2. **Hasta que la instrucción entra en IF**, solo con el bloque de estado. Es unas 4 veces
   más barato, pero cambia el significado.
3. **Híbrida:** barata hasta IF y con latches hasta WB. Es más compleja.

**Pruebas de la inferencia**
1. **Contra el modelo de referencia.** `isasim` ya registra en cada ciclo `stall`,
   `redirect a …` y `stop_fetch`. Le falta el PC, los registros y la memoria de cada ciclo
   para que la Debug Unit simulada avance ciclo a ciclo.
2. **Solo casos a mano.**

## Decisión
- **Instrucción de cada etapa: opción 1.** `model.word_at(words, pc)`.
  - Si la PC no conoce el programa, las etapas ID a WB muestran `?`, salvo ID, que usa la
    palabra de IF/ID. Las reglas que no necesitan la palabra se siguen aplicando.
  - Si `IF/ID.instr` no es la palabra cargada, se informa una inconsistencia.
- **Campos: opción 1.** `model.decode_latches` usa `isasim.latches.LAYOUT`.
  - Si las palabras por latch de `INFO` no coinciden, `Snapshot.fields` es `None`: solo se
    muestran las palabras crudas y no se infieren riesgos.
- **Inferencia: opción 2**, en `rvdebug/hazards.py` (`analyze`), con las mismas ecuaciones
  que pipeline.md §5.3, §10.2 y §10.3. El EX se emula con las funciones de `isasim`
  (`alu_op`, `load_extend`, `ALU_CODES`).
  - El forwarding se informa solo con `ID/EX.valid = 1` y hacia los operandos que la
    instrucción lee. Hacia un operando descartado el hardware reenvía igual, pero no tiene
    efecto (pipeline.md §10.2).
  - Una inconsistencia aparece en tres casos: el stall previsto no ocurrió, IF e ID se
    retuvieron sin un load-use, o el salto tomado no produjo el flush.
  - La causa de cada burbuja (stall, flush, HALT o reset) se sigue de un volcado al
    siguiente cuando los dos son de ciclos seguidos.
- **Resaltado e historial** (`Session.history`, una `Entry` por `READ_ALL`).
  - STEP, Paso×N, F4 y STOP comparan con el volcado anterior.
  - El final de `RUN` compara con el volcado anterior al `RUN` (`before_run`, §5).
  - Conectar, `LOAD` y `RESET` vacían el historial.
  - Refrescar no agrega renglón si nada cambió.
  - En una burbuja solo se resaltan `valid` y el control, el mismo criterio que la máscara
    de `isasim`.
  - El historial guarda 10 000 renglones y el panel muestra los 500 más nuevos. Enter
    muestra uno en modo solo lectura; Esc o cualquier acción con el puerto vuelve.
  - La columna «Escrito» de la memoria usada dice en qué volcado se vio el cambio:
    `ciclo N` si fue un paso de un ciclo, `<= N` después de Paso×N o `RUN`.
- **F4: opción 1** (`Session.run_to`), con un límite de 2000 ciclos y cancelable con Esc.
  Si en la placa resulta lento, se pasa a la opción 3 sin cambiar la interfaz.
- **Pruebas: opción 1.**
  - El `Snapshot` de `isasim` suma `pc`, `regs`, `used`, `halted` y `warnings` de cada
    ciclo. Los campos nuevos tienen valor por defecto y no cambian ni la traza ni el `.exp`.
  - `ModelDebugUnit` pasa de `test_placa.py` a `tests/fake_debug_unit.py` y ahora avanza
    todo el volcado ciclo a ciclo.
  - `test_hazards.py` compara `analyze` con los eventos del modelo en cada ciclo de los
    programas del plan y sus variantes `_nops`. Los casos a mano cubren el forwarding, los
    textos y las inconsistencias.

## Consecuencias
- `interfaz_pc.md` cambia en el mismo PR: §1 (qué hay en cada capa), §3 (F4), §4.3 (reglas
  con predicción y observación) y §7.
- `rvdebug` depende de `isasim` también para los campos de los latches (ya dependía a través
  de `rvasm.disassemble`). Si cambia el orden o el ancho de un campo en pipeline.md §8, se
  cambia `isasim/latches.py` y la interfaz lo toma sola.
- Cada ciclo de F4 son dos transacciones. Con el *latency timer* de 16 ms del FT2232 pueden
  ser ~30 ms por ciclo: unos segundos para cientos de ciclos.
- La interfaz no puede volver atrás en la placa: el historial es solo de lectura.
- **Puntos abiertos:** medir en la placa cuánto tarda F4, y confirmar que con el RTL la
  inferencia no informa inconsistencias en los programas de `sw/`. Hasta ahora se probó
  contra la Debug Unit simulada con el modelo de referencia.
