"""Tests de la capa `model` (decisión 040): nombres ABI, formato de los registros y
Snapshot. Los valores esperados están escritos a mano."""

from rvdebug.model import ABI, MemRange, Snapshot, fmt_dec, fmt_hex, reg_name
from rvdebug.protocol import Dump, Latches, State, Status


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
