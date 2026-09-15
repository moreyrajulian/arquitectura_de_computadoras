`timescale 1ns / 1ps
//======================================================================
// Testbench autochequeante del sistema completo UART + Interfaz + ALU.
//
// Verifica el camino de punta a punta:
//   PC --(serie)--> RX --> intf --> ALU --> intf --> TX --(serie)--> PC
//
// Metodologia:
//   - una task envia un byte por la linea 'rx' respetando la trama UART
//     (start=0, 8 datos LSB primero, stop=1) a la velocidad del baud gen.
//   - una task recibe un byte de la linea 'tx' muestreando en el medio.
//   - un modelo de referencia (independiente del RTL) calcula el resultado
//     esperado de cada operacion.
//   - se envia la terna (opcode, A, B), se captura el resultado y se compara.
//   - contador de errores + veredicto TEST PASSED / TEST FAILED.
//
// DVSR chico (por parametro) para que la simulacion sea rapida; la logica
// es identica a la de la placa, solo cambia cuantos ciclos hay por bit.
//======================================================================
module uart_tb;

    localparam integer NB_DATA = 8;
    localparam integer DVSR    = 4;          // divisor chico para simular
    localparam integer BIT_CYC = 16*DVSR;    // ciclos de clk por bit serie
    localparam integer CLK_P   = 10;         // periodo de clk (ns)

    // opcodes (deben coincidir con alu.v)
    localparam [7:0] OP_ADD = 8'h20, OP_SUB = 8'h22, OP_AND = 8'h24,
                     OP_OR  = 8'h25, OP_XOR = 8'h26, OP_SRA = 8'h03,
                     OP_SRL = 8'h02, OP_NOR = 8'h27;

    reg  clk = 0, reset = 1;
    reg  rx = 1;                  // linea hacia la FPGA (reposo = 1)
    wire tx;                      // linea desde la FPGA

    integer errors = 0;
    integer tests  = 0;

    // ---------------- DUT ----------------
    top #(.NB_DATA(NB_DATA), .DVSR(DVSR)) dut (
        .clk(clk), .reset(reset), .rx(rx), .tx(tx)
    );

    always #(CLK_P/2) clk = ~clk;

    // ---------------- envio de un byte por rx ----------------
    task send_byte;
        input [7:0] b;
        integer i;
        begin
            rx = 1'b0;                                   // start bit
            repeat (BIT_CYC) @(posedge clk);
            for (i = 0; i < 8; i = i + 1) begin          // 8 datos, LSB primero
                rx = b[i];
                repeat (BIT_CYC) @(posedge clk);
            end
            rx = 1'b1;                                   // stop bit
            repeat (BIT_CYC) @(posedge clk);
        end
    endtask

    // ---------------- recepcion de un byte desde tx ----------------
    // espera el flanco de bajada (start) y muestrea en el medio de cada bit
    task recv_byte;
        output [7:0] b;
        integer i;
        begin
            b = 8'h00;
            while (tx !== 1'b0) @(posedge clk);          // espero el start bit (linea a 0)
            repeat (BIT_CYC) @(posedge clk);             // atravieso el start bit completo
            for (i = 0; i < 8; i = i + 1) begin          // ahora arranca el bit0
                b[i] = tx;                               // muestreo al principio de cada bit
                repeat (BIT_CYC) @(posedge clk);
            end
        end
    endtask

    // ---------------- modelo de referencia (independiente del RTL) ----------------
    function signed [NB_DATA-1:0] alu_model;
        input [7:0] op;
        input signed [NB_DATA-1:0] a, b;
        reg [2:0] sh;
        begin
            sh = b[2:0];
            case (op)
                OP_ADD: alu_model = a + b;
                OP_SUB: alu_model = a - b;
                OP_AND: alu_model = a & b;
                OP_OR : alu_model = a | b;
                OP_XOR: alu_model = a ^ b;
                OP_NOR: alu_model = ~(a | b);
                OP_SRA: alu_model = a >>> sh;
                OP_SRL: alu_model = $unsigned(a) >> sh;
                default: alu_model = 0;
            endcase
        end
    endfunction

    // ---------------- una operacion completa: envia terna y verifica ----------------
    task run_op;
        input [7:0]  op;
        input [7:0]  a, b;
        input [8*20:1] nombre;    // etiqueta para el log
        reg  [7:0] got;
        reg  [NB_DATA-1:0] esperado;
        begin
            tests = tests + 1;
            send_byte(op);
            send_byte(a);
            send_byte(b);
            recv_byte(got);
            esperado = alu_model(op, a, b);
            if (got !== esperado) begin
                errors = errors + 1;
                $display("  [ERROR] %0s: op=%02h a=%0d b=%0d -> dut=%0d (0x%02h) esperado=%0d",
                         nombre, op, $signed(a), $signed(b), $signed(got), got, $signed(esperado));
            end else begin
                $display("  [ OK  ] %0s: a=%0d b=%0d -> %0d (0x%02h)",
                         nombre, $signed(a), $signed(b), $signed(got), got);
            end
        end
    endtask

    // ---------------- secuencia de prueba ----------------
    initial begin
        // reset inicial
        #100 reset = 1'b1;
        repeat (5) @(posedge clk);
        reset = 1'b0;
        repeat (5) @(posedge clk);

        $display("\n=== Cobertura: una operacion de cada tipo ===");
        run_op(OP_ADD, 8'd5,  8'd3,  "ADD basico");
        run_op(OP_SUB, 8'd10, 8'd4,  "SUB basico");
        run_op(OP_AND, 8'hF0, 8'h0F, "AND");
        run_op(OP_OR , 8'hF0, 8'h0F, "OR");
        run_op(OP_XOR, 8'hAA, 8'h55, "XOR");
        run_op(OP_NOR, 8'h00, 8'h00, "NOR de 0 = FF");
        run_op(OP_SRA, 8'h80, 8'd1,  "SRA negativo");
        run_op(OP_SRL, 8'h80, 8'd1,  "SRL negativo");

        $display("\n=== Casos de borde aritmeticos ===");
        run_op(OP_ADD, 8'd127, 8'd1,   "ADD overflow (127+1)");
        run_op(OP_SUB, 8'd0,   8'd1,   "SUB underflow (0-1)");
        run_op(OP_ADD, 8'd0,   8'd0,   "ADD 0+0");
        run_op(OP_SRA, 8'd8,   8'd1,   "SRA positivo");

        $display("\n=== Opcode invalido (default -> 0) ===");
        run_op(8'h3F, 8'd50, 8'd50, "opcode 0x3F");

        $display("\n=== Operaciones consecutivas (vuelve a S_OP) ===");
        run_op(OP_ADD, 8'd1, 8'd1, "consecutiva 1");
        run_op(OP_SUB, 8'd9, 8'd2, "consecutiva 2");
        run_op(OP_XOR, 8'hFF,8'h0F,"consecutiva 3");

        // veredicto
        $display("\n======================================");
        if (errors == 0)
            $display("TEST PASSED: %0d operaciones, 0 errores", tests);
        else
            $display("TEST FAILED: %0d errores en %0d operaciones", errors, tests);
        $display("======================================\n");
        $finish;
    end

    // timeout de seguridad por si algo se cuelga
    initial begin
        #50_000_000;
        $display("TIMEOUT: la simulacion no termino a tiempo");
        $finish;
    end

endmodule