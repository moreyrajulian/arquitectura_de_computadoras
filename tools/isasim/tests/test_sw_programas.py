"""El modelo coincide con el estado esperado escrito a mano de los programas de sw/.

verificacion.md §2, regla 1: el modelo tiene que coincidir con el .exp de todos los
programas antes de usarlo para verificar el RTL. Son dos fuentes independientes: el
.exp se calculó a mano desde isa.md (I-15) y el modelo ejecuta isa.md.
"""

import struct

import pytest

from isasim_testutil import REPO
from isasim import (COMPLETO, FORWARDING, FORWARDING_STALL, SIN_RIESGOS, ModelError, compare_exp, load_initial_state,
                    load_program, parse_exp, read_all_payload, simulate, write_outputs)
from isasim.files import default_initial_state

SW = REPO / "sw"
PROGRAMS = sorted(p.stem for p in SW.glob("*.s"))

# sw/README.md §5: los originales que no corren sin forwarding, stall o flush
NEEDS_HAZARD_UNITS = ["fwd_exmem", "fwd_memwb", "fwd_prioridad", "loaduse_rs1_rs2",
                      "loaduse_sw_beq", "load_sin_dep", "branch_cond", "jump",
                      "salto_depende", "mixto_lazo", "halt_stall", "halt_camino_equivocado"]
M7 = [p for p in PROGRAMS if p not in NEEDS_HAZARD_UNITS]
# Decisión 029: de esos, los que no tienen carga-uso ni saltos tomados
ONLY_FORWARDING = ["fwd_exmem", "fwd_memwb", "fwd_prioridad", "load_sin_dep"]
NEEDS_STALL_OR_FLUSH = [p for p in NEEDS_HAZARD_UNITS if p not in ONLY_FORWARDING]
# verificacion.md §8.2 (I-40): con forwarding y sin flush corren hasta el HALT; solo
# difieren del .exp los registros que escriben las instrucciones del camino
# equivocado (las marcadas "no se ejecuta" en el .s)
TRACE_ONLY_FORWARDING = {"salto_depende": {20, 21, 22}}
# Decisión 029 (I-41): de NEEDS_STALL_OR_FLUSH, los que solo necesitan el stall
# (sin saltos tomados); el resto necesita el flush
ONLY_STALL = ["loaduse_rs1_rs2", "halt_stall"]
NEEDS_FLUSH = [p for p in NEEDS_STALL_OR_FLUSH if p not in ONLY_STALL]
# verificacion.md §8.2 (I-41): con forwarding y stall, sin flush. loaduse_sw_beq es
# el load seguido de un beq tomado y, desde I-43, de un jalr: x20 y x21 son del
# camino equivocado
TRACE_ONLY_FORWARDING_STALL = {**TRACE_ONLY_FORWARDING, "loaduse_sw_beq": {20, 21}}


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


@pytest.mark.parametrize("name", M7 + ONLY_FORWARDING)
def test_forwarding_mode_matches(name):
    """Decisión 029: con forwarding y sin stall ni flush (desde I-39)."""
    assert compare_exp(run_program(name, FORWARDING), expected(name)) == []


@pytest.mark.parametrize("name", NEEDS_STALL_OR_FLUSH)
def test_stall_or_flush_programs_do_not_pass_with_forwarding_only(name):
    """Los que necesitan stall o flush no dan el .exp solo con forwarding."""
    try:
        r = run_program(name, FORWARDING)
    except ModelError:
        return
    assert compare_exp(r, expected(name)) != []


@pytest.mark.parametrize("name", sorted(TRACE_ONLY_FORWARDING))
def test_trace_only_programs_run_with_forwarding(name):
    """Su traza sirve para pipeline_tb sin +FINAL: no es un ModelError y termina en HALT."""
    r = run_program(name, FORWARDING)
    assert r.halted and r.pipeline_empty
    diffs = compare_exp(r, expected(name))
    assert sorted(d.split(":")[0] for d in diffs) == sorted(f"x{i}" for i in TRACE_ONLY_FORWARDING[name])


@pytest.mark.parametrize("name", M7 + ONLY_FORWARDING + ONLY_STALL)
def test_forwarding_stall_mode_matches(name):
    """Decisión 029: con forwarding y stall de carga-uso, sin flush (desde I-41)."""
    assert compare_exp(run_program(name, FORWARDING_STALL), expected(name)) == []


@pytest.mark.parametrize("name", NEEDS_FLUSH)
def test_flush_programs_do_not_pass_without_flush(name):
    """Los que necesitan el flush no dan el .exp con forwarding y stall."""
    try:
        r = run_program(name, FORWARDING_STALL)
    except ModelError:
        return
    assert compare_exp(r, expected(name)) != []


@pytest.mark.parametrize("name", sorted(TRACE_ONLY_FORWARDING_STALL))
def test_trace_only_programs_run_with_forwarding_stall(name):
    """Su traza sirve para pipeline_tb sin +FINAL: solo difieren los registros del camino equivocado."""
    r = run_program(name, FORWARDING_STALL)
    assert r.halted and r.pipeline_empty
    diffs = compare_exp(r, expected(name))
    assert sorted(d.split(":")[0] for d in diffs) == sorted(
        f"x{i}" for i in TRACE_ONLY_FORWARDING_STALL[name])


@pytest.mark.parametrize("name", PROGRAMS)
def test_cycles_follow_formula(name):
    """verificacion.md §5 (I-43): ciclos = n + 4 + stalls + 2 · saltos tomados.

    n y los saltos salen de la capa ISA (las instrucciones ejecutadas y los saltos que se
    toman); los stalls, de la traza del pipeline. scripts/ciclos.py cuenta lo mismo desde la
    traza para la tabla de verificacion.md §8.8, así que las dos cuentas tienen que coincidir.
    """
    r = run_program(name, COMPLETO)
    snaps = r.snapshots[:r.cycles]
    n = len(r.effects)
    saltos = sum(e.taken for e in r.effects)       # beq/bne tomados, jal y jalr
    stalls = sum("stall" in s.events for s in snaps)
    assert r.cycles == n + 4 + stalls + 2 * saltos
    assert n == sum(s.values["mem_wb"]["valid"] for s in snaps)
    assert saltos == sum(any(e.startswith("redirect") for e in s.events) for s in snaps)


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
