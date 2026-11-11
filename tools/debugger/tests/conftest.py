"""Configuración de pytest para los tests del cliente de la Debug Unit."""

import sys
from pathlib import Path

import pytest

DEBUGGER = Path(__file__).resolve().parents[1]
TESTS = Path(__file__).resolve().parent
for path in (DEBUGGER, TESTS):
    if str(path) not in sys.path:
        sys.path.insert(0, str(path))

from fake_debug_unit import FakeClock, FakeDebugUnit, FakeSerial  # noqa: E402
from rvdebug import DebugClient  # noqa: E402


@pytest.fixture
def clock():
    return FakeClock()


@pytest.fixture
def device():
    return FakeDebugUnit()


@pytest.fixture
def port(device, clock):
    return FakeSerial(device, clock)


@pytest.fixture
def client(port, clock):
    """Cliente sin conectar, sobre el puerto simulado y el reloj falso."""
    return DebugClient(port, clock=clock, sleep=clock.sleep)


@pytest.fixture
def connected(client):
    client.connect()
    return client
