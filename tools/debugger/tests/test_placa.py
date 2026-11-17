"""Tests de placa.py (la prueba en placa, I-49) sin FPGA.

La Debug Unit simulada (fake_debug_unit) tiene como core el modelo de referencia: es una
placa que funciona bien, a la que cada test le puede meter una falla (un registro, un bit de
un latch en un paso) para ver que placa.py la detecta y la informa donde corresponde.
"""

import io
import struct

import pytest

import placa  # noqa: I001  (antes que isasim: placa.py agrega tools/isasim al path)
from fake_debug_unit import HALT, FakeDebugUnit, FakeSerial
from isasim import COMPLETO, LATCHES, WIDTH, simulate
from isasim.latches import to_words
from rvdebug import DebugClient

AVISO_BITS = {"imem_fault": 1 << 2, "dmem_oob": 1 << 3, "dmem_misaligned": 1 << 4}


class ModelDebugUnit(FakeDebugUnit):
    """FakeDebugUnit cuyo core avanza con el modelo de referencia: después de k ciclos los
    latches son la foto k del modelo y, al llegar al HALT, el estado es el final."""

    def __init__(self, **kw):
        self.model = None
        self.k = 0
        self.bad_reg = None        # (i, valor): el registro i queda mal al final
        self.bad_latch = None      # (k, latch, bit): ese bit invertido después del paso k
        self.bad_flags = 0         # avisos invertidos al final (bits 2 a 4 de flags)
        super().__init__(**kw)

    def _cmd_load(self, payload, now):
        words = list(struct.unpack(f"<{len(payload) // 4}I", payload))
        imem = words + [HALT] * (self.imem_words - len(words))
        self.model = simulate(imem, mode=COMPLETO)
        return super()._cmd_load(payload, now)

    def _clear(self):
        super()._clear()
        self.k = 0
        if getattr(self, "model", None) is not None:
            self._apply()

    def _tick(self):
        if self.halted:
            return
        self.k += 1
        self._apply()

    def _cycles_to_halt(self):
        return self.model.cycles - self.k

    def _apply(self):
        r, k = self.model, self.k
        snap = r.snapshots[k]
        packed = {latch: snap.packed(latch) for latch in LATCHES}
        if self.bad_latch and self.bad_latch[0] == k:
            _, latch, bit = self.bad_latch
            packed[latch] ^= 1 << bit
        self.latches = [to_words(latch, packed[latch]) for latch in LATCHES]
        self.cycles = k
        if k == r.cycles:
            self.halted = True
            self.pc = r.pc
            self.regs = list(r.regs)
            self.dmem = list(r.dmem)
            self.used = set(r.used)
            self.flags_extra = sum(bit for name, bit in AVISO_BITS.items() if getattr(r, name))
            self.flags_extra ^= self.bad_flags
            if self.bad_reg:
                self.regs[self.bad_reg[0]] = self.bad_reg[1]


@pytest.fixture
def board(clock):
    return ModelDebugUnit()


@pytest.fixture
def board_client(board, clock):
    client = DebugClient(FakeSerial(board, clock), clock=clock, sleep=clock.sleep)
    client.connect()
    return client


def prog(name):
    return placa.SW / f"{name}.s"


# ---- una placa que funciona ---------------------------------------------------------------

def test_programa_correcto_pasa_con_run_y_step(board_client, board):
    res = placa.verify_program(board_client, prog("fwd_exmem"))
    assert res.ok, res.diffs
    assert res.cycles == 12                     # fwd_exmem.exp: ciclos = 12
    assert res.steps == 12
    cmds = [cmd.name for cmd, _ in board.requests]
    assert cmds.count("STEP") == 12
    assert cmds.count("READ_LATCHES") == 12     # los latches después de cada paso
    assert cmds.count("READ_ALL") == 2          # después de RUN y al final de STEP


def test_los_22_del_plan_pasan(board_client):
    out = io.StringIO()
    assert placa.main(["COMX"], client=board_client, out=out) == 0
    text = out.getvalue()
    assert "22 programas: 22 OK" in text
    assert "FALLA" not in text


def test_con_nops_suma_las_variantes(board_client):
    out = io.StringIO()
    assert placa.main(["COMX", "--nops", "--sin-paso"], client=board_client, out=out) == 0
    assert "32 programas: 32 OK" in out.getvalue()


def test_sin_paso_no_manda_step(board_client, board):
    res = placa.verify_program(board_client, prog("mem_avisos"), step=False)
    assert res.ok, res.diffs
    assert res.steps == 0
    assert all(cmd.name not in ("STEP", "READ_LATCHES") for cmd, _ in board.requests)


# ---- fallas que tiene que detectar --------------------------------------------------------

def test_registro_mal_contra_exp_y_modelo(board_client, board):
    board.bad_reg = (5, 0xDEAD)
    res = placa.verify_program(board_client, prog("fwd_exmem"))
    assert not res.ok
    assert "RUN vs .exp: x5: placa 0x0000DEAD, .exp 0x00000040" in res.diffs
    assert "RUN vs modelo: x5: placa 0x0000DEAD, modelo 0x00000040" in res.diffs


def test_valid_mal_en_un_paso_dice_paso_latch_y_campo(board_client, board):
    board.bad_latch = (3, "if_id", WIDTH["if_id"] - 1)          # el bit de valid
    res = placa.verify_program(board_client, prog("fwd_exmem"))
    assert not res.ok
    assert [d for d in res.diffs if d.startswith("STEP vs modelo: paso 3: IF/ID.valid")]
    assert not [d for d in res.diffs if d.startswith("RUN")]  # el RUN no pasa por el paso 3


def test_dato_de_una_burbuja_no_se_compara(board_client, board):
    # Después del paso 1 ID/EX es una burbuja: de su pc no se compara nada (máscara)
    board.bad_latch = (1, "id_ex", 128)                          # bit 0 de id_ex.pc
    res = placa.verify_program(board_client, prog("fwd_exmem"))
    assert res.ok, res.diffs


def test_relleno_de_la_ultima_palabra_en_cero(board_client, board):
    board.bad_latch = (2, "if_id", WIDTH["if_id"])               # primer bit de relleno
    res = placa.verify_program(board_client, prog("fwd_exmem"))
    assert any("paso 2: IF/ID: relleno distinto de 0" in d for d in res.diffs)


def test_aviso_de_mas_contra_exp_y_modelo(board_client, board):
    board.bad_flags = AVISO_BITS["imem_fault"]
    res = placa.verify_program(board_client, prog("alu_r"), step=False)
    assert "RUN vs .exp: avisos: placa imem_fault, .exp ninguno" in res.diffs
    assert "RUN vs modelo: flags: placa 0x7, modelo 0x3" in res.diffs


def test_main_informa_las_fallas_y_sale_con_1(board_client, board):
    board.bad_reg = (1, 0x1234)
    out = io.StringIO()
    assert placa.main(["COMX", "alu_r", "lui"], client=board_client, out=out) == 1
    text = out.getvalue()
    assert "FALLA" in text
    assert "2 programas: 0 OK, 2 con diferencias (alu_r, lui)" in text


# ---- lo que no se puede probar -------------------------------------------------------------

def test_indep_rechazado(capsys):
    assert placa.main(["COMX", "indep_alu_r"]) == 2
    assert "indep_alu_r" in capsys.readouterr().err


def test_programa_inexistente(capsys):
    assert placa.main(["COMX", "no_existe"]) == 2


def test_palabras_por_latch_distintas_del_modelo(clock, capsys):
    device = FakeDebugUnit(latch_words=(3, 6, 4, 3))
    client = DebugClient(FakeSerial(device, clock), clock=clock, sleep=clock.sleep)
    assert placa.main(["COMX"], client=client, out=io.StringIO()) == 2
    assert "palabras por latch" in capsys.readouterr().err


def test_fpga_que_no_responde(clock, capsys):
    class Muda(FakeDebugUnit):
        def feed(self, data, now):
            return []

    client = DebugClient(FakeSerial(Muda(), clock), clock=clock, sleep=clock.sleep)
    assert placa.main(["COMX"], client=client, out=io.StringIO()) == 2
    assert "no se pudo conectar" in capsys.readouterr().err
