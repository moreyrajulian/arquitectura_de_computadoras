"""Tramas y bloques (rvdebug.protocol) contra protocolo_debug.md §2 a §4."""

import struct
import sys
from pathlib import Path

import pytest

from rvdebug.protocol import (Cmd, Err, ProtocolError, State, build_request, build_response,
                              checksum, load_payload, parse_info, parse_latches,
                              parse_read_all, parse_request, parse_response, parse_status,
                              read_dmem_payload)

REPO = Path(__file__).resolve().parents[3]


def h(text):
    return bytes.fromhex(text)


# ---- ejemplos de §4 ---------------------------------------------------------------------

@pytest.mark.parametrize("cmd, payload, frame", [
    (Cmd.LOAD, h("93005000 73001000"), "A5 10 08 00 93 00 50 00 73 00 10 00 B8"),
    (Cmd.RUN, b"", "A5 20 00 00 20"),
    (Cmd.STEP, b"", "A5 21 00 00 21"),
    (Cmd.READ_REGS, b"", "A5 30 00 00 30"),
    (Cmd.READ_DMEM, read_dmem_payload(0x10, 4), "A5 32 06 00 10 00 00 00 04 00 20"),
])
def test_peticiones_de_ejemplo(cmd, payload, frame):
    assert build_request(cmd, payload) == h(frame)
    assert parse_request(h(frame)) == (cmd, payload)


@pytest.mark.parametrize("cmd, status, payload, frame", [
    (Cmd.LOAD, Err.OK, "01 01 00 00 00 00 00 00 00 00 00 00",
     "5A 10 00 0C 00 01 01 00 00 00 00 00 00 00 00 00 00 1C"),
    (Cmd.RUN, Err.OK, "", "5A 20 00 00 00 20"),
    (Cmd.EVT_HALTED, Err.OK, "04 03 00 00 08 00 00 00 06 00 00 00",
     "5A E0 00 0C 00 04 03 00 00 08 00 00 00 06 00 00 00 E5"),
    (Cmd.READ_REGS, Err.ERR_STATE, "", "5A 30 04 00 00 34"),
    (Cmd.LOAD, Err.ERR_CHECKSUM, "", "5A 10 02 00 00 12"),
])
def test_respuestas_de_ejemplo(cmd, status, payload, frame):
    assert build_response(cmd, status, h(payload)) == h(frame)
    r = parse_response(h(frame))
    assert (r.cmd, r.status, r.payload) == (cmd, status, h(payload))
    assert r.is_event == (cmd == Cmd.EVT_HALTED)


def test_evt_halted_de_ejemplo():
    s = parse_status(parse_response(h("5A E0 00 0C 00 04 03 00 00 08 00 00 00 06 00 00 00 E5")).payload)
    assert (s.state, s.pc, s.cycles, s.dmem_used) == (State.HALTED, 0x08, 6, 0)
    assert s.prog_valid and s.halted and not s.imem_fault


def test_sin_payload_el_chk_es_el_cmd():
    for cmd in Cmd:
        assert build_request(cmd)[-1] == cmd


def test_checksum_es_xor():
    assert checksum(b"") == 0
    assert checksum(bytes([0x10, 0x08, 0x00, 0x93])) == 0x10 ^ 0x08 ^ 0x93


@pytest.mark.parametrize("frame, motivo", [
    ("5A 20 00 00 00 21", "checksum"),
    ("A5 20 00 00 00 20", "SOF"),
    ("5A 20 00 01 00 21", "LEN"),
    ("5A 20 00", "mínimo"),
])
def test_respuesta_mal_formada(frame, motivo):
    with pytest.raises(ProtocolError, match=motivo):
        parse_response(h(frame))


def test_payload_demasiado_largo():
    with pytest.raises(ValueError):
        build_request(Cmd.LOAD, bytes(0x10000))


# ---- payloads -------------------------------------------------------------------------

def test_load_little_endian():
    assert load_payload([0x00500093]) == h("93 00 50 00")
    with pytest.raises(ValueError, match="0x004"):
        load_payload([0, 1 << 32])


@pytest.mark.parametrize("addr, count", [(-4, 1), (1 << 32, 1), (0, 0), (0, 0x4000)])
def test_read_dmem_fuera_de_rango(addr, count):
    with pytest.raises(ValueError):
        read_dmem_payload(addr, count)


def test_bloque_de_informacion():
    info = parse_info(struct.pack("<BHH4BI", 1, 1024, 512, 3, 6, 4, 4, 100_000))
    assert (info.proto_version, info.imem_words, info.dmem_words) == (1, 1024, 512)
    assert info.latch_words == (3, 6, 4, 4) and info.latches_size == 68
    assert info.clk_khz == 100_000


def test_bloque_de_estado_flags():
    s = parse_status(struct.pack("<BBHII", 3, 0b11101, 2, 0x40, 99))
    assert s.state == State.PAUSED and s.state_name == "PAUSED"
    assert s.prog_valid and not s.halted
    assert s.imem_fault and s.dmem_oob and s.dmem_misaligned
    with pytest.raises(ProtocolError, match="estado 7"):
        parse_status(struct.pack("<BBHII", 7, 0, 0, 0, 0))
    with pytest.raises(ProtocolError, match="11 B"):
        parse_status(bytes(11))


def test_latches_se_parten_por_info():
    words = list(range(1, 18))
    lat = parse_latches(struct.pack("<17I", *words), (3, 6, 4, 4))
    assert lat.if_id == (1, 2, 3) and lat.mem_wb == (14, 15, 16, 17)
    assert lat.packed("if_id") == 1 | 2 << 32 | 3 << 64


def test_read_all_usa_dmem_used_del_estado():
    status = struct.pack("<BBHII", 4, 3, 2, 8, 6)
    payload = status + struct.pack("<32I", *range(32)) + bytes(4 * 17) \
        + struct.pack("<4I", 0x10, 7, 0x20, 9)
    dump = parse_read_all(payload, (3, 6, 4, 4))
    assert dump.regs[31] == 31 and dump.used == ((0x10, 7), (0x20, 9))
    with pytest.raises(ProtocolError, match="READ_ALL"):
        parse_read_all(payload[:-1], (3, 6, 4, 4))


# ---- contra el modelo de referencia -------------------------------------------------------

def test_read_all_del_modelo_de_referencia():
    """El volcado READ_ALL que escribe isasim se parte igual que lo arma: los dos lados
    del protocolo coinciden en el orden de los bloques y de las palabras de los latches."""
    sys.path.insert(0, str(REPO / "tools" / "isasim"))
    from isasim import COMPLETO, load_program, read_all_payload, simulate
    from isasim.latches import LATCHES, WORDS

    r = simulate(load_program(REPO / "sw" / "fwd_exmem.s"), mode=COMPLETO)
    dump = parse_read_all(read_all_payload(r), tuple(WORDS[n] for n in LATCHES))
    assert dump.status.state == State.HALTED and dump.status.halted
    assert (dump.status.pc, dump.status.cycles) == (r.pc, r.cycles)
    assert list(dump.regs) == list(r.regs)
    assert dump.used == tuple((4 * i, r.dmem[i]) for i in sorted(r.used))
    for name in LATCHES:
        assert dump.latches.packed(name) == r.final.packed(name)
