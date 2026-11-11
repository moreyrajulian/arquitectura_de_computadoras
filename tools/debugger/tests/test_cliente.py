"""Cliente (rvdebug.client) contra la Debug Unit simulada: comandos (§3), errores,
timeouts y reintentos (§5), y el filtro de palabras antes de LOAD (decisión 025)."""

import threading
import time

import pytest

from fake_debug_unit import HALT, FakeDebugUnit, FakeSerial, RealClock
from rvdebug import (Cmd, DebugClient, DebugError, DeviceError, Err, HaltTimeout,
                     InvalidProgramError, NoResponseError, ProtocolError, State,
                     check_program, response_timeout)
from rvdebug.protocol import build_response

ADDI_X1_5 = 0x00500093         # addi x1, x0, 5
PROG = [ADDI_X1_5, HALT]       # el programa de los ejemplos de §4


def assemble(source):
    from rvasm import assemble as rvasm_assemble   # el cliente ya agregó el ensamblador al path
    return rvasm_assemble(source, "test.s").words


# ---- conexión ---------------------------------------------------------------------------

def test_connect_lee_info(client, device):
    info = client.connect()
    assert info.proto_version == 1 and info.imem_words == 1024
    assert info.latch_words == device.latch_words
    assert client.device_info == info


def test_connect_rechaza_otra_version(clock):
    port = FakeSerial(FakeDebugUnit(version=2), clock)
    with pytest.raises(ProtocolError, match="versión 2"):
        DebugClient(port, clock=clock, sleep=clock.sleep).connect()


def test_connect_descarta_basura_previa(client, port):
    port.inject(b"\x5a\x00\xff\x13")          # basura al energizar la placa
    client.connect()
    assert len(port.requests(Cmd.INFO)) == 1


def test_connect_olvida_el_estado_anterior(connected, port):
    connected.load(PROG)
    connected.step()
    connected.connect()                       # p. ej. después de apretar el reset de la placa
    assert connected.last_status is None
    connected.step()
    assert [w[1] for w in port.written][-2:] == [Cmd.STATUS, Cmd.STEP]


def test_basura_antes_de_la_respuesta(connected, port):
    port.inject(b"\x00\x13\xa5")
    assert connected.status().state == State.NO_PROG


# ---- comandos -----------------------------------------------------------------------------

def test_load_carga_y_rellena_con_halt(connected, device):
    s = connected.load(PROG)
    assert s.state == State.READY and s.prog_valid and (s.pc, s.cycles) == (0, 0)
    assert device.imem[:3] == [ADDI_X1_5, HALT, HALT]
    assert connected.last_status == s


def test_load_de_un_programa_ensamblado(connected, device):
    words = assemble("addi x1, x0, 5\nsw x1, 0(x0)\nhalt\n")
    assert connected.load(words).state == State.READY
    assert device.imem[:len(words)] == words


def test_load_sin_conectar_pide_info(client, port):
    client.load(PROG)
    assert [w[1] for w in port.written] == [Cmd.INFO, Cmd.LOAD]


def test_step_avanza_un_ciclo(connected):
    connected.load(PROG)
    s1, s2 = connected.step(), connected.step()
    assert (s1.cycles, s2.cycles) == (1, 2)
    assert s2.state == State.PAUSED


def test_step_hasta_el_halt(connected):
    connected.load(PROG)
    states = [connected.step().state for _ in range(6)]
    assert states == [State.PAUSED] * 5 + [State.HALTED]
    with pytest.raises(DeviceError, match="ERR_STATE"):
        connected.step()


def test_run_y_evt_halted_de_ejemplo(connected, port):
    connected.load(PROG)
    connected.run()
    s = connected.wait_halted()
    assert s.state == State.HALTED and (s.pc, s.cycles) == (0x08, 6)
    assert port.sent[-1] == bytes.fromhex("5A E0 00 0C 00 04 03 00 00 08 00 00 00 06 00 00 00 E5")


def test_lecturas(connected, device):
    connected.load(PROG)
    device.regs[1], device.regs[31] = 5, 0xFFFF_FFFF
    device.write_dmem(0x10, 0xCAFE)
    device.write_dmem(0x04, 7)
    device.latches[0] = [0x11, 0x22, 0x1]
    regs = connected.read_regs()
    assert regs[1] == 5 and regs[31] == 0xFFFF_FFFF and len(regs) == 32
    assert connected.read_dmem(0x04, 4) == (7, 0, 0, 0xCAFE)
    assert connected.read_dmem_used() == ((0x04, 7), (0x10, 0xCAFE))
    lat = connected.read_latches()
    assert lat.if_id == (0x11, 0x22, 0x1) and len(lat.id_ex) == 6
    dump = connected.read_all()
    assert dump.status.dmem_used == 2 and dump.regs == regs
    assert dump.latches == lat and dump.used == ((0x04, 7), (0x10, 0xCAFE))
    assert connected.last_status == dump.status


def test_read_dmem_desalineada(connected, port):
    with pytest.raises(DeviceError, match="ERR_ADDR") as e:
        connected.read_dmem(0x02, 1)
    assert e.value.status == Err.ERR_ADDR
    assert len(port.requests(Cmd.READ_DMEM)) == 1     # un error del STATUS no se reintenta


def test_lectura_durante_run(connected, device):
    device.run_seconds = float("inf")
    connected.load(PROG)
    connected.run()
    with pytest.raises(DeviceError, match="ERR_STATE"):
        connected.read_regs()


def test_reset_vuelve_a_ready(connected):
    connected.load(PROG)
    connected.step()
    s = connected.reset()
    assert s.state == State.READY and s.cycles == 0


# ---- filtro de palabras (decisión 025) -------------------------------------------------------

def test_load_rechaza_palabras_fuera_de_isa(connected, port):
    blt = 0x00004063                   # blt x0, x0, 0: opcode de branch con funct3 = 100
    with pytest.raises(InvalidProgramError) as e:
        connected.load([ADDI_X1_5, 0x00000000, blt, HALT])
    assert len(e.value.problems) == 2
    assert e.value.problems[0].startswith("0x004: 0x00000000")
    assert "NOP" in e.value.problems[0]
    assert e.value.problems[1].startswith("0x008: 0x00004063")
    assert "no especificado" in e.value.problems[1]
    assert port.requests(Cmd.LOAD) == []


@pytest.mark.parametrize("words, motivo", [
    ([], "no tiene instrucciones"),
    ([HALT] * 1025, "1025 palabras"),
    ([1 << 32], "32 bits"),
    ([0x00000073], "SYSTEM"),          # ecall: SYSTEM distinta del HALT
])
def test_check_program(words, motivo):
    with pytest.raises(InvalidProgramError, match=motivo):
        check_program(words, 1024)


def test_load_usa_el_tamano_de_info(clock):
    port = FakeSerial(FakeDebugUnit(imem_words=4), clock)
    client = DebugClient(port, clock=clock, sleep=clock.sleep)
    with pytest.raises(InvalidProgramError, match="tiene 4"):
        client.load([HALT] * 5)


# ---- timeouts y reintentos (§5) ---------------------------------------------------------------

def test_reintenta_si_se_pierde_la_respuesta(connected, port, clock):
    port.drop_responses = 1
    t0 = clock()
    assert connected.status().state == State.NO_PROG
    assert len(port.requests(Cmd.STATUS)) == 2
    assert clock() - t0 >= response_timeout(5 + 6, 115200) + 0.15   # T_RESP y la espera


def test_load_grande_no_vence_mientras_sale_por_la_linea(connected, port):
    # T_RESP cuenta la petición (§5): 4101 B tardan 0,356 s y la respuesta sola daría 0,202 s
    port.latency = (4 + 4 * 1024 + 1) * 10 / 115200
    assert connected.load([HALT] * 1024).state == State.READY
    assert len(port.requests(Cmd.LOAD)) == 1


def test_reintenta_si_la_respuesta_llega_rota(connected, port):
    port.corrupt_responses = 1
    connected.status()
    assert len(port.requests(Cmd.STATUS)) == 2


def test_reintenta_ante_err_checksum(connected, port):
    port.corrupt_requests = 1
    assert connected.load(PROG).state == State.READY
    assert len(port.requests(Cmd.LOAD)) == 2
    assert port.sent[1][2] == Err.ERR_CHECKSUM          # la primera respuesta a LOAD


def test_reintenta_ante_err_timeout(connected, port):
    port.truncate_requests = 1
    assert connected.load(PROG).state == State.READY
    assert len(port.requests(Cmd.LOAD)) == 2
    assert port.sent[1][2] == Err.ERR_TIMEOUT


def test_sin_respuesta_despues_de_tres_reintentos(connected, port):
    port.drop_responses = 10
    with pytest.raises(NoResponseError, match="STATUS.*3 reintentos"):
        connected.status()
    assert len(port.requests(Cmd.STATUS)) == 4


def test_descarta_respuestas_viejas(connected, port):
    port.inject(build_response(Cmd.READ_REGS, Err.OK, bytes(128)))
    assert connected.status().state == State.NO_PROG
    assert len(port.requests(Cmd.STATUS)) == 1


def test_len_imposible_no_espera_65535_bytes(connected, port, clock):
    port.inject(bytes([0x5A, Cmd.STATUS, 0x00, 0xFF, 0xFF]))
    t0 = clock()
    connected.status()
    assert clock() - t0 < 1


def test_registro_de_tramas(port, clock):
    frames = []
    client = DebugClient(port, clock=clock, sleep=clock.sleep,
                         on_frame=lambda d, raw: frames.append((d, raw)))
    client.status()
    assert frames == [("tx", bytes.fromhex("A5 02 00 00 02")), ("rx", port.sent[0])]


# ---- STEP y RUN no se reintentan a ciegas (§5) ---------------------------------------------

def test_step_con_respuesta_perdida_no_se_repite(connected, port, device):
    connected.load(PROG)
    port.drop_responses = 1
    s = connected.step()
    assert s.cycles == 1 and device.cycles == 1
    assert len(port.requests(Cmd.STEP)) == 1


def test_step_con_peticion_perdida_se_repite(connected, port, device):
    connected.load(PROG)
    port.drop_requests = 1
    assert connected.step().cycles == 1
    assert len(port.requests(Cmd.STEP)) == 2 and device.cycles == 1


def test_step_sin_estado_previo_pide_status(client, port):
    client.load(PROG)
    client.last_status = None
    client.step()
    assert [w[1] for w in port.written][-2:] == [Cmd.STATUS, Cmd.STEP]


def test_step_despues_de_un_load_sin_respuesta(connected, port, device):
    connected.load(PROG)
    for _ in range(3):
        connected.step()
    port.drop_responses = 4            # la FPGA hace el LOAD (cycles = 0), pero no responde
    with pytest.raises(NoResponseError):
        connected.load(PROG)
    assert connected.last_status is None
    port.drop_responses = 1            # y se pierde la respuesta del STEP
    assert connected.step().cycles == 1
    assert device.cycles == 1          # con el cycles = 3 viejo, lo habría repetido


def test_run_con_confirmacion_perdida_no_se_repite(connected, port, device):
    device.run_seconds = float("inf")
    connected.load(PROG)
    port.drop_responses = 1
    connected.run()
    assert len(port.requests(Cmd.RUN)) == 1 and device.state == State.RUNNING
    assert connected.stop().state == State.PAUSED
    assert connected.wait_halted().state == State.PAUSED


def test_run_que_termino_antes_de_saberlo(connected, port):
    connected.load(PROG)
    port.drop_responses = 1            # se pierde la confirmación; el EVT llega antes que STATUS
    connected.run()
    assert len(port.requests(Cmd.RUN)) == 1
    assert connected.wait_halted().state == State.HALTED


def test_run_con_peticion_perdida_se_repite(connected, port):
    connected.load(PROG)
    port.drop_requests = 1
    connected.run()
    assert len(port.requests(Cmd.RUN)) == 2
    assert connected.wait_halted().state == State.HALTED


# ---- EVT_HALTED y watchdog ---------------------------------------------------------------------

def test_evt_antes_de_la_respuesta_a_status(connected, device, clock):
    device.run_seconds = 0.5
    connected.load(PROG)
    connected.run()
    clock.sleep(1)                     # el EVT ya está en la línea cuando se pide STATUS
    assert connected.status().state == State.HALTED
    assert connected.wait_halted().state == State.HALTED
    with pytest.raises(DebugError, match="no hay una ejecución"):
        connected.wait_halted()


def test_evt_que_llega_mientras_se_espera(connected, device, clock):
    device.run_seconds = 2.0
    connected.load(PROG)
    connected.run()
    t0 = clock()
    assert connected.wait_halted().state == State.HALTED
    assert 2.0 <= clock() - t0 < 2.1


def test_watchdog_y_stop(connected, device, clock):
    device.run_seconds = float("inf")
    connected.load(PROG)
    connected.run()
    t0 = clock()
    with pytest.raises(HaltTimeout, match="5 s"):
        connected.wait_halted()
    assert clock() - t0 >= 5
    s = connected.stop()
    assert s.state == State.PAUSED
    assert connected.wait_halted() == s


def test_run_nuevo_no_ve_el_final_del_anterior(connected, device, clock):
    connected.load(PROG)
    connected.run()                    # el EVT de esta corrida queda sin leer
    clock.sleep(0.1)
    connected.reset()                  # lo lee antes de la respuesta a RESET
    device.run_seconds = float("inf")
    connected.run()
    with pytest.raises(HaltTimeout):
        connected.wait_halted(timeout=1)


def test_evt_anterior_a_la_confirmacion_se_descarta(connected, port, device):
    """La FPGA manda el EVT_HALTED de un RUN siempre después de su confirmación (§3.5):
    uno que llega antes es de otra corrida."""
    device.run_seconds = float("inf")
    connected.load(PROG)
    stale = bytes.fromhex("04 03 00 00 08 00 00 00 06 00 00 00")
    port.inject(build_response(Cmd.EVT_HALTED, Err.OK, stale))
    connected.run()
    with pytest.raises(HaltTimeout):
        connected.wait_halted(timeout=1)


def test_evt_roto_mientras_se_espera(connected, port, device):
    device.run_seconds = 1.0
    connected.load(PROG)
    connected.run()
    port.corrupt_responses = 1         # el EVT llega con el CHK mal: STATUS dice que terminó
    assert connected.wait_halted().state == State.HALTED
    assert len(port.requests(Cmd.STATUS)) == 1


def test_stop_desde_otro_hilo():
    """Un hilo espera el final de RUN y otro lo para: el lock no queda tomado mientras
    se espera."""
    device = FakeDebugUnit()
    device.run_seconds = float("inf")
    client = DebugClient(FakeSerial(device, RealClock()))
    client.load(PROG)
    client.run()
    result = {}
    waiter = threading.Thread(target=lambda: result.update(s=client.wait_halted(timeout=3)))
    t0 = time.monotonic()
    waiter.start()
    time.sleep(0.1)
    client.stop()
    waiter.join(timeout=5)
    assert result["s"].state == State.PAUSED
    assert time.monotonic() - t0 < 1
