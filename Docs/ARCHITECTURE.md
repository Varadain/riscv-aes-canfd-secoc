# Architecture and MMIO map

The top module is `RTL/Top/riscv_aes_advancements.sv`. Its RV32I-style pipeline follows instruction fetch, decode, execute, memory, and write-back. The `RTL/CPU/` folder contains the stages, forwarding, load-use hazard control, register file, and modeled memories.

Security and I/O peripherals attach through the memory-stage MMIO decoder. Custom security instructions use the RISC-V `custom-0` opcode; they supplement rather than replace MMIO.

| Base address | Block | RTL folder |
| --- | --- | --- |
| `0x0300` | AES-128 ECB/CTR and key controls | `RTL/AES/` |
| `0x0400` | Sensor MMIO and SPI interface | `RTL/Peripherals/` |
| `0x0500` | UART output | `RTL/Peripherals/` |
| `0x0600` | Interrupt controller | `RTL/Peripherals/` |
| `0x0700` | DMA-lite memory copy | `RTL/Peripherals/` |
| `0x0800` | Sleep and activity counters | `RTL/Peripherals/` |
| `0x0900` | Hardware CAN-IDS | `RTL/CAN/` |
| `0x0A00` | CAN-FD FIFO, CMAC, freshness, RX DMA | `RTL/CAN/` |

The CAN-FD/SecOC block accepts complete frames with up to 64 payload bytes and four-entry TX/RX FIFOs. A fixed AES-CMAC profile checks the received authenticator and monotonic freshness value. Only accepted frames reach the IDS and RX DMA. RX DMA stores a 22-word record with identifier, flags, timestamp, freshness, tag, and payload.

CAN-IDS uses identifier, DLC, payload, replay, and interval rules. It inspects the first eight payload bytes, while SecOC authenticates all 64 payload bytes. Interrupt bit 4 reports IDS alerts; bit 5 reports CAN-FD/SecOC events.

CAN is a communication protocol, not an error-injection mechanism. Bus arbitration, bit stuffing, CRC, timing, error confinement, electrical signaling, and transceiver operation are outside the implemented frame-level security boundary.
