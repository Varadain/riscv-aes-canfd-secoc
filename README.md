# RISC-V, AES, CAN-IDS, and CAN-FD/SecOC

This package supports the manuscript *A RISC-V Security Processor with AES Acceleration and Secure CAN-FD Monitoring*. It contains the processor and security RTL, focused UVM environments, the C-DPI CMAC reference, archived verification logs, FPGA reports, and the VCD underlying the displayed receive/DMA waveform.

The processor handles software control while the security peripherals encrypt data, authenticate protected frames, reject stale freshness values, screen trusted traffic, and move accepted records into memory. The CAN-FD block operates at the complete-frame boundary; an external CAN-FD protocol core and transceiver are still required for a physical bus.

## Repository folders

```text
RTL/
  Top/                 Integrated processor top
  CPU/                 Pipeline, hazards, forwarding, and memories
  AES/Reusable/        Iterative AES datapath
  CAN/                 CAN-IDS and CAN-FD/SecOC controllers
  Peripherals/         UART, sensor/SPI, DMA, interrupts, activity counters
UVM/
  CAN_IDS/             IDS environment, assertions, coverage, and runners
  CANFD_SecOC/         Security environment and independent C-DPI CMAC model
  ReferenceModels/     Shared independent AES-128 C reference
Testbench/             Directed full-SoC testbench
FPGA/Quartus/          FPGA project files and timing constraints
Scripts/               Evidence checks, hashes, and figure generation
Evidence/
  2026-10-03/          Fresh full regressions and FPGA flow; exact input provenance
  Verification/        Recorded UVM logs, CSV summaries, and directed results
  Quartus/             Recorded FPGA implementation reports
  Waveforms/           Recorded receive/DMA VCD
  Logs/                Original tool execution logs
  Provenance/          Original synthesis-bundle fingerprint
Docs/                  Architecture, reproduction steps, and result boundaries
```

Start with the [processor top](RTL/Top/riscv_aes_advancements.sv), [CAN RTL](RTL/CAN/), or [UVM environments](UVM/). Read the [architecture guide](Docs/ARCHITECTURE.md), [reproduction steps](Docs/REPRODUCTION.md), and [results guide](Docs/RESULTS.md) for context. Generated outputs go into the ignored `Build/` folder.

## Start here

```powershell
git clone https://github.com/Varadain/riscv-aes-canfd-secoc.git
cd riscv-aes-canfd-secoc
python Scripts/validate_evidence.py
python Scripts/check_artifact_hashes.py
```

These checks need Python 3.9 or later and Git. They validate the archived files, not new RTL behavior. Running the verification or FPGA flow also needs the separately licensed tools described below.

## Architecture and register map

The top module is `RTL/Top/riscv_aes_advancements.sv`. Its five-stage pipeline retains forwarding, load-use stalling, and branch flushing. MMIO connects the following peripherals:

| Base | Peripheral | Purpose |
| --- | --- | --- |
| `0x0300` | AES / AES-CTR | Encryption, key controls, counter-mode data path |
| `0x0400` | Sensor / SPI | Sensor registers and external SPI master interface |
| `0x0500` | UART | Serial output |
| `0x0600` | Interrupt controller | Pending/enable state; IDS bit 4 and SecOC bit 5 |
| `0x0700` | DMA-lite | Memory-to-memory record movement |
| `0x0800` | Activity counters | Sleep requests and activity observations |
| `0x0900` | CAN-IDS | Identifier/payload/timing rules and alert counters |
| `0x0A00` | CAN-FD / SecOC | Four-entry TX/RX FIFOs, CMAC, freshness, authenticated RX DMA |

With SecOC checking enabled and a provisioned key, receive verification releases an accepted frame to IDS screening and optional RX DMA in parallel. IDS classification is not a DMA authorization gate. A rejected frame is not released to either path. Software can bypass SecOC checking with control bit 8 at `0x0A00`; this prototype assumes trusted configuration. The IDS examines only the low 11 identifier bits and first eight payload bytes; the fixed CMAC profile authenticates the complete 29-bit identifier and all 64 stored payload bytes.

## Evidence and scope

The complete verification and FPGA flow were repeated on 3 October 2026 from a fresh v1.1.0 checkout, commit `e31227ddf8db7af6dcc089848dd589938981cbe0`. No previous build database was copied. The new reports, ten seeded UVM transcripts, four processor-test modes, VCD, input hashes, and tool versions are in [Evidence/2026-10-03](Evidence/2026-10-03/). Read [the fresh validation record](Docs/FRESH_VALIDATION_20261003.md) for commands and limitations.

The older July evidence remains unchanged for historical traceability. Its original 33-source synthesis bundle has SHA-256 `9fc6ee8605a86637b84872689ffb0b2c9dbc4285f4f7121932f2b5d5bf461157`. The public RTL was extracted from that bundle except for the restricted vendor SPI core. The October campaign uses the modular public sources with that SPI dependency supplied locally.

- Directed SoC checks: 161 passed, 0 failed.
- Additional modes: SecurityExtension 36/0, CanFdSecoc 17/0, FullSocScenario 18/0. These modes overlap; their counts should not be added as independent coverage.
- CAN-IDS UVM: seeds 1, 7, 19, 42, 99; 209 transactions each; 38/38 portable bins.
- CAN-FD/SecOC UVM: the same five seeds; 46 transactions each; 16/16 portable bins.
- FPGA: Cyclone V `5CGXFC7C7F23C8`, Quartus 23.1, 50 MHz target.
- Utilization: 22,261 ALMs, 22,113 registers; maximum frequency 56.91 MHz.
- Vectorless power: 582.88 mW, low confidence; not measured board power.

The CAN-FD security controller accepts MMIO frame descriptors; it is not an ISO 11898 MAC/PHY and no physical CAN bus was tested. The fixed SecOC-style profile is not a complete AUTOSAR stack. The 32-bit freshness and 64-bit tag are separate descriptor fields: packing them with 64 application bytes would exceed a single CAN-FD frame. Neither fragmentation nor a 52-byte application-payload wire mapping is implemented. Replay state is volatile, global to the RX path, and resets with the design. IDS labels are generated verification labels, not a field-dataset accuracy evaluation. Questa Starter Edition used UVM components, seeded procedural stimulus, portable bin collectors, and concurrent assertions; native solver/covergroup closure is not claimed.

## Files

`Evidence/Verification/` contains unmodified archived logs and per-seed CSV files. `Evidence/Quartus/` contains map, fit, timing, and power reports. `Evidence/Waveforms/canfd_dma_debug.vcd` is the recorded waveform source. `UVM/CAN_IDS/` and `UVM/CANFD_SecOC/` contain the two focused environments; `Testbench/` contains the directed SoC testbench.

`SHA256SUMS.json` records the packaged file hashes. `Scripts/validate_evidence.py` checks CSV aggregates against the raw UVM logs and FPGA summaries without running a simulator:

```powershell
python Scripts/validate_evidence.py
```

## Focused verification

Use Questa Intel FPGA Starter Edition 2023.3 or a compatible licensed Questa installation. The recorded logs use UVM 1.1d. Install your own simulator and libraries; none are distributed here. Add its binaries to PATH. CAN-FD/SecOC also needs an x64 C compiler and Questa's `svdpi.h`; the original Windows runner uses the `python-zig` executable from the author's Python 3.12 Scripts installation. Adapt that compiler location for your system.

```powershell
foreach ($seed in 1,7,19,42,99) {
  & ./UVM/CAN_IDS/run_can_ids_uvm_questa.ps1 -Seed $seed -RandomTransactions 200
  & ./UVM/CANFD_SecOC/run_canfd_secoc_uvm_questa.ps1 -Seed $seed -RandomTransactions 40
}
```

The scripts create/delete only their generated work libraries under `Build/Questa/`, after checking the build boundary. Regression summaries go into `Build/Regressions/`. `-NativeCovergroups` is optional and requires a suitable licence; it was not used for the reported evidence. New outputs are separate from archived `Evidence/` files.

## Full SoC and FPGA reproduction

The vendor-generated `sensor_spi_ip` module is deliberately omitted. Its source carries Altera licence restrictions and must not be republished without authorization. Regenerate an Avalon SPI master using Quartus/Platform Designer under your vendor licence, with module name `sensor_spi_ip`: 50 MHz input, 1 MHz SPI, 8-bit data, one slave, CPOL 0, CPHA 0, MSB first, no extra delay. Preserve the port interface expected by `RTL/Peripherals/sensor_spi_mmio.sv`; place the QIP at `IP/sensor_spi_ip/sensor_spi_ip.qip`.

Open `FPGA/Quartus/riscv_aes_advancements.qpf`. Its QSF references this external QIP and the relocated RTL; source order and the target device are preserved. After regeneration, run map, fit, assembler, STA and power with the `riscv_aes_advancements` revision. Outputs go into `Build/Quartus/`. The SDC constrains the internal clock to 20 ns; it is not a board-ready constraint set. Add exact pins and external delays before hardware use. Regenerated IP and tool versions can change fitted results.

The SoC testbench is `Testbench/riscv_core_tb.sv`. Compile the design sources from the QSF and the regenerated SPI model with `vlog -sv`, then run `work.riscv_core_tb` to completion. The monolithic restricted-IP bundle, commercial libraries, simulator binaries, FPGA bitstream, and ASIC files are not included.

After providing the local SPI model, the checked runner invokes all four processor modes and rejects simulation logs containing failed checks:

```powershell
& ./Scripts/run_processor_integration_questa.ps1 -DumpCanFdWaveform
```

## Visualization

`Scripts/create_project_figures.py` uses Python and Matplotlib, reads the archived VCD and public RTL, and writes figures under `Build/Figures/`. Run `python Scripts/create_project_figures.py` after installing its plotting dependency. Plot generation does not replace simulation or synthesis.

The original figure script retains the July waveform for historical reproduction. For the October waveform, use `Scripts/render_current_waveform.py`, which resolves the exercised signal names from VCD hierarchy rather than fixed aliases:

```powershell
python Scripts/render_current_waveform.py Evidence/2026-10-03/Waveforms/canfd_dma_debug.vcd Build/Figures/questa_canfd_secoc_dma_waveform
```

## Related work and publication

The AES architecture was reported in the GCON paper by Inamdar, Kulkarni, and Nanaware, DOI https://doi.org/10.1109/GCON69192.2026.11648274. The baseline processor paper by Inamdar and Kulkarni was accepted for ISAIA 2026, with presentation scheduled for 10 October 2026. This artifact package accompanies the additional CAN security integration and verification work; it must not be used to imply that the earlier AES or processor concepts are newly introduced.

The public artifact repository is https://github.com/Varadain/riscv-aes-canfd-secoc. `CITATION.cff` identifies this software artifact; it does not claim that the journal manuscript has been accepted or published. A permanent release or commit link can be cited in the manuscript. A DOI-backed archive may be added later; this repository does not currently have a DOI.

## Rights and excluded files

No open-source software licence is selected by this upload. Public visibility does not grant a licence to redistribute or reuse the implementation; the authors should agree on a licence before adding one. Existing third-party notices are retained.

The restricted vendor SPI source, commercial libraries, tool binaries, author photos, journal submission documents, publisher-formatted conference PDFs, bitstreams, build databases, and ASIC implementation files are excluded. The original restricted-IP synthesis bundle is identified only by its SHA-256, not redistributed.
