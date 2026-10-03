"""Formatos de salida y linea de comandos."""

from rvasm import HALT_WORD, assemble, render, to_bin, to_coe, to_hex, to_listing
from rvasm.cli import EXIT_ASM_ERROR, EXIT_OK, EXIT_USAGE, main

# Programa de protocolo_debug.md 4: addi x1, x0, 5 y halt
EXAMPLE = "addi x1, x0, 5\nhalt\n"


def test_bin_is_the_load_payload_of_the_protocol_example():
    # LOAD: A5 10 08 00 | 93 00 50 00 73 00 10 00 | B8
    assert to_bin(assemble(EXAMPLE)) == bytes.fromhex("93005000 73001000")


def test_hex_one_word_per_line_for_readmemh():
    assert to_hex(assemble(EXAMPLE)) == "00500093\n00100073\n"


def test_coe_for_block_memory_generator():
    coe = to_coe(assemble(EXAMPLE), source_name="p.s")
    assert coe == ("; generado por rvasm desde p.s\n"
                   "memory_initialization_radix=16;\n"
                   "memory_initialization_vector=\n"
                   "00500093,\n"
                   "00100073;\n")


def test_fill_pads_with_halt_to_1024_words():
    prog = assemble(EXAMPLE)
    lines = to_hex(prog, fill=True).splitlines()
    assert len(lines) == 1024
    assert lines[:2] == ["00500093", "00100073"]
    assert set(lines[2:]) == {f"{HALT_WORD:08x}"}
    assert len(to_bin(prog, fill=True)) == 4096
    assert to_coe(prog, fill=True).count(",") == 1023


def test_listing_shows_address_word_line_and_labels():
    lst = to_listing(assemble("inicio: addi x1, x0, 5\nhalt\n"))
    assert "inicio:" in lst
    assert "0x0000  00500093     1 | inicio: addi x1, x0, 5" in lst
    assert "0x0004  00100073     2 | halt" in lst


def test_render_rejects_unknown_format():
    import pytest
    with pytest.raises(ValueError):
        render(assemble(EXAMPLE), "elf")


# ---- CLI --------------------------------------------------------------------------
def test_cli_writes_every_format_from_extension(tmp_path):
    src = tmp_path / "p.s"
    src.write_text(EXAMPLE)
    outs = [tmp_path / f"p.{ext}" for ext in ("hex", "bin", "coe", "lst")]
    args = [str(src)] + [a for o in outs for a in ("-o", str(o))]
    assert main(args) == EXIT_OK
    assert outs[0].read_text() == "00500093\n00100073\n"
    assert outs[1].read_bytes() == bytes.fromhex("9300500073001000")
    assert "memory_initialization_vector" in outs[2].read_text()
    assert "addi x1, x0, 5" in outs[3].read_text()


def test_cli_hex_to_stdout_by_default(tmp_path, capsys):
    src = tmp_path / "p.s"
    src.write_text(EXAMPLE)
    assert main([str(src)]) == EXIT_OK
    assert capsys.readouterr().out == "00500093\n00100073\n"


def test_cli_reports_errors_with_line_and_writes_nothing(tmp_path, capsys):
    src = tmp_path / "p.s"
    src.write_text("nop\nadd x1, x2, x40\nhalt\n")
    out = tmp_path / "p.hex"
    assert main([str(src), "-o", str(out)]) == EXIT_ASM_ERROR
    err = capsys.readouterr().err
    assert f"{src}:2: error: registro inexistente 'x40'" in err
    assert "1 error; no se genero salida" in err
    assert not out.exists()


def test_cli_warns_without_halt(tmp_path, capsys):
    src = tmp_path / "p.s"
    src.write_text("nop\n")
    assert main([str(src)]) == EXIT_OK
    assert "warning" in capsys.readouterr().err
    assert main([str(src), "-W"]) == EXIT_OK
    assert capsys.readouterr().err == ""


def test_cli_missing_file_and_unknown_extension(tmp_path, capsys):
    assert main([str(tmp_path / "no_existe.s")]) == EXIT_USAGE
    src = tmp_path / "p.s"
    src.write_text(EXAMPLE)
    assert main([str(src), "-o", str(tmp_path / "p.txt")]) == EXIT_USAGE
    assert "no se reconoce el formato" in capsys.readouterr().err
    assert main([str(src), "-o", str(tmp_path / "p.txt"), "-f", "hex"]) == EXIT_OK
