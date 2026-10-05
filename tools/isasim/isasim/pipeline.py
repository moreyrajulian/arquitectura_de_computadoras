"""Capa 2: el pipeline ciclo a ciclo (docs/spec/pipeline.md §3 a §10).

Calcula el contenido de los cuatro registros de segmentación en cada ciclo con las
fórmulas de pipeline.md: memorias sincrónicas (decisión 009), banco con bypass
(007), forwarding (§10.2), carga-uso conservadora (§10.3, decisión 011), saltos
resueltos en EX con flush (§10.5, decisión 012) y parada por HALT (§3.4, decisión
001).

Cada instrucción que llega a WB (y cada store en MEM) se compara con lo que dice la
capa 1 (isa.py). Si no coinciden, el modelo se detiene: en el modo completo es una
inconsistencia entre isa.md y pipeline.md; en un modo reducido, el programa
necesita un mecanismo que ese modo no tiene.
"""

import copy
from dataclasses import dataclass, field

from .isa import (
    HALT_WORD, IMEM_WORDS, DMEM_WORDS, MASK32, MEM_BYTES, OP_BRANCH, OP_I, OP_JAL,
    OP_JALR, OP_LOAD, OP_LUI, OP_R, OP_STORE, IsaSim, ModelError, alu_op, decode,
    field_, sext,
)
from .latches import LATCHES, Snapshot, bubble

# alu_ctrl = {instr[30], funct3} (pipeline.md §4.5)
ALU_CODES = {
    0b0000: "add", 0b1000: "sub", 0b0001: "sll", 0b0010: "slt", 0b0011: "sltu",
    0b0100: "xor", 0b0101: "srl", 0b1101: "sra", 0b0110: "or", 0b0111: "and",
}
CONTROL = ["alu_ctrl", "alu_src_a", "alu_src_b", "branch", "jal", "jalr",
           "mem_read", "mem_write", "reg_write", "mem_to_reg", "halt"]


@dataclass(frozen=True)
class Mode:
    """Mecanismos de riesgo presentes. El flush por HALT (§3.4) existe siempre."""

    forwarding: bool = True     # §10.2
    stall: bool = True          # §10.3
    flush: bool = True          # §10.5: flush de IF/ID e ID/EX por salto tomado

    @property
    def name(self):
        if self == COMPLETO:
            return "completo"
        if self == SIN_RIESGOS:
            return "sin_riesgos"
        off = [n for n in ("forwarding", "stall", "flush") if not getattr(self, n)]
        return "sin_" + "_".join(off)

    @property
    def missing(self):
        return [n for n in ("forwarding", "stall", "flush") if not getattr(self, n)]


COMPLETO = Mode()                                   # M8 en adelante
SIN_RIESGOS = Mode(False, False, False)             # M7 (I-38)


def control(word, valid):
    """Tabla de verdad de pipeline.md §4.4 ("x" se implementa como 0)."""
    c = dict.fromkeys(CONTROL, 0)
    if not valid:
        return c                                    # burbuja
    opcode, funct3, i30 = word & 0x7F, field_(word, 14, 12), field_(word, 30, 30)
    if word == HALT_WORD:
        c["halt"] = 1
    elif opcode == OP_R:
        c.update(alu_ctrl=(i30 << 3) | funct3, reg_write=1)
    elif opcode == OP_I:
        c.update(alu_ctrl=((i30 if funct3 == 0b101 else 0) << 3) | funct3,
                 alu_src_b=1, reg_write=1)
    elif opcode == OP_LOAD:
        c.update(alu_src_b=1, mem_read=1, reg_write=1, mem_to_reg=1)
    elif opcode == OP_STORE:
        c.update(alu_src_b=1, mem_write=1)
    elif opcode == OP_BRANCH:
        c.update(alu_ctrl=0b1000, branch=1)
    elif opcode == OP_JAL:
        c.update(jal=1, reg_write=1)
    elif opcode == OP_JALR:
        c.update(alu_src_b=1, jalr=1, reg_write=1)
    elif opcode == OP_LUI:
        c.update(alu_src_a=1, alu_src_b=1, reg_write=1)
    return c                                        # no reconocida: todo en 0


def imm_gen(word):
    """Generador de inmediatos (pipeline.md §4.3). Devuelve (inmediato, definido)."""
    opcode = word & 0x7F
    i = lambda hi, lo: field_(word, hi, lo)         # noqa: E731
    if opcode in (OP_I, OP_LOAD, OP_JALR):
        return sext(i(31, 20), 12), True
    if opcode == OP_STORE:
        return sext((i(31, 25) << 5) | i(11, 7), 12), True
    if opcode == OP_BRANCH:
        return sext((i(31, 31) << 12) | (i(7, 7) << 11) | (i(30, 25) << 5) | (i(11, 8) << 1), 13), True
    if opcode == OP_LUI:
        return word & 0xFFFF_F000, True
    if opcode == OP_JAL:
        return sext((i(31, 31) << 20) | (i(19, 12) << 12) | (i(20, 20) << 11) | (i(30, 21) << 1), 21), True
    # tipo R, HALT y no reconocidas: imm_sel = "x", el valor depende del RTL
    return sext(i(31, 20), 12), False


def load_extend(read_data, funct3, offset):
    """Extensión del load en WB (pipeline.md §7.1)."""
    byte = (read_data >> (8 * offset)) & 0xFF
    half = (read_data >> (16 * (offset >> 1))) & 0xFFFF
    return {
        0b000: sext(byte, 8), 0b001: sext(half, 16), 0b010: read_data,
        0b100: byte, 0b101: half,
    }.get(funct3, read_data)


def store_bytes(funct3, data, offset):
    """wdata y we[3:0] de un store (pipeline.md §6.2)."""
    if funct3 == 0b000:
        b = data & 0xFF
        return b * 0x0101_0101, 0b0001 << offset
    if funct3 == 0b001:
        h = data & 0xFFFF
        return h * 0x0001_0001, 0b0011 << (offset & 0b10)
    return data & MASK32, 0b1111


@dataclass
class RunResult:
    mode: Mode
    cycles: int                    # ciclos con enable = 1 hasta el HALT en WB inclusive
    halted: bool
    pc: int                        # pc_reg al final (campo pc del bloque de estado)
    regs: list
    dmem: list
    used: set
    imem_fault: bool
    dmem_oob: bool
    dmem_misaligned: bool
    snapshots: list                # Snapshot de cada ciclo 1..cycles y la foto final
    per_instr: dict                # latch -> lista de (ciclo, valores, imm_definido)
    effects: list                  # traza de la capa 1
    events: list = field(default_factory=list)

    @property
    def final(self):
        return self.snapshots[-1]

    @property
    def pipeline_empty(self):
        return all(self.final.values[l]["valid"] == 0 for l in LATCHES)


def simulate(imem, regs=None, dmem=None, mode=COMPLETO, max_cycles=100_000):
    """Corre las dos capas y devuelve el resultado del pipeline ya verificado."""
    isa = IsaSim(imem, regs, dmem, delay_slots=0 if mode.flush else 2)
    isa.run(max_instructions=max_cycles)
    return PipelineSim(imem, regs, dmem, mode, isa).run(max_cycles)


class PipelineSim:
    def __init__(self, imem, regs, dmem, mode, isa):
        if len(imem) != IMEM_WORDS:
            raise ModelError(f"la memoria de programa tiene que tener {IMEM_WORDS} palabras")
        self.imem = list(imem)
        self.regs = list(regs) if regs else [0] * 32
        self.regs[0] = 0
        self.dmem = list(dmem) if dmem else [0] * DMEM_WORDS
        self.mode = mode
        self.isa = isa
        self.effects = isa.effects

    # ---- comparación con la capa 1 -------------------------------------------------

    def _fail(self, cycle, msg):
        if self.mode == COMPLETO:
            why = ("inconsistencia entre isa.md (capa 1) y pipeline.md (capa 2): "
                   "revisar las dos especificaciones")
        else:
            m = self.mode.missing
            names = m[0] if len(m) == 1 else ", ".join(m[:-1]) + " ni " + m[-1]
            why = (f"el modo {self.mode.name} no tiene {names} y el programa lo necesita "
                   "(o no tiene `nop` suficientes)")
        raise ModelError(f"ciclo {cycle}: {msg}. Causa probable: {why}")

    def _check_wb(self, cycle, k, mw, wb_data):
        if k >= len(self.effects):
            self._fail(cycle, f"llegó a WB una instrucción de más (pc 0x{mw['pc']:08X})")
        eff = self.effects[k]
        if mw["pc"] != eff.pc:
            self._fail(cycle, f"llegó a WB la instrucción de pc 0x{mw['pc']:08X} y según la "
                              f"ISA tocaba la de pc 0x{eff.pc:08X} ({eff.instr})")
        writes = mw["reg_write"] and mw["rd"] != 0
        got = (mw["rd"], wb_data) if writes else None
        if got != eff.reg_write:
            fmt = lambda w: "nada" if w is None else f"x{w[0]} = 0x{w[1]:08X}"   # noqa: E731
            self._fail(cycle, f"pc 0x{eff.pc:08X} ({eff.instr}) escribe {fmt(got)} y según "
                              f"la ISA escribe {fmt(eff.reg_write)}")

    def _check_mem(self, cycle, k, em, idx, new_word):
        if k >= len(self.effects):
            self._fail(cycle, f"llegó a MEM una instrucción de más (pc 0x{em['pc']:08X})")
        eff = self.effects[k]
        if eff.pc != em["pc"]:
            return                                   # lo informa la comparación en WB
        if eff.mem_addr is not None and eff.mem_addr != em["result"]:
            self._fail(cycle, f"pc 0x{eff.pc:08X} ({eff.instr}) accede a 0x{em['result']:08X} "
                              f"y según la ISA a 0x{eff.mem_addr:08X}")
        got = (idx, new_word) if em["mem_write"] else None
        if got != eff.store:
            fmt = lambda s: "nada" if s is None else f"dmem[0x{4 * s[0]:03X}] = 0x{s[1]:08X}"  # noqa: E731
            self._fail(cycle, f"pc 0x{eff.pc:08X} ({eff.instr}) deja {fmt(got)} y según la "
                              f"ISA deja {fmt(eff.store)}")

    # ---- simulación ------------------------------------------------------------------

    def run(self, max_cycles):
        mode = self.mode
        L = {name: bubble(name) for name in LATCHES}     # reset: todo burbuja
        imm_def = True                                   # inmediato definido en ID/EX
        pc = 0
        halted = imem_fault = dmem_oob = dmem_mis = False
        used = set()
        snapshots, per_instr = [], {name: [] for name in LATCHES}
        k_wb = k_mem = 0
        cycle = 0
        finished = False

        while cycle < max_cycles:
            cycle += 1
            events = []
            snapshots.append(Snapshot(cycle, copy.deepcopy(L), imm_def, events))
            fi, de, em, mw = L["if_id"], L["id_ex"], L["ex_mem"], L["mem_wb"]

            # WB (§7): valor final
            load_val = load_extend(mw["read_data"], mw["funct3"], mw["offset"])
            wb_data = load_val if mw["mem_to_reg"] else mw["result"]
            wb_we, wb_rd = mw["reg_write"], mw["rd"]

            # ID (§4): campos, banco con bypass, inmediato y control
            word, v = fi["instr"], fi["valid"]
            ctrl = control(word, v)
            rs1f, rs2f = field_(word, 19, 15), field_(word, 24, 20)

            def read(r):
                if r == 0:
                    return 0
                return wb_data if (wb_we and wb_rd == r) else self.regs[r]

            imm, imm_ok = imm_gen(word)

            # EX (§5): forwarding, ALU, saltos y resultado
            def forward(rsf, data):
                if mode.forwarding:
                    if em["reg_write"] and em["rd"] != 0 and em["rd"] == rsf:
                        return em["result"]
                    if mw["reg_write"] and mw["rd"] != 0 and mw["rd"] == rsf:
                        return wb_data
                return data

            rs1_val = forward(de["rs1"], de["rs1_data"])
            rs2_val = forward(de["rs2"], de["rs2_data"])
            a = 0 if de["alu_src_a"] else rs1_val
            b = de["imm"] if de["alu_src_b"] else rs2_val
            op = ALU_CODES.get(de["alu_ctrl"])
            if op is None:
                raise ModelError(f"ciclo {cycle}: alu_ctrl {de['alu_ctrl']:04b} no definido")
            alu_out = alu_op(op, a, b)
            zero = int(alu_out == 0)
            taken = de["branch"] and (zero ^ (de["funct3"] & 1))
            redirect = bool(taken or de["jal"] or de["jalr"])
            redirect_pc = (alu_out & ~1 & MASK32) if de["jalr"] else (de["pc"] + de["imm"]) & MASK32
            result = (de["pc"] + 4) & MASK32 if (de["jal"] or de["jalr"]) else alu_out

            # MEM (§6): lectura READ_FIRST (memoria.md §3.2) y escritura por bytes
            addr = em["result"]
            idx, offset = (addr >> 2) % DMEM_WORDS, addr & 0b11
            read_word = self.dmem[idx]
            new_word = read_word
            if em["mem_write"]:
                wdata, we = store_bytes(em["funct3"], em["store_data"], offset)
                for i in range(4):
                    if we >> i & 1:
                        new_word = (new_word & ~(0xFF << 8 * i) & MASK32) | (wdata & (0xFF << 8 * i))
            mem_access = em["mem_write"] or em["mem_to_reg"]
            size = em["funct3"] & 0b11
            if mem_access and addr >= MEM_BYTES:
                dmem_oob = True
            if mem_access and ((size == 0b01 and addr & 1) or (size == 0b10 and addr & 0b11)):
                dmem_mis = True

            # Riesgos y control del pipeline (§3.4, §10.3, §10.4)
            load_use = bool(mode.stall and de["mem_read"] and de["rd"] != 0 and v
                            and (de["rd"] == rs1f or de["rd"] == rs2f))
            stall = load_use and not redirect
            stop_fetch = bool(ctrl["halt"] or de["halt"] or em["halt"] or mw["halt"] or halted)
            flush_if_id = (redirect and mode.flush) or stop_fetch
            flush_id_ex = (redirect and mode.flush) or stall
            en_fetch = not stall                     # en_pc = en_if_id
            if redirect:
                pc_next = redirect_pc
            elif stop_fetch:
                pc_next = pc
            else:
                pc_next = (pc + 4) & MASK32

            for flag, text in ((stall, "stall"), (redirect, f"redirect a 0x{redirect_pc:08X}"),
                               (stop_fetch, "stop_fetch")):
                if flag:
                    events.append(text)

            # Comparación con la capa 1
            if em["valid"]:
                self._check_mem(cycle, k_mem, em, idx, new_word)
                k_mem += 1
            if mw["valid"]:
                self._check_wb(cycle, k_wb, mw, wb_data)
                k_wb += 1
                if wb_we and wb_rd:
                    events.append(f"x{wb_rd} <- 0x{wb_data:08X}")
            finished = bool(mw["valid"] and mw["halt"])

            # Flanco: se cargan los registros (prioridad rst > en > flush, §2)
            new = {}
            if en_fetch:
                new["if_id"] = {"valid": int(not flush_if_id), "pc": pc,
                                "instr": self.imem[(pc >> 2) % IMEM_WORDS]}
            else:
                new["if_id"] = fi
            id_values = {"valid": int(v), "pc": fi["pc"], "rs1_data": read(rs1f),
                         "rs2_data": read(rs2f), "imm": imm, "rs1": rs1f, "rs2": rs2f,
                         "rd": field_(word, 11, 7), "funct3": field_(word, 14, 12), **ctrl}
            if flush_id_ex:                          # burbuja: valid y control en 0
                id_values.update(dict.fromkeys(CONTROL, 0), valid=0)
            new["id_ex"] = id_values
            new["ex_mem"] = {"valid": de["valid"], "pc": de["pc"], "result": result,
                             "store_data": rs2_val, "rd": de["rd"], "funct3": de["funct3"],
                             "mem_write": de["mem_write"], "reg_write": de["reg_write"],
                             "mem_to_reg": de["mem_to_reg"], "halt": de["halt"]}
            new["mem_wb"] = {"valid": em["valid"], "pc": em["pc"], "result": em["result"],
                             "read_data": read_word, "rd": em["rd"], "funct3": em["funct3"],
                             "offset": offset, "reg_write": em["reg_write"],
                             "mem_to_reg": em["mem_to_reg"], "halt": em["halt"]}

            if em["mem_write"]:
                self.dmem[idx] = new_word
                used.add(idx)
            if wb_we and wb_rd != 0:
                self.regs[wb_rd] = wb_data
            if mw["valid"] and mw["halt"]:
                halted = True
            if mw["valid"] and (mw["pc"] >= MEM_BYTES or mw["pc"] & 0b11):
                imem_fault = True
            if en_fetch:
                pc = pc_next

            loaded = {"if_id": en_fetch, "id_ex": True, "ex_mem": True, "mem_wb": True}
            new_imm_def = imm_ok
            for name in LATCHES:
                if loaded[name] and new[name]["valid"]:
                    per_instr[name].append(
                        (cycle + 1, dict(new[name]), new_imm_def if name == "id_ex" else True))
            L, imm_def = new, new_imm_def

            if finished:
                break

        snapshots.append(Snapshot(cycle + 1, copy.deepcopy(L), imm_def, ["foto final"]))
        result = RunResult(mode, cycle, halted, pc, self.regs, self.dmem, used,
                           imem_fault, dmem_oob, dmem_mis, snapshots, per_instr, self.effects)
        self._check_final(result)
        return result

    def _check_final(self, r):
        s = self.isa.state
        if not r.halted:
            return                                   # sin HALT: solo hasta donde se ejecutó
        if r.regs != s.regs:
            diff = [i for i in range(32) if r.regs[i] != s.regs[i]]
            self._fail(r.cycles, f"registros finales distintos de la ISA: {diff}")
        if r.dmem != s.dmem:
            self._fail(r.cycles, "memoria de datos final distinta de la ISA")
        if (r.imem_fault, r.dmem_oob, r.dmem_misaligned) != (
                s.imem_fault, s.dmem_oob, s.dmem_misaligned):
            self._fail(r.cycles, "avisos de acceso distintos de la ISA")
        if r.used != s.used:
            self._fail(r.cycles, "mapa de palabras usadas distinto de la ISA")
