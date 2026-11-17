# 041 - Reset del sistema en la placa: botón sincronizado y reset de encendido

- **Estado:** propuesta
- **Fecha:** 2026-11-17
- **Autores:** Costamagna, Matías

## Contexto
La I-49 arma el top de la Basys 3 (`fpga/riscv_basys3/top.v`). Todo el RTL espera un `i_rst`
**síncrono y activo en alto** (decisión [010](010_convenciones-rtl.md)): `uart`, `debug_unit`,
`debug_exec` y `debug_dump` lo reciben como reset del sistema, y el core recibe `core_rst`, que
lo incluye (decisión [037](037_fsm-de-ejecucion-de-la-debug-unit.md)). En la placa, ese reset
sale del botón central (btnC), y hay tres problemas:

- **btnC es asíncrono al reloj.** Si se suelta cerca de un flanco, cada flip-flop puede ver el
  reset terminar en un ciclo distinto, o quedar metaestable. Una FSM que sale del reset con la
  mitad de sus bits en un ciclo y la otra mitad en el siguiente puede quedar en un estado que
  no existe.
- **El botón rebota** durante algunos milisegundos al apretarlo y al soltarlo.
- **Al configurar la FPGA nadie aprieta el botón.** Sin reset, cada registro arranca de su
  valor INIT, que por defecto es 0. Hoy eso funciona de casualidad, porque `DBG_ST_NO_PROG`, el
  estado `IDLE` de `debug_unit` y el reposo de `uart_fsm` se codifican con 0. Pero el registro
  de la línea `tx` (`uart_tx_datapath`) vale 1 en reposo: con INIT = 0 la FPGA arrancaría con
  `tx` en 0, que la PC ve como un start bit. Y si alguien cambia una codificación, el sistema
  arranca en un estado que ningún testbench probó. El reset del TP2 tenía el mismo problema, porque iba
  directo del botón a los flip-flops.

La 010 prevé que un sincronizador de entrada pueda necesitar reset asíncrono y pide documentarlo
como excepción.

## Opciones consideradas
1. **btnC directo a `i_rst`**, como en el TP2.
   - Ventajas: nada que escribir.
   - Desventajas: tiene los tres problemas. Depende del INIT = 0 para arrancar bien.
2. **Sincronizador de dos flip-flops**, sin reset de encendido.
   - Ventajas: resuelve la metaestabilidad; un rebote solo reafirma el reset.
   - Desventajas: sigue dependiendo del INIT = 0 al encender, y un rebote corto al soltar puede
     dar pulsos de reset de un ciclo, que alcanzan pero nadie probó.
3. **Sincronizador + contador de reset de encendido** (*power-on reset*), con valores iniciales
   en la declaración de los registros, que Vivado carga como INIT.
   - Ventajas: resuelve los tres problemas. El reset dura un mínimo garantizado al encender y
     después de cada soltada (el contador vuelve a 0 mientras el botón está apretado, así que un
     rebote solo lo alarga). No necesita reset asíncrono: no es la excepción de la 010.
   - Desventajas: es el primer valor inicial de registro en `rtl/`. Funciona en FPGA y en xsim,
     pero no en un ASIC. Para este proyecto no importa.
4. **Sincronizador de reset asíncrono** (se activa asíncrono y se libera sincronizado) con
   `FDPE`/`FDCE`.
   - Ventajas: el reset actúa aunque no haya reloj.
   - Desventajas: es justo la excepción que la 010 quiere evitar, y aquí no hay ningún caso sin
     reloj: el de la Basys 3 corre desde que la FPGA se configura. Con el Clock Wizard (I-57) el
     reset tiene que esperar `locked`, y eso se hace igual de bien con la opción 3.

## Decisión
**Opción 3**, en un módulo nuevo **`rtl/common/reset_sync.v`**:

- El pedido de reset `i_rst_req` (el botón, o el MMCM sin enganchar desde la decisión
  [042](042_reloj-del-sistema-a-65-mhz.md)) pasa por dos flip-flops con `ASYNC_REG = "TRUE"`,
  para que Vivado los ubique juntos y no los optimice.
- Un contador de `POR_CYCLES` ciclos (16 por defecto) mantiene `o_rst = 1` al configurar la FPGA
  y después de que baja `i_rst_req`. Mientras `i_rst_req = 1`, el contador vuelve a 0.
- `o_rst` sale de un registro: es síncrono y sin glitches. Sube 3 ciclos después de apretar y
  baja `POR_CYCLES + 3` ciclos después de soltar. El reset de encendido dura `POR_CYCLES + 1`
  ciclos.
- El módulo no tiene reset propio. Sus registros arrancan del valor inicial de la declaración
  (`reg rst_reg = 1'b1;`), que es el INIT del flip-flop. Solo este módulo usa valores iniciales.
  El resto del RTL sigue con la regla de la 010.

Va en `rtl/common/` y no en `fpga/riscv_basys3/`: tiene testbench propio en `tb/unit/` y lo
puede usar cualquier diseño.

## Consecuencias
- El top conecta `reset | ~locked` (btnC o el MMCM sin enganchar, decisión 042) a `reset_sync`,
  y su `o_rst` es el reset del sistema. En `basys3.xdc`, `reset` y `rx` llevan `set_false_path`,
  y también el primer flip-flop de `reset_sync`: es un sincronizador.
- `tb/unit/reset_sync_tb.v` prueba el reset de encendido sin estímulo, el botón a destiempo del
  reloj, un pulso de un ciclo, rebotes al apretar y al soltar, y que `o_rst` solo cambia en un
  flanco y nunca dura menos de `POR_CYCLES + 1` ciclos. `tb/unit/top_tb.v` arranca el sistema
  entero sin ningún reset del testbench, solo con el de encendido.
- **Clock Wizard.** El MMCM tarda en enganchar y su salida no es confiable hasta `locked = 1`.
  La decisión 042 lo agrega desde `debug-v1` y mantiene el reset hasta entonces con este mismo
  mecanismo: `~locked` entra a `i_rst_req` junto con el botón, así que el contador vuelve a 0
  mientras el MMCM no enganchó.
- **Qué hace el botón**: lo mismo que el reset de encendido. La Debug Unit vuelve a `IDLE` y a
  `NO_PROG` (`prog_valid = 0`), el core queda en reset, la FIFO de la UART se vacía y una trama
  a medias se pierde. `imem` y `dmem` no se tocan, porque son BRAM sin reset (decisión
  [022](022_imem-sin-reset-de-salida-y-contenido-inicial.md)). Pero con `prog_valid = 0` hay
  que volver a hacer `LOAD`, y el `LOAD` limpia `dmem`. Es lo que la PC ya espera después de
  "apretar el reset de la placa" (`protocolo_debug.md` §5).
