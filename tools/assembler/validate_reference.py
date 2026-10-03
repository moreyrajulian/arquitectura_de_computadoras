"""Valida rvasm contra un ensamblador RISC-V estandar (GNU as o LLVM).

Ensambla cada programa con rvasm y con el ensamblador estandar, y compara
palabra por palabra. Con --update guarda la salida del ensamblador estandar
en tests/reference/<programa>.hex, que es contra lo que comparan los tests
automaticos (asi los tests no necesitan el toolchain instalado).

Uso:
    python tools/assembler/validate_reference.py                 # programas de tests/programs
    python tools/assembler/validate_reference.py prog.s otro.s   # programas propios
    python tools/assembler/validate_reference.py --update        # regenera las referencias

Ensambladores que busca, en orden (el primero que encuentre):
    1. GNU:  riscv64-unknown-elf-as / riscv32-unknown-elf-as / riscv-none-elf-as (+ objcopy)
    2. LLVM: clang + llvm-objcopy
    3. LLVM empaquetado en zig: pip install ziglang  (python -m ziglang cc)
Se puede forzar uno con --tool gnu|clang|zig.

Diferencias de sintaxis que se adaptan antes de pasarle el programa al
ensamblador estandar (son extensiones de rvasm):
    halt  -> ebreak      (decision 001)
    //    -> #           (comentarios)
"""

import argparse
import importlib.util
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from rvasm import AssemblerError, assemble  # noqa: E402

PROGRAMS_DIR = HERE / "tests" / "programs"
REFERENCE_DIR = HERE / "tests" / "reference"


@dataclass
class Toolchain:
    name: str
    assemble_cmd: list[str]      # se le agregan: <entrada.s> -o <salida.o>
    objcopy_cmd: list[str]       # se le agregan: <entrada.o> <salida.bin>
    version: str


def _version(cmd: list[str]) -> str:
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        return (out.stdout or out.stderr).strip().splitlines()[0]
    except (OSError, IndexError, subprocess.TimeoutExpired):
        return "?"


def find_toolchain(forced: str | None = None) -> Toolchain | None:
    copy = ["-O", "binary", "--only-section=.text"]
    if forced in (None, "gnu"):
        for prefix in ("riscv64-unknown-elf-", "riscv32-unknown-elf-", "riscv-none-elf-"):
            gas, objcopy = shutil.which(prefix + "as"), shutil.which(prefix + "objcopy")
            if gas and objcopy:
                return Toolchain("GNU as",
                                 [gas, "-march=rv32i", "-mabi=ilp32", "-mno-relax"],
                                 [objcopy, *copy], _version([gas, "--version"]))
    if forced in (None, "clang"):
        clang, objcopy = shutil.which("clang"), shutil.which("llvm-objcopy")
        if clang and objcopy:
            return Toolchain("LLVM (clang)",
                             [clang, "--target=riscv32-unknown-elf", "-march=rv32i",
                              "-mno-relax", "-c"],
                             [objcopy, *copy], _version([clang, "--version"]))
    if forced in (None, "zig"):
        if importlib.util.find_spec("ziglang") is None:
            return None
        zig = [sys.executable, "-m", "ziglang"]
        # generic_rv32 = RV32I sin extensiones (sin C: no hay instrucciones comprimidas)
        return Toolchain("LLVM (zig cc)",
                         [*zig, "cc", "-target", "riscv32-freestanding-none",
                          "-mcpu=generic_rv32", "-mno-relax", "-c"],
                         [*zig, "objcopy", *copy], "zig " + _version([*zig, "version"]))
    return None


def to_portable(source: str) -> str:
    source = re.sub(r"\bhalt\b", "ebreak", source, flags=re.IGNORECASE)
    return source.replace("//", "#")


def assemble_standard(tool: Toolchain, source: str) -> list[int]:
    with tempfile.TemporaryDirectory() as tmp:
        src, obj, binf = Path(tmp, "prog.s"), Path(tmp, "prog.o"), Path(tmp, "prog.bin")
        src.write_text(to_portable(source), encoding="utf-8")
        for cmd in ([*tool.assemble_cmd, str(src), "-o", str(obj)],
                    [*tool.objcopy_cmd, str(obj), str(binf)]):
            res = subprocess.run(cmd, capture_output=True, text=True)
            if res.returncode != 0:
                raise RuntimeError(f"fallo '{Path(cmd[0]).name}':\n{res.stderr.strip()}")
        data = binf.read_bytes()
    if len(data) % 4:
        raise RuntimeError("la salida no es multiplo de 4 bytes (instrucciones comprimidas?)")
    return [int.from_bytes(data[i:i + 4], "little") for i in range(0, len(data), 4)]


def read_reference(path: Path) -> list[int]:
    words = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.split("//", 1)[0].strip()
        if line:
            words.append(int(line, 16))
    return words


def write_reference(path: Path, tool: Toolchain, program: Path, words: list[int]) -> None:
    header = (f"// Referencia generada por {tool.name} ({tool.version})\n"
              f"// desde tests/programs/{program.name} con validate_reference.py --update.\n"
              "// No editar a mano: es la fuente independiente contra la que se valida rvasm.\n")
    path.write_text(header + "".join(f"{w:08x}\n" for w in words), encoding="utf-8")


def compare(name: str, ours: list[int], theirs: list[int], source_map) -> bool:
    if ours == theirs:
        print(f"  OK   {name}: {len(ours)} palabras identicas")
        return True
    print(f"  FAIL {name}: rvasm {len(ours)} palabras, referencia {len(theirs)}")
    for i in range(max(len(ours), len(theirs))):
        a = ours[i] if i < len(ours) else None
        b = theirs[i] if i < len(theirs) else None
        if a != b:
            line_no, src = source_map.get(4 * i, (0, ""))
            fa = f"{a:08x}" if a is not None else "--------"
            fb = f"{b:08x}" if b is not None else "--------"
            print(f"       0x{4 * i:04x}: rvasm {fa}  ref {fb}   linea {line_no}: {src.strip()}")
    return False


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Valida rvasm contra un ensamblador estandar.")
    parser.add_argument("programs", nargs="*", type=Path,
                        help="programas .s (por defecto, todos los de tests/programs)")
    parser.add_argument("--update", action="store_true",
                        help="guarda la salida del ensamblador estandar en tests/reference")
    parser.add_argument("--tool", choices=("gnu", "clang", "zig"), help="fuerza el ensamblador")
    args = parser.parse_args(argv)

    tool = find_toolchain(args.tool)
    if tool is None:
        print("No se encontro un ensamblador RISC-V estandar. Opciones:\n"
              "  - pip install ziglang           (LLVM empaquetado, cualquier SO)\n"
              "  - apt install binutils-riscv64-unknown-elf\n"
              "  - clang + llvm-objcopy en el PATH", file=sys.stderr)
        return 2
    print(f"Ensamblador de referencia: {tool.name} - {tool.version}")

    programs = args.programs or sorted(PROGRAMS_DIR.glob("*.s"))
    ok = True
    for prog in programs:
        source = prog.read_text(encoding="utf-8")
        try:
            ours = assemble(source, str(prog))
        except AssemblerError as e:
            print(f"  FAIL {prog.name}: rvasm no lo ensambla\n{e}")
            ok = False
            continue
        try:
            theirs = assemble_standard(tool, source)
        except RuntimeError as e:
            print(f"  FAIL {prog.name}: {e}")
            ok = False
            continue
        ok &= compare(prog.name, ours.words, theirs, ours.source_map)
        if args.update:
            REFERENCE_DIR.mkdir(parents=True, exist_ok=True)
            write_reference(REFERENCE_DIR / f"{prog.stem}.hex", tool, prog, theirs)
            print(f"       referencia guardada en tests/reference/{prog.stem}.hex")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
