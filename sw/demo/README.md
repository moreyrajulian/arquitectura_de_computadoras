# sw/demo: programas de demostración

Dos programas cortos para la presentación (I-58), pensados para recorrerlos en paso a paso
con el debugger ([`interfaz_pc.md`](../../docs/spec/interfaz_pc.md)). Entre los dos muestran
el forwarding, el bypass del banco, el stall de carga-uso y el flush por saltos.

| Programa | Instrucciones | Ciclos | Qué muestra |
|---|---:|---:|---|
| `demo_datos` | 10 | 15 | Riesgos de datos: forwarding hacia la ALU y hacia el dato del store, bypass del banco, carga-uso y load sin dependencia |
| `demo_control` | 15 | 44 | Saltos: lazo con `bne` hacia atrás, forwarding al comparador, `lw` seguido de `beq`, flush y un HALT en el camino equivocado |

Siguen las reglas de [`sw/README.md`](../README.md) §3: un comentario por instrucción con su
valor, `.exp` escrito a mano y ciclos con `n + 4 + stalls + 2 · saltos_tomados`. Usan solo
`x1`–`x15`, y el camino equivocado escribe `x15 = -1`.

**No son parte de la regresión.** Están en esta carpeta para que las listas de
`sw/programas.py` y los tests, que miran solo `sw/*.s`, no los incluyan. Se verifican a mano:

```sh
python tools/isasim/sim.py sw/demo/demo_datos.s --exp auto        # contra el modelo
python tools/debugger/comparar.py COM10 sw/demo/demo_datos.s --cada-ciclo   # placa contra el modelo
```

## Cobertura

"Ciclo" es el contador de la barra de estado de la TUI después de N pasos (`F10`) desde
`LOAD` o `RESET`: es lo que se ve en pantalla con el core detenido.

### `demo_datos`

| Ciclo | Mecanismo | Dónde |
|:---:|---|---|
| 4 | Forwarding desde MEM/WB y desde EX/MEM, los dos a la vez | `add x3, x1, x2`: x1 de `addi x1`, x2 de `addi x2` |
| 5 | Forwarding desde EX/MEM al dato del store | `sw x3`: x3 del `add` anterior |
| 6 | Forwarding desde MEM/WB | `sub x4, x3, x1`: x3 del `add` |
| 7 | Carga-uso previsto | `lw x5` en EX, `add x6, x5, x4` en ID |
| 8 | Stall y bypass del banco | burbuja en EX; `sub x4` en WB mientras `add x6` lee x4 en ID |
| 9 | Forwarding del dato del load desde MEM/WB | `add x6` recibe x5; x4 ya está en `ID/EX` |
| 10 | Load sin dependencia: no frena | `lw x7` en EX, `sw x6` en ID |
| 11 | Forwarding desde MEM/WB al dato del store | `sw x6`: x6 del `add` |
| 11–15 | HALT en vuelo y vaciado del pipeline | |

### `demo_control`

| Ciclo | Mecanismo | Dónde |
|:---:|---|---|
| 7 | Forwarding desde EX/MEM al dato del store | `sw x5`: x5 del `add` |
| 8 | Bypass del banco | `addi x2, x5` lee x5 en ID con el `add` en WB |
| 11 | Forwarding al comparador; se predice el salto tomado | `bne x3, x4`: x3 del `addi` anterior |
| 12 | Flush: IF/ID e ID/EX en burbuja | después del `bne` tomado (también en 20 y 28) |
| 35 | Salto no tomado, sin ciclos perdidos | `bne` de la cuarta vuelta |
| 36 | Forwarding desde MEM/WB a la base de un load; carga-uso previsto | `lw x6, -4(x3)`; `beq` en ID |
| 37 | Stall | burbuja en EX |
| 38 | Forwarding del dato del load al comparador; HALT en ID | `beq x6, x2` recibe x6 y se toma; el HALT de `0x30` está en ID |
| 39 | Flush: el HALT del camino equivocado se anula y el core sigue | |
| 40–44 | HALT real y vaciado del pipeline | `fin` |

La memoria queda con 2, 3, 5 y 8 en `0x100`–`0x10C`.

## Guion

- **`demo_datos`**: todo en paso a paso, 15 veces `F10`. El punto fuerte son los ciclos 8
  y 9: el `add x6` después del `lw x5` frena, x4 llega por el bypass del banco y x5 por
  forwarding desde MEM/WB.
- **`demo_control`**:
  1. `F10` hasta el ciclo 12: la primera vuelta, el forwarding al comparador y el flush.
  2. `Shift+F10` con N = 23 hasta el ciclo 35: el `bne` de la última vuelta no se toma.
  3. `F10` hasta el final: el stall del `lw` con el `beq`, el flush del HALT del camino
     equivocado y el HALT real.
  4. `F3` y `F5`: la corrida en continuo y el estado final, con los 44 ciclos.

`F4` no sirve para avanzar dentro del lazo: para cuando la instrucción de la línea elegida
llega a WB, y eso pasa en la primera vuelta. Con otra cantidad de vueltas V (el fin del
arreglo en `x4` es `0x100 + 4 · V`), el programa tarda `12 + 8 · V` ciclos y el
`Shift+F10` del paso 2 es N = `8 · V − 9`.

## Prueba en placa

Con el bitstream de `master` a 92 MHz (decisión
[045](../../docs/decisiones/045_reloj-del-sistema-a-92-mhz.md)), los dos coinciden con el modelo
en todos los ciclos:

```
> python tools\debugger\comparar.py COM8 sw\demo\demo_datos.s --cada-ciclo
INFO: protocolo 1, imem 1024, dmem 1024, latches 3/6/4/4 palabras, 92000 kHz
demo_datos.s: 10 palabras; el modelo termina en 15 ciclos
LOAD y 15 STEP, comparando cada ciclo
15 ciclos: todos coinciden con el modelo

> python tools\debugger\comparar.py COM8 sw\demo\demo_control.s --cada-ciclo
INFO: protocolo 1, imem 1024, dmem 1024, latches 3/6/4/4 palabras, 92000 kHz
demo_control.s: 15 palabras; el modelo termina en 44 ciclos
LOAD y 44 STEP, comparando cada ciclo
44 ciclos: todos coinciden con el modelo
```

Ensayo del guion con el debugger, en los ciclos clave:

| Captura | Qué muestra |
|---|---|
| [`debugger_demo_datos_ciclo08.png`](../../docs/capturas/debugger_demo_datos_ciclo08.png) | Stall: burbuja en EX, PC e IF/ID retenidos; `sub x4` en WB escribe x4 = 3 mientras `add x6` lo lee en ID |
| [`debugger_demo_datos_ciclo09.png`](../../docs/capturas/debugger_demo_datos_ciclo09.png) | `add x6` en EX: x5 = 8 por forwarding desde MEM/WB y `rs2_data = 3` en ID/EX, que entró por el bypass del banco |
| [`debugger_demo_datos_halted.png`](../../docs/capturas/debugger_demo_datos_halted.png) | Estado final: 15 ciclos, pipeline vacío, registros y memoria del `.exp` |
| [`debugger_demo_control_ciclo38.png`](../../docs/capturas/debugger_demo_control_ciclo38.png) | `beq` en EX recibe x6 = 8 desde MEM/WB y se toma; el HALT de `0x30` está en ID y frena el fetch |
| [`debugger_demo_control_ciclo39.png`](../../docs/capturas/debugger_demo_control_ciclo39.png) | Flush: IF/ID e ID/EX en burbuja, el HALT del camino equivocado se anula y el core sigue (`PAUSED`, no `HALTED`) |
| [`debugger_demo_control_halted.png`](../../docs/capturas/debugger_demo_control_halted.png) | Estado final: 44 ciclos, pipeline vacío, Fibonacci 2, 3, 5, 8 en memoria y x15 = 0 |

En el ciclo 8 el panel de registros todavía muestra x4 = 0: muestra el banco después del flanco,
y la escritura de WB aparece en el ciclo 9. Lo que prueba el bypass es que en el ciclo 9 ID/EX ya
tiene el 3.
