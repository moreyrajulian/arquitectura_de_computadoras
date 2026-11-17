"""Tests de la interfaz de texto (decisión 040) con `App.run_test()` y Pilot, sobre la
Debug Unit simulada: los controles de interfaz_pc.md §3, la tabla de registros y los
controles deshabilitados. Se saltean si no está textual."""

import asyncio
from pathlib import Path

import pytest

pytest.importorskip("textual")

from textual.widgets import DataTable  # noqa: E402

from fake_debug_unit import FakeClock, FakeDebugUnit, FakeSerial, RealClock  # noqa: E402
from rvdebug import DebugClient  # noqa: E402
from rvdebug.protocol import Cmd, State  # noqa: E402
from rvdebug.tui import DebuggerApp  # noqa: E402
from rvdebug.tui.screens import ConfirmScreen, ErrorsScreen  # noqa: E402

REPO = Path(__file__).resolve().parents[3]
SIZE = (160, 45)                     # tamaño mínimo de la terminal (interfaz_pc.md §2)


class Bench:
    """La app con un conector al puerto simulado."""

    def __init__(self, prog=None, port="SIM", halt_watchdog=1.0, clock=None):
        self.device = FakeDebugUnit()
        self.clock = clock or FakeClock()
        self.frames = []
        self.app = DebuggerApp(self.connect, port=port, prog=prog, halt_watchdog=halt_watchdog)

    def connect(self, name, on_frame):
        def trace(direction, raw):
            self.frames.append(direction)
            on_frame(direction, raw)
        return DebugClient(FakeSerial(self.device, self.clock), clock=self.clock,
                           sleep=self.clock.sleep, on_frame=trace)

    def cmds(self):
        return [cmd for cmd, _ in self.device.requests]


async def settle(pilot):
    """Espera a que terminen los hilos con el puerto y se redibuje."""
    for _ in range(4):
        await pilot.pause()
        await pilot.app.workers.wait_for_complete()
    await pilot.pause()


def run(coro):
    asyncio.run(coro)


def regs_table(app):
    table = app.query_one("#regs-table", DataTable)
    return [[str(cell) for cell in table.get_row_at(i)] for i in range(table.row_count)]


def footer_enabled(app, action):
    return app.check_action(action, ()) is True


def write(tmp_path, text):
    path = tmp_path / "p.s"
    path.write_text(text, encoding="utf-8")
    return path


def test_conecta_y_carga_con_argumentos():
    async def body():
        bench = Bench(prog=REPO / "sw" / "alu_r.s")
        async with bench.app.run_test(size=SIZE) as pilot:
            await settle(pilot)
            s = bench.app.session
            assert s is not None and s.state == State.READY
            assert bench.cmds()[:4] == [Cmd.INFO, Cmd.STATUS, Cmd.READ_ALL, Cmd.LOAD]
            prog = bench.app.query_one("#prog-table", DataTable)
            assert str(prog.get_row_at(0)[0]) == "0x000"
            assert "tx" in bench.frames and "rx" in bench.frames
    run(body())


def test_f1_conecta_y_desconecta():
    async def body():
        bench = Bench(port=None)
        async with bench.app.run_test(size=SIZE) as pilot:
            await settle(pilot)
            assert bench.app.session is None
            bench.app.port_name = "SIM"     # sin abrir el selector de puertos
            assert not footer_enabled(bench.app, "step")
            await pilot.press("f1")
            await settle(pilot)
            assert bench.app.session is not None
            assert bench.app.session.state == State.NO_PROG
            await pilot.press("f1")
            await settle(pilot)
            assert bench.app.session is None
    run(body())


def test_registros_con_nombres_abi_y_decimal(tmp_path):
    async def body():
        bench = Bench(prog=write(tmp_path, "addi x1, x0, 5\nhalt\n"))
        async with bench.app.run_test(size=SIZE) as pilot:
            await settle(pilot)
            bench.device.regs[1] = 5
            bench.device.regs[5] = 0xFFFF_FFFF
            await pilot.press("f10")             # STEP + READ_ALL
            await settle(pilot)
            assert bench.cmds()[-2:] == [Cmd.STEP, Cmd.READ_ALL]
            rows = regs_table(bench.app)
            assert rows[1] == ["x1/ra", "0x00000005", "5"]
            assert rows[5] == ["x5/t0", "0xFFFFFFFF", "-1"]
            assert rows[31][0] == "x31/t6"
            await pilot.press("d")               # sin signo
            await settle(pilot)
            assert regs_table(bench.app)[5][2] == "4294967295"
            await pilot.press("0")               # oculta los que valen 0
            await settle(pilot)
            assert [r[0] for r in regs_table(bench.app)] == ["x1/ra", "x5/t0"]
    run(body())


def test_controles_deshabilitados_por_estado(tmp_path):
    async def body():
        bench = Bench()
        async with bench.app.run_test(size=SIZE) as pilot:
            await settle(pilot)
            app = bench.app
            assert app.session.state == State.NO_PROG
            for action in ("run", "step", "step_n", "stop", "reprogram"):
                assert not footer_enabled(app, action), action
            for action in ("load", "reset", "refresh", "connect"):
                assert footer_enabled(app, action), action
            await pilot.press("f10")             # deshabilitado: no manda nada
            await settle(pilot)
            assert Cmd.STEP not in bench.cmds()
            app._job(app.session.load_file, write(tmp_path, "addi x1, x0, 5\nhalt\n"))
            await settle(pilot)
            assert footer_enabled(app, "step") and footer_enabled(app, "reprogram")
            await pilot.press("f5")              # RUN hasta el HALT
            await settle(pilot)
            assert app.session.state == State.HALTED
            assert not footer_enabled(app, "run") and not footer_enabled(app, "step")
            assert footer_enabled(app, "reset")
            await pilot.press("f3")              # RESET: se puede volver a correr
            await settle(pilot)
            assert app.session.state == State.READY
    run(body())


def test_paso_por_n(tmp_path):
    async def body():
        bench = Bench(prog=write(tmp_path, "addi x1, x0, 5\n" * 4 + "halt\n"))
        async with bench.app.run_test(size=SIZE) as pilot:
            await settle(pilot)
            await pilot.press("shift+f10")
            await pilot.pause()
            inp = bench.app.screen.query_one("#steps-input")
            inp.value = "3"
            await pilot.press("enter")
            await settle(pilot)
            assert bench.app.session.snapshot.status.cycles == 3
            assert bench.cmds()[-4:] == [Cmd.STEP] * 3 + [Cmd.READ_ALL]
    run(body())


def test_error_de_ensamblado_muestra_la_linea(tmp_path):
    async def body():
        bench = Bench()
        async with bench.app.run_test(size=SIZE) as pilot:
            await settle(pilot)
            bench.app._load_path(write(tmp_path, "addi x1, x0, 5\nadd x2, x1, x33\n"))
            await settle(pilot)
            assert isinstance(bench.app.screen, ErrorsScreen)
            assert any(":2:" in line for line in bench.app.screen.lines)
            assert Cmd.LOAD not in bench.cmds()
    run(body())


async def wait_screen(pilot, name):
    for _ in range(50):
        await pilot.pause()
        if type(pilot.app.screen).__name__ == name:
            return True
    return False


def test_watchdog_detener(tmp_path):
    # Con el reloj falso los 0,5 s de cada espera pasan enseguida: el aviso llega solo
    async def body():
        bench = Bench(prog=write(tmp_path, "addi x1, x0, 5\nhalt\n"))
        async with bench.app.run_test(size=SIZE) as pilot:
            await settle(pilot)
            bench.device.run_seconds = float("inf")      # no termina
            await pilot.press("f5")
            assert await wait_screen(pilot, "WatchdogScreen")
            assert bench.app.session.state == State.RUNNING
            assert Cmd.STATUS in bench.cmds()[-3:]       # el contador de ciclos (§5)
            await pilot.click("#yes")                    # Detener: STOP
            await settle(pilot)
            assert bench.app.session.state == State.PAUSED
            assert bench.cmds()[-2:] == [Cmd.STOP, Cmd.READ_ALL]
    run(body())


def test_cargar_en_running_pide_confirmacion(tmp_path):
    async def body():
        # Reloj real: con el falso, el RUN sin final manda STATUS sin parar
        bench = Bench(prog=write(tmp_path, "addi x1, x0, 5\nhalt\n"), halt_watchdog=1e9,
                      clock=RealClock())
        async with bench.app.run_test(size=SIZE) as pilot:
            await settle(pilot)
            bench.device.run_seconds = float("inf")
            await pilot.press("f5")
            for _ in range(5):
                await pilot.pause()
            app = bench.app
            assert app.session.state == State.RUNNING
            assert app.query_one("#registers").has_class("stale")
            assert footer_enabled(app, "stop") and footer_enabled(app, "reset")
            assert not footer_enabled(app, "step") and not footer_enabled(app, "refresh")
            app.action_load()
            await pilot.pause()
            assert isinstance(app.screen, ConfirmScreen)
            await pilot.click("#no")                     # no carga
            await pilot.pause()
            assert bench.cmds().count(Cmd.LOAD) == 1     # solo el de --prog
            await pilot.press("f6")                      # STOP: el RUN termina en PAUSED
            await settle(pilot)
            assert app.session.state == State.PAUSED
            assert not app.query_one("#registers").has_class("stale")
            assert bench.cmds()[-1] == Cmd.READ_ALL
    run(body())


def test_f2_elige_el_archivo_y_lo_carga(tmp_path):
    async def body():
        bench = Bench()
        async with bench.app.run_test(size=SIZE) as pilot:
            await settle(pilot)
            await pilot.press("f2")
            assert await wait_screen(pilot, "FileScreen")
            path = write(tmp_path, "addi x1, x0, 5\nhalt\n")
            bench.app.screen.query_one("#file-input").value = str(path)
            await pilot.press("enter")
            await settle(pilot)
            assert bench.app.session.state == State.READY
            assert bench.device.imem[0] == 0x00500093
            assert "p.s" in str(bench.app.query_one("#header").render())
    run(body())


def test_selector_de_archivos_y_de_puerto(tmp_path, monkeypatch):
    from rvdebug.tui import screens

    (tmp_path / "a.s").write_text("halt\n")
    (tmp_path / "b.hex").write_text("00100073\n")
    (tmp_path / "notas.txt").write_text("")
    (tmp_path / "sub").mkdir()
    tree = screens._ProgramTree(tmp_path)
    assert sorted(p.name for p in tree.filter_paths(tmp_path.iterdir())) == ["a.s", "b.hex",
                                                                             "sub"]
    ports = [("/dev/ttyS0", "serie", False), ("/dev/ttyUSB0", "FT2232 A", True),
             ("/dev/ttyUSB1", "FT2232 B", True)]
    assert screens.proposed_port(ports) == "/dev/ttyUSB1"      # la UART es la segunda
    assert screens.proposed_port(ports[:1]) == "/dev/ttyS0"
    assert screens.proposed_port([]) == ""

    async def body():
        monkeypatch.setattr(screens, "list_ports", lambda: ports)
        bench = Bench(port=None)
        async with bench.app.run_test(size=SIZE) as pilot:
            await settle(pilot)
            await pilot.press("f1")
            assert await wait_screen(pilot, "PortScreen")
            assert bench.app.screen.query_one("#port-input").value == "/dev/ttyUSB1"
            await pilot.press("enter")
            await settle(pilot)
            assert bench.app.port_name == "/dev/ttyUSB1" and bench.app.session is not None
    run(body())
