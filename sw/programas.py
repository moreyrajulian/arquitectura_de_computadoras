"""Listas de programas de sw/ (verificacion.md 4).

Las usan sw/test_programas.py y scripts/regresion.py. Al agregar un programa del
plan o una variante _nops, se suma aca (sw/README.md).
"""

from pathlib import Path

SW = Path(__file__).resolve().parent

PROGRAMS = sorted(p.stem for p in SW.glob("*.s"))

# verificacion.md 4.1 y 4.2: los 22 programas del plan
PLAN = [
    "alu_r", "alu_i", "shifts", "lui", "mem_palabra", "mem_byte_media",
    "branch_cond", "jump", "halt_basico", "mem_avisos",
    "fwd_exmem", "fwd_memwb", "fwd_prioridad", "fwd_x0", "bypass_banco",
    "loaduse_rs1_rs2", "loaduse_sw_beq", "load_sin_dep", "salto_depende",
    "halt_stall", "halt_camino_equivocado", "mixto_lazo",
]
# La issue I-15: un programa independiente por grupo de instrucciones, y
# la I-34: un store seguido de un load a la misma direccion
INDEP = ["indep_alu_r", "indep_alu_i", "indep_cargas", "indep_stores",
         "indep_saltos", "indep_lui", "indep_store_load"]
# Programas de riesgos y de saltos que no corren sin forwarding, stall o flush
NOPS = ["fwd_exmem", "fwd_memwb", "fwd_prioridad", "loaduse_rs1_rs2",
        "loaduse_sw_beq", "load_sin_dep", "branch_cond", "jump",
        "salto_depende", "mixto_lazo"]
# verificacion.md 4.3: prueban el HALT con el stall y con el flush, sin variante
SOLO_M8 = ["halt_stall", "halt_camino_equivocado"]

# Los que corren en M7 (I-38): el plan sin riesgos, las variantes _nops y los indep_
SIN_RIESGOS = ([n for n in PLAN if n not in NOPS and n not in SOLO_M8]
               + [f"{n}_nops" for n in NOPS] + INDEP)
