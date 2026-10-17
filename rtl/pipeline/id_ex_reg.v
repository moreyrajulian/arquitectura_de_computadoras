`timescale 1ns / 1ps
`default_nettype none

//======================================================================
// id_ex_reg
//
// Registro de segmentación ID/EX (docs/spec/pipeline.md §2, §8).
//
// Función:
//   Guarda los 20 campos de ID/EX (161 bits) con las entradas comunes a
//   los cuatro registros de segmentación y la prioridad rst > en > flush
//   (§2):
//     rst          -> burbuja: valid = 0 y control en 0
//     en = 0       -> conserva todo, aunque flush = 1 (core detenido
//                     durante un stall: la instrucción no se pierde)
//     en = 1       -> carga la instrucción de ID; con flush = 1 carga
//                     burbuja en su lugar
//   Una burbuja tiene valid = 0 y las 11 señales de control en 0
//   (alu_ctrl ... halt), igual que la que genera el modelo de referencia
//   y que la de control_unit con if_id_valid = 0. Así no escribe
//   registros ni memoria, no salta, no frena por load-use (mem_read) y
//   no para el core (halt).
//   Los campos de datos (pc ... funct3) no se resetean y se cargan con
//   en aunque haya flush: los datos de una burbuja no importan (§2,
//   decisión 010), y así redirect y stall solo llegan a los flip-flops
//   de valid y control (§5.3).
//   El registro no decodifica nada: copia lo que llega de ID. Que una
//   instrucción con if_id_valid = 0 traiga el control en 0 lo resuelve
//   control_unit.
//
// Parámetros:
//   NB_PC       : ancho del PC
//   NB_DATA     : ancho de los datos (rs1_data, rs2_data, imm)
//   NB_ADDR     : ancho del número de registro (rs1, rs2, rd)
//   NB_FUNCT3   : ancho de funct3
//   NB_ALU_CTRL : ancho de alu_ctrl (códigos ALU_* de riscv_defs.vh)
//
// Puertos:
//   i_clk         : reloj del sistema
//   i_rst         : reset síncrono, activo en alto; gana sobre i_en
//   i_en          : en_id_ex = enable (§10.4); en 0 conserva
//   i_flush       : flush_id_ex = redirect | stall (§10.4); carga burbuja
//   i_valid       : if_id_valid
//   i_pc          : if_id_pc                                [NB_PC-1:0]
//   i_rs1_data    : valor de rs1 leído del banco (con bypass) [NB_DATA-1:0]
//   i_rs2_data    : valor de rs2 leído del banco (con bypass) [NB_DATA-1:0]
//   i_imm         : inmediato de imm_gen                    [NB_DATA-1:0]
//   i_rs1         : campo rs1 de la instrucción             [NB_ADDR-1:0]
//   i_rs2         : campo rs2 de la instrucción             [NB_ADDR-1:0]
//   i_rd          : campo rd de la instrucción              [NB_ADDR-1:0]
//   i_funct3      : campo funct3 de la instrucción          [NB_FUNCT3-1:0]
//   i_alu_ctrl ... i_halt : las 11 señales de control_unit (§4.4)
//   o_valid ... o_halt    : id_ex_<campo> de §8, un puerto por campo
//   o_latch       : ID/EX agrupado para la Debug Unit, en el orden de §8,
//                   valid en el bit más alto (decisión 023)
//                   [NB_PC+3*NB_DATA+3*NB_ADDR+NB_FUNCT3+NB_ALU_CTRL+10:0]
//
// Latencia: 1 ciclo (entradas -> salidas).
// Reset   : o_valid = 0 y control en 0; los campos de datos no se
//           resetean.
//======================================================================

module id_ex_reg
#(
    parameter integer NB_PC       = 32,
    parameter integer NB_DATA     = 32,
    parameter integer NB_ADDR     = 5,
    parameter integer NB_FUNCT3   = 3,
    parameter integer NB_ALU_CTRL = 4
)
(
    input  wire                   i_clk,
    input  wire                   i_rst,
    input  wire                   i_en,
    input  wire                   i_flush,
    // Datos
    input  wire                   i_valid,
    input  wire [NB_PC-1:0]       i_pc,
    input  wire [NB_DATA-1:0]     i_rs1_data,
    input  wire [NB_DATA-1:0]     i_rs2_data,
    input  wire [NB_DATA-1:0]     i_imm,
    input  wire [NB_ADDR-1:0]     i_rs1,
    input  wire [NB_ADDR-1:0]     i_rs2,
    input  wire [NB_ADDR-1:0]     i_rd,
    input  wire [NB_FUNCT3-1:0]   i_funct3,
    // Control
    input  wire [NB_ALU_CTRL-1:0] i_alu_ctrl,
    input  wire                   i_alu_src_a,
    input  wire                   i_alu_src_b,
    input  wire                   i_branch,
    input  wire                   i_jal,
    input  wire                   i_jalr,
    input  wire                   i_mem_read,
    input  wire                   i_mem_write,
    input  wire                   i_reg_write,
    input  wire                   i_mem_to_reg,
    input  wire                   i_halt,
    // Salidas: id_ex_<campo>
    output wire                   o_valid,
    output wire [NB_PC-1:0]       o_pc,
    output wire [NB_DATA-1:0]     o_rs1_data,
    output wire [NB_DATA-1:0]     o_rs2_data,
    output wire [NB_DATA-1:0]     o_imm,
    output wire [NB_ADDR-1:0]     o_rs1,
    output wire [NB_ADDR-1:0]     o_rs2,
    output wire [NB_ADDR-1:0]     o_rd,
    output wire [NB_FUNCT3-1:0]   o_funct3,
    output wire [NB_ALU_CTRL-1:0] o_alu_ctrl,
    output wire                   o_alu_src_a,
    output wire                   o_alu_src_b,
    output wire                   o_branch,
    output wire                   o_jal,
    output wire                   o_jalr,
    output wire                   o_mem_read,
    output wire                   o_mem_write,
    output wire                   o_reg_write,
    output wire                   o_mem_to_reg,
    output wire                   o_halt,
    // 1 + 32 + 3*32 + 3*5 + 3 + 4 + 10 = 161 bits (§8)
    output wire [NB_PC+3*NB_DATA+3*NB_ADDR+NB_FUNCT3+NB_ALU_CTRL+10:0] o_latch
);

    // Campos agrupados en el orden de §8: datos (pc ... funct3) y
    // control (alu_ctrl ... halt)
    localparam integer NB_DATA_FIELDS = NB_PC + 3*NB_DATA + 3*NB_ADDR + NB_FUNCT3;
    localparam integer NB_CTRL        = NB_ALU_CTRL + 10;

    wire [NB_DATA_FIELDS-1:0] data_in = {i_pc, i_rs1_data, i_rs2_data, i_imm,
                                         i_rs1, i_rs2, i_rd, i_funct3};
    wire [NB_CTRL-1:0]        ctrl_in = {i_alu_ctrl, i_alu_src_a, i_alu_src_b,
                                         i_branch, i_jal, i_jalr, i_mem_read,
                                         i_mem_write, i_reg_write, i_mem_to_reg,
                                         i_halt};

    reg                       id_ex_valid_reg;
    reg [NB_CTRL-1:0]         id_ex_ctrl_reg;
    reg [NB_DATA_FIELDS-1:0]  id_ex_data_reg;

    // valid y control: con reset; prioridad rst > en > flush (§2)
    always @(posedge i_clk) begin
        if (i_rst) begin
            id_ex_valid_reg <= 1'b0;
            id_ex_ctrl_reg  <= {NB_CTRL{1'b0}};
        end
        else if (i_en) begin
            if (i_flush) begin
                id_ex_valid_reg <= 1'b0;
                id_ex_ctrl_reg  <= {NB_CTRL{1'b0}};
            end
            else begin
                id_ex_valid_reg <= i_valid;
                id_ex_ctrl_reg  <= ctrl_in;
            end
        end
    end

    // Datos: sin reset (decisión 010); el flush no los toca
    always @(posedge i_clk) begin
        if (i_en)
            id_ex_data_reg <= data_in;
    end

    assign o_valid = id_ex_valid_reg;
    assign {o_pc, o_rs1_data, o_rs2_data, o_imm,
            o_rs1, o_rs2, o_rd, o_funct3} = id_ex_data_reg;
    assign {o_alu_ctrl, o_alu_src_a, o_alu_src_b, o_branch, o_jal, o_jalr,
            o_mem_read, o_mem_write, o_reg_write, o_mem_to_reg,
            o_halt} = id_ex_ctrl_reg;
    assign o_latch = {id_ex_valid_reg, id_ex_data_reg, id_ex_ctrl_reg};

endmodule

`default_nettype wire
