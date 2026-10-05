"""Archivos de entrada y salida del modelo.

Entrada:
- programa: `.s` (se ensambla con rvasm, tools/assembler) o `.hex` (salida de
  `asm.py`, una palabra por línea); la memoria se completa con HALT, como `LOAD`;
- estado inicial (`sw/estado_inicial/regs.hex` y `dmem.hex`, decisión 019 de
  programas de prueba): formato `$readmemh` con `@índice` y comentarios `//`.

Salida (verificacion.md §5 y protocolo_debug.md §3):
- estado final en el formato del `.exp`;
- volcado binario con el formato del payload de `READ_ALL`;
- traza por ciclo y por instrucción, un archivo `$readmemh` por latch, con su máscara.
"""

import re
import struct
import sys
from pathlib import Path

from .isa import DMEM_WORDS, HALT_WORD, IMEM_WORDS, MASK32, ModelError
from .latches import LATCHES, LAYOUT, TITLES, WORDS, compare_mask, hex_digits, pack, to_words

TOOLS = Path(__file__).resolve().parents[2]          # tools/
AVISOS = ("imem_fault", "dmem_oob", "dmem_misaligned")


# ---- entrada ------------------------------------------------------------------------

def read_memh(path, size, default=0):
    """Lee un archivo en formato `$readmemh` (valores hex, `@índice`, comentarios //).
    Lo que no aparece vale `default` (0 para el estado inicial, igual que en el
    testbench, que pone todo en cero antes de leerlo)."""
    mem, index = [default] * size, 0
    for n, raw in enumerate(Path(path).read_text(encoding="utf-8").splitlines(), 1):
        line = raw.split("//")[0].strip()
        for tok in line.split():
            tok = tok.replace("_", "")
            if tok.startswith("@"):
                index = int(tok[1:], 16)
                continue
            if not re.fullmatch(r"[0-9A-Fa-f]{1,8}", tok):
                raise ModelError(f"{path}:{n}: valor hex inválido {tok!r}")
            if index >= size:
                raise ModelError(f"{path}:{n}: índice 0x{index:X} fuera de rango (máximo {size - 1})")
            mem[index] = int(tok, 16)
            index += 1
    return mem


def load_program(path):
    """Devuelve las 1024 palabras de imem (rellenas con HALT, como después de LOAD)."""
    path = Path(path)
    if path.suffix == ".s":
        sys.path.insert(0, str(TOOLS / "assembler"))
        from rvasm import AssemblerError, assemble        # el ensamblador del proyecto
        try:
            words = assemble(path.read_text(encoding="utf-8"), path.name).words
        except AssemblerError as e:
            msgs = "; ".join(f"{d.line}: {d.message}" for d in e.errors)
            raise ModelError(f"{path.name} no ensambla: {msgs}") from e
    elif path.suffix == ".hex":
        # lo que el archivo no nombra queda en HALT, como deja imem un LOAD
        return read_memh(path, IMEM_WORDS, default=HALT_WORD)
    else:
        raise ModelError(f"{path.name}: se espera un .s o un .hex")
    if len(words) > IMEM_WORDS:
        raise ModelError(f"{path.name}: {len(words)} palabras, el máximo es {IMEM_WORDS}")
    return list(words) + [HALT_WORD] * (IMEM_WORDS - len(words))


def load_initial_state(directory):
    """regs.hex y dmem.hex de un directorio de estado inicial (los que falten valen 0)."""
    d = Path(directory)
    regs = read_memh(d / "regs.hex", 32) if (d / "regs.hex").exists() else [0] * 32
    dmem = read_memh(d / "dmem.hex", DMEM_WORDS) if (d / "dmem.hex").exists() else [0] * DMEM_WORDS
    if regs[0]:
        raise ModelError(f"{d / 'regs.hex'}: x0 no se puede inicializar")
    return regs, dmem


def default_initial_state(program):
    """Convención de sw/README.md §2: los programas indep_* parten de estado_inicial/."""
    p = Path(program)
    if p.stem.startswith("indep_"):
        return p.parent / "estado_inicial"
    return None


# ---- .exp ---------------------------------------------------------------------------

def parse_exp(text):
    """Lee un .exp (verificacion.md §5). Registros y memoria no listados valen 0."""
    out, section = {"regs": {}, "dmem": {}}, None
    for n, raw in enumerate(text.splitlines(), 1):
        line = raw.split("#")[0].rstrip()
        if not line.strip():
            continue
        if line.strip() in ("regs:", "dmem:"):
            section = line.strip()[:-1]
            continue
        m = re.fullmatch(r"\s+x(\d+)\s*=\s*0x([0-9A-Fa-f]{8})", line)
        if m and section == "regs":
            out["regs"][int(m[1])] = int(m[2], 16)
            continue
        m = re.fullmatch(r"\s+0x([0-9A-Fa-f]{1,3})\s*=\s*0x([0-9A-Fa-f]{8})", line)
        if m and section == "dmem":
            out["dmem"][int(m[1], 16)] = int(m[2], 16)
            continue
        m = re.fullmatch(r"(halted|pipeline_vacio|avisos|ciclos)\s*=\s*(.+)", line.strip())
        if m:
            out[m[1]] = m[2].strip()
            section = None
            continue
        raise ModelError(f"línea {n} del .exp con formato desconocido: {raw!r}")
    return out


def avisos_text(r):
    on = [name for name in AVISOS if getattr(r, name)]
    return ", ".join(on) if on else "ninguno"


def format_exp(r, name="programa"):
    """Estado final en el formato del .exp (solo lo distinto de cero)."""
    lines = [f"# {name}: estado final según el modelo de referencia (modo {r.mode.name})",
             "regs:"]
    lines += [f"  x{i:<2} = 0x{v:08X}" for i, v in enumerate(r.regs) if i and v]
    lines.append("dmem:")
    lines += [f"  0x{4 * i:03X} = 0x{v:08X}" for i, v in enumerate(r.dmem) if v]
    lines += [f"halted = {int(r.halted)}",
              f"pipeline_vacio = {int(r.pipeline_empty)}",
              f"avisos = {avisos_text(r)}",
              f"ciclos = {r.cycles}"]
    return "\n".join(lines) + "\n"


def compare_exp(r, exp):
    """Diferencias entre el resultado y un .exp parseado (lista vacía = coinciden)."""
    diffs = []
    for i in range(1, 32):
        want = exp["regs"].get(i, 0)
        if r.regs[i] != want:
            diffs.append(f"x{i}: modelo 0x{r.regs[i]:08X}, .exp 0x{want:08X}")
    for i in range(DMEM_WORDS):
        want = exp["dmem"].get(4 * i, 0)
        if r.dmem[i] != want:
            diffs.append(f"dmem[0x{4 * i:03X}]: modelo 0x{r.dmem[i]:08X}, .exp 0x{want:08X}")
    for key, got in (("halted", str(int(r.halted))),
                     ("pipeline_vacio", str(int(r.pipeline_empty))),
                     ("ciclos", str(r.cycles))):
        if key in exp and exp[key] != got:
            diffs.append(f"{key}: modelo {got}, .exp {exp[key]}")
    if "avisos" in exp:
        want = {a.strip() for a in exp["avisos"].split(",")} - {"ninguno"}
        got = {a for a in AVISOS if getattr(r, a)}
        if want != got:
            diffs.append(f"avisos: modelo {sorted(got) or 'ninguno'}, .exp {sorted(want) or 'ninguno'}")
    return diffs


# ---- volcado (READ_ALL) ---------------------------------------------------------------

def read_all_payload(r):
    """Payload de READ_ALL (protocolo_debug.md §3.1 y §3.6), little-endian."""
    flags = 1 | (r.halted << 1) | (r.imem_fault << 2) | (r.dmem_oob << 3) | (r.dmem_misaligned << 4)
    state = 4 if r.halted else 3                 # HALTED, o PAUSED si se cortó por ciclos
    out = struct.pack("<BBHII", state, flags, len(r.used), r.pc, r.cycles)
    out += struct.pack("<32I", *r.regs)
    for name in LATCHES:
        out += struct.pack(f"<{WORDS[name]}I", *to_words(name, r.final.packed(name)))
    for i in sorted(r.used):
        out += struct.pack("<II", 4 * i, r.dmem[i])
    return out


# ---- trazas -------------------------------------------------------------------------

def _hex_line(latch, number):
    return f"{number:0{hex_digits(latch)}X}"


def write_outputs(r, outdir, name):
    """Escribe en outdir/: estado (.exp), volcado, traza por ciclo y por instrucción."""
    out = Path(outdir)
    out.mkdir(parents=True, exist_ok=True)
    (out / f"{name}.exp").write_text(format_exp(r, name), encoding="utf-8")
    (out / f"{name}.read_all.bin").write_bytes(read_all_payload(r))
    for latch in LATCHES:
        rows = r.snapshots                               # ciclos 1..N más la foto final
        (out / f"{name}.ciclo.{latch}.hex").write_text(
            "".join(_hex_line(latch, s.packed(latch)) + "\n" for s in rows), encoding="utf-8")
        (out / f"{name}.ciclo.{latch}.mask.hex").write_text(
            "".join(_hex_line(latch, s.mask(latch)) + "\n" for s in rows), encoding="utf-8")
        inst = r.per_instr[latch]
        (out / f"{name}.instr.{latch}.hex").write_text(
            "".join(_hex_line(latch, pack(latch, v)) + "\n" for _, v, _ in inst), encoding="utf-8")
        (out / f"{name}.instr.{latch}.mask.hex").write_text(
            "".join(_hex_line(latch, compare_mask(latch, v, d)) + "\n" for _, v, d in inst),
            encoding="utf-8")
    (out / f"{name}.traza.txt").write_text(format_trace(r), encoding="utf-8")
    return out


def _describe(latch, v):
    if not v["valid"]:
        return "--"
    from .isa import decode, disassemble
    if latch == "if_id":
        try:
            return f"{v['pc']:04X} {disassemble(decode(v['instr']))}"
        except ModelError:
            return f"{v['pc']:04X} .word 0x{v['instr']:08X}"
    return f"{v['pc']:04X}"


def format_trace(r):
    """Traza legible: qué instrucción hay en cada latch en cada ciclo."""
    w = 30
    head = f"{'ciclo':>5} | " + " | ".join(f"{TITLES[l]:<{w if l == 'if_id' else 6}}" for l in LATCHES)
    lines = [f"# modo {r.mode.name}; {r.cycles} ciclos; el pc indica la instrucción en cada latch",
             head, "-" * len(head)]
    for s in r.snapshots:
        cells = [f"{_describe(l, s.values[l]):<{w if l == 'if_id' else 6}}" for l in LATCHES]
        lines.append(f"{s.cycle:>5} | " + " | ".join(cells) + ("   " + "; ".join(s.events) if s.events else ""))
    lines.append("")
    lines.append("Campos de cada latch (pipeline.md §8), primero el bit más alto:")
    for l in LATCHES:
        lines.append(f"  {TITLES[l]} ({sum(x[1] for x in LAYOUT[l])} bits): "
                     + ", ".join(f"{n}[{wd}]" for n, wd, _ in LAYOUT[l]))
    return "\n".join(lines) + "\n"
