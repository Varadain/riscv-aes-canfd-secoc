// ============================================================
// Sensor SPI MMIO Peripheral
//
// Base address: 0x0000_0400
//   0x00 SENSOR_DATA       readable sample register
//   0x04 SENSOR_STATUS     [0] data_ready
//   0x08 SENSOR_CONTROL    [0] enable, [1] clear data_ready
//   0x10 SPI_RXDATA        Intel altera_avalon_spi RXDATA
//   0x14 SPI_TXDATA        Intel altera_avalon_spi TXDATA
//   0x18 SPI_STATUS        Intel altera_avalon_spi STATUS
//   0x1C SPI_CONTROL       Intel altera_avalon_spi CONTROL
//   0x24 SPI_SLAVE_SELECT  Intel altera_avalon_spi SLAVE_SEL
//
// Address range 0x00-0x08 is a simple sensor abstraction used by software.
// Address range 0x10-0x24 is forwarded to the generated Intel SPI IP. Keeping
// this wrapper separate means the generated IP can be replaced or regenerated
// without changing the processor's main MMIO decoder.
//
// Two views share this page:
//   - The abstract SENSOR_* registers give software a simple data/ready model.
//   - The SPI_* registers expose the vendor SPI interface for external hardware.
// A received SPI byte is copied into SENSOR_DATA and raises data_ready, so the
// rest of the SoC can consume either synthetic or external samples identically.
//
// WHY THE INTERFACE SIGNALS EXIST:
//   clk/rst_n/clk_en_i control safe synchronous wrapper and SPI-IP operation.
//   addr/write_data/write_en/read_en form the processor's 32-bit MMIO side.
//   miso is the sensor-to-SoC serial input; mosi/sclk/ss_n drive the sensor.
//   read_data_o unifies abstract-sensor and vendor-SPI register readback.
//   data_ready_irq_o turns a received sample into a software-visible event.
//   active_o feeds activity accounting; it is not a physical power estimate.
// ============================================================
module sensor_spi_mmio (
    input  logic        clk,              // Common SoC/SPI IP clock
    input  logic        rst_n,            // Active-low reset
    input  logic        clk_en_i,         // Enables wrapper/IP transactions
    input  logic [31:0] addr_i,           // Sensor-page byte address
    input  logic [31:0] write_data_i,     // CPU register-write data
    input  logic        write_en_i,       // Selected page write request
    input  logic        read_en_i,        // Selected page read request
    input  logic        spi_miso_i,       // Serial data from external sensor
    output logic        spi_mosi_o,       // Serial command/data to sensor
    output logic        spi_sclk_o,       // SPI serial clock
    output logic        spi_ss_n_o,       // Active-low sensor select
    output logic [31:0] read_data_o,      // Local or vendor-register readback
    output logic        data_ready_irq_o, // Sticky abstract sample-ready event
    output logic        active_o          // Model enabled or SPI register selected
);

    localparam logic [5:0] OFF_DATA       = 6'h00;
    localparam logic [5:0] OFF_STATUS     = 6'h04;
    localparam logic [5:0] OFF_CONTROL    = 6'h08;
    localparam logic [5:0] OFF_SPI_RXDATA = 6'h10;
    localparam logic [5:0] OFF_SPI_TXDATA = 6'h14;
    localparam logic [5:0] OFF_SPI_STATUS = 6'h18;
    localparam logic [5:0] OFF_SPI_CTRL   = 6'h1c;
    localparam logic [5:0] OFF_SPI_SS     = 6'h24;

    // Local sensor-model registers.
    logic [5:0]  reg_offset;
    logic [31:0] sensor_data_reg;
    logic        data_ready_reg;
    logic        enable_reg;
    logic [7:0]  sample_tick;

    // Adapter signals for the 16-bit Intel SPI register interface. The CPU bus
    // is 32 bits, so writes use write_data_i[15:0] and reads are zero-extended.
    logic        spi_reg_sel;
    logic [2:0]  spi_addr;
    logic [15:0] spi_data_to_cpu;
    logic        spi_dataavailable;
    logic        spi_readyfordata;
    logic        spi_irq;

    assign reg_offset = addr_i[5:0];
    assign data_ready_irq_o = data_ready_reg;
    // active_o is an activity indication, not a physical power measurement.
    assign active_o = enable_reg | spi_reg_sel;

    // Translate project MMIO offsets into the compact address numbers expected
    // by the generated SPI IP. spi_reg_sel is also used to prevent local sensor
    // writes from responding to SPI-register accesses.
    always_comb begin
        spi_reg_sel = 1'b0;
        spi_addr    = 3'd0;
        case (reg_offset)
            OFF_SPI_RXDATA: begin
                spi_reg_sel = 1'b1;
                spi_addr    = 3'd0;
            end
            OFF_SPI_TXDATA: begin
                spi_reg_sel = 1'b1;
                spi_addr    = 3'd1;
            end
            OFF_SPI_STATUS: begin
                spi_reg_sel = 1'b1;
                spi_addr    = 3'd2;
            end
            OFF_SPI_CTRL: begin
                spi_reg_sel = 1'b1;
                spi_addr    = 3'd3;
            end
            OFF_SPI_SS: begin
                spi_reg_sel = 1'b1;
                spi_addr    = 3'd5;
            end
            default: ;
        endcase
    end

    // Generated Intel/Altera SPI peripheral. This source is treated as vendor
    // generated code; project-specific explanation belongs in this wrapper.
    sensor_spi_ip u_sensor_spi_ip (
        .clk          (clk),
        .reset_n      (rst_n),
        .spi_select   (spi_reg_sel & clk_en_i),
        .mem_addr     (spi_addr),
        .data_from_cpu(write_data_i[15:0]),
        // Vendor read_n/write_n controls are active low; invert the project's
        // active-high selected request pulses at the wrapper boundary.
        .read_n       (~(read_en_i  & spi_reg_sel & clk_en_i)),
        .write_n      (~(write_en_i & spi_reg_sel & clk_en_i)),
        .MISO         (spi_miso_i),
        .MOSI         (spi_mosi_o),
        .SCLK         (spi_sclk_o),
        .SS_n         (spi_ss_n_o),
        .data_to_cpu  (spi_data_to_cpu),
        .dataavailable(spi_dataavailable),
        .endofpacket  (),
        .irq          (spi_irq),
        .readyfordata (spi_readyfordata)
    );

    // Local sensor abstraction and bridge from received SPI bytes.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sensor_data_reg <= 32'h1234_5678;
            data_ready_reg  <= 1'b1;
            enable_reg      <= 1'b1;
            sample_tick     <= 8'h0;
        end else if (clk_en_i) begin
            if (enable_reg) begin
                sample_tick <= sample_tick + 8'd1;
                if (sample_tick == 8'hff) begin
                    // Fallback synthetic sample when no external SPI data arrives.
                    sensor_data_reg <= sensor_data_reg + 32'h0001_0101;
                    data_ready_reg  <= 1'b1;
                end
            end

            if (spi_dataavailable) begin
                // A received SPI byte becomes the newest software-visible sample.
                // Only the low received byte is used by this simple sensor model.
                sensor_data_reg <= {24'h0, spi_data_to_cpu[7:0]};
                data_ready_reg  <= 1'b1;
            end

            if (write_en_i && !spi_reg_sel) begin
                // Only local offsets are handled here. SPI offsets are handled
                // directly by u_sensor_spi_ip above.
                case (reg_offset)
                    OFF_DATA: sensor_data_reg <= write_data_i;
                    OFF_CONTROL: begin
                        enable_reg <= write_data_i[0];
                        if (write_data_i[1]) begin
                            data_ready_reg <= 1'b0;
                        end
                    end
                    default: ;
                endcase
            end

            if (read_en_i && (reg_offset == OFF_DATA)) begin
                // Reading the abstract sensor sample acknowledges data_ready.
                data_ready_reg <= 1'b0;
            end
        end
    end

    // Merge local sensor reads and SPI IP reads onto one 32-bit CPU data bus.
    always_comb begin
        read_data_o = 32'h0;
        if (read_en_i) begin
            case (reg_offset)
                OFF_DATA:       read_data_o = sensor_data_reg;
                OFF_STATUS:     read_data_o = {31'h0, data_ready_reg};
                OFF_CONTROL:    read_data_o = {31'h0, enable_reg};
                // All readable vendor registers share the IP's 16-bit read bus.
                OFF_SPI_RXDATA,
                OFF_SPI_STATUS,
                OFF_SPI_CTRL,
                OFF_SPI_SS:     read_data_o = {16'h0, spi_data_to_cpu};
                default:        read_data_o = 32'h0;
            endcase
        end
    end

endmodule
