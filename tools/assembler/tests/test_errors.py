"""Errores con numero de linea y mensajes claros."""

import pytest

from rvasm import AssemblerError, assemble


def errors_of(src: str, filename: str = "prog.s") -> list:
    with pytest.raises(AssemblerError) as exc:
        assemble(src, filename)
    return exc.value.errors


def single_error(src: str):
    errs = errors_of(src)
    assert len(errs) == 1, [str(e) for e in errs]
    return errs[0]


@pytest.mark.parametrize("src,line,fragment", [
    # instruccion invalida / no soportada
    ("nop\nmul x1, x2, x3", 2, "instruccion invalida 'mul'"),
    ("nop\nnop\nblt x1, x2, 0", 3, "no soportada"),
    ("auipc x1, 0", 1, "no soportada"),
    ("ecall", 1, "no soportada"),
    # registro inexistente
    ("add x1, x2, x32", 1, "registro inexistente 'x32'"),
    ("addi r1, x0, 1", 1, "registro inexistente 'r1'"),
    ("lw x1, 0(t7)", 1, "registro inexistente 't7'"),
    # inmediato fuera de rango
    ("addi x1, x0, 2048", 1, "fuera de rango: 2048"),
    ("addi x1, x0, -2049", 1, "fuera de rango: -2049"),
    ("andi x1, x0, 0xfff", 1, "fuera de rango"),
    ("slli x1, x1, 32", 1, "shamt fuera de rango"),
    ("srai x1, x1, -1", 1, "shamt fuera de rango"),
    ("lw x1, 2048(x2)", 1, "offset de 12 bits fuera de rango"),
    ("sw x1, -2049(x2)", 1, "offset de 12 bits fuera de rango"),
    ("jalr x1, 4096(x2)", 1, "fuera de rango"),
    ("lui x1, 0x100000", 1, "inmediato de 20 bits fuera de rango"),
    ("lui x1, -1", 1, "inmediato de 20 bits fuera de rango"),
    ("beq x1, x2, 4096", 1, "desplazamiento de branch fuera de rango"),
    ("beq x1, x2, -4100", 1, "desplazamiento de branch fuera de rango"),
    ("jal x0, 1048576", 1, "desplazamiento de jal fuera de rango"),
    ("beq x1, x2, 6", 1, "no es multiplo de 4"),
    ("li x1, 0x100000000", 1, "inmediato de 'li' fuera de rango"),
    (".word 0x100000000", 1, "valor de '.word' fuera de rango"),
    # etiquetas
    ("j nada", 1, "etiqueta no definida 'nada'"),
    ("a: nop\na: nop", 2, "etiqueta 'a' duplicada (definida en la linea 1)"),
    ("x1: nop", 1, "no puede ser etiqueta"),
    ("addi x1, x0, fin\nfin: halt", 1, "no se puede usar como inmediato"),
    # operandos
    ("add x1, x2", 1, "'add' espera 3 operandos y recibio 2"),
    ("halt x1", 1, "'halt' espera 0 operandos"),
    ("add x1,, x2", 1, "operando vacio"),
    ("lw x1, x2", 1, "se esperaba 'offset(registro)'"),
    ("addi x1, x0, x2", 1, "se esperaba un inmediato y se encontro el registro"),
    ("addi x1, x0, 5x", 1, "inmediato invalido '5x'"),
    ("addi x1, x0, 010", 1, "cero a la izquierda"),
    ("beq x1, x2, x3", 1, "se encontro el registro 'x3'"),
    ("addi x1, x0, N", 1, "simbolo no definido 'N'"),
    ("li x1, N\n.equ N, 1", 1, "en 'li' la constante .equ tiene que definirse antes"),
    # directivas
    (".data", 1, "no hay seccion de datos"),
    (".byte 1", 1, "no soportada"),
    (".align 2", 1, "directiva desconocida '.align'"),
    (".word", 1, "necesita al menos un valor"),
])
def test_error_line_and_message(src, line, fragment):
    err = single_error(src)
    assert err.line == line
    assert fragment in err.message


def test_all_errors_are_reported_in_line_order():
    src = "nop\nfoo x1\nadd x1, x2, x99\nnop\naddi x1, x0, 9999\nj nada\n"
    errs = errors_of(src)
    assert [e.line for e in errs] == [2, 3, 5, 6]


def test_invalid_line_still_counts_towards_size():
    # la linea invalida ocupa su palabra: el programa tiene 1025 y se informan los dos errores
    errs = errors_of("nop\n" * 1023 + "foo\n" + "halt\n")
    assert [e.line for e in errs] == [1024, 1025]
    assert "instruccion invalida 'foo'" in errs[0].message
    assert "1025 palabras" in errs[1].message


def test_error_text_has_file_line_and_source():
    err = single_error("nop\n  add x1, x2, x32   # suma\n")
    text = str(err)
    assert text.startswith("prog.s:2: error: registro inexistente 'x32'")
    assert "2 | add x1, x2, x32   # suma" in text


def test_program_too_large():
    errs = errors_of("nop\n" * 1024 + "halt\n")
    assert len(errs) == 1 and "1025 palabras" in errs[0].message


def test_program_of_exactly_1024_words_is_accepted():
    assert len(assemble("nop\n" * 1023 + "halt\n").words) == 1024


def test_li_counts_towards_size():
    errs = errors_of("li a0, 0x12345678\n" * 512 + "halt\n")
    assert "1025 palabras" in errs[0].message


def test_empty_program():
    assert "vacio" in single_error("# solo comentarios\n\n").message


def test_missing_halt_is_a_warning_not_an_error():
    prog = assemble("nop")
    assert len(prog.warnings) == 1
    assert "no tiene 'halt'" in prog.warnings[0].message
    assert "warning" in str(prog.warnings[0])
    assert assemble("nop\nhalt").warnings == []
    assert assemble("nop\nebreak").warnings == []
