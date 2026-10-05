"""El modelo coincide con el estado esperado escrito a mano de los programas de sw/.

verificacion.md §2, regla 1: el modelo tiene que coincidir con el .exp de todos los
programas antes de usarlo para verificar el RTL. Son dos fuentes independientes: el
.exp se calculó a mano desde isa.md (I-15) y el modelo ejecuta isa.md.
"""

import struct

import pytest

from isasim_testutil import REPO
from isasim import (COMPLETO, SIN_RIESGOS, ModelError, compare_exp, load_initial_state,
                    load_program, parse_exp, read_all_payload, simulate, write_outputs)
from isasim.files import default_initial_state

SW = REPO / "sw"
PROGRAMS = sorted(p.stem for p in SW.glob("*.s"))

# sw/README.md §5: los originales que no corren sin forwarding, stall o flush
NEEDS_HAZARD_UNITS = ["fwd_exmem", "fwd_memwb", "fwd_prioridad", "loaduse_rs1_rs2",
                      "loaduse_sw_beq", "load_sin_dep", "branch_cond", "jump",
                      "salto_depende", "mixto_lazo", "halt_stall", "halt_camino_equivocado"]
M7 = [p for p in PROGRAMS if p not in NEEDS_HAZARD_UNITS]


def run_program(name, mode):
    prog = SW / f"{name}.s"
    init = default_initial_state(prog)
    regs, dmem = load_initial_state(init) if init else (None, None)
    return simulate(load_program(prog), regs, dmem, mode)


def expected(name):
    return parse_exp((SW / f"{name}.exp").read_text(encoding="utf-8"))


def test_there_are_programs():
    assert len(PROGRAMS) >= 38 and len(M7) >= 26


@pytest.mark.parametrize("name", PROGRAMS)
def test_matches_expected_state(name):
    """Pipeline completo (M8 en adelante): registros, memoria, avisos y ciclos."""
    assert compare_exp(run_program(name, COMPLETO), expected(name)) == []


@pytest.mark.parametrize("name", M7)
def test_m7_programs_match_without_hazard_units(name):
    """sw/README.md §5: sin riesgos y variantes _nops dan lo mismo en M7."""
    assert compare_exp(run_program(name, SIN_RIESGOS), expected(name)) == []


@pytest.mark.parametrize("name", NEEDS_HAZARD_UNITS)
def test_hazard_programs_do_not_pass_without_hazard_units(name):
    """Sin forwarding, stall ni flush, un programa con riesgos no puede dar el .exp."""
    try:
        r = run_program(name, SIN_RIESGOS)
    except ModelError:
        return
    assert compare_exp(r, expected(name)) != []


def test_read_all_status_block_matches_protocol_example(tmp_path):
    """protocolo_debug.md §4: EVT_HALTED con HALTED, 0 palabras, PC = 0x08, 6 ciclos."""
    prog = tmp_path / "p.hex"
    prog.write_text("00500093\n00100073\n")
    r = simulate(load_program(prog))
    status = read_all_payload(r)[:12]
    assert status == bytes.fromhex("04030000" "08000000" "06000000")


def test_outputs_have_one_line_per_cycle(tmp_path):
    r = run_program("fwd_exmem", COMPLETO)
    write_outputs(r, tmp_path, "fwd_exmem")
    lines = (tmp_path / "fwd_exmem.ciclo.id_ex.hex").read_text().splitlines()
    assert len(lines) == r.cycles + 1                    # más la foto final
    assert all(len(l) == 41 for l in lines)              # 161 bits = 41 dígitos hex
    payload = (tmp_path / "fwd_exmem.read_all.bin").read_bytes()
    used = struct.unpack_from("<H", payload, 2)[0]
    assert len(payload) == 12 + 128 + 4 * 17 + 8 * used
