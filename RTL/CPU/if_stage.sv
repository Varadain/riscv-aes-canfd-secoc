module if_stage (
    input  logic [31:0] pc_i,
    output logic [31:0] instr_o
);
    instr_mem u_instr_mem (
        .addr_i (pc_i),
        .instr_o(instr_o)
    );
endmodule
