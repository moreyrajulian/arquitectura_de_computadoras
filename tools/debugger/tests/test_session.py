"""Tests de la capa `session` (decisión 040) contra la Debug Unit simulada de
fake_debug_unit.py: la secuencia de comandos de cada control y la tabla de controles
habilitados de interfaz_pc.md §3."""

import struct
from pathlib import Path

import pytest

from rvdebug import HaltTimeout, InvalidProgramError
from rvdebug.protocol import Cmd, State
from rvdebug.session import (ENABLED, LOAD, REFRESH, REPROGRAM, RESET, RUN, STEP, STEP_N,
                             STOP, ProgramFileError, Session, read_program)

from rvasm import AssemblerError

REPO = Path(__file__).resolve().parents[3]
HALT = 0x00100073
ADDI = 0x00500093                   # addi x1, x0, 5


@pytest.fixture
def session(connected):
    s = Session(connected)
    s.connect()
    return s


def write(tmp_path, name, text):
    path = tmp_path / name
    path.write_text(text, encoding="utf-8")
    return path


def cmds(device):
    return [cmd for cmd, _ in device.requests]


# ---- lectura de programas -------------------------------------------------------------

def test_lee_un_s(tmp_path):
    loaded = read_program(write(tmp_path, "p.s", "addi x1, x0, 5   # x1 = 5\nhalt\n"))
    assert loaded.words == (ADDI, HALT)
    assert loaded.program.source_map[0][0] == 1
    assert "x1 = 5" in loaded.source


def test_lee_hex_y_bin(tmp_path):
    hexfile = write(tmp_path, "p.hex", "00500093\n00100073\n\n")
    assert read_program(hexfile).words == (ADDI, HALT)
    binfile = tmp_path / "p.bin"
    binfile.write_bytes(struct.pack("<2I", ADDI, HALT))
    loaded = read_program(binfile)
    assert loaded.words == (ADDI, HALT) and loaded.source is None


def test_archivos_malos(tmp_path):
    with pytest.raises(ProgramFileError, match="p.hex:2"):
        read_program(write(tmp_path, "p.hex", "00500093\nzz\n"))
    binfile = tmp_path / "p.bin"
    binfile.write_bytes(b"\x93\x00\x50")
    with pytest.raises(ProgramFileError, match="múltiplo de 4"):
        read_program(binfile)
    with pytest.raises(ProgramFileError, match=r"\.s, \.hex o \.bin"):
        read_program(write(tmp_path, "p.txt", ""))


# ---- conexión y carga -------------------------------------------------------------------

def test_connect_lee_todo(session, device):
    assert session.connected and session.info.imem_words == 1024
    assert session.state == State.NO_PROG
    assert cmds(device)[-2:] == [Cmd.STATUS, Cmd.READ_ALL]
    assert session.snapshot.regs == (0,) * 32


def test_carga_un_programa_de_sw(session, device):
    snap = session.load_file(REPO / "sw" / "alu_r.s")
    words = read_program(REPO / "sw" / "alu_r.s").words
    assert device.imem[:len(words)] == list(words)
    assert device.imem[len(words)] == HALT
    assert cmds(device)[-2:] == [Cmd.LOAD, Cmd.READ_ALL]
    assert snap.status.state == State.READY
    assert session.loaded.path.name == "alu_r.s"


def test_error_de_ensamblado_no_manda_nada(session, device, tmp_path):
    bad = write(tmp_path, "malo.s", "addi x1, x0, 5\nadd x2, x1, x33\nhalt\n")
    before = len(device.requests)
    with pytest.raises(AssemblerError) as err:
        session.load_file(bad)
    assert [e.line for e in err.value.errors] == [2]
    assert len(device.requests) == before
    assert session.loaded is None


def test_hex_con_palabra_fuera_de_isa_no_manda_nada(session, device, tmp_path):
    bad = write(tmp_path, "p.hex", "00500093\n00000000\n00100073\n")
    before = len(device.requests)
    with pytest.raises(InvalidProgramError, match="0x004"):
        session.load_file(bad)
    assert len(device.requests) == before


def test_reprogram_vuelve_a_leer_el_archivo(session, device, tmp_path):
    src = write(tmp_path, "p.s", "addi x1, x0, 5\nhalt\n")
    session.load_file(src)
    src.write_text("addi x1, x0, 7\nhalt\n", encoding="utf-8")
    session.reprogram()
    assert device.imem[0] == 0x00700093          # addi x1, x0, 7
    assert cmds(device).count(Cmd.LOAD) == 2


def test_reprogram_sin_programa(session):
    assert not session.enabled(REPROGRAM)
    with pytest.raises(ProgramFileError):
        session.reprogram()


# ---- ejecución ----------------------------------------------------------------------------

@pytest.fixture
def loaded(session, tmp_path):
    # 4 instrucciones y HALT: el modelo de la placa termina 4 ciclos después de buscar el HALT
    session.load_file(write(tmp_path, "p.s", "addi x1, x0, 5\n" * 4 + "halt\n"))
    return session


def test_step_avanza_un_ciclo_y_lee_todo(loaded, device):
    snap = loaded.step()
    assert snap.status.cycles == 1 and snap.status.state == State.PAUSED
    assert cmds(device)[-2:] == [Cmd.STEP, Cmd.READ_ALL]


def test_step_n_con_un_solo_read_all(loaded, device):
    before = len(device.requests)
    snap = loaded.step_n(3)
    assert snap.status.cycles == 3
    assert cmds(device)[before:] == [Cmd.STEP] * 3 + [Cmd.READ_ALL]


def test_step_n_se_corta_en_halted(loaded, device):
    before = len(device.requests)
    snap = loaded.step_n(100)
    assert snap.status.state == State.HALTED
    assert snap.status.cycles == 9               # HALT buscado en el ciclo 5, en WB en el 9
    assert cmds(device)[before:] == [Cmd.STEP] * 9 + [Cmd.READ_ALL]


def test_run_hasta_el_halt(loaded, device):
    first = loaded.snapshot
    loaded.run()
    assert loaded.state == State.RUNNING and loaded.before_run is first
    snap = loaded.wait_halted()
    assert snap.status.state == State.HALTED and not loaded.running
    assert cmds(device)[-1] == Cmd.READ_ALL


def test_watchdog_y_stop(loaded, device):
    device.run_seconds = float("inf")
    loaded.run()
    with pytest.raises(HaltTimeout):
        loaded.wait_halted(timeout=1.0)
    assert loaded.state == State.RUNNING
    loaded.poll_status()
    assert loaded.snapshot.status.state == State.RUNNING
    loaded.client.stop()
    snap = loaded.wait_halted()
    assert snap.status.state == State.PAUSED


def test_reset_vuelve_a_ready(loaded):
    loaded.step_n(2)
    snap = loaded.reset()
    assert snap.status.state == State.READY and snap.status.cycles == 0


def test_rango_de_memoria(loaded, device):
    device.write_dmem(0x10, 0xCAFE)
    snap = loaded.read_range(0x10, 2)
    assert snap.range.addr == 0x10 and snap.range.words == (0xCAFE, 0)
    assert loaded.refresh().range is None        # después de otra lectura queda viejo


# ---- controles habilitados (interfaz_pc.md §3) --------------------------------------------

EXPECTED = {   # acción -> estados en que se puede
    LOAD: set(State), RESET: set(State), REPROGRAM: set(State),
    RUN: {State.READY, State.PAUSED}, STEP: {State.READY, State.PAUSED},
    STEP_N: {State.READY, State.PAUSED}, STOP: {State.RUNNING},
    REFRESH: set(State) - {State.RUNNING},
}


def test_tabla_de_controles():
    for action, states in EXPECTED.items():
        assert set(ENABLED[action]) == states, action


def test_controles_en_cada_estado(loaded, device):
    def check(state):
        for action, states in EXPECTED.items():
            assert loaded.enabled(action) == (state in states), (action, state)

    check(State.READY)
    loaded.step()
    check(State.PAUSED)
    device.run_seconds = float("inf")
    loaded.run()
    check(State.RUNNING)
    assert loaded.needs_confirm(LOAD) and loaded.needs_confirm(REPROGRAM)
    assert not loaded.needs_confirm(RESET)
    loaded.client.stop()
    loaded.wait_halted()
    device.run_seconds = None
    loaded.step_n(100)
    check(State.HALTED)
    assert not loaded.needs_confirm(LOAD)


def test_sin_conectar_no_hay_controles(connected):
    s = Session(connected)
    assert not any(s.enabled(a) for a in EXPECTED)
