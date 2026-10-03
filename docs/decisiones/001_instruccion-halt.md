# 001 - Codificación y comportamiento de la instrucción HALT

- **Estado:** aceptada
- **Fecha:** 2026-09-28 (actualizada el 2026-10-02 en la revisión de la I-04)
- **Autores:** Moreyra, Julián - Costamagna, Matias

La consigna exige una instrucción de parada, pero HALT no existe en RV32I.
Hay que elegir una codificación que no choque con las instrucciones
implementadas y que el ensamblador pueda generar, y definir qué hace el
hardware al llegar a ella.

Restricciones:
- No colisionar con ninguna instrucción de la tabla de `isa.md`.
- Decodificación barata en ID (ruta crítica; recursos limitados de la Basys 3).
- HALT no usa registros ni inmediato: no debe escribir registros ni memoria,
  ni generar riesgos de datos.
- Debe poder escribirse en los programas de prueba con un mnemónico, sin
  post-procesar el binario.
- Interacción con la Debug Unit: debe poder saber cuándo el procesador se
  detuvo.
- Interacción con saltos: en un pipeline, un HALT puede estar en una ruta
  especulada que un branch anterior todavía va a descartar.

## Opciones consideradas
1. **Opción A: reutilizar `ebreak` (`0x00100073`).**
   - Ventajas: ya definida en RISC-V; el ensamblador estándar la genera
     (`ebreak`); no choca con ninguna instrucción implementada (SYSTEM,
     `0x73`, no se usa en este ISA).
   - Desventajas: se le da a `ebreak` una semántica de parada que la
     especificación no define; si en el futuro se quisiera implementar
     `ebreak`/`ecall` reales habría conflicto. Hay que decodificar el word
     completo (o opcode + `imm[11:0]`) para no confundirla con `ecall`
     (`0x00000073`).
2. **Opción B: opcode propio en el espacio custom (`custom-0`, `0001011`).**
   - Ventajas: no colisiona nunca con el estándar; deja `funct3`/`funct7`
     libres para futuras instrucciones propias.
   - Desventajas: el ensamblador no la conoce; hay que emitirla con
     `.word 0x0000000B` o mantener una macro/parche propio. Agrega un
     comparador de opcode al decodificador.
3. **Opción C: salto a sí mismo (`jal x0, 0`, `0x0000006F`).**
   - Ventajas: sin cambios de hardware, 100 % RV32I.
   - Desventajas: no detiene nada (el pipeline sigue ciclando y buscando);
     es indistinguible de un bucle escrito a propósito; no hay forma de
     avisar a la Debug Unit sin detectar el patrón; no cumple la consigna.
4. **Opción D: usar una palabra ilegal (`0x00000000` / `0xFFFFFFFF`).**
   - Ventajas: decodificación trivial; memoria sin inicializar frenaría sola.
   - Desventajas: se pierde la detección de instrucciones inválidas; una
     carga defectuosa del programa pararía el procesador en silencio;
     imposible de escribir con un mnemónico.

## Decisión
Opción A: `HALT` se codifica como `ebreak` (`0x00100073`). Es la única opción
que cumple las tres condiciones de la consigna a la vez: no choca con lo
implementado, tiene un mnemónico que el ensamblador genera y no exige
herramientas propias. ECALL y el resto de SYSTEM quedan como no implementadas.

### Comportamiento del hardware
1. **Decodificación (ID):** se compara la palabra completa contra
   `0x00100073` (solo si `if_id_valid = 1`) y se genera la señal `is_halt`
   (`id_is_halt` en `pipeline.md`). HALT viaja por el pipeline como una
   instrucción sin efectos: `RegWrite=0`, `MemWrite=0`, `MemRead=0`, sin
   salto. Lo único que lleva es su bit `halt`, que se copia en ID/EX, EX/MEM y
   MEM/WB.
2. **Detener la búsqueda:** mientras haya un HALT en cualquier etapa,
   `stop_fetch` vale 1:

   ```
   stop_fetch  = id_is_halt | id_ex_halt | ex_mem_halt | mem_wb_halt | halted
   flush_if_id = redirect | stop_fetch
   ```

   `stop_fetch` congela el PC (`pc_next = pc_reg`) y además hace flush de IF/ID:
   todo lo que entra a IF/ID detrás del HALT entra con `valid = 0`
   (`pipeline.md` §3.3 y §3.4).
3. **Drenar el pipeline:** las instrucciones anteriores al HALT siguen
   avanzando y completan sus etapas (incluidos saltos, loads y stores) con
   normalidad.
4. **Cancelación por salto anterior:** `stop_fetch` es combinacional: depende
   de los bits `halt` que están en el pipeline en ese ciclo. Si un
   branch/jal/jalr más viejo se resuelve como tomado, `redirect` tiene
   prioridad en el mux del PC, el flush convierte al HALT en burbuja, su bit
   `halt` desaparece y `stop_fetch` se apaga solo. La búsqueda sigue en el
   destino del salto.
5. **Aviso a la Debug Unit:** cuando HALT llega a WB (ya no puede ser
   descartado por nadie anterior) se latchea `halted = 1`, que se expone a la
   Debug Unit. Desde ese momento el pipeline queda vacío y estable, así que
   la Debug Unit puede leer registros y memoria de forma consistente.
6. **Salida del estado halted:** solo con `RESET` o `LOAD` de la Debug Unit
   ([decisión 004](004_carga-y-reprogramacion.md), `protocolo_debug.md` §3.7).
   No se reanuda desde el punto del HALT.
7. **HALT retenido por un stall:** el campo `rs2` de la palabra del HALT vale
   1 (es el inmediato de `ebreak`), así que un load a `x1` justo antes puede
   disparar la detección de load-use. En los registros de segmentación `en`
   tiene prioridad sobre `flush` (`pipeline.md` §2): durante el stall IF/ID
   conserva el HALT aunque `flush_if_id = 1`, y el HALT no se pierde.

### Por qué la parada mira todas las etapas y hace flush de IF/ID
La primera versión de esta decisión congelaba el PC solo mientras `is_halt`
estaba activa en ID. Eso tenía dos problemas:

- **El HALT está en ID un solo ciclo.** Resolviendo saltos en EX, entre que el
  HALT sale de ID y llega a WB pasan tres ciclos (EX, MEM, WB). Si la parada
  dependiera solo de ID, en esos ciclos el PC volvería a avanzar y entrarían
  hasta tres instrucciones posteriores al HALT. Por eso `stop_fetch` es el OR
  de los bits `halt` de todas las etapas, y después de WB lo sostiene
  `halted`.
- **Congelar el PC no cancela la lectura que ya está en curso.** La memoria de
  programa es una BRAM con un ciclo de latencia (decisión 009): en el ciclo en
  que el HALT está en ID, `pc_reg` ya vale `h + 4` (h = dirección del HALT) y
  la BRAM ya está leyendo esa dirección. Esa instrucción aparece en
  `if_id_instr` en el flanco siguiente. Y como después el PC queda congelado
  en `h + 4`, la BRAM la vuelve a leer en cada ciclo. Sin invalidar IF/ID,
  entraría como válida y se repetiría. Por eso `stop_fetch` también hace
  flush de IF/ID, con el mismo mecanismo que ya se usa para los saltos.

```
ciclo              t            t+1          t+2          t+3          t+4
HALT en            IF           ID           EX           MEM          WB → halted <= 1
pc_reg             h            h+4          h+4          h+4          h+4
stop_fetch         0            1            1            1            1
IF/ID recibe       HALT (1)     h+4 (0)      h+4 (0)      h+4 (0)      h+4 (0)
```

(Entre paréntesis, el `valid` que se guarda en IF/ID en el flanco del final de
cada ciclo.)

### ¿Qué sucede si en la memoria no hay una instrucción de parada?
El procesador nunca se detiene por sí mismo: el PC sigue incrementando y
buscando palabras después del final del programa. Lo que ocurre entonces
depende de la memoria de instrucciones:
- Si las posiciones no usadas están en cero (`0x00000000`, palabra ilegal en
  RISC-V), el procesador ejecuta esa palabra según lo que haga el decodificador
  con opcodes no reconocidos (típicamente actúa como NOP), y recorre toda la
  memoria.
- Si el PC se trunca al tamaño de la memoria, al llegar al final da la vuelta
  y **reejecuta el programa desde el inicio**, en bucle.
- Si hay datos en posiciones altas y comparten memoria, se ejecutan como
  instrucciones con resultados impredecibles.
En todos los casos `halted` no se activa y solo la Debug Unit (o el reset)
puede detener la ejecución. Mitigación: los programas de prueba deben terminar
siempre con `ebreak`; opcionalmente se puede agregar una regla de que la
palabra `0x00000000` también active la parada (fuera del alcance de esta
decisión).

## Consecuencias
- **Decodificador (ID):** un comparador de 32 bits adicional y la señal
  `is_halt`.
- **IF:** `stop_fetch` entra al mux de próximo PC y al flush de IF/ID
  (`flush_if_id = redirect | stop_fetch`).
- **Control de riesgos/hazard unit:** nueva causa de congelamiento del PC y de
  inserción de burbujas, con la salvedad del flush por salto anterior. El
  stall por load-use (I-05) debe respetar la prioridad de `en` sobre `flush`;
  opcionalmente, la detección puede ignorar `rs1`/`rs2` en las instrucciones
  que no los usan (HALT, `lui`, `jal`) para evitar stalls innecesarios.
- **Etapa WB / Debug Unit:** nueva señal `halted`, a documentar en la
  interfaz de la Debug Unit.
- **Toolchain:** no requiere cambios; los programas se escriben con `ebreak`.
- **Más simple:** los tests pueden terminar con un mnemónico estándar.
- **Más difícil:** si más adelante se quiere `ebreak`/`ecall` como excepciones
  reales, habrá que recodificar HALT (por ejemplo a `custom-0`) y regenerar
  los programas de prueba.
- **A revisar si cambia algún supuesto:** el punto donde se resuelven los
  branches (EX vs MEM) afecta cuándo es seguro latchear la parada; si se
  agrega reanudación, `halted` debe tener una señal de limpieza.
