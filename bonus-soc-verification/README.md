# Bonus: SoC Verification, Checking the Glue Between IPs

Read the post: https://theartofverification.com/soc-verification/

A mini SoC with three IP blocks (UART, SPI, TIMER) that are treated as already verified. The UVM bench checks only what the SoC team adds: address decode, the pin mux, the interrupt wiring and the chip interrupt pin. A spec model in the scoreboard predicts every register read, both pads and the interrupt pin on every cycle. Five phases: smoke, registers, alias, pin mux and interrupts.

## Run the UVM bench

1. Open [EDA Playground](https://www.edaplayground.com/) (free account).
2. Paste `tav_soc_integration_uvm.sv` into testbench.sv and leave design.sv empty.
3. Pick Synopsys VCS, UVM 1.2. Set the top module to `tav_top`.
4. Run once with no option, then with `+BUG=1` to `+BUG=4`.

| Option | Bug |
|---|---|
| (none) | the clean SoC |
| `+BUG=1` | pin mux mode 2 routes SPI to pad 1 instead of UART |
| `+BUG=2` | the SPI and TIMER interrupt lines are swapped going into IRQ_STATUS |
| `+BUG=3` | the chip interrupt pin is active high instead of active low |
| `+BUG=4` | a write to TIMER also writes SPI (address bit 7 left out of the SPI decode) |

See `expected_output.txt`.

## Run the AI-written test

`tav_soc_ai_check.sv` holds the same SoC and an AI-written integration test (plain SystemVerilog, unedited). The top module forces the DUT's bug port from `+BUG=n`, so the AI code stays as it came back. No UVM needed: pick Synopsys VCS, set the top module to `tav_ai_top`, and run with no option, then `+BUG=1` to `+BUG=4`. See `expected_ai_output.txt`.

Both files ran on Synopsys VCS X-2025.06-SP1 (EDA Playground), 25 Nov 2026.
