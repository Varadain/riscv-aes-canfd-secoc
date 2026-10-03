// ============================================================
// DATA MEMORY: 256 words x 32 bits = 1024 bytes
//
// This RAM stores ordinary program data. MMIO addresses are removed by
// mem_stage before requests reach this module, so this block never decodes AES,
// UART, sensor, interrupt, DMA-control, or power-control registers.
//
// Address convention:
//   - CPU and DMA provide normal BYTE addresses.
//   - Each RAM entry holds one 32-bit (4-byte) word.
//   - addr[9:2] divides the byte address by four to select a word.
//   - addr[1:0] is handled by load_store_unit for byte/halfword operations.
//
// Port model:
//   - CPU port: combinational read and synchronous write.
//   - DMA port: combinational read and synchronous write.
//   - If CPU and DMA write the same word in one cycle, the later DMA assignment
//     in the sequential block has priority in simulation/synthesis semantics.
//
// This compact educational RAM uses only address bits [9:2]. Addresses that
// differ above bit 9 alias to the same physical 1 KiB storage location.
// ============================================================
module data_mem (
    input  logic        clk,              // Common processor/SoC clock
    input  logic        rst_n,            // Active-low synchronous RAM reset

    input  logic [31:0] addr_i,           // CPU byte address
    input  logic [31:0] write_data_i,     // Complete CPU replacement word

    input  logic        mem_read_i,       // Enable CPU combinational read
    input  logic        mem_write_i,      // Enable CPU rising-edge write

    output logic [31:0] read_data_o,      // Complete word returned to MEM stage

    // DMA-lite second port. It also uses normal byte addresses but transfers
    // complete 32-bit words only.
    input  logic [31:0] dma_read_addr_i,  // DMA source byte address
    input  logic [31:0] dma_write_addr_i, // DMA destination byte address
    input  logic [31:0] dma_write_data_i, // Word copied from DMA read port
    input  logic        dma_write_en_i,   // Commit one DMA word on clock edge
    output logic [31:0] dma_read_data_o   // Current DMA source word
);

    // Word index 0 covers byte addresses 0x000-0x003, index 1 covers
    // 0x004-0x007, and index 255 covers 0x3FC-0x3FF.
    logic [31:0] ram [0:255];

    integer i;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            // Clear every word for deterministic simulation and test startup.
            for (i = 0; i < 256; i = i + 1) begin
                ram[i] <= 32'h0;
            end
        end else begin
            if (mem_write_i) begin
                // mem_stage already merged SB/SH data into a complete word.
                ram[addr_i[9:2]] <= write_data_i;
            end

            if (dma_write_en_i) begin
                // DMA always copies a complete aligned 32-bit word.
                ram[dma_write_addr_i[9:2]] <= dma_write_data_i;
            end
        end
    end

    // Asynchronous reads make the selected word visible in the same cycle.
    // The CPU output is forced to zero when no memory read is requested; the DMA
    // read remains continuously available because dma_lite controls its timing.
    assign read_data_o = mem_read_i ? ram[addr_i[9:2]] : 32'h0;
    assign dma_read_data_o = ram[dma_read_addr_i[9:2]];

endmodule
