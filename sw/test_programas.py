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

from rvasm import assemble  # noqa: E402
from rvasm.isa import HALT_WORD, INSTRUCTIONS  # noqa: E402

PROGRAMS = sorted(p.stem for p in SW.glob("*.s"))

# verificacion.md 4.1 y 4.2: los 22 programas del plan
PLAN = [
    "alu_r", "alu_i", "shifts", "lui", "mem_palabra", "mem_byte_media",
    "branch_cond", "jump", "halt_basico", "mem_avisos",
    "fwd_exmem", "fwd_memwb", "fwd_prioridad", "fwd_x0", "bypass_banco",
    "loaduse_rs1_rs2", "loaduse_sw_beq", "load_sin_dep", "salto_depende",
    "halt_stall", "halt_camino_equivocado", "mixto_lazo",
]
# La issue I-15: un programa independiente por grupo de instrucciones
INDEP = ["indep_alu_r", "indep_alu_i", "indep_cargas", "indep_stores",
         "indep_saltos", "indep_lui"]
# Programas de riesgos y de saltos que no corren sin forwarding, stall o flush
NOPS = ["fwd_exmem", "fwd_memwb", "fwd_prioridad", "loaduse_rs1_rs2",
        "loaduse_sw_beq", "load_sin_dep", "branch_cond", "jump",
        "salto_depende", "mixto_lazo"]

AVISOS = {"imem_fault", "dmem_oob", "dmem_misaligned"}

# Las 33 instrucciones de isa.md (ebreak es otro nombre de halt)
ISA = set(INSTRUCTIONS) - {"ebreak"}


def program(name):
    return assemble((SW / f"{name}.s").read_text(encoding="utf-8"), f"{name}.s")


def mnemonic(word):
    """Nombre de la instruccion de isa.md que codifica la palabra."""
    if word == HALT_WORD:
        return "halt"
    opcode, funct3, funct7 = word & 0x7F, (word >> 12) & 7, word >> 25
    for name, spec in INSTRUCTIONS.items():
        if spec.opcode != opcode:
            continue
        if spec.form in ("U", "J"):
            return name
        if spec.funct3 != funct3:
            continue
        if spec.form in ("R", "SHIFT") and spec.funct7 != funct7:
            continue
        return name
    return None


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


def test_every_instruction_is_covered():
    """verificacion.md 4: toda instruccion de isa.md aparece en algun programa."""
    used = {mnemonic(w) for name in PLAN for w in program(name).words}
    assert not sorted(ISA - used)


def test_every_group_is_covered_by_independent_programs():
    used = {mnemonic(w) for name in INDEP for w in program(name).words}
    assert not sorted(ISA - used - {"halt"})


@pytest.mark.parametrize("name", INDEP)
def test_independent_programs_do_not_read_written_registers(name):
    """Ninguna instruccion lee un registro que escribe otra (issue I-15)."""
    written, read = set(), set()
    for word in program(name).words:
        spec = INSTRUCTIONS.get(mnemonic(word))
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
