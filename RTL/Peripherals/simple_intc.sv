// ============================================================
// Simple Interrupt Controller
//
// Base address: 0x0000_0600
//   0x00 IRQ_PENDING [0] AES, [1] UART TX done, [2] sensor ready,
//                    [3] DMA done, [4] CAN-IDS alert, [5] CAN-FD/SecOC
//   0x04 IRQ_ENABLE  same bit layout
//   0x08 IRQ_CLEAR   write 1 to clear pending bits
//
// Each incoming source is converted into a sticky pending bit. This prevents
// short peripheral events from being lost before software reads them.
// irq_o becomes high when any pending source is also enabled.
//
// Software sequence:
//   1. Write IRQ_ENABLE to choose which events may assert irq_o.
//   2. Read IRQ_PENDING to determine which source occurred.
//   3. Service that source.
//   4. Write a one to the corresponding IRQ_CLEAR bit.
//
// Pending capture and interrupt masking are intentionally separate: a masked
// event is still remembered in IRQ_PENDING and may assert irq_o later if enabled.
// This module exposes a combined line; CPU CSR/trap entry is not implemented here.
//
// WHY THE INTERFACE SIGNALS EXIST:
//   clk/rst_n/clk_en_i control sticky pending and mask-register state.
//   addr/write_data/write_en/read_en implement software configuration and ACK.
//   the three *_irq_i inputs identify independent peripheral event sources.
//   read_data_o lets software locate and inspect enabled/pending sources.
//   irq_o combines only enabled pending events into one processor-facing line.
// ============================================================
module simple_intc (
    input  logic        clk,                       // Common SoC clock
    input  logic        rst_n,                     // Active-low reset
    input  logic        clk_en_i,                  // Enables event/register updates
    input  logic [31:0] addr_i,                    // Interrupt-page byte address
    input  logic [31:0] write_data_i,              // Enable or clear bit mask
    input  logic        write_en_i,                // Selected MMIO write
    input  logic        read_en_i,                 // Selected MMIO read
    input  logic        aes_done_irq_i,            // Source bit 0
    input  logic        uart_tx_done_irq_i,        // Source bit 1
    input  logic        sensor_data_ready_irq_i,   // Source bit 2
    input  logic        dma_done_irq_i,            // Source bit 3
    input  logic        can_ids_alert_irq_i,       // Source bit 4
    input  logic        canfd_secoc_irq_i,         // Source bit 5
    output logic [31:0] read_data_o,               // Pending/enable readback
    output logic        irq_o                      // OR of enabled pending bits
);

    localparam logic [5:0] OFF_PENDING = 6'h00;
    localparam logic [5:0] OFF_ENABLE  = 6'h04;
    localparam logic [5:0] OFF_CLEAR   = 6'h08;

    // pending_reg records events; enable_reg controls which events contribute
    // to the combined interrupt output.
    logic [5:0] reg_offset;
    logic [5:0] pending_reg;
    logic [5:0] enable_reg;
    logic [5:0] irq_sources;

    assign reg_offset = addr_i[5:0];
    // Keep the bit ordering identical to the documented register map.
    assign irq_sources = {
        canfd_secoc_irq_i,
        can_ids_alert_irq_i,
        dma_done_irq_i,
        sensor_data_ready_irq_i,
        uart_tx_done_irq_i,
        aes_done_irq_i
    };
    // Bitwise AND first applies the software mask. Reduction OR then converts
    // any remaining active bit into one combined interrupt line.
    assign irq_o = |(pending_reg & enable_reg);

    // Capture new events and process software writes.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pending_reg <= 6'h0;
            enable_reg  <= 6'h0;
        end else if (clk_en_i) begin
            // OR operation makes every observed event sticky.
            pending_reg <= pending_reg | irq_sources;

            if (write_en_i) begin
                case (reg_offset)
                    // A zero in enable_reg masks the source from irq_o but does
                    // not prevent its pending bit from being recorded.
                    OFF_ENABLE: enable_reg <= write_data_i[5:0];

                    // Write-one-to-clear. The expression first includes current
                    // source levels, then clears every bit written as one. Thus
                    // an explicit clear has priority for that bit in this cycle.
                    OFF_CLEAR:  pending_reg <= (pending_reg | irq_sources) & ~write_data_i[5:0];
                    default: ;
                endcase
            end
        end
    end

    // CPU-visible pending and enable registers.
    always_comb begin
        read_data_o = 32'h0;
        if (read_en_i) begin
            case (reg_offset)
                OFF_PENDING: read_data_o = {26'h0, pending_reg};
                OFF_ENABLE:  read_data_o = {26'h0, enable_reg};
                default:     read_data_o = 32'h0;
            endcase
        end
    end

endmodule
