"""Aplicación Textual del debugger (docs/spec/interfaz_pc.md, decisiones 008 y 040).

Solo dibuja y traduce teclas a acciones de `Session`. Todo lo que toca el puerto corre en
un hilo de trabajo y vuelve a la app con `call_from_thread`; el cliente serializa el puerto
con su lock, así que durante RUN se puede mandar STOP, RESET o LOAD desde otro hilo.
"""

from __future__ import annotations

import threading
from collections.abc import Callable
from pathlib import Path

from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.widgets import Footer

from rvasm import AssemblerError

from ..client import DebugClient, HaltTimeout, InvalidProgramError, open_serial
from ..protocol import BAUD, DebugError, State
from ..session import (CONNECT, LOAD, REFRESH, REPROGRAM, RESET, RUN, STEP, STEP_N, STOP,
                       ProgramFileError, Session)
from .screens import (ConfirmScreen, ErrorsScreen, FileScreen, PortScreen, StepsScreen,
                      WatchdogScreen)
from .widgets import (FramesPanel, HeaderBar, MemoryPanel, Placeholder, ProgramPanel,
                      RegistersPanel, StatusBar)

# connector(nombre del puerto, on_frame) -> DebugClient. Los tests pasan uno con el
# puerto simulado.
Connector = Callable[[str, Callable[[str, bytes], None]], DebugClient]

# Acción de la app -> acción de Session (para habilitar los controles)
PORT_ACTIONS = {
    "connect": CONNECT, "load": LOAD, "run": RUN, "step": STEP, "step_n": STEP_N,
    "stop": STOP, "reset": RESET, "reprogram": REPROGRAM, "refresh": REFRESH,
}
# Lo que se puede hacer mientras corre RUN (interfaz_pc.md §5)
DURING_RUN = frozenset({STOP, RESET, LOAD, REPROGRAM})

I53 = "Llega con la I-53 (vista del pipeline)."


def serial_connector(baud: int = BAUD, halt_watchdog: float = 5.0) -> Connector:
    def connect(name: str, on_frame) -> DebugClient:
        return DebugClient(open_serial(name, baud), on_frame=on_frame,
                           halt_watchdog=halt_watchdog)
    return connect


class DebuggerApp(App):
    """Pantalla principal del debugger."""

    CSS_PATH = "debugger.tcss"
    TITLE = "RISC-V Debugger"

    BINDINGS = [
        Binding("f1", "connect", "Conectar"),
        Binding("f2", "load", "Cargar"),
        Binding("f5", "run", "Ejecutar"),
        Binding("f10", "step", "Paso"),
        Binding("shift+f10", "step_n", "Paso×N"),
        Binding("f6", "stop", "Detener"),
        Binding("f3", "reset", "Reiniciar"),
        Binding("f8", "reprogram", "Reprogramar"),
        Binding("f9", "refresh", "Refrescar"),
        Binding("d", "toggle_signed", "Con/sin signo", show=False),
        Binding("0", "toggle_zero", "Ocultar ceros", show=False),
        Binding("t", "toggle_frames", "Tramas", show=False),
        Binding("q", "quit", "Salir"),
    ]

    POLL_S = 0.5            # STATUS durante RUN (interfaz_pc.md §5)

    def __init__(self, connector: Connector | None = None, *, port: str | None = None,
                 prog: str | Path | None = None, baud: int = BAUD,
                 halt_watchdog: float = 5.0):
        super().__init__()
        self.connector = connector or serial_connector(baud, halt_watchdog)
        self.port_name = port
        self.baud = baud
        self.halt_watchdog = halt_watchdog
        self.session: Session | None = None
        self._pending_prog = Path(prog) if prog else None
        self._jobs = 0                  # trabajos con el puerto en curso
        self._run_loop = False          # hay un RUN esperando el final
        self._exiting = False
        self.signed = True
        self.hide_zero = False
        self._shown_program = None

    # ---- pantalla --------------------------------------------------------------------

    def compose(self) -> ComposeResult:
        yield HeaderBar(id="header")
        with Horizontal(id="main"):
            with Vertical(id="left"):
                with Horizontal(id="top"):
                    with Vertical(id="col-a"):
                        yield ProgramPanel(id="program", classes="panel")
                        yield MemoryPanel(id="memory", classes="panel")
                    with Vertical(id="col-b"):
                        yield Placeholder(I53, id="pipeline", classes="panel placeholder")
                        yield Placeholder(I53, id="latches", classes="panel placeholder")
                with Horizontal(id="bottom"):
                    yield Placeholder(I53, id="history", classes="panel placeholder")
                    yield FramesPanel(id="frames", classes="panel")
            yield RegistersPanel(id="registers", classes="panel")
        yield StatusBar(id="statusbar")
        yield Footer()

    def on_mount(self) -> None:
        self.query_one("#pipeline").border_title = "Pipeline"
        self.query_one("#latches").border_title = "Latches intermedios"
        self.query_one("#history").border_title = "Historial de pasos"
        self.query_one("#frames").display = False
        self._show()
        if self.port_name:
            self._connect(self.port_name)

    def _show(self) -> None:
        """Redibuja todo con el estado de la sesión."""
        s = self.session
        snapshot = s.snapshot if s else None
        status = s.status if s else None
        loaded = s.loaded if s else None
        self.query_one(HeaderBar).show(self.port_name if s else None, self.baud, loaded,
                                       status)
        if loaded is not self._shown_program:
            self.query_one(ProgramPanel).show(loaded)
            self._shown_program = loaded
        self.query_one(RegistersPanel).show(snapshot.regs if snapshot else None,
                                            signed=self.signed, hide_zero=self.hide_zero)
        self.query_one(MemoryPanel).show(snapshot, signed=self.signed)
        self.query_one(StatusBar).show(self.port_name, s.info if s else None, status)
        # En RUNNING las lecturas no se permiten: se ve el último volcado, atenuado (§5)
        stale = s is not None and s.state == State.RUNNING
        for panel in self.query(".panel"):
            panel.set_class(stale and panel.id != "frames", "stale")
        self.refresh_bindings()

    # ---- controles habilitados ---------------------------------------------------------

    def check_action(self, action: str, parameters: tuple[object, ...]) -> bool | None:
        if action not in PORT_ACTIONS:
            return True
        wanted = PORT_ACTIONS[action]
        if self._jobs and not (self._run_loop and wanted in DURING_RUN):
            return None
        if self.session is None:
            return True if wanted == CONNECT else None
        return True if self.session.enabled(wanted) else None

    # ---- trabajos con el puerto ----------------------------------------------------------

    def _job(self, fn: Callable, *args, done: Callable | None = None) -> None:
        """Corre `fn(*args)` en un hilo; al terminar redibuja y llama `done(resultado)`."""
        self._jobs += 1
        self.refresh_bindings()

        def body() -> None:
            try:
                result = fn(*args)
            except Exception as exc:        # noqa: BLE001 — se muestra al usuario
                self.call_from_thread(self._error, exc)
            else:
                if done is not None:
                    self.call_from_thread(done, result)
            finally:
                self.call_from_thread(self._job_finished)

        self.run_worker(body, thread=True, group="port", exit_on_error=False)

    def _job_finished(self) -> None:
        self._jobs -= 1
        self._show()

    def _error(self, exc: Exception) -> None:
        if isinstance(exc, AssemblerError):
            self.push_screen(ErrorsScreen("Errores de ensamblado (no se mandó nada)",
                                          [str(e) for e in exc.errors]))
        elif isinstance(exc, InvalidProgramError):
            self.push_screen(ErrorsScreen("Programa rechazado antes de LOAD", exc.problems))
        elif isinstance(exc, (DebugError, ProgramFileError, OSError)):
            self.notify(str(exc), title=type(exc).__name__, severity="error", timeout=8)
        else:
            self.notify(repr(exc), title="Error inesperado", severity="error", timeout=8)

    def _on_frame(self, direction: str, raw: bytes) -> None:
        """Lo llama el cliente desde el hilo de trabajo, con cada trama."""
        if not self._exiting:
            self.call_from_thread(self.query_one(FramesPanel).add, direction, raw)

    def _ask(self, screen) -> object:
        """Muestra un modal desde un hilo de trabajo y espera la respuesta."""
        answer: dict[str, object] = {}
        ready = threading.Event()

        def got(result) -> None:
            answer["r"] = result
            ready.set()

        self.call_from_thread(self.push_screen, screen, got)
        while not ready.wait(0.1):
            if self._exiting:
                return True
        return answer.get("r")

    def _confirm_if_running(self, action: str, then: Callable[[], None]) -> None:
        if self.session is not None and self.session.needs_confirm(action):
            self.push_screen(ConfirmScreen("El programa está corriendo: cargar lo detiene y "
                                           "limpia todo. ¿Seguir?"),
                             lambda ok: then() if ok else None)
        else:
            then()

    # ---- acciones ----------------------------------------------------------------------

    def action_connect(self) -> None:
        if self.session is not None:            # desconectar
            port = getattr(self.session.client, "port", None)
            if hasattr(port, "close"):
                port.close()
            self.session = None
            self._show()
            return
        if self.port_name:
            self._connect(self.port_name)
        else:
            self.push_screen(PortScreen(), self._connect)

    def _connect(self, name: str | None) -> None:
        if not name:
            return

        def body() -> Session:
            session = Session(self.connector(name, self._on_frame))
            session.connect()
            return session

        def done(session: Session) -> None:
            self.session = session
            self.port_name = name
            if self._pending_prog is not None:
                prog, self._pending_prog = self._pending_prog, None
                self._job(session.load_file, prog)

        self._job(body, done=done)

    def action_load(self) -> None:
        self._confirm_if_running(
            LOAD, lambda: self.push_screen(FileScreen(Path.cwd()), self._load_path))

    def _load_path(self, path: Path | None) -> None:
        if path is not None and self.session is not None:
            self._job(self.session.load_file, path)

    def action_reprogram(self) -> None:
        self._confirm_if_running(REPROGRAM, lambda: self._job(self.session.reprogram))

    def action_step(self) -> None:
        self._job(self.session.step)

    def action_step_n(self) -> None:
        self.push_screen(StepsScreen(),
                         lambda n: self._job(self.session.step_n, n) if n else None)

    def action_stop(self) -> None:
        if self._run_loop:
            self._job(self.session.client.stop)     # el RUN en curso hace el READ_ALL
        else:
            self._job(self.session.stop)

    def action_reset(self) -> None:
        self._job(self.session.reset)

    def action_refresh(self) -> None:
        self._job(self.session.refresh)

    def on_memory_panel_range_requested(self, event: MemoryPanel.RangeRequested) -> None:
        if self.session is None or not self.session.enabled(REFRESH):
            self.notify("Conectá la placa y detené el programa para leer memoria",
                        severity="warning")
            return
        self._job(self.session.read_range, event.addr, event.count)

    def action_toggle_signed(self) -> None:
        self.signed = not self.signed
        self._show()

    def action_toggle_zero(self) -> None:
        self.hide_zero = not self.hide_zero
        self._show()

    def action_toggle_frames(self) -> None:
        frames = self.query_one("#frames")
        frames.display = not frames.display

    async def action_quit(self) -> None:
        self._exiting = True
        self.exit()

    # ---- modo continuo (interfaz_pc.md §5) -------------------------------------------------

    def action_run(self) -> None:
        self._jobs += 1
        self._run_loop = True
        self.refresh_bindings()
        self.run_worker(self._run_body, thread=True, group="run", exit_on_error=False)

    def _run_body(self) -> None:
        s = self.session
        try:
            s.run()
            self.call_from_thread(self._show)
            waited = 0.0
            while not self._exiting:
                try:
                    s.wait_halted(self.POLL_S)
                    break                           # terminó: ya hizo el READ_ALL
                except HaltTimeout:
                    waited += self.POLL_S
                s.poll_status()                     # contador de ciclos en la barra
                self.call_from_thread(self._show)
                if waited >= self.halt_watchdog:
                    if self._ask(WatchdogScreen(self.halt_watchdog)):
                        s.client.stop()             # el próximo wait_halted vuelve
                    waited = 0.0
        except Exception as exc:                    # noqa: BLE001
            if not self._exiting:
                self.call_from_thread(self._error, exc)
        finally:
            if not self._exiting:
                self.call_from_thread(self._run_finished)

    def _run_finished(self) -> None:
        self._run_loop = False
        self._job_finished()
