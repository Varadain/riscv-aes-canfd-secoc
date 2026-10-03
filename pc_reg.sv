module pc_reg (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        stall,
    input  logic [31:0] next_pc,
    output logic [31:0] current_pc
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            current_pc <= 32'h0;
        end else if (!stall) begin
            current_pc <= next_pc;
        end
    end
endmodule
