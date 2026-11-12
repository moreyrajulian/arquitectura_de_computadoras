# 035 - UART de la Debug Unit: interfaz de bytes y FIFO de recepción

- **Estado:** propuesta
- **Fecha:** 2026-11-09
- **Autores:** Moreyra, Julián

## Contexto
La I-44 reutiliza la UART del TP2 (`rtl/peripherals/uart/`) como canal de la Debug Unit, a
115200 8N1 con `DVSR` calculado desde `CLK_FREQ_HZ` (decisión [003](003_baudrate-uart.md)).
Hay que fijar tres cosas: la interfaz de bytes hacia la Debug Unit, si hace falta una FIFO de
transmisión y si alcanza el buffer de un byte del lado de recepción.

Lo que ya estaba:
- [`protocolo_debug.md`](../spec/protocolo_debug.md) §1 conecta la Debug Unit a `intf_circ`
  como `alu_top` en el TP2: `r_data` / `rx_empty` / `rd` para recibir y `w_data` / `wr` /
  `tx_full` para transmitir. Cada lado tiene un `flag_buff` de un byte.
- La issue pide "dato + valid en RX; dato + start + busy en TX". Son las mismas señales con
  otros nombres: `rx_empty = 0` es el valid y `rd` lo consume; `wr` es el start y `tx_full`, el
  busy.
- Los módulos del TP2 no siguen la decisión [010](010_convenciones-rtl.md) (sin cabecera,
  `clk`/`reset`, sin prefijos `i_`/`o_`) y los usa `fpga/tp2_uart`, que es histórico: tiene que
  seguir sintetizando.

Restricciones de tiempo (§1 y §5 del protocolo):
- Llega un byte cada ~87 µs (~8700 ciclos a 100 MHz). La FSM de protocolo consume cada byte en
  pocos ciclos **mientras está recibiendo**.
- Mientras transmite (estados `TX_*`), la FSM no lee. Casi siempre es una respuesta y la PC no
  manda nada hasta recibirla. La excepción es `EVT_HALTED`: la FPGA lo manda sin petición, y la
  PC tiene que aceptarlo en cualquier momento de `RUNNING`, aun justo después de mandar un
  `STATUS` o un `LOAD`, que están permitidos en ese estado (§3.5 y §5). El evento son
  5 + 12 = 17 bytes, ~1,5 ms, y en ese tiempo pueden llegar ~17 bytes de la petición.
- El volcado más largo (`READ_ALL`) son cientos de bytes y sale con el core detenido.

## Opciones consideradas

**Interfaz**
1. **La de la spec (`intf_circ`)**: `r_data` / `rx_empty` / `rd` y `w_data` / `wr` / `tx_full`.
   - Ventajas: es la que ya documenta §1 y la que usan los demás módulos; la issue la cumple con
     otros nombres. La FSM de protocolo (I-45) se escribe contra una interfaz conocida.
   - Desventajas: ninguna para este uso.
2. **Una interfaz nueva de pulso** (`rx_valid` de un ciclo, `tx_start` / `tx_busy`).
   - Ventajas: un registro menos del lado de RX.
   - Desventajas: obliga a la FSM a estar mirando la línea en el ciclo exacto del pulso, y
     cambia §1 sin necesidad.

**Recepción**
1. **Un byte (`flag_buff`, como el TP2).**
   - Ventajas: ya existe.
   - Desventajas: si una petición se cruza con un `EVT_HALTED`, el segundo byte pisa al primero
     y se pierde la petición. La PC se recupera por timeout y reintento (§5), pero tarda más de
     200 ms y deja un error en el log que no es de nadie.
2. **FIFO de 32 bytes.**
   - Ventajas: guarda lo que llega mientras sale el evento (a lo sumo ~18 bytes, al mismo
     baudrate), con margen. Cuando la FSM vuelve a `IDLE` consume la FIFO mucho más rápido de
     lo que llegan bytes nuevos, así que una petición larga (`LOAD`) también se pone al día.
     Cuesta unas pocas LUT de memoria distribuida.
   - Desventajas: un módulo más con su testbench.

**Transmisión**
1. **Sin FIFO, un byte (`flag_buff`)**: la FSM espera `tx_full = 0` antes de cada byte.
   - Ventajas: la velocidad la fija el baudrate, no la FSM: con FIFO o sin ella el volcado tarda
     lo mismo (~31 ms a 115200). La FSM de protocolo no tiene otra cosa que hacer mientras
     transmite y el core está detenido durante los volcados.
   - Desventajas: la FSM queda esperando en `TX_PAYLOAD`. No importa, por lo anterior.
2. **FIFO de transmisión.**
   - Ventajas: la FSM terminaría antes de que salga el último byte.
   - Desventajas: no acelera nada visible y suma memoria y casos de prueba.

## Decisión
- **Un módulo nuevo `rtl/peripherals/uart/uart.v`**, con las convenciones de la 010, que
  instancia `baud_gen`, `uart_rx`, `uart_tx` y `flag_buff` del TP2 **sin modificarlos**.
  `fpga/tp2_uart` no cambia.
- **Interfaz de la spec** (opción 1): `o_r_data`, `o_rx_empty`, `i_rd`, `i_w_data`, `i_wr`,
  `o_tx_full`.
- **Recepción con una FIFO de 32 bytes** (`rtl/peripherals/uart/uart_fifo.v`). Si llega un byte
  con la FIFO llena se descarta ese byte; la trama a medias se resuelve con el checksum o el
  timeout de §5. `i_rd` con la FIFO vacía no tiene efecto.
- **Transmisión sin FIFO**, con el byte de `flag_buff`. Un `i_wr` con `o_tx_full = 1` se
  ignora: el byte que está saliendo no se pisa.
- **`i_rx` pasa por un sincronizador de dos flip-flops** antes de `uart_rx`: viene del chip
  USB-UART, asíncrona al reloj. El `top` del TP2 la usaba directo.
- **Parámetros `CLK_FREQ_HZ` y `BAUD`**, con `DVSR = round(CLK_FREQ_HZ / (16 × BAUD))`
  calculado en el módulo como `(CLK_FREQ_HZ + 8 × BAUD) / (16 × BAUD)` (decisión 003).

## Consecuencias
- `protocolo_debug.md` §1 describe `uart` en lugar de `intf_circ`, y `verificacion.md` §3.3
  tiene los casos mínimos de `uart_tb.v` y `uart_fifo_tb.v`.
- La decisión 010 preveía adaptar la UART del TP2 a `i_clk`/`i_rst` y a los prefijos de puertos
  al integrarla en la Debug Unit. Con esta decisión, esa adaptación es el módulo `uart`, que es
  lo único que ve la Debug Unit; los módulos internos del TP2 quedan como están. Sí se hace el
  otro punto de la 010: `baud_generator.v` pasa a llamarse `baud_gen.v`, como su módulo.
- El testbench anterior `tb/unit/uart_tb.v`, que prueba el sistema del TP2 (UART + ALU), pasa
  a llamarse `tb/unit/tp2_uart_top_tb.v`; `uart_tb.v` queda para el módulo nuevo, como pide la
  010. Sigue elaborando solo en el proyecto `tp2_uart`.
- **Regresión (decisión 032).** La 032 dejaba `uart_tb` en `OTRO_DISENO` hasta que la I-44 lo
  ampliara. Ahora la lista tiene `tp2_uart_top_tb`, y `uart_tb` y `uart_fifo_tb` entran a la
  regresión del procesador: su DUT está en `rtl/`, que `create_project.tcl` agrega entero. Pasan
  a ser 21 testbenches unitarios.
- La FSM de protocolo (I-45) lee con `rx_empty` / `rd` en cualquier estado de recepción, y
  después de transmitir encuentra en la FIFO lo que llegó mientras tanto. La transmisión de
  I-47 e I-48 escribe un byte por vez, esperando `tx_full = 0`.
- `i_rst` de `uart` es el reset del sistema, no `core_rst`: un `LOAD` o un `RESET` del core no
  vacía la FIFO.
- **Byte con stop en 0.** `uart_rx` del TP2 descarta el dato, pero no vuelve a mirar la línea
  en el medio del start bit: vuelve a reposo en el medio del stop, toma la línea todavía en 0
  como un start nuevo y recibe los 1 del reposo, así que entra un `0xFF`. No se corrige acá
  porque habría que tocar `uart_fsm` y `uart_rx`, que comparte `tp2_uart`. El protocolo ya lo
  tolera: en reposo la FSM descarta todo byte que no sea `0xA5`, y en medio de una trama lo
  detectan el checksum o el timeout (§5). `uart_tb.v` comprueba este comportamiento.
- Si alguna vez la PC pudiera mandar una petición larga mientras la FPGA transmite algo más
  largo que el evento, habría que revisar la profundidad de la FIFO.
