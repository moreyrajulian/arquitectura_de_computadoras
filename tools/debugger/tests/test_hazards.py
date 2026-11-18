"""Tests de la inferencia de riesgos (interfaz_pc.md §4.3, decisión 043).

Dos tipos de prueba:
- **Contra el modelo de referencia:** en cada ciclo de cada programa de sw/, lo que la PC
  deduce de los latches (stall, salto tomado, parada por HALT) tiene que ser lo que el
  modelo decidió en ese ciclo (los eventos `stall`, `redirect a …` y `stop_fetch` de
  isasim), y nunca se informa una inconsistencia: el modelo es un core que funciona bien.
- **A mano:** forwarding, el texto de cada evento, las etapas que se ven y las
  inconsistencias que aparecen cuando el core hace otra cosa.
"""

import sys
from pathlib import Path

import pytest

from fake_debug_unit import model_snapshot, snapshot_of
from isasim import COMPLETO, simulate
from rvasm import HALT_WORD, assemble
from rvdebug.hazards import (BRANCH_NEXT, DONE, FLUSH, FWD, HALT, NOT_TAKEN, STALL,
                             STALL_NEXT, WARN, analyze)
from rvdebug.protocol import State

SW = Path(__file__).resolve().parents[3] / "sw"
if str(SW) not in sys.path:
    sys.path.insert(0, str(SW))
from programas import NOPS, PLAN  # noqa: E402

# Los indep_* arrancan de sw/estado_inicial: el LOAD no puede dejar ese estado
PROGRAMS = list(PLAN) + [f"{n}_nops" for n in NOPS]


def words_of(source):
    return tuple(assemble(source, "t.s").words)


def model_run(words):
    return simulate(list(words) + [HALT_WORD] * (1024 - len(words)), mode=COMPLETO)


def walk(words, r):
    """analyze en cada ciclo, encadenando el volcado anterior como hace Session."""
    prev = prev_a = None
    out = []
    for k in range(len(r.snapshots)):
        cur = model_snapshot(r, k)
        a = analyze(cur, prev, prev_a, words)
        out.append(a)
        prev, prev_a = cur, a
    return out


def kinds(a):
    return [e.kind for e in a.events]


def of_kind(a, kind):
    return [e for e in a.events if e.kind == kind]


# ---- contra el modelo de referencia ---------------------------------------------------------

@pytest.mark.parametrize("name", PROGRAMS)
def test_inferencia_igual_al_modelo(name):
    words = tuple(assemble((SW / f"{name}.s").read_text(encoding="utf-8"), name).words)
    r = model_run(words)
    analyses = walk(words, r)
    for k, a in enumerate(analyses[:-1]):              # la última es la foto final
        events = r.snapshots[k].events
        where = f"{name}, ciclo {k}: {events} / {kinds(a)}"
        assert a.stall_next == ("stall" in events), where
        redirects = [e for e in events if e.startswith("redirect a ")]
        if redirects:
            assert a.redirect_next is not None, where
            assert redirects[0] == f"redirect a 0x{a.redirect_next:08X}", where
        else:
            assert a.redirect_next is None, where
        assert a.stop_fetch == ("stop_fetch" in events), where
        assert not of_kind(a, WARN), (where, [e.text for e in a.events])
    # Cada stall previsto se ve en el ciclo siguiente, y cada salto tomado también
    stalls = sum(a.stall_next for a in analyses)
    assert stalls == sum(bool(of_kind(a, STALL)) for a in analyses)
    jumps = sum(a.redirect_next is not None for a in analyses)
    assert jumps == sum(bool(of_kind(a, FLUSH)) for a in analyses)
    final = analyses[-1]
    assert kinds(final) == [DONE]
    assert all(s.kind == "empty" for s in final.stages)


# ---- el boceto: stall por load-use en el ciclo 7 -------------------------------------------

SUMA_LW = words_of("""
    addi x1, x0, 5
    addi x2, x0, 7
    add  x3, x1, x2
    sw   x3, 0(x0)
    lw   x4, 0(x0)
    add  x5, x4, x1
    halt
""")


def test_load_use_previsto_en_el_ciclo_6():
    a = walk(SUMA_LW, model_run(SUMA_LW))[6]
    assert a.stall_next
    (event,) = of_kind(a, STALL_NEXT)
    assert event.short == "load-use detectado (lw→add)"
    assert "x4" in event.text


def test_stall_del_boceto_en_el_ciclo_7():
    a = walk(SUMA_LW, model_run(SUMA_LW))[7]
    (event,) = of_kind(a, STALL)
    assert event.text == ("load-use: lw x4, 0(x0) en MEM, add x5, x4, x1 lee x4 → IF e ID "
                          "retenidos, burbuja en EX")
    assert event.short == "STALL load-use, burbuja→EX"
    view = {s.stage: s for s in a.stages}
    assert (view["IF"].pc, view["IF"].text, view["IF"].retained) == (0x18, "halt", True)
    assert view["IF"].note == "PC retenido"
    assert (view["ID"].pc, view["ID"].text, view["ID"].retained) == (0x14, "add x5, x4, x1", True)
    assert view["ID"].note == "IF/ID retenido"
    assert (view["EX"].kind, view["EX"].note) == ("bubble", "burbuja (stall)")
    assert (view["MEM"].text, view["MEM"].note) == ("lw x4, 0(x0)", "lee M[0x0]")
    assert (view["WB"].text, view["WB"].note) == ("sw x3, 0(x0)", "sin escritura")
    # La burbuja del stall no recibe forwarding aunque su rs1 coincida con el rd del lw
    assert not of_kind(a, FWD)


def test_la_burbuja_del_stall_avanza_con_su_causa():
    analyses = walk(SUMA_LW, model_run(SUMA_LW))
    assert {s.stage: s.note for s in analyses[8].stages}["MEM"] == "burbuja (stall)"
    assert {s.stage: s.note for s in analyses[9].stages}["WB"] == "burbuja (stall)"


def test_stall_visto_sin_el_volcado_anterior():
    # Después de Paso×N no hay volcado del ciclo anterior: el stall se deduce igual
    r = model_run(SUMA_LW)
    a = analyze(model_snapshot(r, 7), None, None, SUMA_LW)
    assert of_kind(a, STALL)


# ---- forwarding (pipeline.md §10.2) ----------------------------------------------------------

def test_forwarding_desde_ex_mem_a_los_dos_operandos():
    words = words_of("addi x1, x0, 5\n add x2, x1, x1\n halt")
    a = walk(words, model_run(words))[3]               # addi en EX/MEM, add en ID/EX
    assert [e.short for e in of_kind(a, FWD)] == ["FWD EX/MEM→EX rs1 x1",
                                                 "FWD EX/MEM→EX rs2 x1"]
    assert of_kind(a, FWD)[0].text == "EX/MEM → EX rs1: x1 = 5 (addi x1, x0, 5)"


def test_forwarding_desde_mem_wb_con_el_dato_del_load():
    words = words_of("addi x1, x0, -3\n sw x1, 8(x0)\n lw x2, 8(x0)\n nop\n add x3, x2, x0\n halt")
    analyses = walk(words, model_run(words))
    fwd = [e for a in analyses for e in of_kind(a, FWD)]
    assert "MEM/WB → EX rs1: x2 = -3 (lw x2, 8(x0))" in [e.text for e in fwd]


def test_ex_mem_tiene_prioridad_sobre_mem_wb():
    words = words_of("addi x1, x0, 1\n addi x1, x0, 2\n add x2, x1, x0\n halt")
    a = walk(words, model_run(words))[4]
    assert [e.text for e in of_kind(a, FWD)] == ["EX/MEM → EX rs1: x1 = 2 (addi x1, x0, 2)"]


def test_operando_que_la_instruccion_no_usa_no_se_informa():
    # rs2 de `addi x3, x0, 1` son los bits del inmediato (= 1 = x1): el hardware reenvía a un
    # operando que el control descarta (pipeline.md §10.2), no tiene efecto
    words = words_of("addi x1, x0, 5\n addi x3, x0, 1\n halt")
    assert not [e for a in walk(words, model_run(words)) for e in of_kind(a, FWD)]


def test_x0_nunca_se_reenvia():
    words = words_of("addi x0, x0, 5\n add x2, x0, x0\n halt")
    assert not [e for a in walk(words, model_run(words)) for e in of_kind(a, FWD)]


# ---- saltos (pipeline.md §10.5) --------------------------------------------------------------

BEQ = words_of("beq x0, x0, fin\n addi x1, x0, 1\nfin: halt")


def test_salto_tomado_previsto_y_flush():
    analyses = walk(BEQ, model_run(BEQ))
    assert analyses[2].redirect_next == 8
    assert of_kind(analyses[2], BRANCH_NEXT)[0].short == "salto tomado→0x8"
    (flush,) = of_kind(analyses[3], FLUSH)
    assert flush.text == "beq x0, x0, +8 en 0x0 tomado a 0x8: IF/ID e ID/EX anulados"
    view = {s.stage: s for s in analyses[3].stages}
    assert view["ID"].note == view["EX"].note == "burbuja (flush)"
    assert view["IF"].pc == 8


def test_flush_visto_sin_el_volcado_anterior():
    a = analyze(model_snapshot(model_run(BEQ), 3), None, None, BEQ)
    assert of_kind(a, FLUSH)


def test_branch_no_tomado():
    words = words_of("addi x1, x0, 1\n beq x0, x1, fin\n addi x2, x0, 2\nfin: halt")
    analyses = walk(words, model_run(words))
    assert [e.short for a in analyses for e in of_kind(a, NOT_TAKEN)] == ["beq no tomado"]
    assert not [a for a in analyses if of_kind(a, FLUSH)]


# ---- HALT (pipeline.md §3.4) -----------------------------------------------------------------

def test_halt_en_vuelo_sin_stalls_falsos():
    # Mientras se vacía el pipeline el PC y la burbuja de IF/ID no cambian y a ID/EX le
    # llegan burbujas: la regla vieja de interfaz_pc.md §4.3 lo tomaba como un stall
    words = words_of("addi x1, x0, 5\n halt")
    analyses = walk(words, model_run(words))
    assert not [a for a in analyses if of_kind(a, STALL) or of_kind(a, WARN)]
    assert [k for k, a in enumerate(analyses) if of_kind(a, HALT)] == [2, 3, 4, 5]
    view = {s.stage: s for s in analyses[3].stages}
    assert view["IF"].kind == "stopped" and view["IF"].note == "detenido (HALT)"
    assert view["ID"].note == "burbuja (HALT)"
    assert view["EX"].halt and view["EX"].text == "halt"


def test_programa_terminado():
    words = words_of("addi x1, x0, 5\n halt")
    a = walk(words, model_run(words))[-1]
    (done,) = of_kind(a, DONE)
    assert done.text == "Programa terminado en 6 ciclos, pipeline vacío"


# ---- inconsistencias: el core hace otra cosa que las reglas de pipeline.md -----------------

LW = {"valid": 1, "pc": 0x10, "rd": 4, "rs1": 0, "mem_read": 1, "reg_write": 1,
      "mem_to_reg": 1, "alu_src_b": 1, "funct3": 2}
ADD = {"valid": 1, "pc": 0x14, "instr": 0x001202B3}         # add x5, x4, x1


def test_stall_previsto_que_no_ocurre():
    prev = snapshot_of({"if_id": ADD, "id_ex": LW}, pc=0x18, cycles=6)
    cur = snapshot_of({"if_id": {"valid": 1, "pc": 0x18, "instr": HALT_WORD},
                       "id_ex": {"valid": 1, "pc": 0x14, "rs1": 4, "rs2": 1, "rd": 5,
                                 "reg_write": 1},
                       "ex_mem": {"valid": 1, "pc": 0x10, "rd": 4, "reg_write": 1,
                                  "mem_to_reg": 1, "funct3": 2}}, pc=0x1C, cycles=7)
    a = analyze(cur, prev, None, SUMA_LW)
    (warn,) = of_kind(a, WARN)
    assert "se esperaba un stall" in warn.text.lower()


def test_stall_que_no_corresponde():
    addi = {"valid": 1, "pc": 0x0, "rd": 1, "reg_write": 1, "alu_src_b": 1}
    if_id = {"valid": 1, "pc": 0x4, "instr": 0x00700113}       # addi x2, x0, 7
    prev = snapshot_of({"if_id": if_id, "id_ex": addi}, pc=0x8, cycles=2)
    cur = snapshot_of({"if_id": if_id, "ex_mem": {"valid": 1, "pc": 0, "rd": 1,
                                                  "reg_write": 1}}, pc=0x8, cycles=3)
    a = analyze(cur, prev, None, SUMA_LW)
    assert "stall inesperado" in of_kind(a, WARN)[0].text


def test_instruccion_de_if_id_distinta_de_la_cargada():
    cur = snapshot_of({"if_id": {"valid": 1, "pc": 0x4, "instr": 0x00000013}}, pc=8, cycles=2)
    (warn,) = of_kind(analyze(cur, None, None, SUMA_LW), WARN)
    assert warn.text == ("IF/ID.instr = 0x00000013 y la palabra cargada en 0x4 es 0x00700113 "
                         "(addi x2, x0, 7)")


def test_salto_previsto_sin_flush():
    beq = {"valid": 1, "pc": 0x0, "branch": 1, "alu_ctrl": 0b1000, "imm": 8}
    prev = snapshot_of({"id_ex": beq, "if_id": {"valid": 1, "pc": 4, "instr": BEQ[1]}},
                       pc=0x8, cycles=2)
    cur = snapshot_of({"ex_mem": {"valid": 1, "pc": 0x0},
                       "id_ex": {"valid": 1, "pc": 0x4, "rd": 1, "reg_write": 1},
                       "if_id": {"valid": 1, "pc": 8, "instr": HALT_WORD}}, pc=0xC, cycles=3)
    a = analyze(cur, prev, None, BEQ)
    assert "se esperaba un flush" in of_kind(a, WARN)[0].text


# ---- sin programa conocido o con otro formato de latches ---------------------------------------

def test_sin_programa_conocido():
    # Conectado a una placa con un programa que no cargó esta PC: solo IF/ID trae la palabra
    r = model_run(SUMA_LW)
    a = analyze(model_snapshot(r, 7), model_snapshot(r, 6), None, None)
    view = {s.stage: s for s in a.stages}
    assert view["ID"].text == "add x5, x4, x1"
    assert view["MEM"].text == "?" and view["IF"].text == "?"
    assert of_kind(a, STALL)


def test_latches_con_otro_formato():
    from rvdebug.model import Snapshot
    from rvdebug.protocol import Latches, Status
    snap = Snapshot(Status(State.PAUSED, 1, 0, 0, 3), (0,) * 32,
                    Latches((0,) * 3, (0,) * 6, (0,) * 4, (0,) * 3), ())
    a = analyze(snap, None, None, SUMA_LW)
    assert kinds(a) == [WARN] and not a.stall_next
    assert [s.stage for s in a.stages] == ["IF", "ID", "EX", "MEM", "WB"]
