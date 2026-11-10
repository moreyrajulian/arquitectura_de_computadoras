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

# Originales de NOPS que corren con forwarding y sin stall ni flush: no tienen
# carga-uso ni saltos tomados (decision 029)
SOLO_FORWARDING = ["fwd_exmem", "fwd_memwb", "fwd_prioridad", "load_sin_dep"]

# Los que corren desde I-39, con forwarding y sin stall ni flush
FORWARDING = SIN_RIESGOS + SOLO_FORWARDING

# Originales de NOPS que con forwarding y sin flush se comparan solo contra la
# traza, sin +FINAL: el modelo ejecuta el camino equivocado igual que el RTL, pero
# el .exp necesita el flush (I-42). salto_depende es el unico con forwarding hacia
# los saltos (verificacion.md 4.3 y 8.2, I-40)
SOLO_TRAZA_FORWARDING = ["salto_depende"]

# Programas que suma el stall de carga-uso (I-41) con forwarding y sin flush: no
# tienen saltos tomados. halt_stall es de SOLO_M8 (no tiene variante _nops)
SOLO_STALL = ["loaduse_rs1_rs2", "halt_stall"]

# Los que corren desde I-41, con forwarding y stall, sin flush
FORWARDING_STALL = FORWARDING + SOLO_STALL

# Con forwarding y stall, sin +FINAL (decision 030): ademas de salto_depende,
# loaduse_sw_beq, el unico load seguido de un salto que usa el dato. Su beq se
# toma y el .exp difiere solo en x20, del camino equivocado (I-42)
SOLO_TRAZA_FORWARDING_STALL = SOLO_TRAZA_FORWARDING + ["loaduse_sw_beq"]

# Programas que suma el flush por saltos (I-42): los originales con saltos tomados que
# faltaban. halt_camino_equivocado es de SOLO_M8 (no tiene variante _nops)
SOLO_FLUSH = ["branch_cond", "jump", "mixto_lazo", "halt_camino_equivocado"]

# Desde I-42 el RTL tiene forwarding, stall y flush: modo completo, todos los programas
# con +FINAL (decision 029). Es PROGRAMS, asi un .s nuevo entra solo a la regresion; los
# de SOLO_TRAZA_FORWARDING_STALL ya dan su .exp. test_programas.py comprueba que las
# listas de M8 juntas son todos los programas
COMPLETO = PROGRAMS
