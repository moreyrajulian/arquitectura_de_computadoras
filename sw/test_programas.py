"""Chequeos de los programas de prueba de sw/ que no necesitan ejecutarlos.

Correr desde la raiz del repo:  python -m pytest sw

No verifican los valores de los .exp: eso lo hace el modelo de referencia
(I-16), que tiene que coincidir con todos (verificacion.md 2). Verifican las
convenciones de sw/README.md: que cada programa ensamble y tenga su .exp, que
el .exp tenga el formato de verificacion.md 5, que esten todos los programas del
plan, que entre todos aparezca cada instruccion del ISA y que los indep_ sean
de verdad independientes.
"""

import re
import sys
from pathlib import Path

import pytest

SW = Path(__file__).resolve().parent
sys.path.insert(0, str(SW.parent / "tools" / "assembler"))

from rvasm import assemble, classify  # noqa: E402
from rvasm.isa import HALT_WORD, INSTRUCTIONS  # noqa: E402

from programas import (FORWARDING, FORWARDING_STALL, INDEP, NOPS, PLAN, PROGRAMS,  # noqa: E402
                       SIN_RIESGOS, SOLO_FORWARDING, SOLO_M8, SOLO_STALL,
                       SOLO_TRAZA_FORWARDING, SOLO_TRAZA_FORWARDING_STALL)

AVISOS = {"imem_fault", "dmem_oob", "dmem_misaligned"}

# Las 33 instrucciones de isa.md (ebreak es otro nombre de halt)
ISA = set(INSTRUCTIONS) - {"ebreak"}


def program(name):
    return assemble((SW / f"{name}.s").read_text(encoding="utf-8"), f"{name}.s")


def parse_exp(text):
    """Devuelve los campos del .exp; falla si una linea no tiene el formato."""
    fields, section = {"regs": {}, "dmem": {}}, None
    for raw in text.splitlines():
        line = raw.split("#")[0].rstrip()
        if not line:
            continue
        if line in ("regs:", "dmem:"):
            section = line[:-1]
            continue
        m = re.fullmatch(r"\s+x(\d+)\s*=\s*0x([0-9A-F]{8})", line)
        if m and section == "regs":
            fields["regs"][int(m[1])] = int(m[2], 16)
            continue
        m = re.fullmatch(r"\s+0x([0-9A-F]{3})\s*=\s*0x([0-9A-F]{8})", line)
        if m and section == "dmem":
            fields["dmem"][int(m[1], 16)] = int(m[2], 16)
            continue
        m = re.fullmatch(r"(halted|pipeline_vacio|avisos|ciclos)\s*=\s*(.+)", line)
        if m:
            fields[m[1]] = m[2].strip()
            section = None
            continue
        raise AssertionError(f"linea con formato desconocido: {raw!r}")
    return fields


@pytest.mark.parametrize("name", PROGRAMS)
def test_assembles_without_warnings(name):
    prog = program(name)
    assert not prog.warnings, prog.warnings
    assert HALT_WORD in prog.words


@pytest.mark.parametrize("name", PROGRAMS)
def test_has_expected_state(name):
    exp = SW / f"{name}.exp"
    assert exp.exists(), f"falta {exp.name}: un programa sin .exp no es una prueba"
    fields = parse_exp(exp.read_text(encoding="utf-8"))
    assert fields.get("halted") == "1"
    assert fields.get("pipeline_vacio") == "1"
    assert fields.get("ciclos", "").isdigit()
    avisos = fields.get("avisos", "")
    assert avisos == "ninguno" or {a.strip() for a in avisos.split(",")} <= AVISOS
    assert all(1 <= r <= 31 for r in fields["regs"])
    assert all(a % 4 == 0 and a < 0x1000 for a in fields["dmem"])


def test_no_orphan_expected_state():
    orphans = sorted(p.stem for p in SW.glob("*.exp") if p.stem not in PROGRAMS)
    assert not orphans


def test_plan_programs_exist():
    assert not sorted(set(PLAN + INDEP) - set(PROGRAMS))


def test_nops_variants_exist():
    assert not sorted(f"{n}_nops" for n in NOPS if f"{n}_nops" not in PROGRAMS)
    assert not sorted(n for n in PROGRAMS if n.endswith("_nops") and n[:-5] not in PROGRAMS)
    # Una variante que no esta en NOPS quedaria afuera de SIN_RIESGOS sin avisar
    assert not sorted(n for n in PROGRAMS if n.endswith("_nops") and n[:-5] not in NOPS)


def test_m7_programs():
    """verificacion.md 4.3: los solo de M8 son del plan y no tienen variante _nops."""
    assert not sorted(set(SOLO_M8) - set(PLAN))
    assert not sorted(n for n in SOLO_M8 if f"{n}_nops" in PROGRAMS)
    assert not sorted(set(SIN_RIESGOS) - set(PROGRAMS))


def test_forwarding_programs():
    """Decision 029: los que suma el modo forwarding son originales con variante _nops."""
    assert not sorted(set(SOLO_FORWARDING) - set(NOPS))
    assert not sorted(set(FORWARDING) - set(PROGRAMS))
    assert len(FORWARDING) == len(set(FORWARDING))


def test_trace_only_forwarding_programs():
    """verificacion.md 8.2: los que corren sin +FINAL son originales que no estan en FORWARDING."""
    assert not sorted(set(SOLO_TRAZA_FORWARDING) - set(NOPS))
    assert not sorted(set(SOLO_TRAZA_FORWARDING) & set(FORWARDING))


def test_forwarding_stall_programs():
    """Decision 029 (I-41): el stall suma originales del plan que no estaban en FORWARDING."""
    assert not sorted(set(SOLO_STALL) - set(NOPS + SOLO_M8))
    assert not sorted(set(SOLO_STALL) & set(FORWARDING))
    assert not sorted(set(FORWARDING) - set(FORWARDING_STALL))
    assert len(FORWARDING_STALL) == len(set(FORWARDING_STALL))


def test_trace_only_forwarding_stall_programs():
    """Decision 030: los que corren sin +FINAL con el stall no estan en FORWARDING_STALL."""
    assert not sorted(set(SOLO_TRAZA_FORWARDING_STALL) - set(NOPS))
    assert not sorted(set(SOLO_TRAZA_FORWARDING_STALL) & set(FORWARDING_STALL))


def test_every_instruction_is_covered():
    """verificacion.md 4: toda instruccion de isa.md aparece en algun programa."""
    used = {classify(w).name for name in PLAN for w in program(name).words}
    assert not sorted(ISA - used)


def test_every_group_is_covered_by_independent_programs():
    used = {classify(w).name for name in INDEP for w in program(name).words}
    assert not sorted(ISA - used - {"halt"})


@pytest.mark.parametrize("name", INDEP)
def test_independent_programs_do_not_read_written_registers(name):
    """Ninguna instruccion lee un registro que escribe otra (issue I-15)."""
    written, read = set(), set()
    for word in program(name).words:
        spec = INSTRUCTIONS.get(classify(word).name)
        if spec is None:
            continue
        rd, rs1, rs2 = (word >> 7) & 31, (word >> 15) & 31, (word >> 20) & 31
        if spec.form in ("R", "I", "SHIFT", "LOAD", "JALR", "U", "J"):
            written.add(rd)
        if spec.form in ("R", "S", "B"):
            read |= {rs1, rs2}
        elif spec.form in ("I", "SHIFT", "LOAD", "JALR"):
            read.add(rs1)
    assert not sorted((written & read) - {0})
    assert all(r >= 11 for r in written - {0}), "los indep_ escriben x11-x31"
