# 002 - Formato de trama del protocolo de debug

- **Estado:** propuesta
- **Fecha:** 2026-09-29
- **Autores:** Costamagna, Matías

## Contexto
La PC y la Debug Unit intercambian comandos y volcados por UART. La FPGA tiene que
resincronizarse sola ante ruido o una trama cortada, y el formato tiene que ser fácil de
implementar en una FSM de Verilog y de verificar a mano en una captura. Los volcados tienen
longitudes muy distintas (de 0 a más de 200 bytes). Detalle en `docs/spec/protocolo_debug.md`.

## Opciones consideradas
1. **Trama con longitud fija por comando, sin encabezado.** Es la más simple, pero el receptor
   no puede saltear un comando desconocido y una pérdida de bytes desincroniza todo.
2. **Trama `SOF | CMD | LEN | payload | CHK`, little-endian, checksum XOR.** Cada trama se
   delimita sola, la FPGA descarta todo byte distinto de `0xA5` en reposo y el XOR es un
   registro de 8 bits. Detecta cualquier error de un bit, pero no dos errores en la misma
   posición de bit ni bytes permutados.
3. **Igual que la 2 con CRC-8.** Detecta más errores, pero cuesta más en hardware y no se
   verifica a mano.
4. **Protocolo de texto (ASCII hex).** Legible en una terminal, pero duplica los bytes en la
   línea y complica el parseo en la FSM.

## Decisión
Opción 2. `SOF` distinto según la dirección (`0xA5` petición, `0x5A` respuesta), `LEN` de 2
bytes, todo multibyte en little-endian (igual que RISC-V, así una palabra de instrucción viaja
como está en memoria) y `CHK` = XOR de `CMD` hasta el último byte del payload. Toda petición
recibe exactamente una respuesta con el mismo `CMD`.

## Consecuencias
- La FSM de recepción es simple: estados `IDLE`, `RX_CMD`, `RX_LEN`, `RX_PAYLOAD`, `RX_CHK`.
- Un error de encabezado obliga a consumir `LEN + 1` bytes antes de responder, para no
  interpretar el payload como una trama nueva (estado `DISCARD`).
- Si en la práctica pasan errores que el XOR no detecta, se cambia a CRC-8 sin tocar el resto de
  la trama (reemplaza esta nota, ver plantilla).
- Los ejemplos de tramas del documento sirven como casos de prueba del testbench y del cliente.