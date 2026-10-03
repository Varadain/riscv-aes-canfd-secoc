module hazard_unit (
    input  logic [4:0] id_rs1_i,
    input  logic [4:0] id_rs2_i,
    input  logic [4:0] ex_rd_i,
    input  logic       ex_mem_read_i,
    output logic       stall_o,
    output logic       flush_ifid_o
);
    always_comb begin
        stall_o = 1'b0;
        flush_ifid_o = 1'b0;

        if (ex_mem_read_i && (ex_rd_i != 5'h0) && ((ex_rd_i == id_rs1_i) || (ex_rd_i == id_rs2_i))) begin
            stall_o = 1'b1;
            flush_ifid_o = 1'b1;
        end
    end
endmodule
