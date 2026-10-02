# 010 - Detección de load-use conservadora y sin forwarding hacia MEM

- **Estado:** aceptada
- **Fecha:** 2026-10-02
- **Autores:** Costamagna, Matías

## Contexto
La unidad de detección de riesgos tiene que frenar un ciclo a la instrucción que usa el dato
de un load inmediatamente anterior, porque ese dato recién sale de la BRAM en WB (decisión
009). La regla del libro compara el `rd` del load (en ID/EX) con los campos `rs1` y `rs2` de
la instrucción que está en ID (`docs/spec/pipeline.md` §10.3).

En RISC-V esos campos están siempre en los mismos bits, pero no todas las instrucciones los
usan: en `lui` y `jal` son parte del inmediato, en las I-type `rs2` es parte del inmediato, y
el HALT (`0x0010_0073`) tiene un 1 en el campo `rs2`. Si coinciden con el `rd` del load, la
regla frena sin necesidad.

Además, un load seguido de un store que guarda el dato cargado (`lw x1, …` y `sw x1, …`) no
necesitaría frenar: el store recién usa el dato en MEM, y para entonces el load está en WB.

## Opciones consideradas
1. **A — Comparar los campos sin decodificar.** `load_use` usa `instr[19:15]` e
   `instr[24:20]` tal cual.
   - Ventajas: la lógica más chica y la más corta en el camino de ID. Es la misma regla que
     usa la unidad de forwarding (que también compara campos sin filtrar), lo que garantiza
     que nunca se reenvía la dirección de un load desde EX/MEM.
   - Desventajas: algunos stalls de más (un ciclo cada uno, sin efecto en el resultado).
2. **B — Filtrar con `uses_rs1`/`uses_rs2` que genera la unidad de control.**
   - Ventajas: elimina los stalls falsos.
   - Desventajas: dos señales más en la unidad de control y una dependencia del decodificador
     en el camino de la detección. Para mantener la garantía de arriba, la unidad de forwarding
     tendría que filtrar igual, o habría que agregar `~ex_mem_mem_to_reg` a su condición de
     `fwd = 10`.
3. **C — Además, forwarding de MEM/WB hacia el dato del store en MEM.**
   - Ventajas: el par load → store no pierde el ciclo.
   - Desventajas: un mux y un comparador más en MEM, un caso más que verificar. Es un patrón
     poco frecuente en los programas de prueba (copias de memoria).

## Decisión
**Opción A, sin la C.** Los stalls de más solo cuestan ciclos en casos raros y nunca cambian
el resultado; a cambio, las dos unidades usan la misma regla y quedan más simples de
implementar y de verificar. La métrica que se evalúa es el camino crítico, no los ciclos por
programa.

## Consecuencias
- `pipeline.md` §10.3: la detección compara `if_id_rs1`/`if_id_rs2` sin mirar el formato y se
  documentan los falsos positivos (`lui`, `jal`, HALT) y el par load → store.
- La interfaz de PC (I-16) puede mostrar como "stall" casos en que la instrucción no usaba el
  registro; la regla de inferencia de `interfaz_pc.md` §4.3 ya es la misma.
- Si los programas de prueba muestran muchos stalls falsos, o si se quiere bajar el CPI,
  revisar la opción B, filtrando igual en las dos unidades.