# 042 - Reloj del sistema a 65 MHz con el Clock Wizard para la prueba en placa

- **Estado:** propuesta
- **Fecha:** 2026-11-17
- **Autores:** Costamagna, Matías

## Contexto
La síntesis del top `riscv_basys3` (I-49) a 100 MHz, el reloj de la Basys 3, no cierra timing:
**WNS = −5,227 ns**, con 159 endpoints que fallan (post-síntesis, en
[`docs/timing/`](../timing/README.md)). El camino de datos mide unos 15 ns, o sea unos 65 MHz.
Los 30 peores caminos son una sola familia, la decisión de salto: dato de un load en WB →
forwarding → operando B de la ALU → desplazador → `zero` → `redirect` → flush de ID/EX, `ena` de
`imem` y enable de IF/ID. Es la hipótesis de la decisión
[012](012_resolucion-saltos.md), con un agravante: `zero` sale del resultado ya multiplexado de
la ALU, así que el camino pasa por el barrel shifter. Ninguno de esos caminos pasa por la Debug
Unit.

La I-49 pide timing a 100 MHz cumplido **o el problema anotado para M11**. Pero la prueba en
placa necesita un reloj con el que el diseño cumpla timing: con −5 ns, un fallo en la placa no
diría nada. La consigna prevé bajar la frecuencia con el Clock Wizard. Las medidas sobre el
camino crítico son de la I-56 y el Clock Wizard de la I-57, las dos de M11.

## Opciones consideradas
**Cómo cerrar timing para la prueba en placa**
1. **Comparador de igualdad para los saltos** (medida 1 de la 012): `taken` sale de comparar los
   operandos ya reenviados, sin pasar por la ALU.
   - Ventajas: no cambia ciclos ni `.exp`.
   - Desventajas: saca unos 5 de los 12 niveles. Según la estimación post-síntesis, sola no
     alcanza para 100 MHz. Además toca el pipeline en medio de la prueba en placa, y es la I-56.
2. **Registrar `redirect`** (medida 2 de la 012).
   - Desventajas: 3 ciclos de penalización por salto tomado. Cambian el modelo, los `.exp` y
     `ciclos` de todos los programas con saltos.
3. **Clock Wizard** (medida 3 de la 012): un MMCM baja el reloj de la placa y da el único reloj
   del sistema.
   - Ventajas: no toca el pipeline ni los programas. La UART, `INFO` y el timeout de la Debug Unit
     salen de `CLK_FREQ_HZ`, así que se adaptan solos. Es el mecanismo que la I-57 iba a poner de
     todos modos.
   - Desventajas: el procesador anda más lento que el reloj de la placa. Para la consigna no
     importa: los programas de prueba corren en microsegundos.
4. **Probar en placa a 100 MHz igual** y anotarlo para M11.
   - Desventajas: la prueba no vale nada con −5 ns de slack.

**Qué frecuencia** (con la opción 3, medidas post-implementación en `docs/timing/`)
- **50 MHz**: período de 20 ns contra un camino de unos 15 ns. Margen holgado, pero es el
  primer valor que se probó, no el mejor posible.
- **70 MHz**: WNS = +0,083 ns. Pero se midió con un `create_clock` del `.xdc` propio que
  reemplazaba el reloj de entrada del IP y descartaba su input jitter (CRITICAL WARNING
  `[Constraints 18-1055]`). El margen era optimista y casi nulo.
- **65 MHz**: WNS = **+0,519 ns**, WHS = +0,070 ns, 0 warnings críticos, con el reloj de entrada y
  el jitter que define el IP. La placa da 22 de 22 programas con `RUN` y `STEP` y 32 de 32 con las
  variantes `_nops`.

## Decisión
**Opción 3: Clock Wizard a 65 MHz desde `debug-v1`.** Es la mayor de las frecuencias medidas que
cierra con margen real, medida con las restricciones correctas.
- `ip/clk_wiz.tcl` crea `clk_wiz_sys`: un MMCM con entrada de 100 MHz (pin W5) y salida
  `clk_out1` de 65 MHz por un BUFG (el wizard elige D = 5, M = 50,375: VCO de 1007,5 MHz y
  divisor 15,5; jitter de salida 254,9 ps), con `locked` y sin entrada de
  reset.
- `clk_out1` (`clk_sys` en el top) es el único reloj de la UART, la Debug Unit y el core: un solo
  dominio, como pide la decisión [018](018_paso-a-paso-sin-clock.md). El reloj de la placa solo
  entra al MMCM.
- `CLK_FREQ_HZ` del top vale 65 MHz y tiene que coincidir con la salida del IP.
- El reloj de entrada lo define el `.xdc` del IP. `basys3.xdc` **no** tiene `create_clock` sobre
  `clk`: reemplazarlo descarta el input jitter del IP.
- El reset del sistema queda activo hasta que el MMCM engancha:
  `rst_req = reset | ~locked` entra a `reset_sync` (decisión
  [041](041_reset-del-sistema-en-la-placa.md)), cuya entrada pasa a llamarse `i_rst_req`. El
  contador del reset de encendido vuelve a 0 mientras `locked = 0`, y el reset dura `POR_CYCLES`
  ciclos después de que engancha.

## Consecuencias
- **Cambiar la frecuencia toca tres valores que tienen que coincidir:**
  `CLKOUT1_REQUESTED_OUT_FREQ` en `ip/clk_wiz.tcl`, `CLK_FREQ_HZ` en el top y `F_SYS` en
  `tb/unit/top_tb.v`. El testbench mide el período de `clk_sys` y, si no coincide con `F_SYS`,
  termina con `TEST FAILED` y dice qué cambiar. Después hay que regenerar el IP.
- **El comparador de igualdad sigue siendo la primera medida de la I-56.** Esta nota no la
  descarta: la I-56 mide el diseño, aplica las medidas de la 012 y decide si se puede subir de
  65 MHz.
- **I-57**: el Clock Wizard ya está. Le queda elegir la frecuencia final con los datos de la I-56,
  y lo que pida la consigna sobre el Clock Wizard para el informe.
- `basys3.xdc` tiene `set_false_path` hacia el primer flip-flop de `reset_sync`, porque `locked`
  entra asíncrono.
- `protocolo_debug.md` §1: a 65 MHz `DVSR = 35`, 116 071 baud (+0,76 %). El timeout de la Debug
  Unit (`CLK_FREQ_HZ / 10`) sigue siendo de 100 ms.
- `INFO` informa `clk_khz = 65000`. El cliente no cambia.
- `top_tb` entra al top con 100 MHz, como la placa, y cuenta los ciclos con `clk_sys`. Para
  simular rápido le pone `BAUD = CLK_FREQ_HZ / 32` (`DVSR = 2`), sin cambiar `CLK_FREQ_HZ`. El
  MMCM se simula con su modelo de la biblioteca `unisim`: el testbench espera a `locked` antes de
  mirar el sistema.
- Las BRAM de IP se sintetizan fuera de contexto con un reloj de 20 ns, distinto del real
  (`[Timing 38-316]`, un warning, no crítico). No cambia nada en una BRAM sin lógica alrededor.
