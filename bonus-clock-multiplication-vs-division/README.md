# Bonus: Clock Multiplication vs Division

Read the post: https://theartofverification.com/clock-multiplication-vs-division/

One UVM bench drives two clock sources from the same 100 MHz reference: an RTL divider (ref / N) and a behavioural PLL model (ref x M, with a lock signal). The divider is checked exactly, period by period. The PLL is checked by time, with a 2 ps tolerance, and only while it is locked to the ratio it locked to.

## Run the UVM bench

1. Open [EDA Playground](https://www.edaplayground.com/) (free account).
2. Paste `tav_clock_mult_div_uvm.sv` into testbench.sv and leave design.sv empty.
3. Pick Synopsys VCS, UVM 1.2. Set the top module to `tav_top`.
4. Run once with no option, then with `+BUG=1`, `+BUG=2` and `+BUG=3`.

| Option | Bug |
|---|---|
| (none) | the clean design |
| `+BUG=1` | divider counts one cycle too many (divides by N + 1) |
| `+BUG=2` | divider takes a new ratio mid-period |
| `+BUG=3` | PLL lock detector fires 3 reference cycles early |

See `expected_output.txt`.

## Run the AI-written checker

`tav_clock_ai_check.sv` holds a PLL checker written by an AI tool from the spec alone, unedited, next to the same designs. No UVM needed: pick Synopsys VCS and set the top module to `tav_ai_top`. Run with no option and with `+BUG=3`. On the clean design it reports 82 false errors; the post explains why. See `expected_ai_output.txt`.

Both files ran on Synopsys VCS X-2025.06-SP1 (EDA Playground), 25 Nov 2026.
