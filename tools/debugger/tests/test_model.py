"""Tests de la capa `model` (decisiones 040 y 043): nombres ABI, formato de los registros,
Snapshot, campos de los latches, instrucción de cada etapa y diferencias entre volcados.
Los valores esperados están escritos a mano."""

from fake_debug_unit import latches_of, snapshot_of
from isasim.latches import WIDTH
from rvdebug.model import (ABI, Diff, MemRange, Snapshot, diff, fmt_dec, fmt_hex, reg_name,
                           word_at)
from rvdebug.protocol import Dump, Latches, State, Status

HALT = 0x00100073


def test_nombres_abi():
    assert len(ABI) == 32
    assert reg_name(0) == "x0/zero"
    assert reg_name(1) == "x1/ra"
    assert reg_name(2) == "x2/sp"
    assert reg_name(8) == "x8/s0"
    assert reg_name(10) == "x10/a0"
    assert reg_name(17) == "x17/a7"
    assert reg_name(18) == "x18/s2"
    assert reg_name(27) == "x27/s11"
    assert reg_name(28) == "x28/t3"
    assert reg_name(31) == "x31/t6"


def test_hex_de_32_bits():
    assert fmt_hex(0) == "0x00000000"
    assert fmt_hex(0xC) == "0x0000000C"
    assert fmt_hex(0xFFFF_FFFF) == "0xFFFFFFFF"


def test_decimal_con_y_sin_signo():
    assert fmt_dec(12) == "12"
    assert fmt_dec(0xFFFF_FFFF) == "-1"
    assert fmt_dec(0xFFFF_FFFF, signed=False) == "4294967295"
    assert fmt_dec(0x8000_0000) == "-2147483648"
    assert fmt_dec(0x8000_0000, signed=False) == "2147483648"
    assert fmt_dec(0x7FFF_FFFF) == "2147483647"


def _dump():
    status = Status(State.PAUSED, 0x01, 1, 0x18, 7)
    latches = Latches((1, 2, 3), (0,) * 6, (0,) * 4, (0,) * 4)
    return Dump(status, tuple(range(32)), latches, ((0, 12),))


def test_snapshot_desde_read_all():
    snap = Snapshot.from_dump(_dump())
    assert snap.status.pc == 0x18 and snap.status.cycles == 7
    assert snap.regs[3] == 3
    assert snap.latches.if_id == (1, 2, 3)
    assert snap.used == ((0, 12),)
    assert snap.range is None


def test_snapshot_con_estado_y_rango_nuevos():
    snap = Snapshot.from_dump(_dump())
    running = snap.with_status(Status(State.RUNNING, 0x01, 1, 0x40, 900))
    assert running.status.cycles == 900 and running.regs == snap.regs
    rng = snap.with_range(MemRange(0x10, (5, 6)))
    assert rng.range.addr == 0x10 and rng.range.words == (5, 6)
    assert snap.range is None           # inmutable


# ---- campos de los latches (pipeline.md §8, decisión 043) ---------------------------------

def test_campos_de_los_latches():
    snap = snapshot_of({"if_id": {"valid": 1, "pc": 0x14, "instr": 0x001202B3},
                        "id_ex": {"valid": 1, "rd": 4, "mem_read": 1, "imm": 0xFFFF_FFFC},
                        "mem_wb": {"valid": 1, "offset": 3, "halt": 1}})
    f = snap.fields
    assert f["if_id"] == {"valid": 1, "pc": 0x14, "instr": 0x001202B3}
    assert f["id_ex"]["rd"] == 4 and f["id_ex"]["mem_read"] == 1
    assert f["id_ex"]["imm"] == 0xFFFF_FFFC and f["id_ex"]["reg_write"] == 0
    assert f["mem_wb"]["offset"] == 3 and f["mem_wb"]["halt"] == 1
    assert f["ex_mem"]["valid"] == 0
    assert list(f["ex_mem"]) == ["valid", "pc", "result", "store_data", "rd", "funct3",
                                 "mem_write", "reg_write", "mem_to_reg", "halt"]


def test_el_relleno_no_cambia_los_campos():
    latches = latches_of({"if_id": {"valid": 1, "pc": 8}})
    words = list(latches.if_id)
    words[2] |= 1 << (WIDTH["if_id"] - 64)          # primer bit de relleno de la palabra 2
    snap = Snapshot(Status(State.PAUSED, 1, 0, 0, 0), (0,) * 32,
                    Latches(tuple(words), latches.id_ex, latches.ex_mem, latches.mem_wb), ())
    assert snap.fields["if_id"] == {"valid": 1, "pc": 8, "instr": 0}


def test_otras_palabras_por_latch_no_se_decodifican():
    snap = Snapshot(Status(State.PAUSED, 1, 0, 0, 0), (0,) * 32,
                    Latches((0,) * 3, (0,) * 6, (0,) * 4, (0,) * 3), ())
    assert snap.fields is None


# ---- instrucción de cada dirección (decisión 043) ---------------------------------------

def test_palabra_de_una_direccion():
    words = (0x00500093, 0x00700113)
    assert word_at(words, 0) == 0x00500093
    assert word_at(words, 4) == 0x00700113
    assert word_at(words, 8) == HALT                # LOAD llena el resto con HALT
    assert word_at(words, 0x1004) == 0x00700113     # alias addr[11:2] (memoria.md §6)
    assert word_at(words, 6) == 0x00700113          # desalineada: se ignoran los bits 1:0
    assert word_at(None, 0) is None                 # programa desconocido


# ---- diferencias entre volcados (interfaz_pc.md §4.2) -------------------------------------

def test_sin_volcado_anterior_no_cambia_nada():
    d = diff(None, snapshot_of(regs=(0, 5) + (0,) * 30))
    assert d == Diff() and not d and d.counts == (0, 0, 0)


def test_registros_y_memoria_que_cambiaron():
    prev = snapshot_of(regs=(0, 5) + (0,) * 30, used=((0, 7),))
    cur = snapshot_of(regs=(0, 5, 0, 12) + (0,) * 28, used=((0, 12), (8, 1)))
    d = diff(prev, cur)
    assert d.regs == {3}
    assert d.mem == {0, 8}                          # una que cambió y una nueva
    assert d.counts == (1, 0, 2)
    assert d.summary(cur) == "x3=12, M[0x0]=12, M[0x8]=1"


def test_valores_negativos_en_el_resumen():
    prev = snapshot_of()
    cur = snapshot_of(regs=(0, 0xFFFF_FFFF) + (0,) * 30)
    assert diff(prev, cur).summary(cur) == "x1=-1"
    assert diff(cur, cur).summary(cur) == "—"


def test_campos_de_latch_que_cambiaron():
    prev = snapshot_of({"if_id": {"valid": 1, "pc": 0x10, "instr": 0x00002203}})
    cur = snapshot_of({"if_id": {"valid": 1, "pc": 0x14, "instr": 0x001202B3},
                       "id_ex": {"valid": 1, "pc": 0x10, "mem_read": 1}})
    d = diff(prev, cur)
    assert d.latches == {("if_id", "pc"), ("if_id", "instr"), ("id_ex", "valid"),
                         ("id_ex", "pc"), ("id_ex", "mem_read")}
    assert d.counts == (0, 5, 0)


def test_en_una_burbuja_solo_cuentan_valid_y_el_control():
    # Los datos de una burbuja no importan (pipeline.md §2): no se resaltan
    prev = snapshot_of({"id_ex": {"valid": 1, "rd": 4, "rs1": 1, "mem_read": 1}})
    cur = snapshot_of({"id_ex": {"valid": 0, "rd": 5, "rs1": 4}})
    assert diff(prev, cur).latches == {("id_ex", "valid"), ("id_ex", "mem_read")}
