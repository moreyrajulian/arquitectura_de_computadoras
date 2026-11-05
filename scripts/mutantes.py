"""Mutantes del RTL para comprobar que la regresión puede fallar (verificacion.md §6, decisión 031).

Cada mutante rompe una regla de la spec en una copia de un archivo de rtl/: reemplaza textos
que tienen que aparecer exactamente una vez en el original. rtl/ no se toca:

    python scripts/regresion.py --mutante sin_forwarding     # uno
    python scripts/regresion.py --mutante todos              # todos, uno detrás del otro

escribe cada copia en build/mutantes/<nombre>/ y la lista en build/regresion/mutantes.txt.
Después, regresion.tcl corre la regresión entera una vez por mutante, con la copia en lugar
del original, y dice qué corridas lo detectan. Un mutante que no hace fallar ninguna corrida
es un mecanismo que los programas no cubren.

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

# Líneas de forwarding_unit.v que tocan los mutantes (pipeline.md §10.2)
EX_MEM_WRITES = "wire ex_mem_writes = i_ex_mem_reg_write & (i_ex_mem_rd != REG_X0);"
MEM_WB_WRITES = "wire mem_wb_writes = i_mem_wb_reg_write & (i_mem_wb_rd != REG_X0);"
PRIORIDAD_A = ("ex_mem_rs1 ? FWD_EX_MEM :\n                     mem_wb_rs1 ? FWD_WB     :",
               "mem_wb_rs1 ? FWD_WB     :\n                     ex_mem_rs1 ? FWD_EX_MEM :")
PRIORIDAD_B = ("ex_mem_rs2 ? FWD_EX_MEM :\n                     mem_wb_rs2 ? FWD_WB     :",
               "mem_wb_rs2 ? FWD_WB     :\n                     ex_mem_rs2 ? FWD_EX_MEM :")

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
}


def aplicar(nombre):
    """Devuelve el texto mutado del archivo. Falla si un cambio no aparece exactamente una vez."""
    m = MUTANTES[nombre]
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
    destino = SALIDA / nombre / Path(MUTANTES[nombre].archivo).name
    destino.parent.mkdir(parents=True, exist_ok=True)
    destino.write_text(aplicar(nombre), encoding="utf-8")
    return destino


def main():
    errores = 0
    for nombre, m in MUTANTES.items():
        try:
            aplicar(nombre)
            estado = "ok"
        except ValueError as e:
            estado, errores = f"ERROR: {e}", errores + 1
        print(f"{nombre:22s} {m.archivo:32s} {m.regla}  [{estado}]")
    return 1 if errores else 0


if __name__ == "__main__":
    sys.exit(main())
