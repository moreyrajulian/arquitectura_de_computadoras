# 032 - Testbenches unitarios en la regresión por lotes

- **Estado:** propuesta
- **Fecha:** 2026-11-09
- **Autores:** Costamagna, Matías

## Contexto
[`verificacion.md`](../spec/verificacion.md) §6 dice que la regresión de la I-43 "corre todos los
testbenches y todos los programas y la aprobación es única: ningún `TEST FAILED`". La decisión
[028](028_regresion-por-lotes.md) dejó afuera a los testbenches unitarios: "cada uno se corre con
su `top`. Si la I-43 los suma, se agrega otro tipo de línea a `corridas.txt`". Hasta ahora cada PR
corría a mano el testbench de su módulo, y nada comprobaba que un cambio en un módulo no rompiera
el testbench de otro.

Restricciones:
- Los testbenches de `tb/unit/` que usan `imem` o `dmem` (`imem_tb`, `dmem_tb`, `if_stage_tb`,
  `mem_stage_tb`) simulan los IP, así que corren en el proyecto de Vivado, como `pipeline_tb`.
- Cada testbench es otro `top`: `launch_simulation -step simulate` no sirve, porque reusa el
  snapshot de `pipeline_tb`. Cada uno compila y elabora desde cero.
- `uart_tb` es el testbench del sistema del TP2 (UART + interfaz + ALU): su DUT es
  `fpga/tp2_uart/top.v`, que no está en el proyecto `riscv_basys3`, así que ahí no elabora
  (`Module <top> not found`).
- `regresion.tcl` repite `corridas.txt` entera una vez por mutante (decisión
  [031](031_mutantes-de-la-regresion.md)). Un mutante de un módulo hace fallar su propio
  testbench, y eso no dice nada de si los programas cubren el mecanismo, que es lo que mide §6.

## Opciones consideradas
1. **Otro tipo de línea en `corridas.txt`**, como sugería la 028. Ventaja: una sola lista.
   Desventajas: `regresion.tcl` tendría que saltear esas líneas en las pasadas con mutante y
   distinguir en cada línea si cambia el `top`; una lista que se recorre distinto según el tipo
   de línea es más fácil de romper.
2. **Una lista aparte, `build/regresion/unitarios.txt`**, que `regresion.py` escribe solo en la
   regresión normal y `regresion.tcl` corre después de los programas. Ventajas: las pasadas con
   mutante no cambian; la lista no existe cuando no corresponde, como `mutantes.txt`.
   Desventaja: un archivo más.
3. **Un script aparte para los unitarios.** Ventaja: no toca `regresion.tcl`. Desventaja: la
   aprobación deja de ser única, que es lo que pide §6.

## Decisión
**Opción 2.** `regresion.py` escribe en `unitarios.txt` los `tb/unit/*_tb.v`, menos la plantilla
y los de otro diseño (el módulo superior se llama como el archivo, `verificacion.md` §7), cuando
corre la regresión normal: sin nombres de programas, sin `--mutante` y sin `--sin-unitarios`. En
cualquier otro caso la borra. `regresion.tcl`, después de la pasada sin mutante, corre cada testbench con su `top`,
decide por la última línea `TEST` y lo suma al resumen (`UNITARIOS: n de m testbenches con TEST
PASSED`). Una falla de un unitario hace fallar la regresión, como una corrida de `pipeline_tb`.

Los testbenches de otro diseño están en una lista explícita, `OTRO_DISENO` de `regresion.py`, con
el motivo, y `regresion.py` avisa en cada corrida que no los corre. Hoy es solo `uart_tb`. Sumar el
`top` del TP2 a la simulación del procesador chocaría con el `top.v` de `fpga/riscv_basys3/`
cuando exista (I-49), y correrlo en el proyecto `tp2_uart` haría más lento y más complejo el
script por un testbench que no prueba el procesador.

## Consecuencias
- `python scripts/regresion.py` y `regresion.tcl` son la regresión completa de §6: los programas
  de `sw/` y los 19 testbenches unitarios del procesador. Los logs de los unitarios quedan en
  `build/regresion/logs/unit/<tb>.log`.
- La regresión tarda más: cada unitario compila desde cero. Para iterar sobre un programa se
  corre con su nombre, o con `--sin-unitarios`.
- Un testbench nuevo en `tb/unit/` entra solo a la regresión, siempre que su módulo superior se
  llame como el archivo y termine con la línea `TEST` de §6.
- Las pasadas con mutante no corren los unitarios.
- **La I-44** amplía `uart_tb` para la UART de debug (`verificacion.md` §3.3). Cuando pruebe
  módulos del procesador, sale de `OTRO_DISENO` y entra a la regresión.
