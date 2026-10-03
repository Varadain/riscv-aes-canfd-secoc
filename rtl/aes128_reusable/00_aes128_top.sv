// -----------------------------------------------------------------------------
// Top-level AES-128 sequential encryption core.
// File order starts here so readers see the external interface and FSM first.
//
// Hardware-reuse idea:
//   A fully unrolled AES may instantiate one large datapath for every round.
//   This core instead stores the current 128-bit state and repeatedly calls one
//   SubBytes unit, one MixColumns unit, and one key-expansion unit. The result is
//   lower hardware duplication and lower simultaneous switching, at the cost of
//   additional clock cycles per encrypted block.
//
// Handshake:
//   - Pulse start for one clock while the core is idle.
//   - busy remains high while all ten AES-128 rounds execute.
//   - done pulses near completion and ciphertext holds the encrypted block.
//
// Round schedule:
//   Initial: state = plaintext XOR key
//   Rounds 1-9: SubBytes -> ShiftRows -> MixColumns -> AddRoundKey
//   Round 10:   SubBytes -> ShiftRows -> AddRoundKey (no MixColumns)
//
// The FSM waits for each sequential helper's done pulse before reusing the next
// datapath. Inputs are accepted only in S_IDLE; start while busy is ignored.
// -----------------------------------------------------------------------------

module AES128_updated_new (
    input  wire         clk,        // Core clock
    input  wire         reset,      // Active-high asynchronous reset
    input  wire         start,      // One-cycle request, accepted only in IDLE
    output reg          busy,       // High from accepted start through round 10
    output reg          done,       // One-clock ciphertext-valid pulse
    input  wire [127:0] plaintext,  // One AES input block
    input  wire [127:0] key,        // AES-128 key for this block
    output reg  [127:0] ciphertext  // Registered result, held until next result
);

// FSM states are split into START and WAIT pairs because the reusable helper
// units also use start/done handshakes. START emits one request pulse; WAIT holds
// the state until the helper reports that its registered output is complete.
localparam S_IDLE       = 4'd0;
localparam S_SUB_START  = 4'd1;
localparam S_SUB_WAIT   = 4'd2;
localparam S_MIX_START  = 4'd3;
localparam S_MIX_WAIT   = 4'd4;
localparam S_KEY_START  = 4'd5;
localparam S_KEY_WAIT   = 4'd6;
localparam S_DONE       = 4'd7;

// Quartus preserve/keep attributes make the reusable datapath and its internal
// round activity easier to inspect in synthesis and waveform tools.
(* preserve = 1 *) reg [3:0]   state;
(* preserve = 1 *) reg [127:0] state_reg;
(* preserve = 1 *) reg [127:0] round_key;
(* preserve = 1 *) reg [3:0]   round;

// Outputs and completion pulses from the three shared helper datapaths.
wire [127:0] sb_out;
wire [127:0] mix_out;
wire [127:0] new_key;
wire         sbox_done;
wire         mix_done;
wire         key_done;

// One-clock request pulses sent to the three reusable helper blocks.
reg sbox_start;
reg mix_start;
reg key_start;

// AES state is stored as four 32-bit columns: b0..b3, b4..b7, b8..b11, b12..b15.
// ShiftRows rotates row 1 by 1 byte, row 2 by 2 bytes, and row 3 by 3 bytes.
// It is combinational because it only rewires byte positions; it requires no
// arithmetic unit or additional state machine.
function [127:0] shift_rows;
    input [127:0] s;
    reg [7:0] b0;  reg [7:0] b1;  reg [7:0] b2;  reg [7:0] b3;
    reg [7:0] b4;  reg [7:0] b5;  reg [7:0] b6;  reg [7:0] b7;
    reg [7:0] b8;  reg [7:0] b9;  reg [7:0] b10; reg [7:0] b11;
    reg [7:0] b12; reg [7:0] b13; reg [7:0] b14; reg [7:0] b15;
    begin
        {b0, b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12, b13, b14, b15} = s;
        shift_rows = {b0, b5, b10, b15, b4, b9, b14, b3, b8, b13, b2, b7, b12, b1, b6, b11};
    end
endfunction

(* keep = 1 *) wire [127:0] initial_addroundkey;
(* keep = 1 *) wire [127:0] state_after_shiftrows;
(* keep = 1 *) wire [127:0] state_after_roundkey;
(* keep = 1 *) wire         final_round;

// AES begins with AddRoundKey before round 1.
assign initial_addroundkey  = plaintext ^ key;

// ShiftRows is combinational here and consumes the completed SubBytes result.
assign state_after_shiftrows = shift_rows(sb_out);

// After key expansion, XOR the transformed state with the new round key.
assign state_after_roundkey = state_reg ^ new_key;

// AES-128 has ten rounds; round 10 omits MixColumns.
assign final_round          = (round == 4'd10);

// The same helper instances are reused for every AES round. There are not ten
// copies of these blocks, which is the central area/activity-saving decision.
AES_SBOX_SEQ   u_sbox (.clk(clk), .reset(reset), .start(sbox_start), .in_block(state_reg), .out_block(sb_out),  .done(sbox_done));
AES_MIXCOL_SEQ u_mix  (.clk(clk), .reset(reset), .start(mix_start),  .in_block(state_reg), .out_block(mix_out), .done(mix_done));
AES_KEYEXP_SEQ u_key  (.clk(clk), .reset(reset), .start(key_start),  .round(round), .in_key(round_key), .out_key(new_key), .done(key_done));

always @(posedge clk or posedge reset) begin
    if (reset) begin
        state       <= S_IDLE;
        busy        <= 1'b0;
        done        <= 1'b0;
        round       <= 4'd1;
        state_reg   <= 128'd0;
        round_key   <= 128'd0;
        ciphertext  <= 128'd0;
        sbox_start  <= 1'b0;
        mix_start   <= 1'b0;
        key_start   <= 1'b0;
    end else begin
        // Starts are one-cycle pulses unless a state below asserts one.
        sbox_start <= 1'b0;
        mix_start  <= 1'b0;
        key_start  <= 1'b0;

        case (state)
            S_IDLE: begin
                busy <= 1'b0;
                done <= 1'b0;
                if (start) begin
                    // Latch the transaction and perform the initial key XOR.
                    // plaintext and key are sampled through these assignments.
                    state_reg <= initial_addroundkey;
                    round_key <= key;
                    round     <= 4'd1;
                    busy      <= 1'b1;
                    state     <= S_SUB_START;
                end
            end

            S_SUB_START: begin
                // Ask the byte-serial SubBytes block to process state_reg.
                sbox_start <= 1'b1;
                state      <= S_SUB_WAIT;
            end

            S_SUB_WAIT: begin
                if (sbox_done) begin
                    // SubBytes is complete; apply ShiftRows immediately.
                    state_reg <= state_after_shiftrows;
                    state     <= S_KEY_START;
                    if (!final_round) begin
                        // Rounds 1-9 continue through MixColumns.
                        state <= S_MIX_START;
                    end
                    // For round 10, the default S_KEY_START path intentionally
                    // skips MixColumns as required by AES-128.
                end
            end

            S_MIX_START: begin
                // Start the one-column-per-cycle MixColumns unit.
                mix_start <= 1'b1;
                state     <= S_MIX_WAIT;
            end

            S_MIX_WAIT: begin
                if (mix_done) begin
                    // Save the mixed state before generating the round key.
                    state_reg <= mix_out;
                    state     <= S_KEY_START;
                end
            end

            S_KEY_START: begin
                // Generate the key required by the current AES round.
                key_start <= 1'b1;
                state     <= S_KEY_WAIT;
            end

            S_KEY_WAIT: begin
                if (key_done) begin
                    // Complete this round with AddRoundKey.
                    round_key <= new_key;
                    state_reg <= state_after_roundkey;

                    if (final_round) begin
                        // Round 10 result is the final AES ciphertext.
                        ciphertext <= state_after_roundkey;
                        state      <= S_DONE;
                    end else begin
                        // Reuse the same hardware for the next round.
                        round <= round + 4'd1;
                        state <= S_SUB_START;
                    end
                end
            end

            S_DONE: begin
                // Completion indication is asserted for one state visit. The
                // ciphertext register remains valid after returning to IDLE.
                done  <= 1'b1;
                busy  <= 1'b0;
                state <= S_IDLE;
            end

            default: begin
                // Defensive recovery if state contains an illegal encoding.
                state <= S_IDLE;
            end
        endcase
    end
end
endmodule
