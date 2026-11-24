# 045 - Reloj del sistema a 92 MHz, la máxima frecuencia del barrido

- **Estado:** aceptada
- **Fecha:** 2026-11-22
- **Autores:** Moreyra, Julián

## Contexto
La decisión [042](042_reloj-del-sistema-a-65-mhz.md) puso el Clock Wizard a 65 MHz para la prueba
en placa, cuando el diseño no cerraba timing a 100 MHz. Después la I-56 aplicó el comparador de
igualdad para los saltos (decisión [044](044_comparador-de-igualdad-en-saltos.md)) y el WNS a
65 MHz pasó a +1,418 ns, con una estimación de ~71,6 MHz como cota. La I-57 pide elegir la
frecuencia final con un barrido hasta la máxima que cumpla timing (WNS ≥ 0), con margen y
justificada, y medirla antes y después.

El barrido (`scripts/barrido.tcl`, [`docs/timing/`](../timing/README.md), sección I-57) implementa
el diseño desde cero a 16 frecuencias, de 65 a 100 MHz, con la estrategia por defecto. El flujo es
determinista: con las mismas entradas da la misma implementación (82 a 90 MHz se midió dos veces
con resultados idénticos, y 92 MHz tres veces, con el barrido, `scripts/timing.tcl` y la GUI).

| Tramo | WNS | Observación |
|---|---|---|
| 65–74 MHz | +1,08 a +1,42 ns | El crítico es el salto (`dmem` → forwarding → comparador → `redirect`) |
| 76–90 MHz | +0,23 a +0,49 ns | El margen cae de golpe; el crítico alterna entre la Debug Unit y el salto |
| **92 MHz** | **+0,026 ns** | La mayor que cierra |
| 95 MHz | −0,449 ns (42 endpoints) | No cierra |
| 100 MHz | −0,714 ns (122 endpoints) | No cierra |

La cota de 71,6 MHz de la I-56 resultó pesimista: con un reloj más exigente la colocación y el
ruteo se esfuerzan más, y el retardo de datos del peor camino baja de 13,15 ns (65 MHz) a
10,12 ns (92 MHz).

## Opciones consideradas
1. **74 MHz**: la mayor de la meseta, con ~1 ns de margen (8 % del período).
   - Ventajas: una reimplementación después de un cambio de RTL muy probablemente siga cerrando.
   - Desventajas: deja un 20 % de frecuencia sin usar.
2. **80 u 82 MHz**: +0,41 y +0,49 ns. El wizard elige D = 1 y el jitter baja (incertidumbre de
   0,077 contra 0,13 ns).
   - Desventajas: el margen ya es del orden de las caídas que muestra el barrido entre una
     frecuencia y la siguiente, así que no protege mucho más que 92 MHz.
3. **92 MHz**: la máxima del barrido, +0,026 ns.
   - Ventajas: es lo que pide la consigna, la frecuencia máxima a la que funciona el diseño.
   - Desventajas: sin margen para reimplementar: cualquier cambio de RTL o de restricciones
     cambia el ruteo y obliga a volver a medir.
4. **Afinar entre 92 y 95 MHz** (93, 94).
   - Desventajas: afina un valor que no cambia la elección; el wizard da otros D/M/O y el
     resultado no es monótono.

## Decisión
**Opción 3: Clock Wizard a 92 MHz.** El análisis estático de Vivado ya usa el peor caso de
proceso, tensión y temperatura del dispositivo, así que con WNS ≥ 0 el diseño funciona en la
placa; el margen solo protege las implementaciones futuras, y el RTL no se vuelve a cambiar. Lo
confirman la regresión en simulación y la prueba en placa a 92 MHz.

- `ip/clk_wiz.tcl` pide 92 MHz. El wizard elige D = 5, M = 48,875 (VCO de 977,5 MHz) y
  O = 10,625: **92 000 000 Hz exactos**, con 248,4 ps de jitter pico a pico y 294,2 ps de error de
  fase.
- `CLK_FREQ_HZ` del top y `F_SYS` de `tb/unit/top_tb.v` valen 92 000 000, como pide la 042.
- Lo demás de la 042 sigue igual: un MMCM, un solo reloj, el reset retenido hasta `locked` y el
  reloj de entrada definido por el `.xdc` del IP.

## Consecuencias
- **Reemplaza la frecuencia de la 042** (65 → 92 MHz). El resto de la 042 sigue vigente.
- **Resultado a 92 MHz** (post-implementación, `scripts/timing.tcl`): WNS +0,026 ns, WHS
  +0,037 ns, 0 de 5360 endpoints fallan; 2907 LUT (14 %), 1884 FF (5 %), 2 BRAM, 1 MMCM; 0,200 W
  estimados. A 65 MHz, con el mismo flujo, eran +1,418 ns, 2813 LUT, 1882 FF y 0,200 W.
- **Varias etapas quedan en el límite**: ID/EX +0,026 ns, EX/MEM +0,114, `pc_reg` +0,171,
  `imem` +0,428. No hay un único camino que, acortado, permita subir mucho más.
- **El consumo casi no depende de la frecuencia**: de 0,128 W dinámicos, 0,120 W son del MMCM;
  la lógica del procesador suma unos 7 mW. Es la estimación sin vectores de simulación, con
  confianza *Medium*.
- **La síntesis estima −0,465 ns** (21 endpoints): sin colocación ni ruteo, Vivado estima los
  cables. Vale el resultado post-route.
- **UART**: `DVSR = 50`, 115 000 baud (−0,17 %); tabla en
  [`protocolo_debug.md`](../spec/protocolo_debug.md) §1. El timeout de la Debug Unit
  (`CLK_FREQ_HZ / 10`) sigue siendo de 100 ms e `INFO` informa `clk_khz = 92000`.
- **Si cambia el RTL o el `.xdc`**, hay que volver a correr `scripts/timing.tcl` antes de generar
  el bitstream; si el WNS sale negativo, se baja la frecuencia con `scripts/barrido.tcl`
  (74 MHz tuvo ~1 ns de margen).
- `scripts/timing.tcl` regenera el proyecto antes de implementar: reabrir uno viejo medía el
  reloj del IP de cuando se creó el proyecto, porque los IP se configuran solo en
  `create_project.tcl`.
- La implementación tiene 2 warnings de DRC (PDRC-132 y PDRC-134, en `SLICE_X53Y10`): ninguno
  crítico, el bitstream se genera.
