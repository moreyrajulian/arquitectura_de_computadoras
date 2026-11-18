"""Tests de comparar.py (I-54) sin FPGA.

Como en test_placa.py, la placa es `ModelDebugUnit`: una Debug Unit simulada cuyo core es el
modelo de referencia, así que cualquier programa tiene que coincidir. Cada test le puede meter
una falla (un registro, un bit de un latch en un paso, un aviso) para ver que comparar.py la
detecta y la informa en el ciclo que corresponde.
"""

import io
from pathlib import Path

import pytest

import comparar  # noqa: I001  (antes que isasim: agrega tools/isasim al path)
from fake_debug_unit import AVISO_BITS, FakeDebugUnit, FakeSerial, ModelDebugUnit
from isasim import WIDTH
from rvasm import assemble
from rvdebug import DebugClient

SW = comparar.SW


@pytest.fixture
def board(clock):
    return ModelDebugUnit()


@pytest.fixture
def board_client(board, clock):
    return DebugClient(FakeSerial(board, clock), clock=clock, sleep=clock.sleep)


def run(argv, client, out=None):
    out = out if out is not None else io.StringIO()
    code = comparar.main(argv, client=client, out=out)
    return code, out.getvalue()


def cmds(board):
    return [cmd.name for cmd, _ in board.requests]


@pytest.fixture
def lazo(tmp_path):
    """Un programa sin HALT: el modelo nunca termina."""
    path = tmp_path / "lazo.s"
    path.write_text("addi x1, x0, 1\nlazo: addi x1, x1, 1\njal x0, lazo\n", encoding="utf-8")
    return path


# ---- una placa que funciona ---------------------------------------------------------------

def test_run_coincide_con_el_modelo(board_client, board):
    code, text = run(["COMX", str(SW / "fwd_exmem.s")], board_client)
    assert code == 0, text
    assert "ciclo 12" in text                  # fwd_exmem.exp: ciclos = 12
    assert "coincide con el modelo" in text
    assert "STEP" not in cmds(board)
    assert cmds(board)[-3:] == ["LOAD", "RUN", "READ_ALL"]


@pytest.mark.parametrize("path", sorted(SW.glob("*.s")), ids=lambda p: p.stem)
def test_todos_los_programas_de_sw_coinciden(board_client, path):
    # También los indep_*: los dos lados parten de todo en cero después de LOAD
    code, text = run(["COMX", str(path)], board_client)
    assert code == 0, text


def test_ciclos_compara_en_ese_ciclo(board_client, board):
    code, text = run(["COMX", str(SW / "fwd_exmem.s"), "--ciclos", "5"], board_client)
    assert code == 0, text
    assert "ciclo 5" in text
    assert cmds(board).count("STEP") == 5
    assert "RUN" not in cmds(board)


def test_ciclos_corta_en_halted(board_client, board):
    code, text = run(["COMX", str(SW / "fwd_exmem.s"), "--ciclos", "100"], board_client)
    assert code == 0, text
    assert "ciclo 12" in text
    assert cmds(board).count("STEP") == 12


def test_cada_ciclo_compara_el_volcado_de_cada_paso(board_client, board):
    code, text = run(["COMX", str(SW / "fwd_exmem.s"), "--cada-ciclo"], board_client)
    assert code == 0, text
    assert "12 ciclos" in text
    assert cmds(board).count("STEP") == 12
    assert cmds(board).count("READ_ALL") == 13        # después de LOAD y de cada paso


def test_programa_hex(board_client, tmp_path):
    words = assemble((SW / "mem_byte_media.s").read_text(encoding="utf-8")).words
    path = tmp_path / "prog.hex"
    path.write_text("".join(f"{w:08x}\n" for w in words), encoding="utf-8")
    code, text = run(["COMX", str(path)], board_client)
    assert code == 0, text


def test_programa_sin_halt_con_ciclos(board_client, lazo):
    code, text = run(["COMX", str(lazo), "--ciclos", "30"], board_client)
    assert code == 0, text
    assert "ciclo 30" in text


def test_sin_cargar_compara_el_estado_actual(board_client, board):
    words = assemble((SW / "loaduse_rs1_rs2.s").read_text(encoding="utf-8")).words
    board_client.connect()
    board_client.load(words)
    for _ in range(7):
        board_client.step()
    board.requests.clear()
    code, text = run(["COMX", str(SW / "loaduse_rs1_rs2.s"), "--sin-cargar"], board_client)
    assert code == 0, text
    assert "ciclo 7" in text
    assert "LOAD" not in cmds(board) and "STEP" not in cmds(board)


# ---- fallas que tiene que detectar --------------------------------------------------------

def test_registro_mal(board_client, board):
    board.bad_reg = (5, 0xDEAD)
    code, text = run(["COMX", str(SW / "fwd_exmem.s")], board_client)
    assert code == 1
    assert "x5: placa 0x0000DEAD, modelo 0x00000040" in text


def test_aviso_de_mas(board_client, board):
    board.bad_flags = AVISO_BITS["imem_fault"]
    code, text = run(["COMX", str(SW / "alu_r.s")], board_client)
    assert code == 1
    assert "flags: placa 0x7, modelo 0x3" in text


def test_cada_ciclo_informa_la_primera_diferencia(board_client, board):
    board.bad_latch = (3, "if_id", WIDTH["if_id"] - 1)          # el bit de valid
    code, text = run(["COMX", str(SW / "fwd_exmem.s"), "--cada-ciclo"], board_client)
    assert code == 1
    assert "primera diferencia en el ciclo 3" in text
    assert "IF/ID.valid: placa 0x" in text
    assert cmds(board).count("STEP") == 3                       # corta ahí


def test_dato_de_una_burbuja_no_se_compara(board_client, board):
    board.bad_latch = (1, "id_ex", 128)                          # bit 0 de id_ex.pc
    code, text = run(["COMX", str(SW / "fwd_exmem.s"), "--cada-ciclo"], board_client)
    assert code == 0, text


def test_sin_cargar_con_otro_programa_difiere(board_client):
    board_client.connect()
    board_client.load(assemble((SW / "alu_r.s").read_text(encoding="utf-8")).words)
    board_client.run()
    board_client.wait_halted()
    code, text = run(["COMX", str(SW / "lui.s"), "--sin-cargar"], board_client)
    assert code == 1
    assert "diferencias con el modelo" in text


def test_placa_que_no_termina(board_client, board, capsys):
    board.run_seconds = float("inf")
    code, text = run(["COMX", str(SW / "fwd_exmem.s"), "--timeout", "1"], board_client)
    assert code == 1
    assert "no llegó a HALTED" in text
    assert "STOP" in cmds(board)


# ---- lo que no se puede comparar -----------------------------------------------------------

def test_programa_sin_halt_sin_ciclos(board_client, lazo, capsys):
    code, _ = run(["COMX", str(lazo), "--max-ciclos", "200"], board_client)
    assert code == 2
    assert "--ciclos" in capsys.readouterr().err


def test_ciclos_mayor_que_el_limite_del_modelo(board_client, lazo, capsys):
    code, _ = run(["COMX", str(lazo), "--ciclos", "500", "--max-ciclos", "100"], board_client)
    assert code == 2
    assert "--max-ciclos" in capsys.readouterr().err


def test_ciclos_mayor_que_el_limite_con_halt_antes(board_client):
    # El modelo termina antes del límite: la placa corta en HALTED y no hace falta más
    code, text = run(["COMX", str(SW / "alu_r.s"), "--ciclos", "500", "--max-ciclos", "100"],
                     board_client)
    assert code == 0, text


def test_ciclos_tiene_que_ser_positivo(board_client, capsys):
    code, _ = run(["COMX", str(SW / "alu_r.s"), "--ciclos", "0"], board_client)
    assert code == 2


def test_sin_cargar_no_se_combina_con_ciclos(board_client, capsys):
    code, _ = run(["COMX", str(SW / "alu_r.s"), "--sin-cargar", "--ciclos", "3"],
                  board_client)
    assert code == 2


def test_sin_cargar_sin_programa_en_la_placa(board_client, capsys):
    code, _ = run(["COMX", str(SW / "alu_r.s"), "--sin-cargar"], board_client)
    assert code == 2
    assert "NO_PROG" in capsys.readouterr().err


def test_sin_cargar_con_la_placa_en_running(board_client, board, capsys):
    board.run_seconds = float("inf")
    board_client.connect()
    board_client.load(assemble((SW / "alu_r.s").read_text(encoding="utf-8")).words)
    board_client.run()
    code, _ = run(["COMX", str(SW / "alu_r.s"), "--sin-cargar"], board_client)
    assert code == 2
    assert "RUNNING" in capsys.readouterr().err


def test_sin_cargar_ciclo_fuera_del_modelo(board_client, lazo, capsys):
    words = assemble(lazo.read_text(encoding="utf-8")).words
    board_client.connect()
    board_client.load(words)
    for _ in range(60):
        board_client.step()
    code, _ = run(["COMX", str(lazo), "--sin-cargar", "--max-ciclos", "50"], board_client)
    assert code == 2
    assert "--max-ciclos" in capsys.readouterr().err


def test_programa_inexistente(capsys):
    assert comparar.main(["COMX", "no_existe.s"]) == 2
    assert "no_existe.s" in capsys.readouterr().err


def test_error_de_ensamblado(tmp_path, capsys):
    path = tmp_path / "malo.s"
    path.write_text("addi x1, x0\n", encoding="utf-8")
    assert comparar.main(["COMX", str(path)]) == 2
    assert "malo.s" in capsys.readouterr().err


def test_palabras_por_latch_distintas_del_modelo(clock, capsys):
    device = FakeDebugUnit(latch_words=(3, 6, 4, 3))
    client = DebugClient(FakeSerial(device, clock), clock=clock, sleep=clock.sleep)
    code, _ = run(["COMX", str(SW / "alu_r.s")], client)
    assert code == 2
    assert "palabras por latch" in capsys.readouterr().err


def test_fpga_que_no_responde(clock, capsys):
    class Muda(FakeDebugUnit):
        def feed(self, data, now):
            return []

    client = DebugClient(FakeSerial(Muda(), clock), clock=clock, sleep=clock.sleep)
    code, _ = run(["COMX", str(SW / "alu_r.s")], client)
    assert code == 2
    assert "no se pudo conectar" in capsys.readouterr().err


def test_ruta_relativa_al_repo():
    # Se puede nombrar un programa de sw/ por su nombre, como en placa.py
    assert comparar.program_path("fwd_exmem") == SW / "fwd_exmem.s"
    assert comparar.program_path("otro/prog.hex") == Path("otro/prog.hex")
