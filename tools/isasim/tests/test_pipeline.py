"""Capa 2: tiempos y contenido de los latches según pipeline.md."""

import pytest

from isasim import COMPLETO, SIN_RIESGOS, ModelError, Mode
from isasim.latches import LATCHES, WIDTH, WORDS, compare_mask, pack, unpack

NO_FLUSH = Mode(True, True, False)


def test_latch_widths_match_pipeline_md():
    assert WIDTH == {"if_id": 65, "id_ex": 161, "ex_mem": 109, "mem_wb": 110}
    assert sum(WORDS.values()) == 17                      # palabras de READ_LATCHES


def test_pack_unpack_roundtrip():
    v = unpack("id_ex", (1 << 161) - 12345)
    assert pack("id_ex", v) == (1 << 161) - 12345


def test_protocol_example_cycles_and_pc(run):
    r = run("addi x1, x0, 5\n halt")                      # protocolo_debug.md §4
    assert (r.cycles, r.pc, r.regs[1], r.halted) == (6, 0x8, 5, True)
    assert r.pipeline_empty


@pytest.mark.parametrize("source, cycles", [
    ("addi x1, x0, 1\n addi x2, x0, 2\n addi x3, x0, 3\n halt", 4 + 4),
    ("addi x1, x0, 1\n sw x1, 0(x0)\n lw x2, 0(x0)\n add x3, x2, x2\n halt", 5 + 4 + 1),
    ("beq x0, x0, fin\n addi x1, x0, 1\nfin: halt", 2 + 4 + 2),
    ("addi x1, x0, 1\n beq x0, x1, fin\n addi x2, x0, 2\nfin: halt", 4 + 4),  # no tomado: 0
    ("lw x1, 0(x0)\n halt", 2 + 4 + 1),                   # falso positivo: HALT tiene rs2 = 1
])
def test_cycle_formula(run, source, cycles):
    """verificacion.md §5: ciclos = n + 4 + stalls + 2 · saltos_tomados."""
    assert run(source).cycles == cycles


def id_ex_of(r, pc):
    """Contenido de ID/EX la primera vez que tiene la instrucción de `pc`."""
    for cycle, v, _ in r.per_instr["id_ex"]:
        if v["pc"] == pc:
            return v
    raise AssertionError(pc)


def test_id_ex_keeps_the_stale_value_that_forwarding_fixes(run):
    """El ejemplo de la decisión: en ID todavía se lee el valor viejo de x1."""
    r = run("addi x1, x0, 5\n add x2, x1, x1\n halt")
    assert id_ex_of(r, 4)["rs1_data"] == 0               # lo leído del banco en ID
    assert r.regs[2] == 10                               # el forwarding lo corrige en EX


def test_distance_three_uses_register_file_bypass(run):
    r = run("addi x1, x0, 5\n nop\n nop\n add x2, x1, x0\n halt")
    assert id_ex_of(r, 12)["rs1_data"] == 5              # WB escribe y ID lee en el mismo ciclo


def test_load_use_inserts_one_bubble_in_id_ex(run):
    r = run("lw x1, 0(x0)\n add x2, x1, x1\n halt")
    valid = [s.values["id_ex"]["valid"] for s in r.snapshots]
    # ciclo 2: nada; 3: lw; 4: burbuja del stall; 5: add
    assert valid[1:5] == [0, 1, 0, 1]


def test_taken_branch_flushes_two_instructions(run):
    r = run("beq x0, x0, fin\n addi x1, x0, 1\n addi x2, x0, 2\nfin: halt")
    assert r.regs[1] == r.regs[2] == 0
    wrong = [v for _, v, _ in r.per_instr["if_id"] if v["pc"] in (4, 8)]
    assert len(wrong) == 1                               # pc 4 entra a IF/ID; pc 8 llega anulado
    assert all(v["pc"] not in (4, 8) for _, v, _ in r.per_instr["id_ex"])


def test_halt_stops_fetch_and_leaves_pipeline_empty(run):
    r = run("addi x1, x0, 1\n halt\n addi x2, x0, 2\n addi x3, x0, 3")
    assert r.regs[2] == r.regs[3] == 0 and r.pipeline_empty


def test_bubble_mask_compares_only_valid_and_control():
    v = unpack("ex_mem", 0)
    m = unpack("ex_mem", compare_mask("ex_mem", v))
    assert m["valid"] == 1 and m["reg_write"] == 1 and m["result"] == 0 and m["pc"] == 0


def test_r_type_immediate_is_not_compared(run):
    r = run("add x1, x0, x0\n halt")
    _, v, defined = r.per_instr["id_ex"][0]
    assert not defined
    assert unpack("id_ex", compare_mask("id_ex", v, defined))["imm"] == 0


# ---- modos ------------------------------------------------------------------------------

def test_sin_riesgos_rejects_a_program_that_needs_forwarding(run):
    with pytest.raises(ModelError, match="sin_riesgos"):
        run("addi x1, x0, 5\n add x2, x1, x1\n halt", SIN_RIESGOS)


def test_sin_riesgos_accepts_the_same_program_with_nops(run):
    r = run("addi x1, x0, 5\n nop\n nop\n add x2, x1, x1\n halt", SIN_RIESGOS)
    assert r.regs[2] == 10


def test_without_flush_the_two_instructions_after_a_jump_execute(run):
    r = run("jal x0, fin\n addi x1, x0, 1\n addi x2, x0, 2\nfin: halt", NO_FLUSH)
    assert r.regs[1] == 1 and r.regs[2] == 2
    assert r.cycles == run("jal x0, fin\n addi x1, x0, 1\n addi x2, x0, 2\nfin: halt").cycles


def test_no_halt_stops_at_the_cycle_limit():
    from isasim_testutil import words_of
    from isasim import simulate
    r = simulate(words_of("loop: jal x0, loop"), max_cycles=50)
    assert not r.halted and r.cycles == 50
