# 027 - Memoria de datos: qué lógica de MEM va en `dmem`

- **Estado:** propuesta
- **Fecha:** 2026-10-22
- **Autores:** Costamagna, Matías

## Contexto
La I-32 (#44) pide `rtl/memory/data_mem.v` con accesos de byte, media palabra y palabra según
`funct3`, **extensión de signo o de ceros en las lecturas**, un puerto de lectura para la Debug
Unit e inicialización desde archivo (el estado inicial de la I-15). La fila de la I-32 en
[`verificacion.md`](../spec/verificacion.md) §3.1 le suma los avisos de acceso y el mapa de
palabras usadas. Esos pedidos no coinciden con lo que ya fijaron los specs:

- **Extensión de los loads.** [`pipeline.md`](../spec/pipeline.md) §6.3 y §7.1 y las decisiones
  [009](009_memorias-sincronicas.md) y [016](016_acceso-por-byte.md) la ponen en WB. El registro de
  salida de la BRAM **es** `mem_wb_read_data`: cuando el dato existe, la instrucción ya está en
  WB, y lo que elige el byte (`mem_wb_funct3`, `mem_wb_offset`) son campos de MEM/WB. El volcado
  de latches necesita además la palabra sin extender.
- **Mapa de palabras usadas.** La decisión [005](005_memoria-de-datos-usada.md) y
  [`protocolo_debug.md`](../spec/protocolo_debug.md) §3.6 y §7 lo ponen en la Debug Unit, que mira
  `dmem_we` y `dmem_addr` del core. Su limpieza en `CLEAR`, el contador `dmem_used` y el mux de
  dirección de la LUTRAM ([`memoria.md`](../spec/memoria.md) §7) son lógica de la Debug Unit.
- **Inicialización.** `memoria.md` §3.6 y las decisiones [021](021_banco-incremental.md) y
  [022](022_imem-sin-reset-de-salida-y-contenido-inicial.md) fijan que el IP arranca sin archivo y
  que los testbenches cargan la memoria por el puerto B. `pipeline_tb.v` ya carga
  `sw/estado_inicial/dmem.hex` así (`STAGE_MEM`, I-34).
- **Avisos.** `memoria.md` §6.2 los calcula en MEM con `ex_mem_result`, `ex_mem_funct3`,
  `mem_write` y `mem_to_reg` (`dmem_oob`, `dmem_misaligned`) y en WB con `mem_wb_pc`
  (`imem_fault`), pero no dice en qué módulo. La decisión [023](023_interfaz-debug-del-core.md)
  agrega sus puertos al core en la I-35.
- **Nombre.** `memoria.md` §3.2 y `verificacion.md` llaman al módulo `dmem` (`dmem_tb.v`), como su
  par `imem`.

Restricciones:
- La dirección de la BRAM y el dato leído están en el camino crítico candidato
  (decisión [012](012_resolucion-saltos.md)): nada se puede agregar entre `ex_mem_result` y
  `addra`, ni entre `douta` y la extensión.
- El modelo de referencia (`tools/isasim`) lee la memoria en todos los ciclos (`READ_FIRST`) y
  calcula los avisos con `funct3[1:0]`. El RTL tiene que coincidir bit a bit.
- Un testbench no puede abrir un archivo por ruta relativa: xsim corre en `build/vivado_<diseño>/…`.

## Opciones consideradas

**Extensión de los loads**
1. **En `dmem`**, como pide la issue. Para hacerlo, `dmem` tendría que recibir `mem_wb_funct3` y
   `mem_wb_offset`, que son señales de WB, o tener su propia copia de esos 5 bits, que el banco no
   vería por jerarquía.
   - Ventajas: cumple la casilla de la issue tal como está escrita.
   - Desventajas: el módulo cruza el límite entre MEM y WB; si se duplican los flip-flops,
     además dejan de ser los campos de MEM/WB de `pipeline.md` §8.
2. **En WB (`write_back`, I-35)**, como fijan 009 y 016. `dmem` entrega la palabra completa.
   - Ventajas: no cambia ningún spec; `mem_wb_read_data` sigue siendo la salida de la BRAM.
   - Desventajas: la casilla de la issue se cumple recién en la I-35.
3. **Un módulo `load_ext` ahora**, para que lo instancie la I-35.
   - Ventajas: la extensión queda escrita y probada en la I-32.
   - Desventajas: adelanta trabajo de la I-35 y mueve sus casos de `write_back_tb` a otro
     testbench.

**Avisos `dmem_oob` y `dmem_misaligned`**
1. **En `dmem`.** Se calculan con la dirección y el `funct3` que `dmem` ya recibe, más `i_a_load`,
   `i_rst` y el `enable` (`i_a_en = en_mem_wb = enable`).
   - Ventajas: cumple la fila de `verificacion.md`; la lógica queda donde están sus entradas; la
     I-35 solo los saca como puertos del core.
   - Desventajas: `dmem`, a diferencia de `imem`, tiene `i_rst`. Los tres avisos quedan en dos
     módulos, porque `imem_fault` usa `mem_wb_pc` y va en WB.
2. **Los tres en WB (I-35), junto a `halted`.**
   - Ventajas: `dmem` queda como un envoltorio sin reset.
   - Desventajas: hay que cambiar la fila de `verificacion.md`; WB tendría que recibir la
     dirección y el `funct3` de EX/MEM solo para esto.

**Mapa de palabras usadas**
1. **En `dmem`**, como dice la fila de `verificacion.md`.
   - Desventajas: le da a `dmem` puertos que solo usa la Debug Unit (limpieza, recorrido,
     contador) y contradice 005 y `protocolo_debug.md` §7.
2. **En la Debug Unit (I-46 e I-48)**, como fija 005.
   - Ventajas: no contradice ninguna decisión. El core le pasa `dmem_we` y `dmem_addr`.
   - Desventajas: hay que mover el caso de la fila de la I-32 a la de la Debug Unit.

**Archivo de estado inicial en el testbench unitario**
1. **Leerlo con un plusarg** (`+DMEM_INIT=<ruta>`), como el `DIR` de `pipeline_tb`.
   - Desventajas: el testbench falla si no se configura el plusarg en el proyecto.
2. **No leer archivos.** `dmem_tb` carga las 1024 palabras por el puerto B, con las tres del
   estado inicial, igual que lo hace `pipeline_tb` con el archivo.
   - Ventajas: corre sin configuración; prueba el mismo mecanismo de carga.
   - Desventajas: las tres palabras están repetidas en el testbench.

## Decisión
- **El módulo se llama `dmem`** (`rtl/memory/dmem.v`, `tb/unit/dmem_tb.v`).
- **`dmem` = IP `dmem_bram` + máscara de bytes y replicación de los stores + avisos
  `dmem_oob` y `dmem_misaligned`.** Recibe la dirección completa (`ex_mem_result`), y el alias sale
  de los bits que no llegan a la BRAM, como en `imem`.
- **La extensión de los loads queda en WB (I-35)**: `dmem` entrega la palabra completa
  (opción 2).
- **`imem_fault` queda en WB (I-35)**, porque usa `mem_wb_pc`.
- **El mapa de palabras usadas es de la Debug Unit** (decisión 005).
- **`dmem_tb` no lee archivos.** La carga desde `sw/estado_inicial/dmem.hex` la hace el banco
  incremental (I-34).
- Un store con un `funct3` que no es `sb` ni `sh` escribe como `sw`, igual que `store_bytes` del
  modelo. No llega nunca, porque control_unit convierte esos stores en NOP (decisión
  [024](024_instrucciones-no-soportadas.md)), pero así RTL y modelo coinciden en todos los casos.

Motivo: es el reparto que respeta los límites de etapa de `pipeline.md` (todo lo de `dmem` depende
de EX/MEM y termina en la BRAM o en un flip-flop de MEM) y que no contradice ninguna decisión
aceptada. Lo que la issue pedía distinto lo resuelven la I-35 y la Debug Unit, donde ya estaba
previsto.

## Consecuencias
- `ip/dmem_bram.tcl` deja explícitos `Use_RSTA_Pin`, `Use_RSTB_Pin`, `Load_Init_File` y
  `Fill_Remaining_Memory_Locations` en `false` (contenido en cero).
- `memoria.md` §3.3 documenta los puertos de `dmem`; §6.2 y §7 dicen dónde está cada aviso y el
  mapa. `pipeline.md` §6 remite a esta nota.
- `verificacion.md` §3.1: la fila de la I-32 pierde el mapa de palabras usadas y suma `READ_FIRST`
  y la lectura por el puerto B; el mapa pasa a las filas de la I-46 y la I-48.
- **I-34:** `mem_stage` instancia `dmem` con `i_a_en = en_mem_wb`, `i_rst = core_rst` y
  `o_a_dout` como `mem_wb_read_data`, y saca el puerto B como `i_dmem_b_*` / `o_dmem_b_dout`. La
  Debug Unit obtiene `dmem_we = enable & ex_mem_mem_write` y `dmem_addr = ex_mem_result[11:2]` de
  EX/MEM, sin pedirle la máscara a `dmem`.
- **I-35:** la extensión (`pipeline.md` §7.1) e `imem_fault` van en WB; `o_dmem_oob` y
  `o_dmem_misaligned` del core salen de `dmem`.
- La casilla "extensión de signo o de ceros en las lecturas" de la I-32 se cumple en la I-35.
