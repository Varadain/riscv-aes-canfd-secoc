// ============================================================
// LOAD/STORE WIDTH AND BYTE-LANE FORMATTER
//
// data_mem always reads and writes complete 32-bit words. This combinational
// helper converts those words into RV32I byte, halfword, and word operations.
//
// ls_tag_i encoding generated in ex_stage:
//   000 = LW / SW   (complete 32-bit word)
//   001 = LB / SB   (signed byte load or byte store)
//   010 = LH / SH   (signed halfword load or halfword store)
//   011 = LBU       (zero-extended byte load)
//   100 = LHU       (zero-extended halfword load)
//
// The design is little-endian: the lowest byte address selects mem_word_i[7:0].
// Narrow stores use read-modify-write. Bytes outside the selected lane are
// copied from mem_word_i into merged_store_word_o so they are not destroyed.
//
// Alignment note: this compact core does not raise misalignment exceptions.
// Halfword selection uses byte_off_i[1], and word operations pass through the
// complete word. Software should therefore use naturally aligned addresses.
// ============================================================
module load_store_unit (
    input  logic [2:0]  ls_tag_i,           // Width/sign operation tag
    input  logic [1:0]  byte_off_i,         // Address bits [1:0]
    input  logic [31:0] mem_word_i,         // Complete word read from RAM
    input  logic [31:0] store_data_i,       // Forwarded rs2 store value
    output logic [31:0] load_data_o,        // CPU-ready load value
    output logic [31:0] merged_store_word_o // Complete word written back to RAM
);
    // Selected little-endian byte and halfword before extension.
    logic [7:0]  sel_byte;
    logic [15:0] sel_half;

    always_comb begin
        // Select one of four byte lanes using the low two byte-address bits.
        case (byte_off_i)
            2'b00: sel_byte = mem_word_i[7:0];
            2'b01: sel_byte = mem_word_i[15:8];
            2'b10: sel_byte = mem_word_i[23:16];
            default: sel_byte = mem_word_i[31:24];
        endcase

        // Address bit 1 selects the lower or upper 16-bit half of the word.
        sel_half = byte_off_i[1] ? mem_word_i[31:16] : mem_word_i[15:0];

        // Default pass-through for LW/SW.
        load_data_o = mem_word_i;
        merged_store_word_o = store_data_i;

        case (ls_tag_i)
            3'b001: begin // LB / SB
                // LB copies the selected byte's sign bit into the upper 24 bits.
                load_data_o = {{24{sel_byte[7]}}, sel_byte};
                // SB replaces only the addressed byte lane with store_data[7:0].
                case (byte_off_i)
                    2'b00: merged_store_word_o = {mem_word_i[31:8], store_data_i[7:0]};
                    2'b01: merged_store_word_o = {mem_word_i[31:16], store_data_i[7:0], mem_word_i[7:0]};
                    2'b10: merged_store_word_o = {mem_word_i[31:24], store_data_i[7:0], mem_word_i[15:0]};
                    default: merged_store_word_o = {store_data_i[7:0], mem_word_i[23:0]};
                endcase
            end

            3'b010: begin // LH / SH
                // LH sign-extends bit 15; SH replaces only one 16-bit half.
                load_data_o = {{16{sel_half[15]}}, sel_half};
                if (byte_off_i[1]) begin
                    merged_store_word_o = {store_data_i[15:0], mem_word_i[15:0]};
                end else begin
                    merged_store_word_o = {mem_word_i[31:16], store_data_i[15:0]};
                end
            end

            3'b011: begin // LBU
                // Unsigned load fills all upper bits with zero.
                load_data_o = {24'h0, sel_byte};
            end

            3'b100: begin // LHU
                // Unsigned halfword load also uses zero extension.
                load_data_o = {16'h0, sel_half};
            end

            default: begin
                // Keep the LW/SW defaults assigned above.
            end
        endcase
    end
endmodule
