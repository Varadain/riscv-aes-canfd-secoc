// -----------------------------------------------------------------------------
// Sequential MixColumns block: processes one 32-bit AES column per clock.
//
// Four columns are processed over four active cycles using one shared GF(2^8)
// datapath. This is another major hardware-reuse point in the AES architecture.
//
// Handshake timing:
//   - start is accepted while idle and sets col=0.
//   - one transformed 32-bit column is stored per running cycle.
//   - done pulses when column 3 is stored.
// MixColumns is used in rounds 1-9 only; the top-level FSM skips it in round 10.
// in_block must remain stable during the four running cycles.
// -----------------------------------------------------------------------------

module AES_MIXCOL_SEQ (
    input  wire         clk,       // Core clock
    input  wire         reset,     // Active-high asynchronous reset
    input  wire         start,     // One-cycle MixColumns request
    input  wire [127:0] in_block,  // State after SubBytes and ShiftRows
    output reg  [127:0] out_block, // Registered mixed state
    output reg          done       // One-clock completion pulse
);

// col selects one of the four 32-bit AES state columns.
(* preserve = 1 *) reg        running;
(* preserve = 1 *) reg [1:0]  col;
(* keep = 1 *) reg [31:0] word;
(* keep = 1 *) reg [31:0] mc;

// Multiply by x (hex 02) in GF(2^8). If the old MSB is one, XOR 0x1B after
// shifting to reduce by the AES polynomial x^8+x^4+x^3+x+1.
function [7:0] xt;
    input [7:0] b;
    begin
        xt = {b[6:0], 1'b0} ^ (8'h1b & {8{b[7]}});
    end
endfunction

// Computes one MixColumns output byte: 2*a + 3*b + c + d, where addition in
// GF(2^8) is XOR and multiplication by 3 is xt(b) XOR b.
function [7:0] mixb;
    input [7:0] a;
    input [7:0] b;
    input [7:0] c;
    input [7:0] d;
    begin
        mixb = xt(a) ^ (xt(b) ^ b) ^ c ^ d;
    end
endfunction

// Select the current column and calculate its transformed 32-bit value.
always @(*) begin
    case (col)
        2'd0: word = in_block[127:96];
        2'd1: word = in_block[95:64];
        2'd2: word = in_block[63:32];
        2'd3: word = in_block[31:0];
    endcase

    // Rotate the byte arguments to evaluate all four rows of the fixed AES
    // MixColumns matrix for the selected input column.
    mc = {
        mixb(word[31:24], word[23:16], word[15:8],  word[7:0]),
        mixb(word[23:16], word[15:8],  word[7:0],   word[31:24]),
        mixb(word[15:8],  word[7:0],   word[31:24], word[23:16]),
        mixb(word[7:0],   word[31:24], word[23:16], word[15:8])
    };
end

// Four-cycle column sequencer.
always @(posedge clk or posedge reset) begin
    if (reset) begin
        running   <= 1'b0;
        col       <= 2'd0;
        done      <= 1'b0;
        out_block <= 128'd0;
    end else begin
        // Default-low assignment makes done a pulse rather than sticky status.
        done <= 1'b0;

        if (start && !running) begin
            // Begin with the most-significant AES column.
            running <= 1'b1;
            col     <= 2'd0;
        end else if (running) begin
            // Write the transformed column back into the same position.
            out_block[127 - (col * 32) -: 32] <= mc;

            if (col == 2'd3) begin
                // Fourth column completes MixColumns for this round.
                running <= 1'b0;
                done    <= 1'b1;
            end else begin
                col <= col + 2'd1;
            end
        end
    end
end
endmodule
