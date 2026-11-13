`timescale 1ns / 1ps
`default_nettype none

//======================================================================
// debug_unit
//
// FSM de protocolo de la Debug Unit (I-45, decisiones 006 y 036,
// docs/spec/protocolo_debug.md §2 a §5 y §7, diagrama debug_unit_fsm),
// con la carga de programa (I-46, decisión 037, memoria.md §4).
//
// Función:
//   Recibe peticiones por la interfaz de bytes de uart (decisión 035), las
//   valida, avisa qué comando se aceptó y transmite la respuesta. Una
//   trama por vez:
//     IDLE        descarta todo byte distinto de 0xA5 (SOF). Si
//                 i_evt_pending = 1 y no hay trama en curso, manda el
//                 EVT_HALTED antes de leer más bytes.
//     RX_CMD,     guardan CMD y LEN (little-endian); chk ^= byte.
//     RX_LEN_L/H  (RX_LEN del diagrama)
//     CHECK_HDR   1 ciclo. Valida en este orden: CMD conocido
//                 (ERR_UNKNOWN_CMD), LEN del comando (ERR_LENGTH) y estado
//                 de ejecución, tabla de §3.7 (ERR_STATE).
//     LOAD_PREP   1 ciclo, con un LOAD válido: pulsa o_load_start (la FSM
//                 de ejecución baja prog_valid y pasa a NO_PROG: core
//                 detenido y en reset) y pone el puntero de imem en 0.
//     RX_PAYLOAD  guarda el payload (los 6 bytes de READ_DMEM quedan en
//                 o_arg_addr y o_arg_count); chk ^= byte. En un LOAD arma
//                 cada palabra con 4 bytes (little-endian) y la escribe en
//                 imem por el puerto B con el 4.º byte (memoria.md §4.2).
//     DISCARD     con error de encabezado: consume los LEN bytes que
//                 faltan y el CHK, sin efectos, y responde ese error
//                 aunque el CHK esté mal.
//     RX_CHK      compara el byte con chk (ERR_CHECKSUM si difiere).
//     EXEC        1 ciclo. Valida addr y count de READ_DMEM (ERR_ADDR). Si
//                 no hay error, pulsa o_cmd_valid: el resto de la Debug
//                 Unit ejecuta el comando. Calcula el LEN de la respuesta.
//     CLEAR       solo LOAD y RESET, antes de responder: recorre las
//                 direcciones 0 … max(IMEM_WORDS, DMEM_WORDS) − 1, un ciclo
//                 por dirección. En un LOAD escribe HALT en imem[N …]; en
//                 los dos escribe 0 en dmem y pulsa o_used_clr (mapa de
//                 palabras usadas, I-48). o_clearing = 1 mientras dura: la
//                 FSM de ejecución mantiene el core en reset.
//     TX_HDR      envía 5A, CMD, STATUS, LEN_L, LEN_H.
//     TX_PAYLOAD  envía LEN bytes: el bloque de INFO (§3.2), el bloque de
//                 estado (§3.1) o i_pl_byte (lecturas, I-48).
//     TX_CHK      envía el XOR desde CMD hasta el último byte del payload.
//   Toda respuesta con error tiene LEN = 0. En los estados que esperan un
//   byte de la trama, si pasan RX_TIMEOUT_CYCLES ciclos sin uno, responde
//   ERR_TIMEOUT con el CMD recibido (0x00 si no llegó) y vuelve a IDLE. En
//   IDLE no hay timeout.
//   El bloque de estado se arma con las entradas al terminar de enviar el
//   encabezado (snapshot): ya pasaron los efectos del comando, y pc y
//   cycles no cambian a mitad del envío si el core está corriendo.
//   Un LOAD con error de checksum o timeout después de LOAD_PREP deja imem
//   a medio escribir y no llega a EXEC: no hay CLEAR ni o_cmd_valid, y la
//   FSM de ejecución queda en NO_PROG (memoria.md §4.3). No hay
//   STEP_PULSE: el ciclo de enable del STEP lo da debug_exec, la FSM de
//   ejecución (decisión 037). No usa enable (decisión 018).
//
// Parámetros:
//   CLK_FREQ_HZ       : frecuencia de i_clk en Hz (clk_khz de INFO)
//   RX_TIMEOUT_CYCLES : T_BYTE en ciclos (§5: CLK_FREQ_HZ / 10 = 100 ms)
//   IMEM_WORDS        : palabras de la memoria de programa (1024)
//   DMEM_WORDS        : palabras de la memoria de datos (1024)
//   NB_MEM_ADDR       : bits del índice de palabra de imem y dmem (10)
//   NB_*_LATCH        : bits de cada bus de latch (pipeline.md §8,
//                       decisión 023); INFO informa ceil(NB / 32) palabras
//   NB_BYTE, NB_WORD, NB_LEN, NB_STATE : anchos fijos del protocolo (8,
//                       32, 16 y 3)
//
// Puertos:
//   i_clk             : reloj del sistema
//   i_rst             : reset del sistema, síncrono, activo en alto (no core_rst)
//   i_r_data          : byte más viejo recibido por uart       [NB_BYTE-1:0]
//   i_rx_empty        : uart no tiene bytes recibidos sin leer
//   o_rd              : pulso: consume i_r_data
//   o_w_data          : byte a transmitir                      [NB_BYTE-1:0]
//   o_wr              : pulso: transmite o_w_data (solo con i_tx_full = 0)
//   i_tx_full         : uart todavía está enviando el byte anterior
//   i_state           : estado de ejecución, DBG_ST_* (FSM de ejecución)
//   i_prog_valid      : flags bit 0
//   i_halted          : flags bit 1 (HALT llegó a WB)
//   i_imem_fault      : flags bit 2
//   i_dmem_oob        : flags bit 3
//   i_dmem_misaligned : flags bit 4
//   i_dmem_used       : palabras de dmem escritas               [NB_LEN-1:0]
//   i_pc              : PC del core                            [NB_WORD-1:0]
//   i_cycles          : ciclos ejecutados                      [NB_WORD-1:0]
//   i_evt_pending     : hay un EVT_HALTED por enviar
//   o_evt_done        : pulso: se envió el último byte del EVT_HALTED; quien
//                       maneja i_evt_pending lo baja en ese mismo flanco
//   o_cmd_valid       : pulso de un ciclo: se aceptó o_cmd sin errores
//   o_cmd             : CMD de la trama en curso               [NB_BYTE-1:0]
//   o_arg_addr        : addr de READ_DMEM                      [NB_WORD-1:0]
//   o_arg_count       : count de READ_DMEM                     [NB_LEN-1:0]
//   o_load_start      : pulso en LOAD_PREP: empieza un LOAD válido
//   o_clearing        : 1 durante CLEAR
//   o_imem_b_en       : puerto B de imem: habilita (pulso por palabra)
//   o_imem_b_we       : puerto B de imem: escritura (igual a o_imem_b_en)
//   o_imem_b_addr     : puerto B de imem: índice de palabra [NB_MEM_ADDR-1:0]
//   o_imem_b_din      : puerto B de imem: palabra               [NB_WORD-1:0]
//   o_dmem_b_en       : puerto B de dmem: habilita (solo en CLEAR)
//   o_dmem_b_we       : puerto B de dmem: escritura por byte (1111 en CLEAR) [3:0]
//   o_dmem_b_addr     : puerto B de dmem: índice de palabra [NB_MEM_ADDR-1:0]
//   o_dmem_b_din      : puerto B de dmem: palabra (siempre 0)   [NB_WORD-1:0]
//   o_used_clr        : pulso: borrar la palabra o_dmem_b_addr del mapa de
//                       usadas (en CLEAR, con o_dmem_b_en)
//   o_pl_idx          : índice del byte de payload que se envía, contado
//                       desde el primer byte del payload       [NB_LEN-1:0]
//   i_pl_byte         : byte o_pl_idx de la respuesta a READ_REGS,
//                       READ_LATCHES, READ_DMEM, READ_DMEM_USED y READ_ALL.
//                       En READ_ALL o_pl_idx no se reinicia después del
//                       bloque de estado: los bytes 0 a 11 los arma
//                       debug_unit y la fuente entrega desde o_pl_idx = 12
//                       (el 12 es x0[7:0]). Puede llegar hasta 2 ciclos
//                       después de que cambie o_pl_idx (desde una BRAM)
//                                                              [NB_BYTE-1:0]
//
// Latencia: la respuesta empieza 3 ciclos después del CHK (RX_CHK, EXEC,
//           TX_HDR), más max(IMEM_WORDS, DMEM_WORDS) ciclos de CLEAR en
//           LOAD y RESET; o_cmd_valid está en el ciclo de EXEC. La
//           palabra se escribe en imem en el ciclo en que se lee su 4.º
//           byte. Cada byte
//           espera i_tx_full = 0, y después de o_wr, i_tx_full = 1 en el
//           ciclo siguiente (uart, decisión 035), así que o_pl_idx cambia
//           al menos 2 ciclos antes de que se use i_pl_byte.
// Reset   : IDLE, sin evento en curso. Los registros de datos no se
//           resetean: se cargan antes de usarse.
//======================================================================

module debug_unit
#(
    parameter integer CLK_FREQ_HZ       = 100_000_000,
    parameter integer RX_TIMEOUT_CYCLES = CLK_FREQ_HZ / 10,
    parameter integer IMEM_WORDS        = 1024,
    parameter integer DMEM_WORDS        = 1024,
    parameter integer NB_MEM_ADDR       = 10,
    parameter integer NB_IF_ID_LATCH    = 65,
    parameter integer NB_ID_EX_LATCH    = 161,
    parameter integer NB_EX_MEM_LATCH   = 109,
    parameter integer NB_MEM_WB_LATCH   = 110,
    parameter integer NB_BYTE           = 8,
    parameter integer NB_WORD           = 32,
    parameter integer NB_LEN            = 16,
    parameter integer NB_STATE          = 3
)
(
    input  wire                i_clk,
    input  wire                i_rst,
    // uart (decisión 035)
    input  wire [NB_BYTE-1:0]  i_r_data,
    input  wire                i_rx_empty,
    output wire                o_rd,
    output wire [NB_BYTE-1:0]  o_w_data,
    output wire                o_wr,
    input  wire                i_tx_full,
    // Estado de ejecución y bloque de estado (§3.1)
    input  wire [NB_STATE-1:0] i_state,
    input  wire                i_prog_valid,
    input  wire                i_halted,
    input  wire                i_imem_fault,
    input  wire                i_dmem_oob,
    input  wire                i_dmem_misaligned,
    input  wire [NB_LEN-1:0]   i_dmem_used,
    input  wire [NB_WORD-1:0]  i_pc,
    input  wire [NB_WORD-1:0]  i_cycles,
    // EVT_HALTED
    input  wire                i_evt_pending,
    output wire                o_evt_done,
    // Comando aceptado
    output wire                o_cmd_valid,
    output wire [NB_BYTE-1:0]  o_cmd,
    output wire [NB_WORD-1:0]  o_arg_addr,
    output wire [NB_LEN-1:0]   o_arg_count,
    // Carga de programa (I-46)
    output wire                   o_load_start,
    output wire                   o_clearing,
    output wire                   o_imem_b_en,
    output wire                   o_imem_b_we,
    output wire [NB_MEM_ADDR-1:0] o_imem_b_addr,
    output wire [NB_WORD-1:0]     o_imem_b_din,
    output wire                   o_dmem_b_en,
    output wire [3:0]             o_dmem_b_we,
    output wire [NB_MEM_ADDR-1:0] o_dmem_b_addr,
    output wire [NB_WORD-1:0]     o_dmem_b_din,
    output wire                   o_used_clr,
    // Payload de las lecturas (I-48)
    output wire [NB_LEN-1:0]   o_pl_idx,
    input  wire [NB_BYTE-1:0]  i_pl_byte
);

    `include "riscv_defs.vh"

    //------------------------------------------------------------------
    // Constantes
    //------------------------------------------------------------------
    // Estados de la FSM de protocolo (diagrama debug_unit_fsm)
    localparam [3:0] ST_IDLE       = 4'd0;
    localparam [3:0] ST_RX_CMD     = 4'd1;
    localparam [3:0] ST_RX_LEN_L   = 4'd2;
    localparam [3:0] ST_RX_LEN_H   = 4'd3;
    localparam [3:0] ST_CHECK_HDR  = 4'd4;
    localparam [3:0] ST_RX_PAYLOAD = 4'd5;
    localparam [3:0] ST_DISCARD    = 4'd6;
    localparam [3:0] ST_RX_CHK     = 4'd7;
    localparam [3:0] ST_EXEC       = 4'd8;
    localparam [3:0] ST_TX_HDR     = 4'd9;
    localparam [3:0] ST_TX_PAYLOAD = 4'd10;
    localparam [3:0] ST_TX_CHK     = 4'd11;
    localparam [3:0] ST_LOAD_PREP  = 4'd12;
    localparam [3:0] ST_CLEAR      = 4'd13;

    // Timeout entre bytes (§5)
    localparam integer NB_TOUT = $clog2(RX_TIMEOUT_CYCLES + 1);
    localparam [NB_TOUT-1:0] TOUT_LAST = RX_TIMEOUT_CYCLES - 1;

    // Bloque de información (§3.2)
    localparam [7:0]  PROTO_VERSION = 8'd1;
    localparam [7:0]  LW_IF_ID      = (NB_IF_ID_LATCH  + 31) / 32;
    localparam [7:0]  LW_ID_EX      = (NB_ID_EX_LATCH  + 31) / 32;
    localparam [7:0]  LW_EX_MEM     = (NB_EX_MEM_LATCH + 31) / 32;
    localparam [7:0]  LW_MEM_WB     = (NB_MEM_WB_LATCH + 31) / 32;
    localparam [15:0] INFO_IMEM     = IMEM_WORDS;
    localparam [15:0] INFO_DMEM     = DMEM_WORDS;
    localparam [31:0] CLK_KHZ       = CLK_FREQ_HZ / 1000;

    // LEN de las respuestas OK (§3)
    localparam [NB_LEN-1:0] LEN_INFO    = 16'd13;
    localparam [NB_LEN-1:0] LEN_STATUS  = 16'd12;
    localparam [NB_LEN-1:0] LEN_REGS    = 16'd128;
    localparam [NB_LEN-1:0] LEN_LATCHES = 4 * (LW_IF_ID + LW_ID_EX + LW_EX_MEM + LW_MEM_WB);

    // Límites de la validación
    localparam [NB_LEN:0]  LOAD_MAX_LEN = 4 * IMEM_WORDS;    // LEN = 4N, N <= IMEM_WORDS
    localparam [NB_LEN-1:0] DMEM_ARGS_LEN = 16'd6;            // addr (4 B) + count (2 B)
    localparam [33:0]      DMEM_BYTES   = 4 * DMEM_WORDS;

    // Recorrido de CLEAR: max(IMEM_WORDS, DMEM_WORDS) direcciones
    localparam integer CLR_WORDS = (IMEM_WORDS > DMEM_WORDS) ? IMEM_WORDS : DMEM_WORDS;
    localparam [NB_MEM_ADDR-1:0] CLR_LAST = CLR_WORDS - 1;

    //------------------------------------------------------------------
    // Registros
    //------------------------------------------------------------------
    reg [3:0]          state_reg,   state_next;
    reg [NB_BYTE-1:0]  cmd_reg,     cmd_next;      // CMD (0xE0 en el evento)
    reg [NB_LEN-1:0]   len_reg,     len_next;      // LEN de la petición
    reg [NB_LEN:0]     cnt_reg,     cnt_next;      // bytes que faltan (RX_PAYLOAD, DISCARD)
    reg [NB_BYTE-1:0]  chk_reg,     chk_next;
    reg [NB_BYTE-1:0]  err_reg,     err_next;      // STATUS de la respuesta
    reg [47:0]         arg_reg,     arg_next;      // últimos 6 bytes del payload
    reg [NB_TOUT-1:0]  tout_reg,    tout_next;
    reg [NB_LEN-1:0]   idx_reg,     idx_next;      // byte del encabezado o del payload
    reg [NB_LEN-1:0]   rsp_len_reg, rsp_len_next;  // LEN de la respuesta
    reg                evt_reg,     evt_next;      // la trama que sale es el EVT_HALTED
    reg [95:0]         snap_reg,    snap_next;     // bloque de estado que se envía
    reg [NB_MEM_ADDR-1:0] addr_reg, addr_next;     // palabra de imem (LOAD) o de CLEAR

    //------------------------------------------------------------------
    // Bytes de entrada y salida
    //------------------------------------------------------------------
    wire rx_group = (state_reg == ST_RX_CMD)     | (state_reg == ST_RX_LEN_L) |
                    (state_reg == ST_RX_LEN_H)   | (state_reg == ST_RX_PAYLOAD) |
                    (state_reg == ST_DISCARD)    | (state_reg == ST_RX_CHK);
    wire idle_rx  = (state_reg == ST_IDLE) & ~i_evt_pending;
    wire rx_strobe = ~i_rx_empty & (rx_group | idle_rx);
    wire [NB_BYTE-1:0] rx_byte = i_r_data;

    wire tx_group = (state_reg == ST_TX_HDR) | (state_reg == ST_TX_PAYLOAD) |
                    (state_reg == ST_TX_CHK);
    wire tx_strobe = tx_group & ~i_tx_full;

    //------------------------------------------------------------------
    // Validación del encabezado (CHECK_HDR) y de READ_DMEM (EXEC)
    //------------------------------------------------------------------
    reg cmd_known;
    reg len_ok;
    reg state_ok;

    always @(*) begin
        cmd_known = 1'b0;
        len_ok    = (len_reg == {NB_LEN{1'b0}});
        state_ok  = 1'b1;
        case (cmd_reg)
            DBG_CMD_INFO, DBG_CMD_STATUS, DBG_CMD_RESET, DBG_CMD_STOP:
                cmd_known = 1'b1;
            DBG_CMD_LOAD: begin
                cmd_known = 1'b1;
                len_ok    = (len_reg[1:0] == 2'b00) & (len_reg != {NB_LEN{1'b0}}) &
                            ({1'b0, len_reg} <= LOAD_MAX_LEN);
            end
            DBG_CMD_RUN, DBG_CMD_STEP: begin
                cmd_known = 1'b1;
                state_ok  = (i_state == DBG_ST_READY) | (i_state == DBG_ST_PAUSED);
            end
            DBG_CMD_READ_REGS, DBG_CMD_READ_LATCHES, DBG_CMD_READ_DMEM_USED,
            DBG_CMD_READ_ALL: begin
                cmd_known = 1'b1;
                state_ok  = (i_state != DBG_ST_RUNNING);
            end
            DBG_CMD_READ_DMEM: begin
                cmd_known = 1'b1;
                len_ok    = (len_reg == DMEM_ARGS_LEN);
                state_ok  = (i_state != DBG_ST_RUNNING);
            end
            default: ;
        endcase
    end

    reg [NB_BYTE-1:0] hdr_err;

    always @(*) begin
        hdr_err = DBG_OK;
        if (!cmd_known)
            hdr_err = DBG_ERR_UNKNOWN_CMD;
        else if (!len_ok)
            hdr_err = DBG_ERR_LENGTH;
        else if (!state_ok)
            hdr_err = DBG_ERR_STATE;
    end

    // READ_DMEM: addr alineada, count > 0 y addr + 4·count <= 4·DMEM_WORDS,
    // en 34 bits para que no dé la vuelta (§3.6)
    wire [NB_WORD-1:0] arg_addr  = arg_reg[31:0];
    wire [NB_LEN-1:0]  arg_count = arg_reg[47:32];
    wire [33:0]        rd_end    = {2'b00, arg_addr} + {16'b0, arg_count, 2'b00};
    wire addr_ok  = (arg_addr[1:0] == 2'b00) & (arg_count != {NB_LEN{1'b0}}) &
                    (rd_end <= DMEM_BYTES);
    wire addr_err = (cmd_reg == DBG_CMD_READ_DMEM) & ~addr_ok;

    //------------------------------------------------------------------
    // LEN y fuente del payload de la respuesta OK
    //------------------------------------------------------------------
    reg [NB_LEN-1:0] ok_len;

    always @(*) begin
        case (cmd_reg)
            DBG_CMD_INFO:           ok_len = LEN_INFO;
            DBG_CMD_STATUS, DBG_CMD_LOAD, DBG_CMD_RESET, DBG_CMD_STEP,
            DBG_CMD_STOP:           ok_len = LEN_STATUS;
            DBG_CMD_READ_REGS:      ok_len = LEN_REGS;
            DBG_CMD_READ_LATCHES:   ok_len = LEN_LATCHES;
            DBG_CMD_READ_DMEM:      ok_len = {arg_count[NB_LEN-3:0], 2'b00};
            DBG_CMD_READ_DMEM_USED: ok_len = {i_dmem_used[NB_LEN-4:0], 3'b000};
            DBG_CMD_READ_ALL:       ok_len = LEN_STATUS + LEN_REGS + LEN_LATCHES +
                                             {i_dmem_used[NB_LEN-4:0], 3'b000};
            default:                ok_len = {NB_LEN{1'b0}};   // RUN
        endcase
    end

    //------------------------------------------------------------------
    // Carga de programa (memoria.md §4.2) y CLEAR
    //------------------------------------------------------------------
    wire is_load  = (cmd_reg == DBG_CMD_LOAD);
    wire is_reset = (cmd_reg == DBG_CMD_RESET);

    // En RX_PAYLOAD de un LOAD, cnt_reg arranca en LEN (múltiplo de 4) y
    // baja con cada byte: el 4.º byte de cada palabra llega con cnt ≡ 1 (mod 4).
    // arg_reg tiene los 3 anteriores en [47:24], el primero en [31:24]
    wire load_word = (state_reg == ST_RX_PAYLOAD) & is_load & rx_strobe &
                     (cnt_reg[1:0] == 2'b01);
    wire [NB_WORD-1:0] load_data = {rx_byte, arg_reg[47:24]};

    // CLEAR: HALT en imem[N …] (solo LOAD, N = LEN / 4) y 0 en dmem
    wire clearing  = (state_reg == ST_CLEAR);
    wire [NB_LEN-2:0] n_words = len_reg[NB_LEN-1:2];
    wire clr_imem  = clearing & is_load & ({{(NB_LEN-1-NB_MEM_ADDR){1'b0}}, addr_reg} >= n_words) &
                     ({1'b0, addr_reg} < IMEM_WORDS);
    wire clr_dmem  = clearing & ({1'b0, addr_reg} < DMEM_WORDS);

    wire src_info   = (cmd_reg == DBG_CMD_INFO);
    wire src_status = evt_reg | (cmd_reg == DBG_CMD_STATUS) | (cmd_reg == DBG_CMD_LOAD) |
                      (cmd_reg == DBG_CMD_RESET) | (cmd_reg == DBG_CMD_STEP) |
                      (cmd_reg == DBG_CMD_STOP) |
                      ((cmd_reg == DBG_CMD_READ_ALL) & (idx_reg < LEN_STATUS));

    //------------------------------------------------------------------
    // Bloques de información y de estado, byte 0 en los bits bajos
    //------------------------------------------------------------------
    wire [8*13-1:0] info_block = {CLK_KHZ, LW_MEM_WB, LW_EX_MEM, LW_ID_EX, LW_IF_ID,
                                  INFO_DMEM, INFO_IMEM, PROTO_VERSION};

    wire [7:0]  flags       = {3'b000, i_dmem_misaligned, i_dmem_oob, i_imem_fault,
                               i_halted, i_prog_valid};
    wire [95:0] status_live = {i_cycles, i_pc, i_dmem_used, flags,
                               {(8-NB_STATE){1'b0}}, i_state};

    reg [NB_BYTE-1:0] tx_byte;

    always @(*) begin
        tx_byte = chk_reg;                                   // TX_CHK
        if (state_reg == ST_TX_HDR) begin
            case (idx_reg[2:0])
                3'd0:    tx_byte = DBG_SOF_RSP;
                3'd1:    tx_byte = cmd_reg;
                3'd2:    tx_byte = err_reg;
                3'd3:    tx_byte = rsp_len_reg[7:0];
                default: tx_byte = rsp_len_reg[15:8];
            endcase
        end
        else if (state_reg == ST_TX_PAYLOAD) begin
            if (src_info)
                tx_byte = info_block[8*idx_reg[3:0] +: 8];
            else if (src_status)
                tx_byte = snap_reg[8*idx_reg[3:0] +: 8];
            else
                tx_byte = i_pl_byte;
        end
    end

    //------------------------------------------------------------------
    // Secuencial
    //------------------------------------------------------------------
    always @(posedge i_clk) begin
        if (i_rst) begin
            state_reg <= ST_IDLE;
            evt_reg   <= 1'b0;
        end
        else begin
            state_reg <= state_next;
            evt_reg   <= evt_next;
        end
        cmd_reg     <= cmd_next;
        len_reg     <= len_next;
        cnt_reg     <= cnt_next;
        chk_reg     <= chk_next;
        err_reg     <= err_next;
        arg_reg     <= arg_next;
        tout_reg    <= tout_next;
        idx_reg     <= idx_next;
        rsp_len_reg <= rsp_len_next;
        snap_reg    <= snap_next;
        addr_reg    <= addr_next;
    end

    //------------------------------------------------------------------
    // Siguiente estado y camino de datos
    //------------------------------------------------------------------
    always @(*) begin
        state_next   = state_reg;
        cmd_next     = cmd_reg;
        len_next     = len_reg;
        cnt_next     = cnt_reg;
        chk_next     = chk_reg;
        err_next     = err_reg;
        arg_next     = arg_reg;
        tout_next    = tout_reg;
        idx_next     = idx_reg;
        rsp_len_next = rsp_len_reg;
        evt_next     = evt_reg;
        snap_next    = snap_reg;
        addr_next    = addr_reg;

        // Timeout entre bytes de una trama: se reinicia con cada byte
        if (rx_group) begin
            if (rx_strobe)
                tout_next = {NB_TOUT{1'b0}};
            else if (tout_reg == TOUT_LAST) begin
                err_next     = DBG_ERR_TIMEOUT;
                rsp_len_next = {NB_LEN{1'b0}};
                idx_next     = {NB_LEN{1'b0}};
                chk_next     = 8'h00;
                state_next   = ST_TX_HDR;
            end
            else
                tout_next = tout_reg + 1'b1;
        end

        case (state_reg)
            ST_IDLE: begin
                if (i_evt_pending) begin
                    evt_next     = 1'b1;
                    cmd_next     = DBG_CMD_EVT_HALTED;
                    err_next     = DBG_OK;
                    rsp_len_next = LEN_STATUS;
                    idx_next     = {NB_LEN{1'b0}};
                    chk_next     = 8'h00;
                    state_next   = ST_TX_HDR;
                end
                else if (rx_strobe && (rx_byte == DBG_SOF_REQ)) begin
                    cmd_next   = 8'h00;              // ERR_TIMEOUT antes del CMD
                    chk_next   = 8'h00;
                    tout_next  = {NB_TOUT{1'b0}};
                    state_next = ST_RX_CMD;
                end
            end

            ST_RX_CMD: begin
                if (rx_strobe) begin
                    cmd_next   = rx_byte;
                    chk_next   = chk_reg ^ rx_byte;
                    state_next = ST_RX_LEN_L;
                end
            end

            ST_RX_LEN_L: begin
                if (rx_strobe) begin
                    len_next[7:0] = rx_byte;
                    chk_next      = chk_reg ^ rx_byte;
                    state_next    = ST_RX_LEN_H;
                end
            end

            ST_RX_LEN_H: begin
                if (rx_strobe) begin
                    len_next[15:8] = rx_byte;
                    chk_next       = chk_reg ^ rx_byte;
                    state_next     = ST_CHECK_HDR;
                end
            end

            ST_CHECK_HDR: begin
                if (hdr_err != DBG_OK) begin
                    err_next   = hdr_err;
                    cnt_next   = {1'b0, len_reg} + 1'b1;   // payload y CHK
                    state_next = ST_DISCARD;
                end
                else if (is_load)
                    state_next = ST_LOAD_PREP;
                else if (len_reg == {NB_LEN{1'b0}})
                    state_next = ST_RX_CHK;
                else begin
                    cnt_next   = {1'b0, len_reg};
                    state_next = ST_RX_PAYLOAD;
                end
            end

            ST_LOAD_PREP: begin                        // o_load_start
                addr_next  = {NB_MEM_ADDR{1'b0}};
                cnt_next   = {1'b0, len_reg};           // LEN > 0, múltiplo de 4
                state_next = ST_RX_PAYLOAD;
            end

            ST_RX_PAYLOAD: begin
                if (rx_strobe) begin
                    chk_next = chk_reg ^ rx_byte;
                    arg_next = {rx_byte, arg_reg[47:8]};    // el primero termina en [7:0]
                    cnt_next = cnt_reg - 1'b1;
                    if (load_word)                           // palabra escrita en imem
                        addr_next = addr_reg + 1'b1;
                    if (cnt_reg == {{NB_LEN{1'b0}}, 1'b1})
                        state_next = ST_RX_CHK;
                end
            end

            ST_DISCARD: begin
                if (rx_strobe) begin
                    cnt_next = cnt_reg - 1'b1;
                    if (cnt_reg == {{NB_LEN{1'b0}}, 1'b1}) begin
                        rsp_len_next = {NB_LEN{1'b0}};
                        idx_next     = {NB_LEN{1'b0}};
                        chk_next     = 8'h00;
                        state_next   = ST_TX_HDR;
                    end
                end
            end

            ST_RX_CHK: begin
                if (rx_strobe) begin
                    if (rx_byte != chk_reg) begin
                        err_next     = DBG_ERR_CHECKSUM;
                        rsp_len_next = {NB_LEN{1'b0}};
                        idx_next     = {NB_LEN{1'b0}};
                        chk_next     = 8'h00;
                        state_next   = ST_TX_HDR;
                    end
                    else
                        state_next = ST_EXEC;
                end
            end

            ST_EXEC: begin
                if (addr_err) begin
                    err_next     = DBG_ERR_ADDR;
                    rsp_len_next = {NB_LEN{1'b0}};
                end
                else begin
                    err_next     = DBG_OK;
                    rsp_len_next = ok_len;
                end
                idx_next   = {NB_LEN{1'b0}};
                chk_next   = 8'h00;
                addr_next  = {NB_MEM_ADDR{1'b0}};
                state_next = (is_load | is_reset) ? ST_CLEAR : ST_TX_HDR;
            end

            ST_CLEAR: begin
                addr_next = addr_reg + 1'b1;
                if (addr_reg == CLR_LAST)
                    state_next = ST_TX_HDR;
            end

            ST_TX_HDR: begin
                if (tx_strobe) begin
                    if (idx_reg != {NB_LEN{1'b0}})           // el SOF no entra al CHK
                        chk_next = chk_reg ^ tx_byte;
                    if (idx_reg == 16'd4) begin
                        snap_next  = status_live;
                        idx_next   = {NB_LEN{1'b0}};
                        state_next = (rsp_len_reg == {NB_LEN{1'b0}}) ? ST_TX_CHK : ST_TX_PAYLOAD;
                    end
                    else
                        idx_next = idx_reg + 1'b1;
                end
            end

            ST_TX_PAYLOAD: begin
                if (tx_strobe) begin
                    chk_next = chk_reg ^ tx_byte;
                    idx_next = idx_reg + 1'b1;
                    if (idx_reg == rsp_len_reg - 1'b1)
                        state_next = ST_TX_CHK;
                end
            end

            ST_TX_CHK: begin
                if (tx_strobe) begin
                    evt_next   = 1'b0;
                    state_next = ST_IDLE;
                end
            end

            default: state_next = ST_IDLE;
        endcase
    end

    //------------------------------------------------------------------
    // Salidas
    //------------------------------------------------------------------
    assign o_rd        = rx_strobe;
    assign o_wr        = tx_strobe;
    assign o_w_data    = tx_byte;
    assign o_evt_done  = (state_reg == ST_TX_CHK) & tx_strobe & evt_reg;
    assign o_cmd_valid = (state_reg == ST_EXEC) & ~addr_err;
    assign o_cmd       = cmd_reg;
    assign o_arg_addr  = arg_addr;
    assign o_arg_count = arg_count;
    assign o_pl_idx    = idx_reg;

    assign o_load_start  = (state_reg == ST_LOAD_PREP);
    assign o_clearing    = clearing;
    assign o_imem_b_en   = load_word | clr_imem;
    assign o_imem_b_we   = load_word | clr_imem;
    assign o_imem_b_addr = addr_reg;
    assign o_imem_b_din  = clearing ? INSTR_HALT : load_data;
    assign o_dmem_b_en   = clr_dmem;
    assign o_dmem_b_we   = {4{clr_dmem}};
    assign o_dmem_b_addr = addr_reg;
    assign o_dmem_b_din  = {NB_WORD{1'b0}};
    assign o_used_clr    = clr_dmem;

endmodule

`default_nettype wire
