# docs/

Documentación del proyecto. Todo es Markdown más diagramas con su fuente editable
(`.drawio`) y una copia exportada (`.png` o `.svg`) para que se vea en GitHub.

## Índice

| Carpeta | Contenido | Cuándo leerla |
|---|---|---|
| `spec/` | Especificación previa al código: ISA, arquitectura del pipeline, protocolo de debug, mapa de memoria, plan de verificación | Antes de escribir o revisar un módulo |
| `decisiones/` | Una nota por decisión de diseño, con el porqué (plantilla: `decisiones/_plantilla.md`) | Cuando no se entiende por qué algo es como es |
| `diagramas/` | Diagramas del sistema, camino de datos, control y riesgos, protocolo, interfaz | Para tener la vista general |
| `timing/` | Reportes de Vivado, camino crítico, frecuencia elegida y métricas | En la etapa de integración |
| `tps/` | Informes y material de los trabajos prácticos (TP1, TP2, ...) | Como referencia histórica |

Al comienzo varias de estas carpetas están vacías (solo tienen un `.gitkeep`): se van
llenando a medida que avanzan los issues del milestone de especificación.

## Convenciones

- **Una decisión, una nota.** Numeradas (`001-...md`) y con el formato de la plantilla:
  contexto, opciones, decisión, consecuencias. Si una decisión cambia, se crea una nota
  nueva que reemplaza a la anterior en lugar de borrarla.
- **Fuente y exportado juntos.** Si agregás `datapath.drawio`, también va `datapath.png`
  (o `.svg`) con el mismo nombre.
- **Diagramas simples en Mermaid.** Máquinas de estados y secuencias pueden escribirse como
  bloques ```` ```mermaid ```` dentro del `.md`; GitHub los renderiza.
- **Referenciar, no duplicar.** Si algo ya está en un documento de `spec/`, los demás lo
  enlazan en lugar de copiarlo.
- **Cambios de interfaz.** Si un PR cambia una interfaz entre módulos o el protocolo de
  debug, actualiza el documento de `spec/` correspondiente en el mismo PR.
