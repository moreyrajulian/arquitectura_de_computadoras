"""Configuración de pytest para los tests del modelo de referencia."""

import pytest

from isasim_testutil import words_of

from isasim import COMPLETO, simulate


@pytest.fixture
def run():
    """run(fuente, mode=COMPLETO, regs=None, dmem=None) -> RunResult"""
    def _run(source, mode=COMPLETO, regs=None, dmem=None):
        return simulate(words_of(source), regs, dmem, mode)
    return _run
