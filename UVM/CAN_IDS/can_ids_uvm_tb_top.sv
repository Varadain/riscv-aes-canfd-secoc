`timescale 1ns/1ps

// ============================================================================
// CAN-IDS UVM simulation top
// ============================================================================
module can_ids_uvm_tb_top;
    import uvm_pkg::*;
    import can_ids_uvm_pkg::*;
    `include "uvm_macros.svh"

    logic clk;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    can_ids_uvm_if ids_if(clk);

    can_ids_mmio u_can_ids_mmio (
        .clk          (clk),
        .rst_n        (ids_if.rst_n),
        .clk_en_i     (ids_if.clk_en),
        .addr_i       (ids_if.addr),
        .write_data_i (ids_if.wdata),
        .write_en_i   (ids_if.write_en),
        .read_en_i    (ids_if.read_en),
        .hw_submit_i  (1'b0),
        .hw_frame_id_i(11'h0),
        .hw_frame_dlc_i(4'h0),
        .hw_frame_payload_i(64'h0),
        .hw_frame_fd_i(1'b0),
        .hw_ready_o   (),
        .read_data_o  (ids_if.rdata),
        .alert_irq_o  (ids_if.alert_irq),
        .alert_debug_o(ids_if.alert_debug),
        .active_o     (ids_if.active)
    );

    initial begin
        ids_if.init();
    end

    initial begin
        uvm_config_db#(virtual can_ids_uvm_if)::set(null, "*", "vif", ids_if);
        run_test("can_ids_uvm_test");
    end
endmodule
