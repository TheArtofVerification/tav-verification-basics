# Bonus: RISC-V Verification with an ISS Golden Model

Read the post: https://theartofverification.com/risc-v-verification/

A small single-cycle RV32I core and an instruction set simulator (ISS) written from the RISC-V spec. The UVM bench runs the same program on both and compares every retired instruction: pc, instruction, register write, memory write and next pc. Three phases: one hand-written program, 20 random programs, and 200 random encodings.

## Run the UVM bench

1. Open [EDA Playground](https://www.edaplayground.com/) (free account).
2. Paste `tav_riscv_iss_uvm.sv` into testbench.sv and leave design.sv empty.
3. Pick Synopsys VCS, UVM 1.2. Set the top module to `tav_top`.
4. Run once with no option, then with `+BUG=1` to `+BUG=4`.

| Option | Bug |
|---|---|
| (none) | the clean core |
| `+BUG=1` | SLT and SLTI compare as unsigned |
| `+BUG=2` | a write to x0 is not ignored |
| `+BUG=3` | the branch offset is not sign-extended |
| `+BUG=4` | loose decode: encodings outside the subset run |

See `expected_output.txt`.

## Run the three-way ISS comparison

`tav_riscv_ai_check.sv` compares my first ISS, my fixed ISS and an AI-written ISS (unedited) on random programs and on 20,000 random encodings. No UVM needed: pick Synopsys VCS, set the top module to `tav_ai_top`, no run options. See `expected_ai_output.txt`.

Both files ran on Synopsys VCS X-2025.06-SP1 (EDA Playground), 25 Nov 2026.
