"""Capa `model`: qué hace el pipeline en un volcado (docs/spec/interfaz_pc.md §4.2 y §4.3,
decisión 043). Python puro, sin Textual.

La Debug Unit no informa stalls, forwarding ni saltos: la PC los **deduce** de los campos
de los latches con las mismas ecuaciones de pipeline.md §10 y la resolución de saltos de
§5.3 (decisión 012). Hay dos tipos de deducción:

- **Lo que pasa en este ciclo**, de un solo volcado: forwarding hacia EX, si el próximo
  flanco frena IF e ID (load-use), si el salto en EX se toma y si hay un HALT en vuelo.
- **Lo que ya pasó**, también de un solo volcado: un load en MEM con una burbuja en EX y la
  instrucción que lo usa en ID es un stall; un salto en MEM con IF/ID e ID/EX en burbuja es
  un flush. Así se ve también después de Paso×N, sin el volcado del ciclo anterior.

Con el volcado del ciclo anterior se comparan las dos: si lo previsto no ocurrió (o algo se
retuvo sin un load-use) se informa una inconsistencia, que es una pista de un error en la
unidad de riesgos.

La instrucción de cada etapa sale del `pc` de su latch y de las palabras que se mandaron con
LOAD (`word_at`): solo IF/ID lleva la palabra (pipeline.md §8). La de IF/ID se compara con
la cargada.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from isasim.isa import MASK32, ModelError, alu_op, decode, field_
from isasim.pipeline import ALU_CODES, load_extend

from rvasm import disassemble

from .model import HALT_WORD, IMEM_WORDS, Snapshot, fmt_dec, word_at
from .protocol import State

STAGES = ("IF", "ID", "EX", "MEM", "WB")
# Latch que tiene la instrucción que procesa cada etapa (interfaz_pc.md §4.2)
STAGE_LATCH = {"ID": "if_id", "EX": "id_ex", "MEM": "ex_mem", "WB": "mem_wb"}

# Tipos de evento, en el orden en que se muestran
STALL = "stall"              # ocurrió un stall por load-use (IF e ID retenidos)
FLUSH = "flush"              # ocurrió un flush por salto tomado
FWD = "fwd"                  # forwarding hacia EX en este ciclo
STALL_NEXT = "stall_next"    # load-use: el próximo flanco frena IF e ID
BRANCH_NEXT = "branch_next"  # el salto en EX se toma: el próximo flanco anula IF/ID e ID/EX
NOT_TAKEN = "not_taken"      # el branch en EX no se toma
HALT = "halt"                # HALT en vuelo: IF dejó de buscar
WARN = "warn"                # lo observado no coincide con las reglas de pipeline.md
DONE = "done"                # HALTED: programa terminado
ORDER = (STALL, FLUSH, FWD, STALL_NEXT, BRANCH_NEXT, NOT_TAKEN, HALT, WARN, DONE)

# Tipo de caja de cada etapa
INSTR, BUBBLE, STOPPED, EMPTY, UNKNOWN = "instr", "bubble", "stopped", "empty", "unknown"


@dataclass(frozen=True)
class Event:
    kind: str
    text: str        # explicación (panel Pipeline)
    short: str       # para el historial


@dataclass(frozen=True)
class StageView:
    """Lo que se dibuja en la caja de una etapa."""
    stage: str
    kind: str                 # INSTR, BUBBLE, STOPPED, EMPTY o UNKNOWN
    pc: int | None = None
    word: int | None = None
    text: str = ""            # desensamblado, "burbuja" o "?" si no se conoce la palabra
    retained: bool = False    # retenida por un stall (inferido)
    halt: bool = False        # es el HALT
    note: str = ""            # debajo de la caja


@dataclass(frozen=True)
class Analysis:
    events: tuple[Event, ...]
    stages: tuple[StageView, ...]
    stall_next: bool = False
    redirect_next: int | None = None     # destino, si el salto en EX se toma
    stop_fetch: bool = False
    causes: dict[str, str] = field(default_factory=dict, compare=False)  # etapa -> causa de su burbuja

    def of(self, kind: str) -> list[Event]:
        return [e for e in self.events if e.kind == kind]

    @property
    def short(self) -> str:
        """Los eventos en una línea, para el historial."""
        return "; ".join(e.short for e in self.events) or "—"


def text_of(word: int | None) -> str:
    """Desensamblado sin el comentario de las palabras fuera de isa.md; "?" si no se conoce."""
    if word is None:
        return "?"
    try:
        return disassemble(word).split("  #")[0]
    except Exception:                      # noqa: BLE001 — una palabra que no se entiende
        return f".word 0x{word:08X}"


def _mnemonic(word: int | None) -> str:
    return text_of(word).split()[0]


def _instr(word: int | None):
    """La instrucción decodificada, o None si no se conoce o no es de isa.md."""
    if word is None:
        return None
    try:
        return decode(word)
    except ModelError:
        return None


def _rs(word: int) -> tuple[int, int]:
    """rs1 y rs2 de una palabra sin decodificar, como los compara el detector (§10.3)."""
    return field_(word, 19, 15), field_(word, 24, 20)


def analyze(cur: Snapshot, prev: Snapshot | None = None, prev_analysis: Analysis | None = None,
            words=None, imem_words: int = IMEM_WORDS) -> Analysis:
    """Las etapas y los eventos de `cur`. `prev` es el volcado anterior (si es del ciclo
    anterior se comparan lo previsto y lo observado) y `prev_analysis` su análisis, para
    no recalcularlo y para seguir la causa de cada burbuja. `words` son las palabras que se
    mandaron con LOAD (None si no se conocen)."""
    status = cur.status
    L = cur.fields
    if status.state == State.HALTED:
        return Analysis((Event(DONE, f"Programa terminado en {status.cycles} ciclos, "
                                     "pipeline vacío", "HALTED"),),
                        tuple(StageView(s, EMPTY) for s in STAGES))
    if L is None:
        stages = (StageView("IF", INSTR, status.pc, word_at(words, status.pc, imem_words),
                            text_of(word_at(words, status.pc, imem_words))),)
        stages += tuple(StageView(s, UNKNOWN, text="?") for s in STAGES[1:])
        return Analysis((Event(WARN, "Los latches tienen otro formato (palabras por latch de "
                                     "INFO distintas de pipeline.md §8): no se infieren "
                                     "riesgos", "latches con otro formato"),), stages)

    fi, de, em, mw = L["if_id"], L["id_ex"], L["ex_mem"], L["mem_wb"]
    at = lambda pc: word_at(words, pc, imem_words)                        # noqa: E731
    wb_data = (load_extend(mw["read_data"], mw["funct3"], mw["offset"]) if mw["mem_to_reg"]
               else mw["result"])
    events: list[Event] = []

    # ---- lo que pasa en este ciclo -------------------------------------------------------

    def source(rs):
        """De dónde recibe EX el registro `rs` (unidad de forwarding, §10.2)."""
        if em["reg_write"] and em["rd"] != 0 and em["rd"] == rs:
            return "EX/MEM", em["result"], em["pc"]
        if mw["reg_write"] and mw["rd"] != 0 and mw["rd"] == rs:
            return "MEM/WB", wb_data, mw["pc"]
        return None

    rs1_val, rs2_val = de["rs1_data"], de["rs2_data"]
    if de["valid"]:                                  # una burbuja conserva rs1/rs2 viejos
        ex_instr = _instr(at(de["pc"]))
        for operand, reg, used in (("rs1", de["rs1"], ex_instr is None or ex_instr.reads_rs1),
                                   ("rs2", de["rs2"], ex_instr is None or ex_instr.reads_rs2)):
            src = source(reg)
            if src is None:
                continue
            name, value, from_pc = src
            if operand == "rs1":
                rs1_val = value
            else:
                rs2_val = value
            if used:                                 # a un operando descartado no tiene efecto
                events.append(Event(FWD, f"{name} → EX {operand}: x{reg} = {fmt_dec(value)} "
                                         f"({text_of(at(from_pc))})",
                                    f"FWD {name}→EX {operand} x{reg}"))

    # Resolución del salto en EX (§5.3), con los operandos ya reenviados
    redirect = None
    if de["valid"] and (de["branch"] or de["jal"] or de["jalr"]):
        op = ALU_CODES.get(de["alu_ctrl"])
        if op is not None:
            a = 0 if de["alu_src_a"] else rs1_val
            b = de["imm"] if de["alu_src_b"] else rs2_val
            out = alu_op(op, a, b)
            taken = de["branch"] and ((out == 0) ^ (de["funct3"] & 1))
            text = text_of(at(de["pc"]))
            if taken or de["jal"] or de["jalr"]:
                redirect = (out & ~1 & MASK32) if de["jalr"] else (de["pc"] + de["imm"]) & MASK32
                events.append(Event(BRANCH_NEXT, f"{text} en 0x{de['pc']:X} se toma: el "
                                                 f"próximo ciclo salta a 0x{redirect:X} y "
                                                 "anula IF/ID e ID/EX",
                                    f"salto tomado→0x{redirect:X}"))
            else:
                events.append(Event(NOT_TAKEN, f"{text} en 0x{de['pc']:X} no se toma: sigue "
                                               "en secuencia, sin ciclos perdidos",
                                    f"{_mnemonic(at(de['pc']))} no tomado"))

    # Detección de load-use (§10.3) y stall (§10.4)
    load_use = bool(de["mem_read"] and de["rd"] != 0 and fi["valid"]
                    and de["rd"] in _rs(fi["instr"]))
    stall_next = load_use and redirect is None
    if stall_next:
        events.append(Event(STALL_NEXT, f"load-use: {text_of(at(de['pc']))} (EX) carga "
                                        f"x{de['rd']} y {text_of(fi['instr'])} (ID) lo lee → "
                                        "el próximo ciclo retiene IF e ID y mete una burbuja "
                                        "en EX",
                            f"load-use detectado ({_mnemonic(at(de['pc']))}→"
                            f"{_mnemonic(fi['instr'])})"))

    # Parada por HALT (§3.4)
    halt_in_id = bool(fi["valid"] and fi["instr"] == HALT_WORD)
    halt_after = any(x["valid"] and x["halt"] for x in (de, em, mw))
    stop_fetch = halt_in_id or halt_after or status.halted
    if stop_fetch:
        events.append(Event(HALT, "HALT en vuelo: IF deja de buscar y el pipeline se vacía",
                            "HALT en vuelo"))

    # ---- lo que ya pasó --------------------------------------------------------------------

    stalled = bool(not de["valid"] and em["valid"] and em["mem_to_reg"] and em["rd"] != 0
                   and fi["valid"] and em["rd"] in _rs(fi["instr"]))
    if stalled:
        events.append(Event(STALL, f"load-use: {text_of(at(em['pc']))} en MEM, "
                                   f"{text_of(fi['instr'])} lee x{em['rd']} → IF e ID "
                                   "retenidos, burbuja en EX",
                            "STALL load-use, burbuja→EX"))
    jump = _instr(at(em["pc"])) if em["valid"] else None
    flushed = bool(jump is not None and jump.kind in ("BRANCH", "JAL", "JALR")
                   and not fi["valid"] and not de["valid"])
    if flushed:
        events.append(Event(FLUSH, f"{text_of(jump.word)} en 0x{em['pc']:X} tomado a "
                                   f"0x{status.pc:X}: IF/ID e ID/EX anulados",
                            f"FLUSH salto→0x{status.pc:X}"))

    # ---- comparación con lo previsto en el ciclo anterior ------------------------------------

    consecutive = (prev is not None and prev.fields is not None
                   and status.cycles == (prev.status.cycles + 1) & MASK32)
    if consecutive:
        pa = prev_analysis or analyze(prev, words=words, imem_words=imem_words)
        pf = prev.fields["if_id"]
        if pa.stall_next and not stalled:
            events.append(Event(WARN, f"Se esperaba un stall por load-use (x{prev.fields['id_ex']['rd']}) "
                                      "y el core no frenó: revisar la unidad de riesgos",
                                "¡stall esperado!"))
        elif (not pa.stall_next and not pa.stop_fetch and pa.redirect_next is None
              and pf["valid"] and fi == pf and status.pc == prev.status.pc):
            events.append(Event(WARN, "IF e ID se retuvieron sin un load-use: stall inesperado, "
                                      "revisar la unidad de riesgos", "¡stall inesperado!"))
        if pa.redirect_next is not None and not (
                not fi["valid"] and not de["valid"] and status.pc == pa.redirect_next):
            events.append(Event(WARN, f"El salto se tomaba a 0x{pa.redirect_next:X} y se "
                                      "esperaba un flush de IF/ID e ID/EX: revisar la "
                                      "resolución de saltos", "¡flush esperado!"))
        if pa.redirect_next is not None and not flushed and words is None:
            flushed = not fi["valid"] and not de["valid"] and status.pc == pa.redirect_next
    else:
        pa = None

    if fi["valid"] and words is not None and fi["instr"] != at(fi["pc"]):
        loaded = at(fi["pc"])
        events.append(Event(WARN, f"IF/ID.instr = 0x{fi['instr']:08X} y la palabra cargada en "
                                  f"0x{fi['pc']:X} es 0x{loaded:08X} ({text_of(loaded)})",
                            "¡IF/ID.instr distinta!"))

    # ---- causa de cada burbuja -------------------------------------------------------------

    before = pa.causes if pa is not None else {}
    causes: dict[str, str] = {}
    if status.cycles == 0:
        causes = dict.fromkeys(STAGES[1:], "reset")
    else:
        if not fi["valid"]:
            causes["ID"] = "flush" if flushed else ("HALT" if halt_after else before.get("ID", ""))
        if not de["valid"]:
            causes["EX"] = ("stall" if stalled else "flush" if flushed
                            else before.get("ID", ""))
        if not em["valid"]:
            causes["MEM"] = before.get("EX", "")
        if not mw["valid"]:
            causes["WB"] = before.get("MEM", "")

    # ---- cajas -------------------------------------------------------------------------------

    if_word = at(status.pc)
    stages = [StageView("IF", STOPPED if stop_fetch else INSTR, status.pc, if_word,
                        text_of(if_word), retained=stalled, halt=if_word == HALT_WORD,
                        note="PC retenido" if stalled else
                        "detenido (HALT)" if stop_fetch else "")]
    notes = {"ID": "IF/ID retenido" if stalled else "",
             "EX": "",
             "MEM": (f"escribe M[0x{em['result']:X}]" if em["mem_write"] else
                     f"lee M[0x{em['result']:X}]" if em["mem_to_reg"] else ""),
             "WB": (f"x{mw['rd']} ← {fmt_dec(wb_data)}" if mw["reg_write"] and mw["rd"]
                    else "sin escritura")}
    for stage in STAGES[1:]:
        latch = L[STAGE_LATCH[stage]]
        if not latch["valid"]:
            cause = causes.get(stage, "")
            stages.append(StageView(stage, BUBBLE, latch["pc"], text="burbuja",
                                    note=f"burbuja ({cause})" if cause else "burbuja"))
            continue
        word = latch["instr"] if stage == "ID" else at(latch["pc"])
        halt = word == HALT_WORD if stage == "ID" else bool(latch["halt"])
        stages.append(StageView(stage, INSTR, latch["pc"], word, text_of(word),
                                retained=stage == "ID" and stalled, halt=halt,
                                note=notes[stage]))

    events.sort(key=lambda e: ORDER.index(e.kind))
    return Analysis(tuple(events), tuple(stages), stall_next, redirect, stop_fetch, causes)
