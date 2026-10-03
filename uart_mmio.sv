// ============================================================
// UART MMIO Peripheral
//
// Base address: 0x0000_0500
//   0x00 TXDATA     [7:0] byte to transmit; write starts TX when idle
//   0x04 STATUS     [0] busy, [1] done
//   0x08 CONTROL    [0] enable, [1] clear done
//   0x0C BAUD_DIV   [15:0] baud divisor
//
// Writing TXDATA stores one byte and creates a one-cycle start pulse when the
// transmitter is enabled and idle. STATUS.done is sticky so software does not
// miss the uart_tx module's one-clock done pulse.
//
// Typical software sequence:
//   1. Write BAUD_DIV if the reset value is not suitable.
//   2. Write CONTROL[0]=1 to enable transmission.
//   3. Poll STATUS[0] until busy=0.
//   4. Write one byte to TXDATA; this automatically starts uart_tx.
//   5. Poll STATUS[1] or observe the interrupt until done=1.
//   6. Write CONTROL[1]=1 to clear the sticky completion flag.
//
// WHY THE INTERFACE SIGNALS EXIST:
//   clk/rst_n/clk_en_i manage state and allow sleep without clock gating.
//   addr/write_data/write_en/read_en are the CPU MMIO control/data channel.
//   read_data_o returns configuration and status to software.
//   uart_tx_o is the physical serial pin; busy reports live shifter ownership.
//   done is sticky for polling, while done_irq connects the same event to INTC.
//   active_o lets the activity monitor count cycles spent transmitting.
// ============================================================
module uart_mmio (
    input  logic        clk,          // Common SoC clock
    input  logic        rst_n,        // Active-low asynchronous reset
    input  logic        clk_en_i,     // Pauses MMIO/TX state when zero
    input  logic [31:0] addr_i,       // Full MMIO byte address
    input  logic [31:0] write_data_i, // CPU store data
    input  logic        write_en_i,   // One-cycle selected UART write
    input  logic        read_en_i,    // One-cycle selected UART read
    output logic [31:0] read_data_o,  // Zero-extended register read value
    output logic        uart_tx_o,    // Physical UART TX output
    output logic        tx_busy_o,    // Live transmitter state
    output logic        tx_done_o,    // Sticky software completion status
    output logic        tx_done_irq_o,// Sticky interrupt source
    output logic        active_o      // Activity counter input
);

    localparam logic [5:0] OFF_TXDATA   = 6'h00;
    localparam logic [5:0] OFF_STATUS   = 6'h04;
    localparam logic [5:0] OFF_CONTROL  = 6'h08;
    localparam logic [5:0] OFF_BAUD_DIV = 6'h0C;

    // Software-visible configuration and data registers.
    logic [5:0]  reg_offset;
    logic [7:0]  tx_data_reg;
    logic [15:0] baud_div_reg;
    logic        enable_reg;
    // uart_tx produces a pulse; this register holds completion until cleared.
    logic        done_latched;
    logic        tx_start_pulse;
    logic        tx_done_pulse;

    // mem_stage already selected the UART page. Only the low offset is needed
    // to choose a register inside that page.
    assign reg_offset = addr_i[5:0];
    assign tx_done_o = done_latched;
    assign tx_done_irq_o = done_latched;
    assign active_o = tx_busy_o;

    // MMIO write and status-latch logic.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_data_reg    <= 8'h00;
            baud_div_reg   <= 16'd15;
            enable_reg     <= 1'b1;
            done_latched   <= 1'b0;
            tx_start_pulse <= 1'b0;
        end else begin
            // Start is generated for exactly one system-clock cycle.
            tx_start_pulse <= 1'b0;

            if (clk_en_i) begin
                // Convert the transmitter's completion pulse into sticky status.
                if (tx_done_pulse) begin
                    done_latched <= 1'b1;
                end

                if (write_en_i) begin
                    case (reg_offset)
                        OFF_TXDATA: begin
                            tx_data_reg <= write_data_i[7:0];
                            // Writes while busy update the holding register but
                            // do not disturb the byte currently being shifted.
                            // Software should wait for busy=0 before writing if
                            // every byte must be transmitted; there is no FIFO.
                            if (enable_reg && !tx_busy_o) begin
                                tx_start_pulse <= 1'b1;
                                done_latched   <= 1'b0;
                            end
                        end
                        OFF_CONTROL: begin
                            // CONTROL[0] enables TX; CONTROL[1] clears done.
                            enable_reg <= write_data_i[0];
                            if (write_data_i[1]) begin
                                done_latched <= 1'b0;
                            end
                        end
                        // baud = system_clock / (BAUD_DIV + 1).
                        OFF_BAUD_DIV: baud_div_reg <= write_data_i[15:0];
                        default: ;
                    endcase
                end
            end
        end
    end

    // CPU load-data multiplexer for the UART register window.
    always_comb begin
        read_data_o = 32'h0;
        if (read_en_i) begin
            case (reg_offset)
                OFF_TXDATA:   read_data_o = {24'h0, tx_data_reg};
                OFF_STATUS:   read_data_o = {30'h0, done_latched, tx_busy_o};
                OFF_CONTROL:  read_data_o = {31'h0, enable_reg};
                OFF_BAUD_DIV: read_data_o = {16'h0, baud_div_reg};
                default:      read_data_o = 32'h0;
            endcase
        end
    end

    // Physical serial transmitter. Its clock is not gated; clk_en_i controls
    // whether internal state is allowed to advance.
    uart_tx u_uart_tx (
        .clk       (clk),
        .rst_n     (rst_n),
        .clk_en_i  (clk_en_i && enable_reg),
        .start_i   (tx_start_pulse),
        .data_i    (tx_data_reg),
        .baud_div_i(baud_div_reg),
        .tx_o      (uart_tx_o),
        .busy_o    (tx_busy_o),
        .done_o    (tx_done_pulse)
    );

endmodule
