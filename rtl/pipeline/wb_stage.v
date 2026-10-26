`timescale 1ns / 1ps
`default_nettype none

//======================================================================
// wb_stage
//
// Etapa WB completa: extensión del load, mux de write-back, registro
// halted y aviso imem_fault (docs/spec/pipeline.md §7).
//
// Función:
//   Recibe los campos de MEM/WB y no tiene registro de segmentación
//   propio (pipeline.md §7.4):
//     - Extensión del load (§7.1): de mem_wb_read_data toma el byte
//       (read_data >> 8*offset) o la media palabra
//       (read_data >> 16*offset[1]) y la extiende con signo (lb, lh) o
//       con ceros (lbu, lhu); lw entrega la palabra. lh/lhu ignoran
//       offset[0] y lw ignora offset (decisión 015). Un funct3 fuera de
//       la tabla entrega read_data, como lw: no llega nunca, porque la
//       unidad de control convierte esos loads en NOP (decisión 024).
//     - Mux de write-back (§7.2): wb_data = mem_to_reg ? load : result.
//       wb_reg_write y wb_rd son copia de MEM/WB, sin mem_wb_valid: una
//       burbuja ya trae reg_write = 0 (§2). Las tres salidas son
//       combinacionales y van al banco de registros (que aplica enable,
//       §4.2) y a la entrada 01 del forwarding de EX (§5.1).
//     - halted (§7.3, decisión 001): se pone en 1 con
//       enable & mem_wb_valid & mem_wb_halt y queda así hasta el reset.
//     - imem_fault (memoria.md §6.2, decisión 015): se pone en 1 con
//       enable & mem_wb_valid y un mem_wb_pc fuera de rango
//       (pc[31:IMEM_AW+2] != 0) o desalineado (pc[1:0] != 0). Una
//       búsqueda en el camino equivocado se anula antes de WB y no lo
//       levanta.
//   Los dos flip-flops solo cambian con enable = 1 (decisión 018) y el
//   reset gana sobre enable.
//
// Parámetros:
//   NB_PC     : ancho del PC
//   NB_DATA   : ancho de los datos (result, read_data, wb_data)
//   NB_ADDR   : ancho del número de registro
//   NB_FUNCT3 : ancho de funct3
//
// Puertos:
//   i_clk               : reloj del sistema
//   i_rst               : reset síncrono, activo en alto (core_rst); halted
//                         e imem_fault en 0, gana sobre i_enable
//   i_enable            : enable global del core (decisión 018)
//   i_mem_wb_valid      : 1 = instrucción real, 0 = burbuja
//   i_mem_wb_pc         : PC de la instrucción             [NB_PC-1:0]
//   i_mem_wb_result     : resultado de EX                  [NB_DATA-1:0]
//   i_mem_wb_read_data  : palabra leída de dmem            [NB_DATA-1:0]
//   i_mem_wb_rd         : registro destino                 [NB_ADDR-1:0]
//   i_mem_wb_funct3     : tamaño y signo del load          [NB_FUNCT3-1:0]
//   i_mem_wb_offset     : byte dentro de la palabra        [1:0]
//   i_mem_wb_reg_write  : la instrucción escribe rd
//   i_mem_wb_mem_to_reg : el valor final es el load
//   i_mem_wb_halt       : HALT en WB
//   o_wb_reg_write      : escritura del banco (wb_reg_write)
//   o_wb_rd             : registro a escribir (wb_rd)      [NB_ADDR-1:0]
//   o_wb_data           : valor final (wb_data)            [NB_DATA-1:0]
//   o_halted            : HALT llegó a WB
//   o_imem_fault        : aviso imem_fault
//
// Latencia: wb_* combinacionales (0 ciclos); halted e imem_fault se ven
//           un ciclo con enable = 1 después de la instrucción en WB.
// Reset   : o_halted = 0, o_imem_fault = 0.
//======================================================================

module wb_stage
#(
    parameter integer NB_PC     = 32,
    parameter integer NB_DATA   = 32,
    parameter integer NB_ADDR   = 5,
    parameter integer NB_FUNCT3 = 3
)
(
    input  wire                 i_clk,
    input  wire                 i_rst,
    input  wire                 i_enable,
    // MEM/WB
    input  wire                 i_mem_wb_valid,
    input  wire [NB_PC-1:0]     i_mem_wb_pc,
    input  wire [NB_DATA-1:0]   i_mem_wb_result,
    input  wire [NB_DATA-1:0]   i_mem_wb_read_data,
    input  wire [NB_ADDR-1:0]   i_mem_wb_rd,
    input  wire [NB_FUNCT3-1:0] i_mem_wb_funct3,
    input  wire [1:0]           i_mem_wb_offset,
    input  wire                 i_mem_wb_reg_write,
    input  wire                 i_mem_wb_mem_to_reg,
    input  wire                 i_mem_wb_halt,
    // Escritura del banco y forwarding
    output wire                 o_wb_reg_write,
    output wire [NB_ADDR-1:0]   o_wb_rd,
    output wire [NB_DATA-1:0]   o_wb_data,
    // Debug Unit
    output wire                 o_halted,
    output wire                 o_imem_fault
);

    `include "riscv_defs.vh"

    localparam integer NB_BYTE = 8;
    localparam integer NB_HALF = 16;
    localparam integer IMEM_AW = 10;   // 1024 palabras (memoria.md §1)

    //------------------------------------------------------------------
    // Extensión del load (§7.1)
    //------------------------------------------------------------------
    wire [NB_DATA-1:0] wb_byte_word = i_mem_wb_read_data >> (NB_BYTE * i_mem_wb_offset);
    wire [NB_DATA-1:0] wb_half_word = i_mem_wb_read_data >> (NB_HALF * i_mem_wb_offset[1]);
    wire [NB_BYTE-1:0] wb_byte      = wb_byte_word[NB_BYTE-1:0];
    wire [NB_HALF-1:0] wb_half      = wb_half_word[NB_HALF-1:0];

    reg  [NB_DATA-1:0] wb_load;

    always @(*) begin
        case (i_mem_wb_funct3)
            FUNCT3_LB:  wb_load = {{(NB_DATA-NB_BYTE){wb_byte[NB_BYTE-1]}}, wb_byte};
            FUNCT3_LH:  wb_load = {{(NB_DATA-NB_HALF){wb_half[NB_HALF-1]}}, wb_half};
            FUNCT3_LBU: wb_load = {{(NB_DATA-NB_BYTE){1'b0}}, wb_byte};
            FUNCT3_LHU: wb_load = {{(NB_DATA-NB_HALF){1'b0}}, wb_half};
            default:    wb_load = i_mem_wb_read_data;          // lw
        endcase
    end

    //------------------------------------------------------------------
    // Mux de write-back (§7.2)
    //------------------------------------------------------------------
    assign o_wb_data      = i_mem_wb_mem_to_reg ? wb_load : i_mem_wb_result;
    assign o_wb_reg_write = i_mem_wb_reg_write;
    assign o_wb_rd        = i_mem_wb_rd;

    //------------------------------------------------------------------
    // halted (§7.3) e imem_fault (memoria.md §6.2): reset > enable
    //------------------------------------------------------------------
    wire wb_pc_fault = (|i_mem_wb_pc[NB_PC-1:IMEM_AW+2]) | (|i_mem_wb_pc[1:0]);

    reg  halted_reg;
    reg  imem_fault_reg;
    wire halted_next     = halted_reg     | (i_enable & i_mem_wb_valid & i_mem_wb_halt);
    wire imem_fault_next = imem_fault_reg | (i_enable & i_mem_wb_valid & wb_pc_fault);

    always @(posedge i_clk) begin
        if (i_rst) begin
            halted_reg     <= 1'b0;
            imem_fault_reg <= 1'b0;
        end
        else begin
            halted_reg     <= halted_next;
            imem_fault_reg <= imem_fault_next;
        end
    end

    assign o_halted     = halted_reg;
    assign o_imem_fault = imem_fault_reg;

endmodule

`default_nettype wire
