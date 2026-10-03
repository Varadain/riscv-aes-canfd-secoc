// ============================================================
// UART Transmitter
// 8-N-1 transmitter with a programmable baud divisor.
// The bit tick occurs every baud_div_i + 1 clock cycles.
//
// 8-N-1 means:
//   - one low start bit,
//   - eight data bits, least-significant bit first,
//   - no parity bit,
//   - one high stop bit.
//
// Example:
//   For a 50 MHz clock and 115200 baud, the ideal number of clock cycles per
//   UART bit is 50,000,000 / 115,200 = 434. Since this counter includes zero,
//   software normally programs baud_div_i to 433.
//
// Transaction flow:
//   1. uart_mmio places one byte on data_i and pulses start_i.
//   2. This module loads {stop, data, start} into shifter.
//   3. tx_o sends start=0, data[0] through data[7], then stop=1.
//   4. busy_o stays high for the complete ten-bit frame.
//   5. done_o pulses for one system-clock cycle after the stop bit completes.
//
// A new start_i is accepted only while busy_o is low. Deasserting clk_en_i
// pauses the baud counter and frame position without creating a gated clock.
//
// WHY THE INTERFACE SIGNALS EXIST:
//   clk/rst_n define the transmitter state and idle recovery behavior.
//   clk_en_i freezes counters safely during peripheral sleep.
//   start_i is a one-cycle command; data_i is the byte captured with it.
//   baud_div_i makes baud rate programmable for different system clocks.
//   tx_o carries the serial frame, busy_o blocks overlap, and done_o marks exit.
// ============================================================
module uart_tx (
    input  logic        clk,        // System clock
    input  logic        rst_n,      // Active-low asynchronous reset
    input  logic        clk_en_i,   // 1 advances transmitter state
    input  logic        start_i,    // One-cycle request to send data_i
    input  logic [7:0]  data_i,     // Byte transmitted least-significant bit first
    input  logic [15:0] baud_div_i, // Bit period minus one, in system clocks
    output logic        tx_o,       // Physical serial line, idle value is 1
    output logic        busy_o,     // 1 while a ten-bit frame is active
    output logic        done_o      // One-clock completion pulse
);

    // Ten-bit frame register: {stop, data[7:0], start}. Right shifts expose the
    // next least-significant frame bit while ones shift in to preserve idle-high.
    logic [9:0]  shifter;

    // Number of frame bits still waiting to be transmitted.
    logic [3:0]  bit_count;

    // Divides the system clock down to one update per UART bit period. Loading
    // baud_div_i and counting through zero produces baud_div_i+1 clock cycles.
    logic [15:0] baud_count;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // UART is idle high by convention.
            tx_o        <= 1'b1;
            busy_o      <= 1'b0;
            done_o      <= 1'b0;
            shifter     <= 10'h3ff;
            bit_count   <= 4'd0;
            baud_count  <= 16'd0;
        end else begin
            // done_o is a one-clock completion pulse.
            done_o <= 1'b0;

            if (clk_en_i) begin
                if (start_i && !busy_o) begin
                    // Load the complete frame. tx_o is driven low immediately
                    // so the receiver sees the start bit without an extra tick.
                    shifter    <= {1'b1, data_i, 1'b0}; // bit9=stop, bit0=start
                    bit_count  <= 4'd10;
                    baud_count <= baud_div_i;
                    busy_o     <= 1'b1;
                    tx_o       <= 1'b0;
                end else if (busy_o) begin
                    if (baud_count != 16'd0) begin
                        // Hold the current serial bit for its full baud period.
                        baud_count <= baud_count - 16'd1;
                    end else begin
                        // Advance to the next frame bit.
                        baud_count <= baud_div_i;
                        shifter    <= {1'b1, shifter[9:1]};
                        bit_count  <= bit_count - 4'd1;

                        if (bit_count == 4'd1) begin
                            // The stop bit has completed; return to idle high.
                            busy_o <= 1'b0;
                            done_o <= 1'b1;
                            tx_o   <= 1'b1;
                        end else begin
                            // Nonblocking assignments use the old shifter value,
                            // so old shifter[1] is exactly the next serial bit.
                            tx_o <= shifter[1];
                        end
                    end
                end
            end
        end
    end

endmodule
