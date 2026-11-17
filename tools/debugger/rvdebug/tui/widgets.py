"""Paneles de la pantalla principal (docs/spec/interfaz_pc.md §2). Solo dibujan lo que les
pasa la app; no tocan el puerto."""

from __future__ import annotations

from rich.text import Text
from textual.app import ComposeResult
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.message import Message
from textual.widgets import (Button, DataTable, Input, Label, RichLog, Static, TabbedContent,
                             TabPane)

from rvasm import HALT_WORD, disassemble

from ..model import Snapshot, fmt_dec, fmt_hex, reg_name
from ..protocol import Cmd, Err, Info, State, Status, name_of
from ..session import LoadedProgram

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
             status: Status | None) -> None:
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
        self.update(text)


class ProgramPanel(Vertical):
    """Lo que se mandó con LOAD: dirección, palabra e instrucción, y la fuente del `.s`.
    Las etiquetas de etapa (IF … WB) llegan con la I-53."""

    def compose(self) -> ComposeResult:
        with TabbedContent():
            with TabPane("Programa", id="tab-prog"):
                yield DataTable(id="prog-table", cursor_type="row", zebra_stripes=False)
            with TabPane("Fuente .s", id="tab-src"):
                with VerticalScroll():
                    yield Static("", id="prog-source")

    def on_mount(self) -> None:
        self.border_title = "Programa"
        self.query_one("#prog-table", DataTable).add_columns("Dir", "Palabra", "Instrucción")
        self.show(None)

    def show(self, loaded: LoadedProgram | None) -> None:
        table = self.query_one("#prog-table", DataTable)
        table.clear()
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
            table.add_row(f"0x{4 * i:03X}", f"{word:08X}", disassemble_safe(word))
        table.add_row("", "", Text("(resto de imem: HALT)", style="dim"))
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

    def show(self, regs: tuple[int, ...] | None, *, signed: bool, hide_zero: bool) -> None:
        table = self.query_one(DataTable)
        table.clear()
        self.border_subtitle = "con signo" if signed else "sin signo"
        if regs is None:
            return
        for n, value in enumerate(regs):
            if hide_zero and value == 0:
                continue
            style = "dim" if value == 0 else ""
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
        self.query_one("#used-table", DataTable).add_columns("Dirección", "Hex", "Dec")
        self.query_one("#range-table", DataTable).add_columns("Dirección", "Hex", "Dec")

    def show(self, snapshot: Snapshot | None, *, signed: bool) -> None:
        used = self.query_one("#used-table", DataTable)
        used.clear()
        rng = self.query_one("#range-table", DataTable)
        rng.clear()
        if snapshot is None:
            return
        for addr, value in snapshot.used:
            used.add_row(fmt_hex(addr), fmt_hex(value), fmt_dec(value, signed))
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


class Placeholder(Static):
    """Panel que completa otra issue (el boceto lo reserva)."""


class StatusBar(Static):
    """Conexión, INFO y el bloque de estado."""

    def show(self, port: str | None, info: Info | None, status: Status | None) -> None:
        if info is None:
            self.update(Text(" ○ Sin conectar · F1 conecta", style="dim"))
            return
        text = Text(f" ● Conectado {port} · proto v{info.proto_version} · imem "
                    f"{info.imem_words} / dmem {info.dmem_words} pal. · "
                    f"{info.clk_khz / 1000:g} MHz")
        if status is not None:
            text.append(f" │ {name_of(status.state, State)} │ PC {fmt_hex(status.pc)} │ ciclo "
                        f"{status.cycles} ({fmt_time(status.cycles, info.clk_khz)}) │ mem. "
                        f"usada {status.dmem_used}")
        self.update(text)
