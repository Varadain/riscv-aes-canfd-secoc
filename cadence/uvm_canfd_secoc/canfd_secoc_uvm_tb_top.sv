`timescale 1ns/1ps

module canfd_secoc_uvm_tb_top;
    import uvm_pkg::*;
    import canfd_secoc_uvm_pkg::*;
    `include "uvm_macros.svh"

    logic clk;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    canfd_secoc_uvm_if canfd_if(clk);

    canfd_secoc_mmio u_dut (
        .clk                (clk),
        .rst_n              (canfd_if.rst_n),
        .clk_en_i           (canfd_if.clk_en),
        .addr_i             (canfd_if.addr),
        .write_data_i       (canfd_if.wdata),
        .write_en_i         (canfd_if.write_en),
        .read_en_i          (canfd_if.read_en),
        .read_data_o        (canfd_if.rdata),
        .irq_o              (canfd_if.irq),
        .active_o           (canfd_if.active),
        .ids_submit_o       (canfd_if.ids_submit),
        .ids_frame_id_o     (canfd_if.ids_id),
        .ids_frame_dlc_o    (canfd_if.ids_dlc),
        .ids_frame_payload_o(canfd_if.ids_payload),
        .ids_frame_fd_o     (canfd_if.ids_fd),
        .dma_req_o          (canfd_if.dma_req),
        .dma_grant_i        (canfd_if.dma_grant),
        .dma_write_addr_o   (canfd_if.dma_addr),
        .dma_write_data_o   (canfd_if.dma_data),
        .dma_write_en_o     (canfd_if.dma_write_en)
    );

    assign canfd_if.tx_level = u_dut.tx_count_reg[2:0];
    assign canfd_if.rx_level = u_dut.rx_count_reg[2:0];
    assign canfd_if.last_auth_ok = u_dut.last_auth_ok_reg;
    assign canfd_if.last_fresh_ok = u_dut.last_fresh_ok_reg;
    assign canfd_if.rx_accept_count = u_dut.rx_accept_count_reg;
    assign canfd_if.auth_fail_count = u_dut.auth_fail_count_reg;
    assign canfd_if.fresh_fail_count = u_dut.fresh_fail_count_reg;

    initial canfd_if.init();

    initial begin
        uvm_config_db#(virtual canfd_secoc_uvm_if)::set(null, "*", "vif", canfd_if);
        run_test("canfd_secoc_uvm_test");
    end
endmodule
