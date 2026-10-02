# 013 - Tamaño y mapa de direcciones de las memorias

- **Estado:** propuesta
- **Fecha:** 2026-10-02
- **Autores:** Costamagna, Matías

## Contexto
Hay que fijar cuántas palabras tiene la memoria de programa y la de datos y en qué direcciones
las ve el core. Varios documentos ya asumían "1 K palabras" como ejemplo (decisiones 003, 004 y
005) y dejaban el número abierto para esta issue, igual que el valor de reset del PC
(`pipeline.md` §3.1).

Restricciones:
- Las dos memorias son BRAM de doble puerto de 32 bits: el puerto A para el core y el B para la
  Debug Unit (decisiones 009 y [014](014_bram-y-escritura-de-programa.md)). En el Artix-7, un RAMB18
  en *True Dual Port* tiene como máximo 18 bits por puerto, así que la unidad mínima para 32 bits
  es un RAMB36 configurado como 1K × 36. El `xc7a35t` tiene 50.
- El protocolo informa los tamaños en 2 bytes (`INFO`) y el payload de `LOAD` tiene como máximo
  65 535 bytes: no se pueden cargar más de 16 383 palabras.
- Los programas de prueba se escriben a mano en ensamblador y tienen decenas de instrucciones.
- Cargar el programa entero por la UART tarda 4 bytes por palabra a 115200 baud (~87 µs por byte).
- La decodificación de direcciones no debe sumar lógica en IF ni en MEM (camino crítico).

## Opciones consideradas

### Tamaño
1. **256 palabras (1 KiB) cada una.**
   - Ventajas: sobra para los programas de prueba.
   - Desventajas: ocupa el mismo RAMB36 que 1024 palabras (el ancho de 32 bits en TDP ya lo exige),
     así que no ahorra nada y achica el margen para el programa de demo.
2. **1024 palabras (4 KiB) cada una.**
   - Ventajas: es el máximo que entra en un solo RAMB36 de 32 bits. Un programa lleno se carga en
     0,36 s; limpiar cada memoria tarda 1024 ciclos (~10 µs). El mapa de usadas es de 1 Kbit.
   - Desventajas: ninguna relevante para el uso previsto.
3. **4096 palabras o más.**
   - Ventajas: margen para programas grandes.
   - Desventajas: 4 RAMB36 por memoria, carga de 1,4 s si se llena, mapa de usadas 4 veces más
     grande. Ningún programa de prueba lo necesita.

### Mapa de direcciones
1. **A — Harvard, dos espacios que empiezan en `0`.** El PC direcciona la memoria de programa y
   los loads/stores la de datos, cada una desde `0x0000_0000`.
   - Ventajas: decodificar es elegir bits (`addr[11:2]`); el PC arranca en 0; con base `x0` se
     alcanzan los datos de `0x000` a `0x7FF` en una instrucción (`lw x5, 16(x0)`), lo que simplifica
     los programas de prueba.
   - Desventajas: una dirección numérica no dice por sí sola a qué memoria pertenece (no importa,
     porque el core no tiene forma de leer instrucciones como datos ni de ejecutar datos).
2. **B — Mapa unificado con los datos en una base alta** (por ejemplo `0x1000_0000`, como el
   segmento de datos por defecto de los simuladores de RISC-V).
   - Ventajas: cada dirección es única; parecido a un sistema real.
   - Desventajas: todos los programas necesitan `lui` para armar la base; hay que comparar bits
     altos para validar direcciones; el core sigue sin poder acceder a la otra memoria, así que la
     unicidad no aporta nada.
3. **C — Mapa unificado compacto** (código en `0x0000`, datos en `0x2000`).
   - Ventajas: coincide con la configuración "compacta" de algunos simuladores.
   - Desventajas: las mismas que B, con menos espacio para crecer.

## Decisión
**1024 palabras (4 KiB) por memoria y mapa Harvard con los dos espacios desde `0x0000_0000`
(opción 2 y A).** El PC arranca en `0x0000_0000`.

1024 palabras es el tamaño más grande que entra en un RAMB36 con puertos de 32 bits: más chico no
ahorra BRAM y más grande no lo necesita ningún programa. Con los dos espacios en 0 y tamaños
potencia de dos no hay lógica de decodificación, y los programas de prueba acceden a los datos con
base `x0`. Los tamaños quedan como parámetros (`IMEM_AW = 10`, `DMEM_AW = 10`) y `INFO` los informa,
así que crecer después es regenerar el IP y cambiar un parámetro.

## Consecuencias
- `docs/spec/memoria.md` §1 y §2 fijan los rangos; `pipeline.md` §3.1 deja de tener el PC de reset
  "a confirmar".
- `INFO` responde `imem_words = 1024` y `dmem_words = 1024`; `LOAD` acepta `1 ≤ N ≤ 1024`.
- 2 de 50 RAMB36 (4 %).
- **Ensamblador (I-10):** genera código desde 0 y rechaza programas de más de 1024 palabras. No hay
  sección `.data` inicializada, porque `LOAD` pone la memoria de datos en cero (decisión 004): los
  datos se arman con stores.
- **Programas de prueba (I-15):** datos desde `0x000`; para `0x800`–`0xFFF` hace falta registro base
  (el inmediato es de 12 bits con signo); si usan pila, `lui sp, 1` (`sp = 0x1000`) y crece hacia
  abajo.
- Lo que pasa con las direcciones fuera de `0x000`–`0xFFF` lo decide la nota
  [015](015_accesos-desalineados-y-fuera-de-rango.md).
- Si el programa de demo (I-58) no entrara, se pasa a 2048 palabras (2 RAMB36) sin cambiar el
  protocolo ni el cliente.
