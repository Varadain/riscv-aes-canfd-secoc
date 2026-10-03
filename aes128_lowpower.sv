// =============================================================================
// AES-128 compatibility wrapper
//
// Why this module exists:
//   The SoC was originally connected to an AES block with the simple interface
//   below. The publication-quality reusable AES implementation has an extra
//   "busy" output, so this wrapper adapts that implementation without forcing
//   changes throughout the processor and MMIO logic.
//
// Transaction sequence:
//   1. The caller places plaintext and key on the input buses.
//   2. The caller pulses start while clk_en is high.
//   3. The reusable AES core raises busy internally and processes all rounds.
//   4. The core pulses done when ciphertext is valid.
//
// The SoC keeps its original AES primitive interface while the implementation
// is the exact iterative, hardware-reusable AES128_updated_new architecture
// copied under rtl/aes128_reusable/. No generated/gated clock is used.
//
// This wrapper does not buffer a queue of requests. start is accepted only when
// clk_en is high and the reusable core reports idle. plaintext and key should be
// stable when start is accepted; the core captures their initial transformation.
//
// WHY THE INTERFACE SIGNALS EXIST:
//   clk/reset define the reusable AES core's sequential execution context.
//   clk_en controls request acceptance without creating a generated clock.
//   start marks one transaction; plaintext and key are its complete operands.
//   ciphertext is the 128-bit result and done is its one-cycle validity marker.
// =============================================================================
module aes128_lowpower (
    input  logic         clk,        // Common system clock
    input  logic         reset,      // Active-high asynchronous core reset
    input  logic         clk_en,     // Allows acceptance of a new request
    input  logic         start,      // One-cycle encryption request
    input  logic [127:0] plaintext,  // ECB data or CTR nonce||counter input
    input  logic [127:0] key,        // AES-128 encryption key
    output logic [127:0] ciphertext, // Primitive AES encryption result
    output logic         done        // One-cycle result-valid pulse
);

    // busy is used locally to reject a second start while encryption is active.
    logic core_busy;

    // Clock enable is applied to request acceptance, not to the physical clock.
    // This avoids unsafe clock gating. Once a request is accepted, the AES core
    // continues until the full ten-round AES-128 operation is complete.
    AES128_updated_new u_reusable_aes (
        .clk       (clk),
        .reset     (reset),
        .start     (start && clk_en && !core_busy),
        .busy      (core_busy),
        .done      (done),
        .plaintext (plaintext),
        .key       (key),
        .ciphertext(ciphertext)
    );

endmodule
