# 003 - Baudrate de la UART: 115200

- **Estado:** propuesta
- **Fecha:** 2026-09-29
- **Autores:** Costamagna, Matías

## Contexto
El TP2 usó 19200 baud (`DVSR = 326` con 100 MHz). En el modo paso a paso, cada `STEP` es
seguido de un volcado: estado (12 B) + 32 registros (128 B) + latches (~60 B) + memoria de datos
usada (8 B por palabra). Con 20 palabras usadas son unos 360 bytes. Cargar un programa de
1 K palabras son 4 KB. El clock del sistema va a cambiar cuando se aplique el Clock Wizard.

## Opciones consideradas
1. **19200 baud.** Ya validado en la placa. Un volcado tarda ~190 ms y cargar 1 K palabras más de
   2 s: el paso a paso se siente lento.
2. **115200 baud.** Un volcado tarda ~31 ms. Con 100 MHz, `DVSR = 54` da 115 741 baud (+0,47 %).
   Lo soporta el chip USB-UART de la Basys 3 (FT2232).
3. **Más de 115200** (por ejemplo 921600). Más rápido, pero el error de baudrate crece según el
   clock y no hace falta para este uso.

## Decisión
115200 8N1, sin paridad y sin control de flujo. El divisor se calcula en el top como
`DVSR = round(f_clk / (16 × BAUD))` a partir de `CLK_FREQ_HZ`, en lugar de escribirse a mano.
Un error menor al 2 % es seguro para 8N1 (para 80, 75 y 50 MHz da 0,94 %, −0,76 % y 0,47 %).

## Consecuencias
- El top de la Debug Unit necesita los parámetros `CLK_FREQ_HZ` y `BAUD`.
- Al aplicar el Clock Wizard se recalcula `DVSR` solo, sin tocar la UART.
- Si la placa da errores de recepción, se vuelve a 19200 cambiando `BAUD` y la configuración del
  cliente. La lógica de la UART no cambia.
- El comentario de `fpga/tp2_uart/top.v` ("50 MHz, 9600") es incorrecto: con 100 MHz ese `DVSR`
  da ~19200. Conviene corregirlo.