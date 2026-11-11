"""Puerto serie simulado con una Debug Unit detrás, para probar el cliente sin FPGA.

La Debug Unit sigue protocolo_debug.md a nivel de tramas: estados (§3.7), errores
(§5), descarte de bytes en reposo y timeout entre bytes (T_BYTE). El core es un
modelo mínimo y no ejecuta instrucciones: cada ciclo avanza el PC 4 bytes, al buscar
un HALT deja de buscar y el HALT llega a WB 4 ciclos después. Registros, memoria y
latches los fija cada test.

El tiempo lo da un reloj falso (FakeClock): leer sin datos lo adelanta `timeout`, así
los timeouts y las esperas de los reintentos no hacen esperar al test.
"""

import struct
import time

from rvdebug.protocol import (BAUD, Cmd, Err, State, build_response, checksum)

HALT = 0x00100073
T_BYTE = 0.1

ALLOWED = {            # §3.7: estados en que se acepta cada comando
    Cmd.RUN: {State.READY, State.PAUSED},
    Cmd.STEP: {State.READY, State.PAUSED},
}
READS = {Cmd.READ_REGS, Cmd.READ_LATCHES, Cmd.READ_DMEM, Cmd.READ_DMEM_USED, Cmd.READ_ALL}


class FakeClock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now

    def sleep(self, dt):
        self.now += max(0.0, dt)


class RealClock:
    def __call__(self):
        return time.monotonic()

    def sleep(self, dt):
        time.sleep(dt)


class FakeDebugUnit:
    def __init__(self, imem_words=1024, dmem_words=1024, latch_words=(3, 6, 4, 4),
                 clk_khz=100_000, version=1):
        self.imem_words, self.dmem_words = imem_words, dmem_words
        self.latch_words, self.clk_khz, self.version = latch_words, clk_khz, version
        self.imem = [0] * imem_words
        self.prog_valid = False
        self.state = State.NO_PROG
        self.latches = [[0] * n for n in latch_words]
        self.run_seconds = None   # None: lo que tarda el core a clk_khz; inf: no termina nunca
        self.requests = []        # (cmd, payload) de cada trama aceptada, para los tests
        self._clear()
        self._frame = None        # trama en recepción: bytearray sin el SOF
        self._last_byte = 0.0
        self._halt_at = None
        self._run_start = 0.0

    # ---- core mínimo ----------------------------------------------------------------

    def _clear(self):
        """Lo que limpian LOAD y RESET (§3.3 y §3.4)."""
        self.regs = [0] * 32
        self.dmem = [0] * self.dmem_words
        self.used = set()
        self.pc = self.cycles = 0
        self.flags_extra = 0      # avisos de acceso (bits 2 a 4), los pone el test
        self._halt_fetched = None
        self.halted = False

    def _tick(self):
        if self.halted:
            return
        self.cycles += 1
        if self._halt_fetched is None:
            if self.imem[(self.pc // 4) % self.imem_words] == HALT:
                self._halt_fetched = self.cycles
            self.pc += 4
        elif self.cycles - self._halt_fetched >= 4:
            self.halted = True

    def _cycles_to_halt(self):
        saved = (self.pc, self.cycles, self._halt_fetched, self.halted)
        n = 0
        while not self.halted and n < 100_000:
            self._tick()
            n += 1
        self.pc, self.cycles, self._halt_fetched, self.halted = saved
        return n

    def write_dmem(self, addr, value):
        """Como un store del core: escribe y marca la palabra como usada."""
        self.dmem[addr // 4] = value
        self.used.add(addr // 4)

    # ---- bloques ------------------------------------------------------------------

    def status_block(self):
        flags = int(self.prog_valid) | int(self.halted) << 1 | self.flags_extra
        return struct.pack("<BBHII", self.state, flags, len(self.used), self.pc, self.cycles)

    def info_block(self):
        return struct.pack("<BHH4BI", self.version, self.imem_words, self.dmem_words,
                           *self.latch_words, self.clk_khz)

    def regs_block(self):
        return struct.pack("<32I", *self.regs)

    def latches_block(self):
        return b"".join(struct.pack(f"<{len(w)}I", *w) for w in self.latches)

    def used_block(self):
        return b"".join(struct.pack("<II", 4 * i, self.dmem[i]) for i in sorted(self.used))

    # ---- recepción --------------------------------------------------------------------

    def feed(self, data, now):
        """Bytes de la PC. Devuelve las tramas que manda la FPGA en respuesta."""
        out = self.poll(now)
        for byte in data:
            if self._frame is None:
                if byte == 0xA5:          # en reposo se descarta todo lo demás (§2)
                    self._frame = bytearray()
                    self._last_byte = now
                continue
            self._frame.append(byte)
            self._last_byte = now
            if len(self._frame) >= 3:
                length = self._frame[1] | self._frame[2] << 8
                if len(self._frame) == 3 + length + 1:
                    frame, self._frame = bytes(self._frame), None
                    out += self._handle(frame, now)
        return out

    def poll(self, now):
        """Lo que la FPGA manda sin que llegue nada: ERR_TIMEOUT y EVT_HALTED."""
        out = []
        if self._frame is not None and now - self._last_byte > T_BYTE:
            cmd = self._frame[0] if self._frame else 0
            if cmd == Cmd.LOAD and len(self._frame) >= 3:
                self._lose_program()
            self._frame = None
            out.append(build_response(cmd, Err.ERR_TIMEOUT))
        if self.state == State.RUNNING and self._halt_at is not None and now >= self._halt_at:
            while not self.halted:
                self._tick()
            self.state = State.HALTED
            self._halt_at = None
            out.append(build_response(Cmd.EVT_HALTED, Err.OK, self.status_block()))
        return out

    def _lose_program(self):
        self.prog_valid = False
        self.state = State.NO_PROG
        self._halt_at = None

    def _length_ok(self, cmd, length):
        if cmd == Cmd.LOAD:
            return length % 4 == 0 and 1 <= length // 4 <= self.imem_words
        if cmd == Cmd.READ_DMEM:
            return length == 6
        return length == 0

    def _state_ok(self, cmd):
        if cmd in ALLOWED:
            return self.state in ALLOWED[cmd]
        if cmd in READS:
            return self.state != State.RUNNING
        return True

    def _handle(self, frame, now):
        cmd, length, payload, chk = frame[0], frame[1] | frame[2] << 8, frame[3:-1], frame[-1]
        try:
            cmd = Cmd(cmd)
        except ValueError:
            return [build_response(cmd, Err.ERR_UNKNOWN_CMD)]
        if cmd == Cmd.EVT_HALTED:
            return [build_response(cmd, Err.ERR_UNKNOWN_CMD)]
        if not self._length_ok(cmd, length):
            return [build_response(cmd, Err.ERR_LENGTH)]
        if not self._state_ok(cmd):
            return [build_response(cmd, Err.ERR_STATE)]
        if checksum(frame[:-1]) != chk:
            if cmd == Cmd.LOAD:
                self._lose_program()
            return [build_response(cmd, Err.ERR_CHECKSUM)]
        self.requests.append((cmd, bytes(payload)))
        return getattr(self, f"_cmd_{cmd.name.lower()}")(payload, now)

    # ---- comandos -----------------------------------------------------------------

    def _ok(self, cmd, payload=b""):
        return [build_response(cmd, Err.OK, payload)]

    def _cmd_info(self, payload, now):
        return self._ok(Cmd.INFO, self.info_block())

    def _cmd_status(self, payload, now):
        return self._ok(Cmd.STATUS, self.status_block())

    def _cmd_load(self, payload, now):
        words = struct.unpack(f"<{len(payload) // 4}I", payload)
        self.imem = list(words) + [HALT] * (self.imem_words - len(words))
        self.prog_valid = True
        self._reset_core()
        return self._ok(Cmd.LOAD, self.status_block())

    def _reset_core(self):
        self._clear()
        self._halt_at = None
        self.state = State.READY if self.prog_valid else State.NO_PROG

    def _cmd_reset(self, payload, now):
        self._reset_core()
        return self._ok(Cmd.RESET, self.status_block())

    def _cmd_run(self, payload, now):
        self.state = State.RUNNING
        self._run_start = now
        if self.run_seconds is None:
            self._halt_at = now + self._cycles_to_halt() / (self.clk_khz * 1000)
        elif self.run_seconds == float("inf"):
            self._halt_at = None
        else:
            self._halt_at = now + self.run_seconds
        return self._ok(Cmd.RUN)

    def _cmd_step(self, payload, now):
        self._tick()
        self.state = State.HALTED if self.halted else State.PAUSED
        return self._ok(Cmd.STEP, self.status_block())

    def _cmd_stop(self, payload, now):
        if self.state == State.RUNNING:
            self.cycles += max(1, int((now - self._run_start) * 1000))
            self.state = State.PAUSED
            self._halt_at = None
        return self._ok(Cmd.STOP, self.status_block())

    def _cmd_read_regs(self, payload, now):
        return self._ok(Cmd.READ_REGS, self.regs_block())

    def _cmd_read_latches(self, payload, now):
        return self._ok(Cmd.READ_LATCHES, self.latches_block())

    def _cmd_read_dmem(self, payload, now):
        addr, count = struct.unpack("<IH", payload)
        if addr % 4 or count == 0 or addr + 4 * count > 4 * self.dmem_words:
            return [build_response(Cmd.READ_DMEM, Err.ERR_ADDR)]
        words = self.dmem[addr // 4: addr // 4 + count]
        return self._ok(Cmd.READ_DMEM, struct.pack(f"<{count}I", *words))

    def _cmd_read_dmem_used(self, payload, now):
        return self._ok(Cmd.READ_DMEM_USED, self.used_block())

    def _cmd_read_all(self, payload, now):
        return self._ok(Cmd.READ_ALL, self.status_block() + self.regs_block()
                        + self.latches_block() + self.used_block())


class FakeSerial:
    """Puerto con la interfaz de pyserial que usa el cliente, con fallos inyectables.

    Cada contador afecta a las próximas N tramas en ese sentido:
    - `drop_requests`: la petición no llega a la FPGA;
    - `truncate_requests`: llega solo la primera mitad (la FPGA responde ERR_TIMEOUT);
    - `corrupt_requests`: llega con el CHK mal (la FPGA responde ERR_CHECKSUM);
    - `drop_responses`: la respuesta no llega a la PC;
    - `corrupt_responses`: la respuesta llega con el CHK mal.
    """

    def __init__(self, device=None, clock=None, latency=0.0):
        self.device = device or FakeDebugUnit()
        self.clock = clock or FakeClock()
        self.latency = latency
        self.timeout = 0.02
        self.baudrate = BAUD
        self.drop_requests = self.truncate_requests = self.corrupt_requests = 0
        self.drop_responses = self.corrupt_responses = 0
        self.written = []         # peticiones tal como las escribió el cliente
        self.sent = []            # tramas que mandó la FPGA (antes de los fallos de línea)
        self._rx = bytearray()
        self._pending = []        # (instante en que llega, bytes)

    def _emit(self, frames):
        for frame in frames:
            self.sent.append(frame)
            if self.drop_responses:
                self.drop_responses -= 1
                continue
            if self.corrupt_responses:
                self.corrupt_responses -= 1
                frame = frame[:-1] + bytes([frame[-1] ^ 0x01])
            self._pending.append((self.clock() + self.latency, frame))

    def _deliver(self):
        now = self.clock()
        self._emit(self.device.poll(now))
        ready = [data for at, data in self._pending if at <= now]
        self._pending = [(at, data) for at, data in self._pending if at > now]
        for data in ready:
            self._rx += data

    def inject(self, data):
        """Bytes que llegan a la PC sin que los mande la Debug Unit (ruido, tramas viejas)."""
        self._rx += data

    # ---- interfaz de pyserial ------------------------------------------------------------

    def write(self, data):
        data = bytes(data)
        self.written.append(data)
        if self.drop_requests:
            self.drop_requests -= 1
            return len(data)
        if self.truncate_requests:
            self.truncate_requests -= 1
            data = data[:len(data) // 2]
        elif self.corrupt_requests:
            self.corrupt_requests -= 1
            data = data[:-1] + bytes([data[-1] ^ 0x01])
        self._emit(self.device.feed(data, self.clock()))
        return len(data)

    def flush(self):
        pass

    def read(self, n=1):
        self._deliver()
        if not self._rx:
            self.clock.sleep(self.timeout)
            self._deliver()
        out = bytes(self._rx[:n])
        del self._rx[:n]
        return out

    @property
    def in_waiting(self):
        self._deliver()
        return len(self._rx)

    def reset_input_buffer(self):
        self._deliver()
        self._rx.clear()

    def requests(self, cmd):
        """Peticiones de un comando que escribió el cliente (aunque no hayan llegado)."""
        return [w for w in self.written if len(w) > 1 and w[1] == cmd]
