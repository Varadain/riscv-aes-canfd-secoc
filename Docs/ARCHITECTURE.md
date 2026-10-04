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

The CAN-FD/SecOC block accepts MMIO frame descriptors with up to 64 payload bytes and four-entry TX/RX FIFOs. With security checking enabled and the key provisioned, a fixed AES-CMAC profile checks the authenticator and monotonic freshness. Accepted frames reach IDS screening and optional RX DMA in parallel; IDS does not gate DMA. Software can bypass security with control bit 8 at `0x0A00`. RX DMA stores a 22-word record with identifier, flags, timestamp, freshness, tag, and payload.

CAN-IDS uses identifier, DLC, payload, replay, and interval rules. It inspects only the low 11 identifier bits and first eight payload bytes, while SecOC authenticates the full 29-bit identifier and all 64 stored payload bytes. Unused payload bytes must be cleared consistently because the fixed CMAC input does not shorten with DLC. Interrupt bit 4 reports IDS alerts; bit 5 reports CAN-FD/SecOC events.

The 32-bit freshness and 64-bit tag are descriptor fields separate from payload. A physical 64-byte CAN-FD frame cannot carry 64 application bytes plus these 12 bytes; fragmentation or a 52-byte application mapping has not been implemented. Freshness state is volatile and shared across RX traffic, with no demonstrated reset-persistent or wraparound protection. See the fresh validation record for the complete scope boundary.

CAN is a communication protocol, not an error-injection mechanism. Bus arbitration, bit stuffing, CRC, timing, error confinement, electrical signaling, and transceiver operation are outside the implemented frame-level security boundary.
