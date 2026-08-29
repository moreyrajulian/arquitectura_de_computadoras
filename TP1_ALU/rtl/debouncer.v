`timescale 1ns / 1ps

//======================================================================
// Sincronizador + antirrebote + detector de flanco.
// Entrega un pulso de un ciclo de reloj por cada pulsacion valida.
//======================================================================

module debouncer
#(
    parameter integer NB_COUNT = 20   // 2^20 ciclos @100MHz ~ 10.5 ms
)
(
    input  wire i_clk,
    input  wire i_reset,
    input  wire i_btn,
    output wire o_tick
);

    reg [NB_COUNT-1:0] counter;
    reg btn_sync_0, btn_sync_1;
    reg btn_stable, btn_stable_d;

    // Sincronizador de dos etapas: el pulsador es asincronico respecto del clk
    always @(posedge i_clk) begin
        if (i_reset) begin
            btn_sync_0 <= 1'b0;
            btn_sync_1 <= 1'b0;
        end else begin
            btn_sync_0 <= i_btn;
            btn_sync_1 <= btn_sync_0;
        end
    end

    // El valor solo se acepta si se mantuvo estable durante 2^NB_COUNT ciclos
    always @(posedge i_clk) begin
        if (i_reset) begin
            counter    <= {NB_COUNT{1'b0}};
            btn_stable <= 1'b0;
        end else if (btn_sync_1 != btn_stable) begin
            counter <= counter + 1'b1;
            if (&counter) btn_stable <= btn_sync_1;
        end else begin
            counter <= {NB_COUNT{1'b0}};
        end
    end

    // Flanco ascendente -> un unico tick
    always @(posedge i_clk) begin
        if (i_reset) btn_stable_d <= 1'b0;
        else         btn_stable_d <= btn_stable;
    end

    assign o_tick = btn_stable & ~btn_stable_d;

endmodule
