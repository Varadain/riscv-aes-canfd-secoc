module instr_mem (
    input  logic [31:0] addr_i,
    output logic [31:0] instr_o
);

`ifdef SYNTHESIS
    // Synthesis uses a read-only case ROM, avoiding Quartus write-port
    // inference warnings for the simulation-only programmable array.
    always_comb begin
        case (addr_i[9:2])
            8'd0:    instr_o = 32'h00500093; // addi x1, x0, 5
            8'd1:    instr_o = 32'h00A00113; // addi x2, x0, 10
            8'd2:    instr_o = 32'h002081B3; // add x3, x1, x2
            8'd3:    instr_o = 32'h00302023; // sw x3, 0(x0)
            8'd4:    instr_o = 32'h00002203; // lw x4, 0(x0)
            8'd5:    instr_o = 32'h00320463; // beq x4, x3, +8
            8'd6:    instr_o = 32'h00100293; // addi x5, x0, 1
            default: instr_o = 32'h00000013; // nop
        endcase
    end
`elsif ALTERA_RESERVED_QIS
    // Quartus defines ALTERA_RESERVED_QIS during synthesis in some flows.
    always_comb begin
        case (addr_i[9:2])
            8'd0:    instr_o = 32'h00500093; // addi x1, x0, 5
            8'd1:    instr_o = 32'h00A00113; // addi x2, x0, 10
            8'd2:    instr_o = 32'h002081B3; // add x3, x1, x2
            8'd3:    instr_o = 32'h00302023; // sw x3, 0(x0)
            8'd4:    instr_o = 32'h00002203; // lw x4, 0(x0)
            8'd5:    instr_o = 32'h00320463; // beq x4, x3, +8
            8'd6:    instr_o = 32'h00100293; // addi x5, x0, 1
            default: instr_o = 32'h00000013; // nop
        endcase
    end
`else
    // Simulation keeps the ROM visible to riscv_core_tb, including when
    // Quartus regenerates the Questa .do file without custom defines.
    logic [31:0] rom [0:255];

    initial begin
        integer i;
        for (i = 0; i < 256; i++) begin
            rom[i] = 32'h00000013;
        end
        rom[0] = 32'h00500093; // addi x1, x0, 5
        rom[1] = 32'h00A00113; // addi x2, x0, 10
        rom[2] = 32'h002081B3; // add x3, x1, x2
        rom[3] = 32'h00302023; // sw x3, 0(x0)
        rom[4] = 32'h00002203; // lw x4, 0(x0)
        rom[5] = 32'h00320463; // beq x4, x3, +8
        rom[6] = 32'h00100293; // addi x5, x0, 1
        rom[7] = 32'h00000013; // nop
    end

    assign instr_o = rom[addr_i[9:2]];
`endif

endmodule
