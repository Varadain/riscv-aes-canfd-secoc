module forwarding_unit (
    input  logic [4:0] ex_rs1_i,
    input  logic [4:0] ex_rs2_i,
    input  logic [4:0] mem_rd_i,
    input  logic [4:0] wb_rd_i,
    input  logic       mem_reg_write_i,
    input  logic       wb_reg_write_i,
    output logic [1:0] forward_a_o,
    output logic [1:0] forward_b_o
);
    always_comb begin
        forward_a_o = 2'b00;
        forward_b_o = 2'b00;

        if (mem_reg_write_i && (mem_rd_i != 5'h0) && (mem_rd_i == ex_rs1_i)) begin
            forward_a_o = 2'b10;
        end else if (wb_reg_write_i && (wb_rd_i != 5'h0) && (wb_rd_i == ex_rs1_i)) begin
            forward_a_o = 2'b01;
        end

        if (mem_reg_write_i && (mem_rd_i != 5'h0) && (mem_rd_i == ex_rs2_i)) begin
            forward_b_o = 2'b10;
        end else if (wb_reg_write_i && (wb_rd_i != 5'h0) && (wb_rd_i == ex_rs2_i)) begin
            forward_b_o = 2'b01;
        end
    end
endmodule
