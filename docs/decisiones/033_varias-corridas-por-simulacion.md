# 033 - Varias corridas en una simulación de `pipeline_tb`

- **Estado:** propuesta
- **Fecha:** 2026-11-10
- **Autores:** Costamagna, Matías

## Contexto
La decisión [028](028_regresion-por-lotes.md) compila y elabora `pipeline_tb` una vez por
pasada y corre cada línea de `corridas.txt` con `launch_simulation -step simulate`. Eso arranca
xsim de nuevo y solo cambia los plusargs. Cada arranque tarda unos 3,8 s, y casi todo ese tiempo
es cargar el snapshot: un programa de `sw/` simula entre 20 y 115 ciclos, más unos 3000 de carga
y lectura de las memorias. La regresión con `--pausas` (78 corridas) tardaba unos 5 minutos solo
en `pipeline_tb`. Con mutantes (decisión [031](031_mutantes-de-la-regresion.md)), cada uno
repite las 39 corridas y compila de nuevo. Para los 41 de la I-43 son 42 pasadas de
16 s + 39 × 3,8 s, cerca de 2 horas: la corrida se cortó con 22 mutantes terminados.

Restricciones:
- Cada mutante tiene que correr todas las corridas. Para decir que un mutante no se detecta
  hacen falta todas. Además, la tabla de [`verificacion.md`](../spec/verificacion.md) §8.2
  anota cuántas corridas y qué programas detectan cada uno, y así muestra la cobertura frágil:
  `fwd_prioridad`, `fwd_rd0_ex_mem` y `fwd_rd0_mem_wb` los detecta una sola corrida.
- `pipeline_tb` ya carga cada programa como `LOAD` ([`memoria.md`](../spec/memoria.md) §3.5):
  con el core en reset, escribe `imem` y `dmem` completas por el puerto B, y el banco por
  jerarquía después de soltar el reset.
- La regla de la última línea `TEST` (`verificacion.md` §6), el log por corrida y el estado
  `ERROR` (§8.7) tienen que seguir igual.

## Opciones consideradas
1. **Cortar cada mutante en la primera corrida que falla.** Ventaja: no toca el testbench.
   Desventajas: se pierde la tabla de §8.2. Los equivalentes, y cualquier mutante que no se
   detecte, siguen corriendo todo. La regresión normal no se acelera.
2. **Correr menos programas por mutante**, por ejemplo sin los `indep_*`, que solo detectan
   `bypass_sin_we`. Desventajas: elegir los programas sabiendo qué detectan sesga lo que mide
   §6, y se ahorra un 13 %.
3. **Varios Vivado en paralelo.** Desventajas: con 8 GB de RAM entran 2 o 3. Cada uno necesita
   su propio proyecto y su propio `build/regresion/`, y el script se complica.
4. **Varias corridas en una simulación.** `pipeline_tb` lee una lista (`+LISTA`) y corre las
   corridas una tras otra, con el core en reset entre una y otra. Ventajas: xsim arranca una
   vez por pasada, la tabla y los logs por corrida no cambian, y la regresión normal también se
   acelera. Desventajas: cambia el testbench; un estado que sobreviva al reset haría depender
   una corrida de la anterior; y si xsim se cae en medio de una pasada, se pierde el resultado
   de todas las corridas que faltaban, no solo de una.

## Decisión
**Opción 4.**

- **`pipeline_tb`** acepta `+LISTA=<archivo>`, con una corrida por línea: etiqueta, directorio,
  `final`, `pausas` y semilla.
  - La secuencia de siempre pasa a la tarea `correr`. Arranca con el core en reset y pone en
    cero los errores, los chequeos, el `fallo` y el `paso` de la corrida. También el watchdog,
    que va en la tarea `vigilada`, y los ciclos, que ahora se borran con `tb_rst`.
  - El watchdog y `terminar_mal` terminan la corrida, no la simulación (`fork` con `disable`).
  - Antes de cada corrida imprime `CORRIDA <etiqueta>`, y al terminarla su línea `TEST`, la
    misma que con `+DIR`. Al final imprime `LISTA: n de m corridas con TEST PASSED`: esa línea no
    empieza con `TEST`, así no se mezcla con la regla de §6.
  - `+DIR` sigue igual, una sola corrida, para correr un programa a mano y para `ondas.tcl`.
- **`regresion.tcl`** escribe `build/regresion/lista_tb.txt` desde `corridas.txt`, armando las
  rutas absolutas como en la 028, y corre cada pasada en una sola simulación: un
  `launch_simulation` completo y `run all`.
  - Parte el log en las líneas `CORRIDA`. La parte de cada corrida va a
    `logs/[<mutante>/]<etiqueta>.log` y se decide por su última línea `TEST`, como antes. El log
    entero queda en `pipeline_tb.log`.
  - Una corrida que no aparece en el log, o cuya parte no tiene línea `TEST`, queda en `ERROR`.

De la 028, esta decisión reemplaza `-step simulate`. `corridas.txt`, el resto de la 028 y las
decisiones 031 y 032 no cambian. `regresion.py` suma `--invertir`, que escribe las corridas en
orden inverso (ver Consecuencias).

Con el reset alcanza porque es lo que hace la Debug Unit en la placa: `LOAD` y `RESET` de un
programa atrás de otro, sin reconfigurar la FPGA. Si algún estado del core sobrevive al reset,
falla la pasada sin mutante, y eso es un bug del core que hay que corregir.

## Consecuencias
- **Tiempos** (Vivado 2026.1, Linux): con `--pausas 47 --sin-unitarios`, las 78 corridas
  tardan 32 s en total, contando abrir el proyecto y compilar; antes eran unos 5 minutos. La
  simulación entera usa 2,2 s de CPU. Los 41 mutantes, con la pasada sin mutante, tardan 920 s
  en lugar de cerca de 2 horas: cada pasada cuesta poco más que compilar.
- **Validación:**
  - Las 78 corridas dan los mismos chequeos que con una simulación por corrida, también las de
    `+PAUSAS`.
  - De los 22 mutantes que terminaron con el método anterior, 21 dan exactamente las mismas
    corridas detectoras. El otro es `bypass_sin_we`, que ve el estado que el reset no borra (ver
    abajo).
  - Se forzaron, con `MAX_CYCLES = 58`, un timeout, un directorio que no existe y una traza
    más larga que `MAX_CYCLES`. Cada caso termina solo su corrida, y las que vienen después
    pasan con los mismos chequeos que solas.
- **Rutas:** la ruta del repositorio no puede tener espacios, porque `pipeline_tb` lee cada
  campo de la lista hasta el próximo espacio. Con `-testplusarg DIR=...` pasaba lo mismo.
  `regresion.tcl` lo comprueba antes de empezar.
- **Si xsim se cae** en medio de una pasada, las corridas que faltaban quedan en `ERROR`.
  `ERROR` dice que no hay resultado, así que nunca cuentan como detectadas ni como pasadas.
- **Si algún estado sobrevive al reset** y el core lo usa, un programa puede hacer fallar a los
  siguientes. Hay que corregirlo en el core, no esquivarlo, porque en la placa pasaría lo mismo.
  La pasada sin mutante pasa, así que hoy no ocurre.
- **Estado que el reset no borra a propósito.** Los caminos de datos de los registros de
  segmentación no se resetean (decisión [010](010_convenciones-rtl.md)). El core correcto no los
  usa, porque el control de la burbuja los anula, pero un mutante que saca esa condición
  (`bypass_sin_we`, `stall_sin_mem_read`) los ve mientras la burbuja del reset recorre el
  pipeline: en la traza, hasta el ciclo 5. En la primera corrida son X, como antes en todas las
  corridas; en las siguientes, lo que dejó la anterior, como en la placa.
  - Con una simulación por corrida, `bypass_sin_we` fallaba en las 39 corridas en el ciclo 3 o
    4, por la X.
  - Con `+LISTA` falla en 5. De esas, solo 3 se mantienen con `regresion.py --invertir`, que
    escribe las corridas en orden inverso, en los mismos ciclos. Son las que cuenta
    `verificacion.md` §8.2.
  - Un programa cuenta como detector de un mutante así si falla en los dos órdenes. El ciclo
    solo no alcanza para separar estas fallas, porque muchas fallas propias del programa
    también aparecen en los ciclos 4 y 5.
