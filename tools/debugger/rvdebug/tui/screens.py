"""Ventanas modales de la interfaz: elegir puerto y archivo, confirmar, Paso×N, errores
de ensamblado y el watchdog del modo continuo (docs/spec/interfaz_pc.md §3 y §5)."""

from __future__ import annotations

from collections.abc import Iterable
from pathlib import Path

from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.screen import ModalScreen
from textual.widgets import Button, DirectoryTree, Input, Label, OptionList, Static

from ..session import PROGRAM_SUFFIXES

FTDI_VID_PID = (0x0403, 0x6010)      # FT2232 de la Basys 3 (interfaz_pc.md §6)


def list_ports() -> list[tuple[str, str, bool]]:
    """(nombre, descripción, es el FTDI de la placa) de cada puerto serie. Vacío si no
    está pyserial."""
    try:
        from serial.tools import list_ports as lp
    except ImportError:
        return []
    out = []
    for port in sorted(lp.comports(), key=lambda p: p.device):
        ftdi = (port.vid, port.pid) == FTDI_VID_PID
        out.append((port.device, port.description or "", ftdi))
    return out


def proposed_port(ports: list[tuple[str, str, bool]]) -> str:
    """El FTDI de la placa; si tiene dos interfaces, la UART suele ser la segunda."""
    ftdi = [name for name, _, is_ftdi in ports if is_ftdi]
    if ftdi:
        return ftdi[-1]
    return ports[0][0] if ports else ""


class _Modal(ModalScreen):
    BINDINGS = [Binding("escape", "cancel", "Cancelar")]

    def action_cancel(self) -> None:
        self.dismiss(None)


class PortScreen(_Modal):
    """Elige el puerto serie (F1). Propone el de VID/PID de FTDI."""

    def compose(self) -> ComposeResult:
        self._ports = list_ports()
        with Vertical(classes="dialog"):
            yield Label("Puerto serie (Enter conecta)")
            yield Input(value=proposed_port(self._ports), id="port-input")
            if self._ports:
                yield OptionList(*[f"{name}  {desc}" + ("  [FTDI]" if ftdi else "")
                                   for name, desc, ftdi in self._ports], id="port-list")
            else:
                yield Label("No se encontraron puertos (¿pyserial instalado? ¿placa "
                            "conectada?)", classes="help")

    def on_option_list_option_selected(self, event: OptionList.OptionSelected) -> None:
        self.dismiss(self._ports[event.option_index][0])

    def on_input_submitted(self, event: Input.Submitted) -> None:
        self.dismiss(event.value.strip() or None)


class _ProgramTree(DirectoryTree):
    def filter_paths(self, paths: Iterable[Path]) -> Iterable[Path]:
        return [p for p in paths if not p.name.startswith(".")
                and (p.is_dir() or p.suffix.lower() in PROGRAM_SUFFIXES)]


class FileScreen(_Modal):
    """Elige el programa a cargar (F2): un `.s`, `.hex` o `.bin`."""

    def __init__(self, start: Path):
        super().__init__()
        self.start = start

    def compose(self) -> ComposeResult:
        with Vertical(classes="dialog wide"):
            yield Label("Programa (.s, .hex o .bin): elegí un archivo o escribí la ruta")
            yield Input(placeholder="ruta del archivo", id="file-input")
            yield _ProgramTree(self.start, id="file-tree")

    def on_directory_tree_file_selected(self, event: DirectoryTree.FileSelected) -> None:
        self.dismiss(Path(event.path))

    def on_input_submitted(self, event: Input.Submitted) -> None:
        text = event.value.strip()
        self.dismiss(Path(text).expanduser() if text else None)


class ConfirmScreen(_Modal):
    """Pregunta sí o no."""

    def __init__(self, question: str, yes: str = "Sí", no: str = "No"):
        super().__init__()
        self.question, self.yes, self.no = question, yes, no

    def compose(self) -> ComposeResult:
        with Vertical(classes="dialog"):
            yield Label(self.question)
            with Horizontal(classes="buttons"):
                yield Button(self.yes, id="yes", variant="warning")
                yield Button(self.no, id="no")

    def on_button_pressed(self, event: Button.Pressed) -> None:
        self.dismiss(event.button.id == "yes")

    def action_cancel(self) -> None:
        self.dismiss(False)


class WatchdogScreen(ConfirmScreen):
    """El programa no termina (interfaz_pc.md §5): True detiene, False sigue esperando."""

    def __init__(self, seconds: float):
        super().__init__(f"El programa no termina en {seconds:g} s (¿bucle sin HALT?)",
                         yes="Detener", no="Seguir esperando")


class StepsScreen(_Modal):
    """Cantidad de pasos para Paso×N (Shift+F10)."""

    def compose(self) -> ComposeResult:
        with Vertical(classes="dialog"):
            yield Label("Cantidad de pasos (ciclos)")
            yield Input(value="10", id="steps-input", type="integer")

    def on_input_submitted(self, event: Input.Submitted) -> None:
        try:
            n = int(event.value)
        except ValueError:
            n = 0
        if n < 1:
            self.app.notify("La cantidad tiene que ser al menos 1", severity="error")
            return
        self.dismiss(n)


class ErrorsScreen(_Modal):
    """Errores de ensamblado o palabras rechazadas, un renglón por problema."""

    def __init__(self, title: str, lines: list[str]):
        super().__init__()
        self.title_text, self.lines = title, lines

    def compose(self) -> ComposeResult:
        with Vertical(classes="dialog wide"):
            yield Label(self.title_text, classes="error-title")
            with VerticalScroll():
                yield Static("\n".join(self.lines), markup=False)
            yield Button("Cerrar", id="close")

    def on_button_pressed(self, event: Button.Pressed) -> None:
        self.dismiss(None)
