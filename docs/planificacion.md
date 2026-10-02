# Planificación

Cronograma estimado del trabajo final, con el pipeline construido **etapa por etapa**.
Los criterios de terminado de cada tarea están en los issues de GitHub.

![Gantt](diagramas/gantt.png)

## Enfoque por etapas

Cada etapa (IF, ID, EX, MEM, WB) es un milestone con el mismo ciclo:

1. Implementar los módulos de la etapa, cada uno con su testbench unitario.
2. Integrar la etapa al pipeline.
3. Validar el pipeline hasta esa etapa con el banco de pruebas incremental, que compara
   cada registro de segmentación contra la traza del modelo de referencia.

Los módulos de una etapa pueden adelantarse si la persona tiene tiempo libre (por
ejemplo, la unidad de control antes de cerrar IF), pero **la integración sigue siempre el
orden de las etapas**. Los riesgos (forwarding, stall y flush) se agregan recién con las
cinco etapas funcionando, porque involucran a varias a la vez.

## Supuestos de la estimación

- **Inicio real:** 26/09/2026 (primer issue de especificación; la reorganización del
  repositorio y las plantillas son del 24/09). **Fin estimado:** 07/01/2027.
- **Personas:** A es Julián Moreyra y B es Matías Costamagna.
- **Dedicación:** unas 10 a 12 horas por semana por persona. Un "día" del cronograma es un
  día de calendario con esa dedicación (incluye fines de semana), no una jornada completa.
- **Cada persona trabaja en un issue por vez.** Cuando se libera, toma el siguiente issue
  disponible; las etapas del pipeline tienen prioridad, y la Debug Unit y las herramientas
  llenan los huecos. Los issues *A + B* ocupan a los dos.
- **Carga total:** A 102 días, B 114 días (incluidos los compartidos). El plan original
  estaba equilibrado en 108 y 108; la diferencia viene de que B tomó el I-06 (6 días), que
  era de A.
- **Sin margen:** no incluye reserva para imprevistos, parciales de otras materias ni
  feriados. Las fiestas de fin de año caen en plena etapa de interfaz e integración.
- **Reprogramación al 02/10/2026:** M1 avanzó más rápido de lo estimado, así que las tareas
  pendientes de M1 se reprogramaron desde el 02/10 y **todas las tareas desde M2 en adelante
  se adelantaron 14 días**, sin cambiar su orden ni sus duraciones.
- Frente al plan anterior (monociclo y luego segmentación), este enfoque suma unos 10 días
  por persona: un registro de segmentación por issue, una integración por etapa y la traza
  por etapa en el modelo de referencia. A cambio, cada error queda acotado a la última
  etapa integrada.

## Avance al 02/10/2026

| Issue | Responsable | Inicio | Fin real | Estimado | Real | PR |
|---|---|---|---|---|---|---|
| I-01 Diagrama de bloques | A + B | 26/09 | 27/09 | 3 días | 2 días | #18 |
| I-02 ISA | B | 26/09 | 28/09 | 4 días | 3 días | #17, #20 |
| I-03 Formatos de instrucción | B | 28/09 | 28/09 | 2 días | 1 día | #21 |
| I-08 Decisión HALT | A + B | 28/09 | 29/09 | 2 días | 2 días | #22 |
| I-06 Protocolo de debug | B (era de A) | 29/09 | 30/09 | 6 días | 2 días | #23 |
| I-04 Pipeline y datapath | A | 29/09 | en curso | 6 días | — | sin PR (`docs/7_pipeline`) |

## Cómo se reparte el trabajo

Cada persona hace la mitad del proyecto **en cada área**, para que los dos conozcan todas
las partes del sistema y puedan defender cualquiera:

| Área | A | B |
|---|---|---|
| Especificación (M1) | 11 días | 25 días |
| Herramientas y programas (M2, M10, demo) | 20 días | 20 días |
| Pipeline: etapas y riesgos (M3 a M8) | 36 días | 38 días |
| Debug Unit (M9) | 13 días | 13 días |
| Integración y timing (M11) | 8 días | 4 días |
| Tareas conjuntas | 14 días | 14 días |

- **Pipeline:** en cada etapa los módulos se reparten entre los dos. En IF, ID, EX y
  riesgos, **quien integra la etapa no escribió la mayoría de sus módulos**: integrar
  obliga a entender el trabajo del otro.
- **Riesgos:** A hace el forwarding y el flush; B, el stall por carga-uso y la regresión
  completa.
- **Debug Unit:** A hace la UART, la FSM de comandos y la carga de programa; B, los modos
  de ejecución, el volcado de estado y la prueba en placa.
- **Herramientas:** A hace el ensamblador, el modelo de referencia y la interfaz; B, los
  programas de prueba, el cliente del protocolo, el desensamblador, la vista del pipeline,
  la verificación automática y el programa de demo.
- **Especificación:** también está repartida. B escribió la ISA, los formatos y el
  protocolo de debug (este último estaba asignado a A); A escribe el pipeline y el datapath.
  Como cada área se implementa entre los dos, cada documento lo usa también quien no lo
  escribió, y eso lo pone a prueba: por ejemplo, A implementa la UART, la FSM de comandos y
  la carga de programa a partir del protocolo que escribió B.
- **Integración final:** B lleva el pipeline a la placa; A hace el análisis de timing y el
  Clock Wizard.
- **La Debug Unit crece con el pipeline:** la carga de programa y el paso a paso funcionan
  desde la etapa IF, y la prueba en placa (I-49) se hace con el pipeline disponible en ese
  momento.

## Fechas por milestone

| Milestone | Fin estimado |
|---|---|
| M1 - Especificación | 15/10/2026 |
| M2 - Ensamblador y modelo de referencia | 29/10/2026 |
| M3 - Etapa IF | 04/11/2026 |
| M4 - Etapa ID | 12/11/2026 |
| M5 - Etapa EX | 19/11/2026 |
| M6 - Etapa MEM | 22/11/2026 |
| M7 - Etapa WB y cierre del pipeline | 04/12/2026 |
| M8 - Riesgos | 18/12/2026 |
| M9 - Debug Unit | 11/12/2026 |
| M10 - Interfaz de PC | 29/12/2026 |
| M11 - Integración y timing | 07/01/2027 |

M9 (Debug Unit) termina antes que M8 (Riesgos) porque lo lleva B en paralelo.

## Diagrama (Mermaid)

GitHub renderiza este bloque. Es la fuente editable del Gantt: al cambiar una fecha o una
duración, actualizalo acá. Las tareas compartidas aparecen resaltadas; las terminadas se
marcan con `done` y la que está en curso, con `active`.

```mermaid
gantt
    title Trabajo final RISC-V - plan por etapas
    dateFormat YYYY-MM-DD
    axisFormat %d/%m
    tickInterval 1week
    section M1 Especificación
    I-01 Diagrama de bloques (A + B) :crit, done, 2026-09-26, 2d
    I-02 ISA (B) :done, 2026-09-26, 3d
    I-03 Formatos de instrucción (B) :done, 2026-09-28, 1d
    I-08 Decisión HALT (A + B) :crit, done, 2026-09-28, 2d
    I-06 Protocolo de debug (B) :done, 2026-09-29, 2d
    I-04 Pipeline y datapath (A) :active, 2026-09-29, 6d
    I-12 Boceto interfaz PC (B) :2026-10-02, 3d
    I-13 Convenciones RTL (A + B) :crit, 2026-10-05, 1d
    I-14 Paso a paso sin clock (A) :2026-10-06, 2d
    I-09 Decisión saltos (B) :2026-10-06, 3d
    I-11 Plan de verificación (A) :2026-10-08, 3d
    I-07 Mapa de memoria (B) :2026-10-09, 3d
    I-05 Control y riesgos (B) :2026-10-12, 4d
    M1 cerrado :milestone, 2026-10-16, 0d
    section M2 Ensamblador y modelo de referencia
    I-10 Ensamblador (A) :2026-10-16, 7d
    I-15 Programas de prueba (B) :2026-10-20, 4d
    I-16 Modelo de referencia (A) :2026-10-23, 7d
    M2 cerrado :milestone, 2026-10-30, 0d
    section M3 Etapa IF
    I-21 Registro IF/ID (A) :2026-10-11, 2d
    I-17 Banco de pruebas incremental (B) :2026-10-24, 4d
    I-18 Definiciones de la ISA (A) :2026-10-30, 1d
    I-20 Memoria de programa (A) :2026-10-31, 3d
    I-19 PC y próxima dirección (B) :2026-11-01, 2d
    I-22 Integración IF (B) :2026-11-03, 2d
    M3 cerrado :milestone, 2026-11-05, 0d
    section M4 Etapa ID
    I-23 Banco de registros (A) :2026-11-03, 2d
    I-24 Unidad de control (A) :2026-11-05, 3d
    I-25 Generador de inmediatos (B) :2026-11-05, 2d
    I-26 Registro ID/EX (A) :2026-11-08, 2d
    I-27 Integración ID (B) :2026-11-10, 3d
    M4 cerrado :milestone, 2026-11-13, 0d
    section M5 Etapa EX
    I-28 ALU + control de ALU (B) :2026-11-07, 3d
    I-29 Lógica de saltos (A) :2026-11-10, 3d
    I-30 Registro EX/MEM (B) :2026-11-13, 1d
    I-31 Integración EX (A) :2026-11-17, 3d
    M5 cerrado :milestone, 2026-11-20, 0d
    section M6 Etapa MEM
    I-32 Memoria de datos (B) :2026-10-28, 4d
    I-33 Registro MEM/WB (B) :2026-11-14, 1d
    I-34 Integración MEM (B) :2026-11-20, 3d
    M6 cerrado :milestone, 2026-11-23, 0d
    section M7 Etapa WB y cierre del pipeline
    I-35 Write back (B) :2026-11-23, 3d
    I-36 Saltos hacia IF (B) :2026-11-26, 3d
    I-37 HALT y vaciado (A) :2026-11-29, 3d
    I-38 Validación sin riesgos (A) :2026-12-02, 3d
    M7 cerrado :milestone, 2026-12-05, 0d
    section M8 Riesgos
    I-39 Unidad de forwarding (A) :2026-12-05, 4d
    I-40 Verificación forwarding (A) :2026-12-09, 3d
    I-41 Stall carga-uso (B) :2026-12-12, 4d
    I-42 Flush por saltos (A) :2026-12-12, 4d
    I-43 Regresión completa (B) :2026-12-16, 3d
    M8 cerrado :milestone, 2026-12-19, 0d
    section M9 Debug Unit
    I-44 UART para debug (A) :2026-11-13, 4d
    I-45 Debug - FSM de comandos (A) :2026-11-20, 5d
    I-46 Debug - carga de programa (A) :2026-11-25, 4d
    I-47 Debug - modos de ejecución (B) :2026-11-29, 4d
    I-48 Debug - volcado de estado (B) :2026-12-03, 5d
    I-49 Top y prueba en placa (B) :2026-12-08, 4d
    M9 cerrado :milestone, 2026-12-12, 0d
    section M10 Interfaz de PC
    I-50 Cliente del protocolo (B) :2026-10-16, 4d
    I-51 Desensamblador (B) :2026-11-15, 2d
    I-52 Interfaz de usuario (A) :2026-12-16, 6d
    I-53 Vista del pipeline (B) :2026-12-23, 4d
    I-54 Verificación y README (B) :2026-12-27, 3d
    M10 cerrado :milestone, 2026-12-30, 0d
    section M11 Integración y timing
    I-58 Programa de demo (B) :2026-11-17, 3d
    I-55 Pipeline en la placa (B) :2026-12-19, 4d
    I-56 Camino crítico y skew (A) :2026-12-23, 4d
    I-57 Clock Wizard (A) :2026-12-27, 4d
    I-59 Preguntas de la consigna (A + B) :crit, 2026-12-31, 2d
    I-60 Informe y presentación (A + B) :crit, 2027-01-02, 6d
    M11 cerrado :milestone, 2027-01-08, 0d
```

## Cómo mantenerlo

- Revisen el cronograma al cerrar cada milestone y ajusten las fechas que se movieron.
- Si un issue tarda bastante más que lo estimado, anotá la duración real en el issue al
  cerrarlo: sirve para corregir las estimaciones siguientes.
- La fecha de vencimiento de cada milestone en GitHub debería coincidir con la tabla de arriba.
