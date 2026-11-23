`timescale 1ns / 1ps
`default_nettype none

//======================================================================
// top (riscv_basys3)
//
// Top del trabajo final en la Basys 3 (I-49): procesador RISC-V
// segmentado + Debug Unit + UART, con reset por botón (decisión 041) y
// reloj de 92 MHz del Clock Wizard (decisiones 042 y 045).
//
// Función:
//   Conecta los bloques como lo prueban debug_dump_tb (montaje A),
//   debug_load_tb y debug_run_tb, y como lo dicen las decisiones 035 a
//   039:
//     clk (100 MHz) --> clk_wiz_sys --> clk_sys (92 MHz), el único reloj
//     reset (btnC) | ~locked --> reset_sync --> rst del sistema (uart y
//                                               Debug Unit)
//     PC --rx/tx--> uart <--bytes--> debug_unit <--> debug_exec
//                                    debug_unit <--> debug_dump
//     debug_unit --puerto B de imem (LOAD)-----------------> riscv_core
//     debug_dump --puerto B de dmem, banco, latches, marcas-> riscv_core
//     debug_exec --enable, core_rst--> riscv_core --halted--> debug_exec
//   El core no ve el reset del sistema directamente: su reset es
//   core_rst de debug_exec, que lo incluye (decisión 037).
//   Un solo dominio de reloj, clk_sys, sin tocar el clock en ningún punto
//   (decisión 018). A 100 MHz el camino de redirect no cerraba timing
//   (docs/timing/); el MMCM baja la frecuencia (decisión 042). Hasta que
//   engancha (locked = 0) el sistema queda en reset.
//   LEDs de estado, para saber en la placa si responde la FPGA aunque no
//   responda la UART:
//     led[0..4]   estado de ejecución, uno por estado: NO_PROG, READY,
//                 RUNNING, PAUSED, HALTED (DBG_ST_*)
//     led[8..10]  avisos: imem_fault, dmem_oob, dmem_misaligned
//     led[14]     reset del sistema activo
//     led[15]     latido: parpadea a BLINK_HZ (cambia cada
//                 CLK_FREQ_HZ / (2 × BLINK_HZ) ciclos); quieto = sin
//                 reloj o en reset
//     el resto apagados.
//
// Parámetros:
//   CLK_FREQ_HZ : frecuencia de clk_sys en Hz, la salida de clk_wiz_sys
//                 (ip/clk_wiz.tcl): tienen que coincidir. La usan la UART
//                 (DVSR), INFO (clk_khz), el timeout de la Debug Unit y el
//                 latido
//   BAUD        : baudrate de la UART (115200, protocolo_debug.md §1;
//                 top_tb usa CLK_FREQ_HZ / 32 para simular rápido)
//   BLINK_HZ    : frecuencia de parpadeo del latido (2 Hz; top_tb la sube
//                 para verlo en pocos ciclos)
//
// Puertos (los nombres de basys3.xdc, exentos de los prefijos, decisión
// 010):
//   clk   : reloj de la placa (W5, 100 MHz), solo entra al Clock Wizard
//   reset : btnC, asíncrono, activo en alto
//   rx    : línea serie desde la PC (RsRx), reposo en 1
//   tx    : línea serie hacia la PC (RsTx), reposo en 1
//   led   : LEDs LD0 a LD15                              [15:0]
//
// Latencia: la de cada bloque, en ciclos de clk_sys; el reset del sistema
//           sube 3 ciclos después de apretar btnC (reset_sync).
// Reset   : al configurar la FPGA, hasta que el MMCM engancha y con btnC
//           (reset_sync): Debug Unit en IDLE y NO_PROG, core en reset, UART
//           en reposo.
//======================================================================

module top
#(
    parameter integer CLK_FREQ_HZ = 92_000_000,
    parameter integer BAUD        = 115_200,
    parameter integer BLINK_HZ    = 2
)
(
    input  wire        clk,
    input  wire        reset,
    input  wire        rx,
    output wire        tx,
    output wire [15:0] led
);

    `include "riscv_defs.vh"

    // Anchos de los buses de latch (pipeline.md §8, decisión 023) y del
    // protocolo; tienen que coincidir con los puertos de riscv_core
    localparam integer NB_IF_ID_LATCH  = 65;
    localparam integer NB_ID_EX_LATCH  = 161;
    localparam integer NB_EX_MEM_LATCH = 109;
    localparam integer NB_MEM_WB_LATCH = 110;
    localparam integer NB_BYTE         = 8;
    localparam integer NB_WORD         = 32;
    localparam integer NB_LEN          = 16;
    localparam integer NB_STATE        = 3;
    localparam integer NB_MEM_ADDR     = 10;   // índice de palabra de imem y dmem
    localparam integer NB_WE           = 4;    // byte write enable de dmem
    localparam integer NB_REG_ADDR     = 5;
    localparam integer NB_LED          = 16;

    // Latido: medio período de CLK_FREQ_HZ / (2 × BLINK_HZ) ciclos
    localparam integer HB_HALF = CLK_FREQ_HZ / (2 * BLINK_HZ);
    localparam integer NB_HB   = $clog2(HB_HALF);

    //------------------------------------------------------------------
    // Reloj del sistema (decisión 042)
    //------------------------------------------------------------------
    wire clk_sys;
    wire clk_locked;

    clk_wiz_sys u_clk_wiz (
        .clk_in1  (clk),
        .clk_out1 (clk_sys),
        .locked   (clk_locked)
    );

    //------------------------------------------------------------------
    // Reset del sistema (decisión 041): el botón o el MMCM sin enganchar
    //------------------------------------------------------------------
    wire rst_req = reset | ~clk_locked;   // asíncrono: lo sincroniza reset_sync
    wire rst;

    reset_sync u_reset_sync (
        .i_clk     (clk_sys),
        .i_rst_req (rst_req),
        .o_rst     (rst)
    );

    //------------------------------------------------------------------
    // Señales entre bloques
    //------------------------------------------------------------------
    // uart <-> debug_unit
    wire [NB_BYTE-1:0]         uart_r_data;
    wire                       uart_rx_empty;
    wire                       uart_tx_full;
    wire                       du_rd;
    wire [NB_BYTE-1:0]         du_w_data;
    wire                       du_wr;

    // debug_unit
    wire                       du_evt_done;
    wire                       du_cmd_valid;
    wire [NB_BYTE-1:0]         du_cmd;
    wire [NB_WORD-1:0]         du_arg_addr;
    wire [NB_LEN-1:0]          du_arg_count;
    wire                       du_load_start;
    wire                       du_clearing;
    wire                       du_imem_b_en;
    wire                       du_imem_b_we;
    wire [NB_MEM_ADDR-1:0]     du_imem_b_addr;
    wire [NB_WORD-1:0]         du_imem_b_din;
    wire                       du_dmem_b_en;
    wire [NB_WE-1:0]           du_dmem_b_we;
    wire [NB_MEM_ADDR-1:0]     du_dmem_b_addr;
    wire [NB_WORD-1:0]         du_dmem_b_din;
    wire                       du_used_clr;
    wire [NB_LEN-1:0]          du_pl_idx;

    // debug_exec
    wire [NB_STATE-1:0]        ex_state;
    wire                       ex_prog_valid;
    wire [NB_WORD-1:0]         ex_cycles;
    wire                       ex_evt_pending;
    wire                       ex_enable;
    wire                       ex_core_rst;

    // debug_dump
    wire [NB_BYTE-1:0]         dd_pl_byte;
    wire                       dd_pl_ready;
    wire [NB_LEN-1:0]          dd_dmem_used;
    wire                       dd_dmem_b_en;
    wire [NB_WE-1:0]           dd_dmem_b_we;
    wire [NB_MEM_ADDR-1:0]     dd_dmem_b_addr;
    wire [NB_WORD-1:0]         dd_dmem_b_din;
    wire [NB_REG_ADDR-1:0]     dd_reg_addr;

    // riscv_core
    wire                       core_halted;
    wire                       core_imem_fault;
    wire                       core_dmem_oob;
    wire                       core_dmem_misaligned;
    wire                       core_dmem_we;
    wire [NB_MEM_ADDR-1:0]     core_dmem_addr;
    wire [NB_WORD-1:0]         core_pc;
    wire [NB_WORD-1:0]         core_dmem_b_dout;
    wire [NB_WORD-1:0]         core_reg_data;
    wire [NB_IF_ID_LATCH-1:0]  core_if_id_latch;
    wire [NB_ID_EX_LATCH-1:0]  core_id_ex_latch;
    wire [NB_EX_MEM_LATCH-1:0] core_ex_mem_latch;
    wire [NB_MEM_WB_LATCH-1:0] core_mem_wb_latch;

    //------------------------------------------------------------------
    // UART (decisión 035)
    //------------------------------------------------------------------
    uart #(
        .CLK_FREQ_HZ (CLK_FREQ_HZ),
        .BAUD        (BAUD)
    ) u_uart (
        .i_clk      (clk_sys),
        .i_rst      (rst),
        .i_rx       (rx),
        .o_tx       (tx),
        .o_r_data   (uart_r_data),
        .o_rx_empty (uart_rx_empty),
        .i_rd       (du_rd),
        .i_w_data   (du_w_data),
        .i_wr       (du_wr),
        .o_tx_full  (uart_tx_full)
    );

    //------------------------------------------------------------------
    // Debug Unit: protocolo y carga (decisiones 036 y 038)
    //------------------------------------------------------------------
    debug_unit #(
        .CLK_FREQ_HZ     (CLK_FREQ_HZ),
        .NB_IF_ID_LATCH  (NB_IF_ID_LATCH),
        .NB_ID_EX_LATCH  (NB_ID_EX_LATCH),
        .NB_EX_MEM_LATCH (NB_EX_MEM_LATCH),
        .NB_MEM_WB_LATCH (NB_MEM_WB_LATCH)
    ) u_debug_unit (
        .i_clk             (clk_sys),
        .i_rst             (rst),
        .i_r_data          (uart_r_data),
        .i_rx_empty        (uart_rx_empty),
        .o_rd              (du_rd),
        .o_w_data          (du_w_data),
        .o_wr              (du_wr),
        .i_tx_full         (uart_tx_full),
        .i_state           (ex_state),
        .i_prog_valid      (ex_prog_valid),
        .i_halted          (core_halted),
        .i_imem_fault      (core_imem_fault),
        .i_dmem_oob        (core_dmem_oob),
        .i_dmem_misaligned (core_dmem_misaligned),
        .i_dmem_used       (dd_dmem_used),
        .i_pc              (core_pc),
        .i_cycles          (ex_cycles),
        .i_evt_pending     (ex_evt_pending),
        .o_evt_done        (du_evt_done),
        .o_cmd_valid       (du_cmd_valid),
        .o_cmd             (du_cmd),
        .o_arg_addr        (du_arg_addr),
        .o_arg_count       (du_arg_count),
        .o_load_start      (du_load_start),
        .o_clearing        (du_clearing),
        .o_imem_b_en       (du_imem_b_en),
        .o_imem_b_we       (du_imem_b_we),
        .o_imem_b_addr     (du_imem_b_addr),
        .o_imem_b_din      (du_imem_b_din),
        .o_dmem_b_en       (du_dmem_b_en),
        .o_dmem_b_we       (du_dmem_b_we),
        .o_dmem_b_addr     (du_dmem_b_addr),
        .o_dmem_b_din      (du_dmem_b_din),
        .o_used_clr        (du_used_clr),
        .o_pl_idx          (du_pl_idx),
        .i_pl_byte         (dd_pl_byte),
        .i_pl_ready        (dd_pl_ready)
    );

    //------------------------------------------------------------------
    // Debug Unit: ejecución (decisión 037)
    //------------------------------------------------------------------
    debug_exec u_debug_exec (
        .i_clk         (clk_sys),
        .i_rst         (rst),
        .i_cmd_valid   (du_cmd_valid),
        .i_cmd         (du_cmd),
        .i_load_start  (du_load_start),
        .i_mem_busy    (du_clearing),
        .i_evt_done    (du_evt_done),
        .o_state       (ex_state),
        .o_prog_valid  (ex_prog_valid),
        .o_cycles      (ex_cycles),
        .o_evt_pending (ex_evt_pending),
        .i_halted      (core_halted),
        .o_enable      (ex_enable),
        .o_core_rst    (ex_core_rst)
    );

    //------------------------------------------------------------------
    // Debug Unit: volcado (decisión 039)
    //------------------------------------------------------------------
    debug_dump #(
        .NB_IF_ID_LATCH  (NB_IF_ID_LATCH),
        .NB_ID_EX_LATCH  (NB_ID_EX_LATCH),
        .NB_EX_MEM_LATCH (NB_EX_MEM_LATCH),
        .NB_MEM_WB_LATCH (NB_MEM_WB_LATCH)
    ) u_debug_dump (
        .i_clk            (clk_sys),
        .i_rst            (rst),
        .i_cmd_valid      (du_cmd_valid),
        .i_cmd            (du_cmd),
        .i_arg_addr       (du_arg_addr),
        .i_pl_idx         (du_pl_idx),
        .o_pl_byte        (dd_pl_byte),
        .o_pl_ready       (dd_pl_ready),
        .o_dmem_used      (dd_dmem_used),
        .i_du_dmem_b_en   (du_dmem_b_en),
        .i_du_dmem_b_we   (du_dmem_b_we),
        .i_du_dmem_b_addr (du_dmem_b_addr),
        .i_du_dmem_b_din  (du_dmem_b_din),
        .i_used_clr       (du_used_clr),
        .o_dmem_b_en      (dd_dmem_b_en),
        .o_dmem_b_we      (dd_dmem_b_we),
        .o_dmem_b_addr    (dd_dmem_b_addr),
        .o_dmem_b_din     (dd_dmem_b_din),
        .i_dmem_b_dout    (core_dmem_b_dout),
        .i_dmem_we        (core_dmem_we),
        .i_dmem_addr      (core_dmem_addr),
        .o_dbg_reg_addr   (dd_reg_addr),
        .i_dbg_reg_data   (core_reg_data),
        .i_if_id_latch    (core_if_id_latch),
        .i_id_ex_latch    (core_id_ex_latch),
        .i_ex_mem_latch   (core_ex_mem_latch),
        .i_mem_wb_latch   (core_mem_wb_latch)
    );

    //------------------------------------------------------------------
    // Procesador, con imem y dmem adentro (decisión 023)
    //------------------------------------------------------------------
    riscv_core u_core (
        .i_clk             (clk_sys),
        .i_rst             (ex_core_rst),
        .i_enable          (ex_enable),
        .i_imem_b_en       (du_imem_b_en),
        .i_imem_b_we       (du_imem_b_we),
        .i_imem_b_addr     (du_imem_b_addr),
        .i_imem_b_din      (du_imem_b_din),
        .i_dmem_b_en       (dd_dmem_b_en),
        .i_dmem_b_we       (dd_dmem_b_we),
        .i_dmem_b_addr     (dd_dmem_b_addr),
        .i_dmem_b_din      (dd_dmem_b_din),
        .o_dmem_b_dout     (core_dmem_b_dout),
        .i_dbg_reg_addr    (dd_reg_addr),
        .o_dbg_reg_data    (core_reg_data),
        .o_halted          (core_halted),
        .o_imem_fault      (core_imem_fault),
        .o_dmem_oob        (core_dmem_oob),
        .o_dmem_misaligned (core_dmem_misaligned),
        .o_dmem_we         (core_dmem_we),
        .o_dmem_addr       (core_dmem_addr),
        .o_pc              (core_pc),
        .o_if_id_latch     (core_if_id_latch),
        .o_id_ex_latch     (core_id_ex_latch),
        .o_ex_mem_latch    (core_ex_mem_latch),
        .o_mem_wb_latch    (core_mem_wb_latch)
    );

    //------------------------------------------------------------------
    // LEDs de estado
    //------------------------------------------------------------------
    reg  [NB_HB-1:0]  hb_cnt_reg;
    reg  [NB_HB-1:0]  hb_cnt_next;
    reg               hb_reg;
    reg               hb_next;
    reg  [NB_LED-1:0] led_state;

    always @(posedge clk_sys) begin
        if (rst) begin
            hb_cnt_reg <= {NB_HB{1'b0}};
            hb_reg     <= 1'b0;
        end
        else begin
            hb_cnt_reg <= hb_cnt_next;
            hb_reg     <= hb_next;
        end
    end

    always @(*) begin
        hb_cnt_next = hb_cnt_reg + 1'b1;
        hb_next     = hb_reg;
        if (hb_cnt_reg == HB_HALF - 1) begin
            hb_cnt_next = {NB_HB{1'b0}};
            hb_next     = ~hb_reg;
        end
    end

    always @(*) begin
        led_state = {NB_LED{1'b0}};
        case (ex_state)
            DBG_ST_NO_PROG: led_state[0] = 1'b1;
            DBG_ST_READY:   led_state[1] = 1'b1;
            DBG_ST_RUNNING: led_state[2] = 1'b1;
            DBG_ST_PAUSED:  led_state[3] = 1'b1;
            DBG_ST_HALTED:  led_state[4] = 1'b1;
            default:        led_state    = {NB_LED{1'b0}};
        endcase
        led_state[8]  = core_imem_fault;
        led_state[9]  = core_dmem_oob;
        led_state[10] = core_dmem_misaligned;
        led_state[14] = rst;
        led_state[15] = hb_reg;
    end

    assign led = led_state;

endmodule

`default_nettype wire
