"""Mutantes del RTL para comprobar que la regresión puede fallar (verificacion.md §6, decisión 031).

Cada mutante rompe una regla de la spec en una copia de un archivo de rtl/: reemplaza textos
que tienen que aparecer exactamente una vez en el original. rtl/ no se toca:

    python scripts/regresion.py --mutante sin_forwarding     # uno
    python scripts/regresion.py --mutante todos              # todos, uno detrás del otro

escribe cada copia en build/mutantes/<nombre>/ y la lista en build/regresion/mutantes.txt.
Después, regresion.tcl corre la regresión entera una vez por mutante, con la copia en lugar
del original, y dice qué corridas lo detectan. Un mutante que no hace fallar ninguna corrida
es un mecanismo que los programas no cubren.

MUTANTES son los de forwarding (I-40) y los del bypass del banco, el stall, el flush y la
parada por HALT (I-43). EQUIVALENTES rompen un término que ningún programa puede activar en
el core integrado (verificacion.md §8.2): se corren a mano, por nombre, y lo esperado es que
regresion.tcl diga NO DETECTADO. 'todos' no los incluye.

Uso (desde la raíz del repositorio):

    python scripts/mutantes.py          # lista los mutantes y comprueba que se pueden aplicar
"""

import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SALIDA = ROOT / "build" / "mutantes"


@dataclass(frozen=True)
class Mutante:
    archivo: str            # relativo a la raíz del repo
    regla: str              # qué regla de la spec rompe
    cambios: tuple          # pares (texto original, texto mutado)


CORE = "rtl/pipeline/riscv_core.v"
FWD = "rtl/control/forwarding_unit.v"
REGFILE = "rtl/common/regfile.v"
HAZARD = "rtl/control/hazard_unit.v"
PC_LOGIC = "rtl/pipeline/pc_logic.v"
IF_ID = "rtl/pipeline/if_id_reg.v"

# Líneas de forwarding_unit.v que tocan los mutantes (pipeline.md §10.2)
EX_MEM_WRITES = "wire ex_mem_writes = i_ex_mem_reg_write & (i_ex_mem_rd != REG_X0);"
MEM_WB_WRITES = "wire mem_wb_writes = i_mem_wb_reg_write & (i_mem_wb_rd != REG_X0);"
PRIORIDAD_A = ("ex_mem_rs1 ? FWD_EX_MEM :\n                     mem_wb_rs1 ? FWD_WB     :",
               "mem_wb_rs1 ? FWD_WB     :\n                     ex_mem_rs1 ? FWD_EX_MEM :")
PRIORIDAD_B = ("ex_mem_rs2 ? FWD_EX_MEM :\n                     mem_wb_rs2 ? FWD_WB     :",
               "mem_wb_rs2 ? FWD_WB     :\n                     ex_mem_rs2 ? FWD_EX_MEM :")

# Líneas de regfile.v: bypass WB -> ID de cada puerto (pipeline.md §4.2, decisión 007)
BYPASS_RS1 = "(i_we && (i_rd_addr == i_rs1_addr))   ? i_rd_data :"
BYPASS_RS2 = "(i_we && (i_rd_addr == i_rs2_addr))   ? i_rd_data :"
SIN_BYPASS = "1'b0                                  ? i_rd_data :"
X0_RS1 = "(i_rs1_addr == REG_ZERO)              ? DATA_ZERO :"
X0_RS2 = "(i_rs2_addr == REG_ZERO)              ? DATA_ZERO :"

# Líneas de hazard_unit.v: carga-uso (§10.3) y enables y flush (§10.4)
LOAD_WRITES = "wire load_writes = i_id_ex_mem_read & (i_id_ex_rd != REG_X0);"
LOAD_USE = "assign o_load_use = load_writes & i_if_id_valid & (rs1_match | rs2_match);"
STALL = "assign o_stall        = o_load_use & ~i_redirect;"
EN_PC = "assign o_en_pc        = i_enable & ~o_stall;"
EN_IF_ID = "assign o_en_if_id     = i_enable & ~o_stall;"
FLUSH_IF_ID = "assign o_flush_if_id  = i_redirect | i_stop_fetch;"
FLUSH_ID_EX = "assign o_flush_id_ex  = i_redirect | o_stall;"

# Parada por HALT (§3.4): stop_fetch en riscv_core y su prioridad en el PC (§3.1)
STOP_FETCH = "assign stop_fetch = id_is_halt | id_ex_halt | ex_mem_halt | mem_wb_halt | halted;"
PC_PRIORIDAD = ("        if (i_redirect)\n            pc_next = i_redirect_pc;\n"
                "        else if (i_stop_fetch)\n            pc_next = pc_reg;\n")
# IF/ID: prioridad rst > en > flush (§2), la que conserva el HALT durante un stall
IF_ID_VALID = "        else if (i_en)\n            if_id_valid_reg <= ~i_flush;"

MUTANTES = {
    # §6: el mecanismo desactivado entero. EX toma siempre lo leído en ID (FWD_ID_EX)
    "sin_forwarding": Mutante(CORE, "forwarding apagado: fwd_a = fwd_b = FWD_ID_EX (pipeline.md §10.2)", (
        ("    wire [NB_FWD-1:0] fwd_b;\n",
         "    wire [NB_FWD-1:0] fwd_b;\n"
         "    assign fwd_a = {NB_FWD{1'b0}};   // MUTANTE sin_forwarding: FWD_ID_EX\n"
         "    assign fwd_b = {NB_FWD{1'b0}};\n"),
        (".o_fwd_a            (fwd_a),", ".o_fwd_a            (),"),
        (".o_fwd_b            (fwd_b)", ".o_fwd_b            ()"),
    )),
    # Una regla de pipeline.md §10.2 rota por vez en forwarding_unit
    "fwd_prioridad": Mutante(FWD, "MEM/WB tiene prioridad sobre EX/MEM, en fwd_a y en fwd_b",
                             (PRIORIDAD_A, PRIORIDAD_B)),
    "fwd_rd0_ex_mem": Mutante(FWD, "EX/MEM se reenvía aunque rd = x0", (
        (EX_MEM_WRITES, "wire ex_mem_writes = i_ex_mem_reg_write;"),)),
    "fwd_rd0_mem_wb": Mutante(FWD, "MEM/WB se reenvía aunque rd = x0", (
        (MEM_WB_WRITES, "wire mem_wb_writes = i_mem_wb_reg_write;"),)),
    "fwd_reg_write_ex_mem": Mutante(FWD, "EX/MEM se reenvía aunque la instrucción no escriba", (
        (EX_MEM_WRITES, "wire ex_mem_writes = (i_ex_mem_rd != REG_X0);"),)),
    "fwd_reg_write_mem_wb": Mutante(FWD, "MEM/WB se reenvía aunque la instrucción no escriba", (
        (MEM_WB_WRITES, "wire mem_wb_writes = (i_mem_wb_rd != REG_X0);"),)),
    "fwd_a_ex_mem_con_rs2": Mutante(FWD, "fwd_a compara el rd de EX/MEM con rs2 en vez de rs1", (
        ("(i_ex_mem_rd == i_id_ex_rs1)", "(i_ex_mem_rd == i_id_ex_rs2)"),)),
    "fwd_b_ex_mem_con_rs1": Mutante(FWD, "fwd_b compara el rd de EX/MEM con rs1 en vez de rs2", (
        ("(i_ex_mem_rd == i_id_ex_rs2)", "(i_ex_mem_rd == i_id_ex_rs1)"),)),
    "fwd_a_mem_wb_con_rs2": Mutante(FWD, "fwd_a compara el rd de MEM/WB con rs2 en vez de rs1", (
        ("(i_mem_wb_rd == i_id_ex_rs1)", "(i_mem_wb_rd == i_id_ex_rs2)"),)),
    "fwd_b_mem_wb_con_rs1": Mutante(FWD, "fwd_b compara el rd de MEM/WB con rs1 en vez de rs2", (
        ("(i_mem_wb_rd == i_id_ex_rs2)", "(i_mem_wb_rd == i_id_ex_rs1)"),)),
    "fwd_a_sin_mem_wb": Mutante(FWD, "fwd_a no mira MEM/WB", (
        ("mem_wb_rs1 ? FWD_WB     :", "1'b0       ? FWD_WB     :"),)),
    "fwd_b_sin_mem_wb": Mutante(FWD, "fwd_b no mira MEM/WB", (
        ("mem_wb_rs2 ? FWD_WB     :", "1'b0       ? FWD_WB     :"),)),
    "fwd_a_codigo_ex_mem": Mutante(FWD, "fwd_a devuelve FWD_WB cuando coincide EX/MEM", (
        ("ex_mem_rs1 ? FWD_EX_MEM :", "ex_mem_rs1 ? FWD_WB     :"),)),
    "fwd_b_codigo_ex_mem": Mutante(FWD, "fwd_b devuelve FWD_WB cuando coincide EX/MEM", (
        ("ex_mem_rs2 ? FWD_EX_MEM :", "ex_mem_rs2 ? FWD_WB     :"),)),
    "fwd_a_codigo_mem_wb": Mutante(FWD, "fwd_a devuelve FWD_EX_MEM cuando coincide MEM/WB", (
        ("mem_wb_rs1 ? FWD_WB     :", "mem_wb_rs1 ? FWD_EX_MEM :"),)),
    "fwd_b_codigo_mem_wb": Mutante(FWD, "fwd_b devuelve FWD_EX_MEM cuando coincide MEM/WB", (
        ("mem_wb_rs2 ? FWD_WB     :", "mem_wb_rs2 ? FWD_EX_MEM :"),)),

    # Bypass del banco (pipeline.md §4.2, decisión 007), en regfile
    "sin_bypass": Mutante(REGFILE, "bypass WB -> ID apagado: los dos puertos leen el valor guardado", (
        (BYPASS_RS1, SIN_BYPASS), (BYPASS_RS2, SIN_BYPASS))),
    "sin_bypass_rs1": Mutante(REGFILE, "rs1 sin bypass WB -> ID", ((BYPASS_RS1, SIN_BYPASS),)),
    "sin_bypass_rs2": Mutante(REGFILE, "rs2 sin bypass WB -> ID", ((BYPASS_RS2, SIN_BYPASS),)),
    "bypass_sin_we": Mutante(REGFILE, "bypass aunque WB no escriba (sin i_we)", (
        (BYPASS_RS1, "((i_rd_addr == i_rs1_addr))           ? i_rd_data :"),
        (BYPASS_RS2, "((i_rd_addr == i_rs2_addr))           ? i_rd_data :"))),
    "bypass_x0": Mutante(REGFILE, "x0 no se lee como 0: pasa por el bypass si WB lo escribe", (
        (X0_RS1, "1'b0                                  ? DATA_ZERO :"),
        (X0_RS2, "1'b0                                  ? DATA_ZERO :"))),

    # Stall de carga-uso (pipeline.md §10.3 y §10.4), en hazard_unit
    "sin_stall": Mutante(HAZARD, "detección de carga-uso apagada: load_use = 0", (
        (LOAD_USE, "assign o_load_use = 1'b0;   // MUTANTE sin_stall"),)),
    "stall_rd0": Mutante(HAZARD, "un load a x0 frena", (
        (LOAD_WRITES, "wire load_writes = i_id_ex_mem_read;"),)),
    "stall_sin_mem_read": Mutante(HAZARD, "frena aunque la instrucción en EX no sea un load", (
        (LOAD_WRITES, "wire load_writes = (i_id_ex_rd != REG_X0);"),)),
    "stall_solo_rs1": Mutante(HAZARD, "la carga-uso compara solo rs1", (
        ("(rs1_match | rs2_match)", "rs1_match"),)),
    "stall_solo_rs2": Mutante(HAZARD, "la carga-uso compara solo rs2", (
        ("(rs1_match | rs2_match)", "rs2_match"),)),
    "stall_sin_burbuja": Mutante(HAZARD, "el stall no mete la burbuja en ID/EX: flush_id_ex = redirect", (
        (FLUSH_ID_EX, "assign o_flush_id_ex  = i_redirect;"),)),
    "stall_sin_en_pc": Mutante(HAZARD, "el stall no retiene el PC: en_pc = enable", (
        (EN_PC, "assign o_en_pc        = i_enable;"),)),
    "stall_sin_en_if_id": Mutante(HAZARD, "el stall no retiene IF/ID: en_if_id = enable", (
        (EN_IF_ID, "assign o_en_if_id     = i_enable;"),)),

    # Flush por saltos (pipeline.md §10.5), en hazard_unit
    "sin_flush": Mutante(HAZARD, "flush por saltos apagado: el salto tomado no anula IF/ID ni ID/EX", (
        (FLUSH_IF_ID, "assign o_flush_if_id  = i_stop_fetch;"),
        (FLUSH_ID_EX, "assign o_flush_id_ex  = o_stall;"))),
    "flush_sin_if_id": Mutante(HAZARD, "el salto tomado no anula IF/ID", (
        (FLUSH_IF_ID, "assign o_flush_if_id  = i_stop_fetch;"),)),
    "flush_sin_id_ex": Mutante(HAZARD, "el salto tomado no anula ID/EX", (
        (FLUSH_ID_EX, "assign o_flush_id_ex  = o_stall;"),)),

    # Parada por HALT (pipeline.md §3.4)
    "sin_stop_fetch": Mutante(CORE, "parada por HALT apagada: stop_fetch = 0", (
        (STOP_FETCH, "assign stop_fetch = 1'b0;   // MUTANTE sin_stop_fetch"),)),
    "stop_fetch_solo_id": Mutante(CORE, "stop_fetch mira solo el HALT en ID (y halted)", (
        (STOP_FETCH, "assign stop_fetch = id_is_halt | halted;"),)),
    "stop_fetch_sin_halted": Mutante(CORE, "stop_fetch sin halted: el PC vuelve a avanzar al salir el HALT de WB", (
        (STOP_FETCH, "assign stop_fetch = id_is_halt | id_ex_halt | ex_mem_halt | mem_wb_halt;"),)),
    "stop_fetch_sin_flush": Mutante(HAZARD, "stop_fetch no vacía IF/ID: flush_if_id = redirect", (
        (FLUSH_IF_ID, "assign o_flush_if_id  = i_redirect;"),)),
    "stop_fetch_sin_pc": Mutante(PC_LOGIC, "stop_fetch no congela el PC", (
        ("else if (i_stop_fetch)", "else if (1'b0)"),)),
    "stop_fetch_gana_a_redirect": Mutante(PC_LOGIC, "en el PC, stop_fetch gana sobre redirect (§3.1)", (
        (PC_PRIORIDAD, "        if (i_stop_fetch)\n            pc_next = pc_reg;\n"
                       "        else if (i_redirect)\n            pc_next = i_redirect_pc;\n"),)),
    "if_id_flush_gana_a_en": Mutante(IF_ID, "en IF/ID, flush gana sobre en (§2): el stall pierde el HALT", (
        (IF_ID_VALID, "        else if (i_en | i_flush)\n            if_id_valid_reg <= ~i_flush;"),)),
}

# Términos que ningún programa puede activar en el core integrado (verificacion.md §8.2):
# los cubre hazard_unit_tb. Se corren a mano por nombre y regresion.tcl tiene que decir
# NO DETECTADO; 'todos' no los incluye
EQUIVALENTES = {
    "stall_sin_redirect": Mutante(HAZARD, "stall = load_use, sin ~redirect: con los saltos en EX la "
                                  "instrucción en EX es un load o un salto (decisión 012)", (
        (STALL, "assign o_stall        = o_load_use;"),)),
    "stall_sin_valid": Mutante(HAZARD, "la carga-uso no mira if_id_valid: una burbuja en IF/ID nunca "
                               "tiene un load válido detrás, en ID/EX", (
        (LOAD_USE, "assign o_load_use = load_writes & (rs1_match | rs2_match);"),)),
}

TODOS = {**MUTANTES, **EQUIVALENTES}


def aplicar(nombre):
    """Devuelve el texto mutado del archivo. Falla si un cambio no aparece exactamente una vez."""
    m = TODOS[nombre]
    texto = (ROOT / m.archivo).read_text(encoding="utf-8")
    for original, mutado in m.cambios:
        n = texto.count(original)
        if n != 1:
            raise ValueError(f"mutante {nombre}: {original.strip()!r} aparece {n} veces en "
                             f"{m.archivo} (tiene que aparecer una)")
        texto = texto.replace(original, mutado)
    return texto


def escribir(nombre):
    """Escribe la copia mutada en build/mutantes/<nombre>/ y devuelve su ruta."""
    destino = SALIDA / nombre / Path(TODOS[nombre].archivo).name
    destino.parent.mkdir(parents=True, exist_ok=True)
    destino.write_text(aplicar(nombre), encoding="utf-8")
    return destino


def main():
    errores = 0
    for nombre, m in TODOS.items():
        try:
            aplicar(nombre)
            estado = "ok"
        except ValueError as e:
            estado, errores = f"ERROR: {e}", errores + 1
        marca = " (equivalente)" if nombre in EQUIVALENTES else ""
        print(f"{nombre:26s} {m.archivo:32s} {m.regla}{marca}  [{estado}]")
    print(f"{len(MUTANTES)} mutantes ('todos') y {len(EQUIVALENTES)} equivalentes")
    return 1 if errores else 0


if __name__ == "__main__":
    sys.exit(main())
