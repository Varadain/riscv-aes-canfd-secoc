module wb_stage (
    input  logic [31:0] alu_result_i,
    input  logic [31:0] mem_read_data_i,
    input  logic        mem_to_reg_i,
    output logic [31:0] wb_data_o
);
    assign wb_data_o = mem_to_reg_i ? mem_read_data_i : alu_result_i;
endmodule
