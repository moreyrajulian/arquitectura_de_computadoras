"""Validacion contra un ensamblador RISC-V estandar.

tests/reference/*.hex lo genero LLVM con validate_reference.py --update, a
partir de tests/programs/*.s. Este test compara rvasm contra esos archivos,
asi que no necesita el toolchain. Si hay un ensamblador estandar instalado,
ademas se compara en vivo.
"""

import re

import pytest
from conftest import ASSEMBLER_DIR

from rvasm import assemble

PROGRAMS = sorted((ASSEMBLER_DIR / "tests" / "programs").glob("*.s"))
REFERENCE_DIR = ASSEMBLER_DIR / "tests" / "reference"


def _validate_module():
    import validate_reference
    return validate_reference


@pytest.mark.parametrize("program", PROGRAMS, ids=[p.name for p in PROGRAMS])
def test_matches_standard_assembler_reference(program):
    ref = REFERENCE_DIR / f"{program.stem}.hex"
    assert ref.exists(), f"falta {ref.name}: correr validate_reference.py --update"
    expected = _validate_module().read_reference(ref)
    ours = assemble(program.read_text(encoding="utf-8"), program.name)
    assert ours.words == expected


def test_reference_covers_every_instruction():
    """isa_completo.s tiene que usar todas las instrucciones y pseudos soportadas."""
    from rvasm.isa import INSTRUCTIONS, PSEUDO_INSTRUCTIONS
    text = (ASSEMBLER_DIR / "tests" / "programs" / "isa_completo.s").read_text(encoding="utf-8")
    used = set()
    for line in text.splitlines():
        stmt = re.sub(r"^\s*([\w.$]+\s*:\s*)*", "", line.split("#")[0]).strip()
        if stmt:
            used.add(stmt.split()[0].lower())
    # ebreak es la misma palabra que halt
    missing = (set(INSTRUCTIONS) - {"ebreak"}) | set(PSEUDO_INSTRUCTIONS)
    assert not missing - used


@pytest.mark.parametrize("program", PROGRAMS, ids=[p.name for p in PROGRAMS])
def test_live_against_installed_toolchain(program):
    vr = _validate_module()
    tool = vr.find_toolchain()
    if tool is None:
        pytest.skip("no hay ensamblador RISC-V estandar instalado (ver README)")
    source = program.read_text(encoding="utf-8")
    assert assemble(source, program.name).words == vr.assemble_standard(tool, source)
