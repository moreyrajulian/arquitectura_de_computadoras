"""Paneles de la pantalla principal (docs/spec/interfaz_pc.md §2). Solo dibujan lo que les
pasa la app; no tocan el puerto.

Colores de la vista del pipeline (interfaz_pc.md §2, decisión 043): amarillo lo que cambió
en el último paso, naranja lo retenido por un stall, gris las burbujas, azul el forwarding
y rojo el HALT. Todo lo de riesgos es inferido por la PC.
"""

from __future__ import annotations

from rich import box
from rich.console import Group
from rich.panel import Panel
from rich.table import Table
from rich.text import Text
from textual.app import ComposeResult
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.message import Message
from textual.widgets import (Button, DataTable, Input, Label, RichLog, Static, TabbedContent,
                             TabPane)

from isasim.pipeline import ALU_CODES
from rvasm import HALT_WORD, disassemble

from ..hazards import (BRANCH_NEXT, BUBBLE, DONE, EMPTY, FLUSH, FWD, HALT, INSTR, NOT_TAKEN,
                       STALL, STALL_NEXT, STOPPED, WARN, Analysis, StageView)
from ..model import (ABI, IMEM_WORDS, LATCHES, LAYOUT, TITLES, Diff, Snapshot, fmt_dec,
                     fmt_hex, reg_name)
from ..protocol import Cmd, Err, Info, State, Status, name_of
from ..session import (CONNECT, LOAD, REFRESH, REPROGRAM, RESET, RUN, RUN_TO, STEP, STEP_N,
                       STOP, Entry, LoadedProgram)

# Colores explícitos: el amarillo ANSI de muchas terminales sale naranja y se confunde con
# el de las etapas retenidas
CHANGED = "bold black on #ffe9a8"     # cambió en el último paso (amarillo)
RETAINED = "bold black on #ff9f43"    # retenido por un stall, inferido (naranja)
BUBBLE_STYLE = "grey50"               # burbuja (valid = 0)
FWD_STYLE = "bold dodger_blue1"       # forwarding (inferido)
HALT_STYLE = "bold white on red3"     # HALT en vuelo o programa terminado

# Etiqueta y estilo de cada evento inferido en el panel Pipeline
EVENT_BADGE = {
    STALL: ("STALL", RETAINED),
    FLUSH: ("FLUSH", "bold black on grey70"),
    FWD: ("FWD", "bold black on dodger_blue1"),
    STALL_NEXT: ("LOAD-USE", "bold dark_orange"),
    BRANCH_NEXT: ("SALTO", "bold"),
    NOT_TAKEN: ("NO TOMADO", "dim"),
    HALT: ("HALT", HALT_STYLE),
    WARN: ("INCONSISTENTE", HALT_STYLE),
    DONE: ("HALTED", "bold black on hot_pink"),
}

# Cómo se llegó a cada renglón del historial
ACTION_LABEL = {
    CONNECT: "conectar", LOAD: "LOAD", REPROGRAM: "reprogramar", RESET: "RESET",
    STEP: "paso", STEP_N: "paso xN", RUN_TO: "hasta cursor", RUN: "RUN", STOP: "STOP",
    REFRESH: "refrescar",
}


def changed_title(name: str, n: int) -> str:
    """«Registros (1 cambió)», como en el boceto."""
    if n == 0:
        return name
    return f"{name} ({n} cambió)" if n == 1 else f"{name} ({n} cambiaron)"


def short_pc(pc: int) -> str:
    """0x018 para las direcciones de imem (4 KiB), 8 dígitos para las demás."""
    return f"0x{pc:03X}" if pc < 0x1000 else f"0x{pc:08X}"

# Color de cada estado del core en el encabezado (interfaz_pc.md §2)
STATE_STYLE = {
    State.NO_PROG: "bold white on grey37",
    State.READY: "bold black on dodger_blue1",
    State.RUNNING: "bold black on green3",
    State.PAUSED: "bold black on dark_orange",
    State.HALTED: "bold black on hot_pink",
}


def state_badge(state: State | None) -> Text:
    if state is None:
        return Text(" DESCONECTADO ", style="bold white on grey30")
    return Text(f" {name_of(state, State)} ", style=STATE_STYLE.get(state, "bold"))


def access_warnings(status: Status | None) -> list[str]:
    """Avisos de acceso del bloque de estado (memoria.md §6.2)."""
    if status is None:
        return []
    names = (("imem_fault", status.imem_fault), ("dmem_oob", status.dmem_oob),
             ("dmem_misaligned", status.dmem_misaligned))
    return [name for name, on in names if on]


def fmt_time(cycles: int, clk_khz: int) -> str:
    """Tiempo equivalente de `cycles` ciclos a `clk_khz` (barra de estado)."""
    if clk_khz <= 0:
        return "?"
    ns = cycles * 1_000_000 / clk_khz
    for unit, scale in (("s", 1e9), ("ms", 1e6), ("µs", 1e3)):
        if ns >= scale:
            return f"{ns / scale:.3g} {unit}"
    return f"{ns:.3g} ns"


class HeaderBar(Static):
    """Puerto, baudrate, archivo cargado, estado del core y avisos de acceso."""

    def show(self, port: str | None, baud: int, loaded: LoadedProgram | None,
             status: Status | None, viewing: int | None = None) -> None:
        """`viewing`: el ciclo del renglón del historial que se está mirando, si hay uno."""
        text = Text(" RISC-V Debugger", style="bold")
        text.append(f" · {port} @ {baud}" if port else " · sin conectar")
        if loaded is not None:
            text.append(f" · prog: {loaded.path.name}")
        text.append("   ")
        text.append_text(state_badge(status.state if status else None))
        warnings = access_warnings(status)
        if warnings:
            text.append("  ")
            text.append(f" ⚠ {', '.join(warnings)} ", style="bold black on yellow")
        if viewing is not None:
            text.append("  ")
            text.append(f" HISTORIAL: ciclo {viewing} (solo lectura) · Esc vuelve ",
                        style="bold black on grey70")
        self.update(text)


class ProgramPanel(Vertical):
    """Lo que se mandó con LOAD: dirección, palabra, instrucción y la etapa en que está
    cada una (IF … WB, `*` si está retenida por un stall), y la fuente del `.s`. Enter o F4
    sobre una línea corre hasta que esa instrucción llegue a WB."""

    class RunToRequested(Message):
        def __init__(self, addr: int):
            super().__init__()
            self.addr = addr

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._rows = 0                 # palabras listadas (sin la fila del resto)
        self._labeled: set[int] = set()

    def compose(self) -> ComposeResult:
        with TabbedContent():
            with TabPane("Programa", id="tab-prog"):
                yield DataTable(id="prog-table", cursor_type="row", zebra_stripes=False)
            with TabPane("Fuente .s", id="tab-src"):
                with VerticalScroll():
                    yield Static("", id="prog-source")

    def on_mount(self) -> None:
        self.border_title = "Programa"
        self.query_one("#prog-table", DataTable).add_columns("Dir", "Palabra", "Instrucción",
                                                             "Etapa")
        self.show(None)

    def show(self, loaded: LoadedProgram | None) -> None:
        table = self.query_one("#prog-table", DataTable)
        table.clear()
        self._rows = 0
        self._labeled.clear()
        source = self.query_one("#prog-source", Static)
        if loaded is None:
            self.border_title = "Programa"
            source.update(Text("Sin programa: F2 carga un .s, .hex o .bin", style="dim"))
            return
        words = list(loaded.words)
        while len(words) > 1 and words[-1] == HALT_WORD and words[-2] == HALT_WORD:
            words.pop()                     # un .hex con --fill: el relleno no se lista
        self.border_title = f"Programa ({len(words)} palabras)"
        for i, word in enumerate(words):
            table.add_row(f"0x{4 * i:03X}", f"{word:08X}", disassemble_safe(word), "")
        table.add_row("", "", Text("(resto de imem: HALT)", style="dim"), "")
        self._rows = len(words)
        if loaded.source is None:
            source.update(Text(f"{loaded.path.name}: sin fuente (.hex/.bin)", style="dim"))
        else:
            lines = loaded.source.splitlines()
            width = len(str(len(lines)))
            body = Text()
            for n, line in enumerate(lines, 1):
                body.append(f"{n:>{width}} ", style="dim")
                body.append(line + "\n")
            source.update(body)

    def show_stages(self, analysis: Analysis | None, imem_words: int = IMEM_WORDS) -> None:
        """Las etiquetas de etapa junto a cada instrucción (interfaz_pc.md §4.2)."""
        table = self.query_one("#prog-table", DataTable)
        if self._rows == 0:
            return
        labels: dict[int, list[StageView]] = {}
        for view in analysis.stages if analysis else ():
            if view.pc is None or view.kind not in (INSTR, STOPPED):
                continue
            index = (view.pc >> 2) % imem_words
            labels.setdefault(min(index, self._rows), []).append(view)
        for row in self._labeled - set(labels):
            table.update_cell_at((row, 3), "")
        for row, views in labels.items():
            text = Text()
            for i, view in enumerate(views):
                if i:
                    text.append(",")
                name = view.stage + ("*" if view.retained else "")
                if row == self._rows:                       # después del programa: HALT
                    name += f"@{short_pc(view.pc)}"
                style = (RETAINED if view.retained else HALT_STYLE if view.halt
                         else "bold reverse")
                text.append(name, style=style)
            table.update_cell_at((row, 3), text)
        self._labeled = set(labels)

    def cursor_addr(self) -> int | None:
        """Dirección de la línea elegida, o None si es la fila del resto o no hay programa."""
        row = self.query_one("#prog-table", DataTable).cursor_row
        return 4 * row if 0 <= row < self._rows else None

    def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
        if event.data_table.id == "prog-table":
            event.stop()
            addr = self.cursor_addr()
            if addr is not None:
                self.post_message(self.RunToRequested(addr))


def disassemble_safe(word: int) -> str:
    try:
        return disassemble(word)
    except Exception:                       # palabras que el desensamblador no conoce
        return "?"


class RegistersPanel(Vertical):
    """Los 32 registros con nombre ABI, hex y decimal (con o sin signo)."""

    def compose(self) -> ComposeResult:
        yield DataTable(id="regs-table", cursor_type="none", zebra_stripes=False)
        yield Label("[d] con/sin signo  [0] ocultar ceros", classes="help",
                    markup=False)

    def on_mount(self) -> None:
        self.border_title = "Registros"
        self.query_one(DataTable).add_columns("Reg", "Hex", "Dec")
        self.show(None, signed=True, hide_zero=False)

    def show(self, regs: tuple[int, ...] | None, *, signed: bool, hide_zero: bool,
             changed: frozenset[int] = frozenset()) -> None:
        table = self.query_one(DataTable)
        table.clear()
        self.border_title = changed_title("Registros", len(changed))
        self.border_subtitle = "con signo" if signed else "sin signo"
        if regs is None:
            return
        for n, value in enumerate(regs):
            if hide_zero and value == 0 and n not in changed:
                continue
            style = CHANGED if n in changed else "dim" if value == 0 else ""
            table.add_row(Text(reg_name(n), style=style), Text(fmt_hex(value), style=style),
                          Text(fmt_dec(value, signed), style=style, justify="right"))


class MemoryPanel(Vertical):
    """Memoria de datos: «Usada» (READ_DMEM_USED, dentro de READ_ALL) y «Rango» (READ_DMEM)."""

    class RangeRequested(Message):
        def __init__(self, addr: int, count: int):
            super().__init__()
            self.addr = addr
            self.count = count

    def compose(self) -> ComposeResult:
        with TabbedContent():
            with TabPane("Usada", id="tab-used"):
                yield DataTable(id="used-table", cursor_type="none")
            with TabPane("Rango", id="tab-range"):
                with Horizontal(id="range-form"):
                    yield Input(placeholder="dirección (0x0)", id="range-addr")
                    yield Input(placeholder="palabras", id="range-count")
                    yield Button("Leer", id="range-read", compact=True)
                yield DataTable(id="range-table", cursor_type="none")

    def on_mount(self) -> None:
        self.border_title = "Memoria de datos"
        self.query_one("#used-table", DataTable).add_columns("Dirección", "Hex", "Dec",
                                                             "Escrito")
        self.query_one("#range-table", DataTable).add_columns("Dirección", "Hex", "Dec")

    def show(self, snapshot: Snapshot | None, *, signed: bool,
             changed: frozenset[int] = frozenset(),
             written: dict[int, tuple[int, bool]] | None = None) -> None:
        """`changed`: direcciones que cambiaron en el último paso. `written`: dirección ->
        (ciclo del volcado en que se vio el cambio, si fue un paso de un ciclo); con Paso×N
        o RUN el cambio pudo ser antes, y se muestra `<= N`."""
        used = self.query_one("#used-table", DataTable)
        used.clear()
        rng = self.query_one("#range-table", DataTable)
        rng.clear()
        self.border_title = changed_title("Memoria de datos", len(changed))
        if snapshot is None:
            return
        for addr, value in snapshot.used:
            style = CHANGED if addr in changed else ""
            seen = (written or {}).get(addr)
            when = "" if seen is None or seen[0] > snapshot.status.cycles else (
                f"ciclo {seen[0]}" if seen[1] else f"<= {seen[0]}")
            used.add_row(Text(fmt_hex(addr), style=style), Text(fmt_hex(value), style=style),
                         Text(fmt_dec(value, signed), style=style), Text(when, style=style))
        self.query_one("#tab-used", TabPane).label = f"Usada ({len(snapshot.used)})"
        if snapshot.range is not None:
            for i, value in enumerate(snapshot.range.words):
                rng.add_row(fmt_hex(snapshot.range.addr + 4 * i), fmt_hex(value),
                            fmt_dec(value, signed))

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "range-read":
            self._request()

    def on_input_submitted(self, event: Input.Submitted) -> None:
        self._request()

    def _request(self) -> None:
        addr_text = self.query_one("#range-addr", Input).value.strip() or "0"
        count_text = self.query_one("#range-count", Input).value.strip() or "16"
        try:
            addr = int(addr_text, 0)
            count = int(count_text, 0)
        except ValueError:
            self.app.notify("Dirección y cantidad: números (0x… para hex)", severity="error")
            return
        self.post_message(self.RangeRequested(addr, count))


class FramesPanel(Vertical):
    """Últimas tramas enviadas y recibidas, en hex (oculto por defecto, tecla t)."""

    def compose(self) -> ComposeResult:
        yield RichLog(id="frames-log", max_lines=200, wrap=False, markup=False)

    def on_mount(self) -> None:
        self.border_title = "Tramas"

    def add(self, direction: str, raw: bytes) -> None:
        line = Text("→ " if direction == "tx" else "← ",
                    style="green" if direction == "tx" else "cyan")
        shown = " ".join(f"{b:02X}" for b in raw[:8]) + (" …" if len(raw) > 8 else "")
        line.append(f"{shown:<27} ")
        cmd = name_of(raw[1], Cmd) if len(raw) > 1 else "?"
        if direction == "tx":
            line.append(cmd)
        else:
            status = name_of(raw[2], Err) if len(raw) > 2 else "?"
            line.append(f"{cmd} {status} ({len(raw)} B)")
        self.query_one(RichLog).write(line)


class PipelinePanel(Vertical):
    """Cinco cajas IF → WB con el PC y la instrucción de cada etapa, y debajo los riesgos
    inferidos (interfaz_pc.md §2 y §4.3)."""

    BOX = 11                          # ancho de cada caja (9 de texto y el borde)

    def compose(self) -> ComposeResult:
        yield Static("", id="pipe-boxes")
        yield Static("", id="pipe-events")

    def on_mount(self) -> None:
        self.show(None, None)

    def show(self, snapshot: Snapshot | None, analysis: Analysis | None) -> None:
        boxes = self.query_one("#pipe-boxes", Static)
        events = self.query_one("#pipe-events", Static)
        if snapshot is None or analysis is None:
            self.border_title = "Pipeline"
            boxes.update(Text("Sin volcado: conectá la placa (F1) y cargá un programa (F2)",
                              style="dim"))
            events.update("")
            return
        self.border_title = (f"Pipeline — ciclo {snapshot.status.cycles} · PC "
                             f"{fmt_hex(snapshot.status.pc)}")
        grid = Table.grid(padding=0)
        for i in range(len(analysis.stages)):
            if i:
                grid.add_column(width=2)
            grid.add_column(width=self.BOX)
        heads, cells, notes = [], [], []
        for i, view in enumerate(analysis.stages):
            if i:
                heads.append("")
                cells.append(Text("\n->"))
                notes.append("")
            heads.append(Text(view.stage, justify="center", style="bold"))
            cells.append(self._box(view))
            notes.append(Text(view.note, style=RETAINED if view.retained else "dim"))
        grid.add_row(*heads)
        grid.add_row(*cells)
        grid.add_row(*notes)
        boxes.update(grid)
        lines = []
        for event in analysis.events:
            label, style = EVENT_BADGE[event.kind]
            line = Text()
            line.append(f" {label} ", style=style)
            line.append(" ")
            line.append(event.text, style=FWD_STYLE if event.kind == FWD else "")
            lines.append(line)
        lines.append(Text("Riesgos inferidos por la PC a partir de los latches (la FPGA no "
                          "los informa).", style="dim"))
        events.update(Group(*lines))

    def _box(self, view: StageView) -> Panel:
        if view.kind == EMPTY:
            return Panel(Text(""), width=self.BOX, height=5, box=box.ROUNDED,
                         border_style="grey37", padding=0)
        if view.kind == BUBBLE:
            body = Text("-\nburbuja", style=BUBBLE_STYLE)
            border = BUBBLE_STYLE
        else:
            body = Text(short_pc(view.pc) if view.pc is not None else "?")
            body.append("\n" + view.text)
            border = ("red3" if view.halt else "#ff9f43" if view.retained
                      else BUBBLE_STYLE if view.kind == STOPPED else "")
            if view.kind == STOPPED:
                body.stylize(BUBBLE_STYLE)
        return Panel(body, width=self.BOX, height=5, box=box.ROUNDED, border_style=border,
                     padding=0)


class LatchesPanel(VerticalScroll):
    """Los cuatro latches campo por campo, con los nombres de pipeline.md §8, o sus
    palabras de 32 bits crudas (tecla c). Lo que cambió en el último paso, en amarillo."""

    def compose(self) -> ComposeResult:
        yield Static("", id="latches-body")

    def on_mount(self) -> None:
        self.border_subtitle = r"\[c] campos / hex crudo"
        self.show(None, Diff(), None, raw=False)

    def show(self, snapshot: Snapshot | None, diff: Diff, analysis: Analysis | None, *,
             raw: bool) -> None:
        body = self.query_one("#latches-body", Static)
        self.border_title = changed_title("Latches intermedios", len(diff.latches))
        if snapshot is None:
            body.update(Text("Sin volcado", style="dim"))
            return
        fields = snapshot.fields
        retained = {v.stage for v in analysis.stages if v.retained} if analysis else set()
        blocks = []
        for latch in LATCHES:
            words = snapshot.latches.words(latch)
            if raw or fields is None:
                blocks.append(self._raw(latch, words))
            else:
                blocks.append(self._fields(latch, fields[latch], diff,
                                           "ID" in retained and latch == "if_id"))
        left = Text("\n\n").join([blocks[0], blocks[1]])
        right = Text("\n\n").join([blocks[2], blocks[3]])
        grid = Table.grid(padding=(0, 3))
        grid.add_row(left, right)
        if fields is None:
            body.update(Group(Text("Los latches tienen otro formato que pipeline.md §8: solo "
                                   "las palabras crudas", style=HALT_STYLE), grid))
        else:
            body.update(grid)

    @staticmethod
    def _raw(latch: str, words: tuple[int, ...]) -> Text:
        text = Text()
        text.append(TITLES[latch], style="bold")
        for i, word in enumerate(words):
            text.append(f"\nw{i} 0x{word:08X}")
        return text

    @staticmethod
    def _fields(latch: str, values: dict[str, int], diff: Diff, retained: bool) -> Text:
        valid = values["valid"]
        title = TITLES[latch] + (" *" if retained else "") + ("" if valid else " — burbuja")
        text = Text()             # el estilo va en cada parte: el de Text() se hereda
        text.append(title, style=RETAINED if retained else "bold" if valid else BUBBLE_STYLE)
        for name, width, _ in LAYOUT[latch]:
            value = values[name]
            if width == 32:
                shown = fmt_hex(value)
            elif name in ("rd", "rs1", "rs2"):
                shown = f"x{value} ({ABI[value]})"
            elif name == "funct3":
                shown = f"{value:03b}"
            elif name == "alu_ctrl":
                shown = f"{value:04b} {ALU_CODES.get(value, '?')}"
            else:
                shown = str(value)
            style = (CHANGED if (latch, name) in diff.latches
                     else "" if valid else BUBBLE_STYLE)
            text.append(f"\n{name:<10} {shown:>12}", style=style)
            if latch == "if_id" and name == "instr" and valid:
                text.append(f"\n  {disassemble_safe(value).split('  #')[0]}", style="dim")
        return text


class HistoryPanel(Vertical):
    """Un renglón por volcado, el más nuevo arriba: ciclo, PC, acción, eventos inferidos y
    qué cambió. Enter muestra ese volcado (solo lectura: la placa no vuelve atrás)."""

    ROWS = 500                        # los más nuevos; el historial guarda más

    class Selected(Message):
        def __init__(self, index: int):
            super().__init__()
            self.index = index

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._shown: tuple | None = None
        self._count = 0

    def compose(self) -> ComposeResult:
        yield DataTable(id="history-table", cursor_type="row", zebra_stripes=False)

    def on_mount(self) -> None:
        self.border_title = "Historial de pasos (guardado en la PC)"
        self.query_one(DataTable).add_columns("", "Ciclo", "PC", "Acción", "Eventos inferidos",
                                              "Cambios")

    def show(self, history: list[Entry], viewing: int | None) -> None:
        key = (len(history), id(history[-1]) if history else None, viewing)
        if key == self._shown:
            return
        self._shown = key
        self._count = len(history)
        table = self.query_one(DataTable)
        table.clear()
        current = len(history) - 1 if viewing is None else viewing
        first = max(0, len(history) - self.ROWS)
        for index in range(len(history) - 1, first - 1, -1):
            entry = history[index]
            snap = entry.snapshot
            style = "bold" if index == current else ""
            table.add_row(Text(">" if index == current else " ", style=style),
                          Text(str(snap.status.cycles), style=style),
                          Text(short_pc(snap.status.pc), style=style),
                          Text(ACTION_LABEL.get(entry.action, entry.action), style="dim"),
                          Text(entry.analysis.short),
                          Text(entry.diff.summary(snap)))
        if viewing is not None and len(history) - 1 - viewing < table.row_count:
            table.move_cursor(row=len(history) - 1 - viewing)

    def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
        event.stop()
        index = self._count - 1 - event.cursor_row
        if 0 <= index < self._count:
            self.post_message(self.Selected(index))


class StatusBar(Static):
    """Conexión, INFO, el bloque de estado y cuántas cosas cambiaron en el último paso."""

    def show(self, port: str | None, info: Info | None, status: Status | None,
             counts: tuple[int, int, int] | None = None) -> None:
        if info is None:
            self.update(Text(" ○ Sin conectar · F1 conecta", style="dim"))
            return
        text = Text(f" ● Conectado {port} · proto v{info.proto_version} · imem "
                    f"{info.imem_words} / dmem {info.dmem_words} pal. · "
                    f"{info.clk_khz / 1000:g} MHz")
        if status is not None:
            text.append(f" │ PC {fmt_hex(status.pc)} │ ciclo "
                        f"{status.cycles} ({fmt_time(status.cycles, info.clk_khz)}) │ mem. "
                        f"usada {status.dmem_used}")
        if counts is not None:
            regs, latches, mem = counts
            text.append(f" │ último paso: {regs} reg, {latches} latches, {mem} mem")
        self.update(text)
