# 006 - Cómo se determina la "memoria de datos usada"

- **Estado:** propuesta
- **Fecha:** 2026-09-29
- **Autores:** Costamagna, Matías

## Contexto
La consigna pide enviar a la PC "el contenido de la memoria de datos usada". La memoria de datos
es una BRAM, así que no hay forma directa de saber qué palabras escribió el programa. Enviar
toda la memoria sería lento (a 115200, 1 KB son ~90 ms) y llena la interfaz de ceros.

## Opciones consideradas
1. **Enviar toda la memoria.** Sin lógica extra, pero desperdicia ancho de banda y no distingue
   un cero escrito de una posición sin tocar.
2. **Enviar un rango pedido por la PC** (`READ_DMEM addr, count`). Simple, pero la PC no sabe qué
   rango mirar.
3. **Un bit por palabra que se marca cuando el core escribe** (`sb`/`sh`/`sw`), más un contador
   `dmem_used`. Exacto; cuesta una memoria de 1 bit por palabra y un contador.
4. **Solo el rango entre la dirección mínima y la máxima escritas.** Más barato, pero manda
   ceros intermedios.

## Decisión
Se ofrecen dos comandos: `READ_DMEM` (opción 2, para inspección manual) y `READ_DMEM_USED`
(opción 3). La Debug Unit observa `dmem_we`/`dmem_addr` del core y mantiene el mapa de palabras
escritas y `dmem_used`, que también viaja en el bloque de estado. `READ_DMEM_USED` responde
pares (`addr`, `valor`) en orden creciente. `LOAD` y `RESET` ponen el mapa en cero.

## Consecuencias
- Un `sb`/`sh` marca la palabra completa que contiene el byte.
- Una palabra escrita con valor cero aparece igual, que es lo que se quiere mostrar.
- El mapa de 1 bit por palabra ocupa poco: 1 K palabras son 1 Kbit (distribuido en LUTRAM o una
  BRAM pequeña; a definir en `memoria.md`).
- `READ_ALL` se puede partir sin ambigüedad porque `dmem_used` viene en el bloque de estado.
- Si la memoria de datos creciera mucho, el volcado de `READ_DMEM_USED` puede tardar en
  el paso a paso; habría que agregar paginación.