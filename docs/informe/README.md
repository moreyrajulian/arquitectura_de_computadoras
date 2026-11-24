# docs/informe/

Informe final del trabajo (I-60). **El PDF para leer es [`informe_final.pdf`](informe_final.pdf).**
Está escrito en LaTeX con la plantilla de informes de la FCEFyN
(`informe-fcefyn.sty`). Resume y enlaza el resto de `docs/`: no copia las figuras, las toma
de `../diagramas/`, `../capturas/` y `../timing/`.

| Archivo | Contenido |
|---|---|
| `main.tex` | Carátula, preámbulo y orden de las secciones |
| `secciones/NN_*.tex` | Una sección por archivo: introducción, sistema, ISA, pipeline, riesgos, memorias, Debug Unit, interfaz, verificación, timing, preguntas de la consigna, uso y conclusiones |
| `secciones/a_decisiones.tex` | Anexo: la lista de decisiones de `docs/decisiones/` |
| `img/` | Logos de la carátula |
| `informe_final.pdf` | El informe compilado, para leerlo sin instalar LaTeX |
| `presentacion.pdf` | La presentación del trabajo, exportada desde las diapositivas |

## Compilar

Desde la raíz del repo (con `-cd`, `-outdir` es relativo a `docs/informe/`), con una distribución de LaTeX que tenga `latexmk` (TeX Live, MiKTeX o
TinyTeX). La salida va a `build/informe/`, que no se versiona; para actualizar el PDF del repo
se copia encima de `informe_final.pdf`:

```sh
latexmk -pdf -cd -outdir=../../build/informe docs/informe/main.tex
cp build/informe/main.pdf docs/informe/informe_final.pdf
```

Cada versión del PDF pesa unos 4 MB en la historia de git: se actualiza solo cuando cambia el
contenido (no por cada corrección chica) y siempre junto con los `.tex` que lo generan.

**En Overleaf (opcional):** *New Project > Upload Project* con un zip de `informe/`, `diagramas/`,
`capturas/` y `timing/` (desde `docs/`: `zip -r informe.zip informe diagramas capturas timing`),
porque las figuras están en las carpetas hermanas. Después, en *Menu > Main document*, elegir
`informe/main.tex`. `main.tex` busca sus archivos y las figuras desde las dos raíces posibles
(`docs/informe/` y `docs/`).

## Versión de entrega

`main.tex` tiene la fecha de entrega fija (27 de noviembre de 2026) y `\entregafinal` activo: si
alguna marca `\completar{...}` quedara sin resolver (sale en rojo en el PDF), el log avisa
cuántas. En la versión entregada no queda ninguna.

Si cambia un número del diseño (frecuencia, slack, recursos, resultados de la regresión o de
la placa), cambia en `docs/timing/` o `docs/spec/` y acá en el mismo cambio.
