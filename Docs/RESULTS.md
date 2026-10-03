# Recorded results and interpretation

The evidence in this repository was recorded on 16 July 2026. Folder reorganization does not rerun synthesis, change RTL behavior, or replace these observations.

The v1.1.0 layout was checked separately with seed 1 in each focused UVM environment: CAN-IDS passed 209 transactions with 38/38 bins; CAN-FD/SecOC passed 46 transactions with 16/16 bins. Both reported zero scoreboard mismatches, assertion failures, UVM errors, and UVM fatals. Those local checks use the relocated runners and included shared C reference; their outputs remain under ignored `Build/` paths, separate from the archived evidence.

| Evidence | Recorded outcome |
| --- | --- |
| Directed SoC verification | 161 passed, 0 failed |
| CAN-IDS UVM | Seeds 1, 7, 19, 42, 99; 209 transactions per seed |
| IDS portable coverage | 38/38 bins per seed |
| IDS assertions | Four concurrent properties, zero failures |
| CAN-FD/SecOC UVM | Same five seeds; 46 transactions per seed |
| SecOC portable coverage | 16/16 bins per seed |
| SecOC assertions | Five concurrent properties, zero failures |
| SecOC outcomes | 117 accepted, 56 bad-MAC, 57 stale-freshness |
| FPGA target | Cyclone V `5CGXFC7C7F23C8`, Quartus 23.1 |
| Logic and registers | 22,261 ALMs; 22,113 registers |
| Clock | 50 MHz target; 56.91 MHz maximum frequency |
| Worst setup and hold | 2.429 ns and 0.144 ns |
| Vectorless power | 582.88 mW, low confidence |

The verification logs and per-seed CSV files are in `Evidence/Verification/`. The Quartus reports are in `Evidence/Quartus/`, original execution logs in `Evidence/Logs/`, and the receive/DMA waveform source in `Evidence/Waveforms/`.

The fitted design leaves FPGA logic capacity for further integration, but exact board pins, external timing, a CAN-FD protocol core, and hardware validation are still required. Wide register-based memory and frame buffers are practical targets for later RAM-based optimization.

Zero mismatches and closed portable bins establish agreement over the tested partitions, not field attack accuracy or universal verification completeness. Vectorless low-confidence power is an estimate, not a measured energy or board-power result.

The SHA-256 manifest verifies the repository files. `Evidence/Provenance/ORIGINAL_SYNTHESIS_BUNDLE_SHA256.txt` identifies the original 33-source bundle; the licensed SPI core from that bundle is intentionally excluded from the 32-source public RTL.
