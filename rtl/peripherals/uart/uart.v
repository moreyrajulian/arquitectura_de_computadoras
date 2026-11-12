`timescale 1ns / 1ps
`default_nettype none

//======================================================================
// uart
//
// UART de la Debug Unit (I-44, decisión 035, docs/spec/protocolo_debug.md
// §1): 8N1 con sobremuestreo 16×, interfaz de bytes como intf_circ del
// TP2 y FIFO de recepción.
//
// Función:
//   Envuelve los módulos de la UART del TP2 sin modificarlos:
//     - baud_gen genera el tick de 16× el baudrate, con
//       DVSR = round(CLK_FREQ_HZ / (16 × BAUD)) (decisión 003).
//     - uart_rx recibe de i_rx (pasada por un sincronizador de dos
//       flip-flops: es asíncrona al reloj) y cada byte completo con stop
//       en 1 entra a uart_fifo. Un byte con stop en 0 se descarta (lo hace
//       uart_rx). Con la FIFO llena, el byte que llega se descarta.
//     - La Debug Unit lee el byte más viejo en o_r_data mientras
//       o_rx_empty = 0 y lo saca con un pulso de i_rd.
//     - Para transmitir, la Debug Unit pone el byte en i_w_data con un
//       pulso de i_wr y o_tx_full = 0. flag_buff lo guarda y o_tx_full
//       queda en 1 hasta el final del stop bit; un i_wr con o_tx_full = 1
//       se ignora. Un ciclo después del i_wr arranca uart_tx.
//   No usa enable (decisión 018): la UART sigue funcionando con el core
//   detenido.
//
// Parámetros:
//   CLK_FREQ_HZ : frecuencia de i_clk en Hz
//   BAUD        : baudrate (115200, protocolo_debug.md §1)
//   NB_DATA     : bits de datos por byte (8)
//   NB_FIFO     : bits de dirección de la FIFO de recepción (5 = 32 bytes)
//
// Puertos:
//   i_clk      : reloj del sistema
//   i_rst      : reset del sistema, síncrono, activo en alto (no core_rst)
//   i_rx       : línea serie desde la PC (reposo en 1)
//   o_tx       : línea serie hacia la PC (reposo en 1)
//   o_r_data   : byte más viejo de la FIFO de recepción  [NB_DATA-1:0]
//   o_rx_empty : no hay bytes recibidos sin leer
//   i_rd       : pulso: saca o_r_data de la FIFO (sin efecto si está vacía)
//   i_w_data   : byte a transmitir                       [NB_DATA-1:0]
//   i_wr       : pulso: transmite i_w_data (ignorado si o_tx_full = 1)
//   o_tx_full  : el byte anterior todavía está saliendo
//
// Latencia: RX: un byte aparece en o_r_data (o_rx_empty = 0) unos 2
//           ciclos después del medio del stop bit (sincronizador y FIFO).
//           TX: el start bit sale 2 ciclos después de i_wr, y o_tx_full
//           baja al terminar el stop bit (10 bits = 160 ticks).
// Reset   : líneas en reposo (o_tx = 1), FIFO vacía, o_tx_full = 0.
//======================================================================

module uart
#(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer BAUD        = 115_200,
    parameter integer NB_DATA     = 8,
    parameter integer NB_FIFO     = 5
)
(
    input  wire               i_clk,
    input  wire               i_rst,
    input  wire               i_rx,
    output wire               o_tx,
    output wire [NB_DATA-1:0] o_r_data,
    output wire               o_rx_empty,
    input  wire               i_rd,
    input  wire [NB_DATA-1:0] i_w_data,
    input  wire               i_wr,
    output wire               o_tx_full
);

    // Divisor del baud generator, redondeado (decisión 003)
    localparam integer DVSR    = (CLK_FREQ_HZ + 8 * BAUD) / (16 * BAUD);
    localparam integer SB_TICK = 16;    // 1 stop bit = 16 ticks

    //------------------------------------------------------------------
    // Sincronizador de la línea de recepción (entrada asíncrona)
    //------------------------------------------------------------------
    reg rx_meta_reg;
    reg rx_sync_reg;

    always @(posedge i_clk) begin
        if (i_rst) begin
            rx_meta_reg <= 1'b1;
            rx_sync_reg <= 1'b1;
        end
        else begin
            rx_meta_reg <= i_rx;
            rx_sync_reg <= rx_meta_reg;
        end
    end

    //------------------------------------------------------------------
    // Baud generator, receptor y transmisor del TP2
    //------------------------------------------------------------------
    wire               s_tick;
    wire               rx_done_tick;
    wire [NB_DATA-1:0] rx_dout;
    wire               tx_done_tick;
    wire [NB_DATA-1:0] tx_din;
    reg                tx_start_reg;

    baud_gen #(
        .DVSR (DVSR)
    ) u_baud_gen (
        .clk   (i_clk),
        .reset (i_rst),
        .tick  (s_tick)
    );

    uart_rx #(
        .NB_DATA (NB_DATA),
        .SB_TICK (SB_TICK)
    ) u_uart_rx (
        .clk          (i_clk),
        .reset        (i_rst),
        .rx           (rx_sync_reg),
        .s_tick       (s_tick),
        .rx_done_tick (rx_done_tick),
        .dout         (rx_dout)
    );

    uart_tx #(
        .NB_DATA (NB_DATA),
        .SB_TICK (SB_TICK)
    ) u_uart_tx (
        .clk          (i_clk),
        .reset        (i_rst),
        .tx_start     (tx_start_reg),
        .s_tick       (s_tick),
        .din          (tx_din),
        .tx_done_tick (tx_done_tick),
        .tx           (o_tx)
    );

    //------------------------------------------------------------------
    // Recepción: FIFO de 2^NB_FIFO bytes (decisión 035)
    //------------------------------------------------------------------
    uart_fifo #(
        .NB_DATA (NB_DATA),
        .NB_ADDR (NB_FIFO)
    ) u_rx_fifo (
        .i_clk   (i_clk),
        .i_rst   (i_rst),
        .i_push  (rx_done_tick),
        .i_data  (rx_dout),
        .i_pop   (i_rd),
        .o_data  (o_r_data),
        .o_empty (o_rx_empty),
        .o_full  ()
    );

    //------------------------------------------------------------------
    // Transmisión: un byte en flag_buff, sin FIFO (decisión 035). El byte
    // que está saliendo no se pisa: wr solo cuenta con tx_full = 0
    //------------------------------------------------------------------
    wire tx_accept = i_wr & ~o_tx_full;

    flag_buff #(
        .NB_DATA (NB_DATA)
    ) u_tx_buf (
        .clk      (i_clk),
        .reset    (i_rst),
        .clr_flag (tx_done_tick),
        .set_flag (tx_accept),
        .d_in     (i_w_data),
        .flag     (o_tx_full),
        .d_out    (tx_din)
    );

    // uart_tx toma din en el ciclo siguiente, cuando flag_buff ya lo guardó
    always @(posedge i_clk) begin
        if (i_rst)
            tx_start_reg <= 1'b0;
        else
            tx_start_reg <= tx_accept;
    end

endmodule

`default_nettype wire
