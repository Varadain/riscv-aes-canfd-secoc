`timescale 1ns/1ps

interface canfd_secoc_uvm_if(input logic clk);
    logic rst_n;
    logic clk_en;
    logic [31:0] addr;
    logic [31:0] wdata;
    logic write_en;
    logic read_en;
    logic [31:0] rdata;
    logic irq;
    logic active;
    logic ids_submit;
    logic [10:0] ids_id;
    logic [3:0] ids_dlc;
    logic [63:0] ids_payload;
    logic ids_fd;
    logic dma_req;
    logic dma_grant;
    logic [31:0] dma_addr;
    logic [31:0] dma_data;
    logic dma_write_en;

    // White-box observation taps are used only by assertions and waveforms.
    logic [2:0] tx_level;
    logic [2:0] rx_level;
    logic last_auth_ok;
    logic last_fresh_ok;
    logic [31:0] rx_accept_count;
    logic [31:0] auth_fail_count;
    logic [31:0] fresh_fail_count;

    logic [31:0] ids_submit_count;
    logic [31:0] dma_write_count;
    logic [31:0] dma_last_id;
    logic [31:0] dma_last_flags;
    logic [31:0] dma_last_freshness;
    logic [31:0] dma_last_payload0;
    logic [31:0] assertion_failures;
    logic [31:0] assertion_cover_hits;

    task automatic init();
        rst_n = 1'b0;
        clk_en = 1'b1;
        addr = 32'h0;
        wdata = 32'h0;
        write_en = 1'b0;
        read_en = 1'b0;
        dma_grant = 1'b1;
        assertion_failures = 32'h0;
        assertion_cover_hits = 32'h0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
    endtask

    task automatic mmio_write(input logic [7:0] offset,
                              input logic [31:0] value);
        @(negedge clk);
        addr = {24'h00000A, offset};
        wdata = value;
        write_en = 1'b1;
        read_en = 1'b0;
        @(posedge clk);
        @(negedge clk);
        write_en = 1'b0;
        addr = 32'h0;
        wdata = 32'h0;
    endtask

    task automatic mmio_read(input logic [7:0] offset,
                             output logic [31:0] value);
        @(negedge clk);
        addr = {24'h00000A, offset};
        write_en = 1'b0;
        read_en = 1'b1;
        #1 value = rdata;
        @(negedge clk);
        read_en = 1'b0;
        addr = 32'h0;
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ids_submit_count <= 32'h0;
            dma_write_count <= 32'h0;
            dma_last_id <= 32'h0;
            dma_last_flags <= 32'h0;
            dma_last_freshness <= 32'h0;
            dma_last_payload0 <= 32'h0;
        end else begin
            if (ids_submit) ids_submit_count <= ids_submit_count + 32'd1;
            if (dma_write_en) begin
                case (dma_write_count % 22)
                    0: dma_last_id <= dma_data;
                    1: dma_last_flags <= dma_data;
                    3: dma_last_freshness <= dma_data;
                    6: dma_last_payload0 <= dma_data;
                    default: ;
                endcase
                dma_write_count <= dma_write_count + 32'd1;
            end
        end
    end

    assert property (@(posedge clk) disable iff (!rst_n)
        !(write_en && read_en))
    else begin
        assertion_failures++;
        $error("CAN-FD UVM bus read and write overlapped");
    end

    assert property (@(posedge clk) disable iff (!rst_n)
        (tx_level <= 3'd4) && (rx_level <= 3'd4))
    else begin
        assertion_failures++;
        $error("CAN-FD FIFO level exceeded depth four");
    end

    assert property (@(posedge clk) disable iff (!rst_n)
        dma_write_en |-> (dma_req && dma_grant))
    else begin
        assertion_failures++;
        $error("CAN-FD DMA write lacked request/grant handshake");
    end

    assert property (@(posedge clk) disable iff (!rst_n)
        ids_submit |-> (last_auth_ok && last_fresh_ok))
    else begin
        assertion_failures++;
        $error("CAN-FD released a frame without successful security checks");
    end

    assert property (@(posedge clk) disable iff (!rst_n)
        ids_submit |=> !ids_submit)
    else begin
        assertion_failures++;
        $error("CAN-FD trusted-frame submit was wider than one cycle");
    end

    cover property (@(posedge clk) disable iff (!rst_n)
        ids_submit && dma_write_count > 0)
    assertion_cover_hits++;

    cover property (@(posedge clk) disable iff (!rst_n)
        $rose(auth_fail_count) || $rose(fresh_fail_count))
    assertion_cover_hits++;
endinterface
