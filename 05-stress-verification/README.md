# Lesson 5: Stress Verification in UVM: Finding the Bugs Normal Random Testing Misses

Read the lesson: https://theartofverification.com/stress-verification/

## Run it

1. Open [EDA Playground](https://www.edaplayground.com/) (free account).
2. Paste `tav_stress_fifo_uvm.sv` into testbench.sv and leave design.sv empty.
3. Pick Synopsys VCS, UVM 1.2. Set the top module to `tav_top`.
4. Run once with no option, then once for each option below (add it to Run Options).

EDA Playground link: (coming soon)

## Run options

- `(none)` the clean design
- `+BUG=1` when full, a push and a pop in the same cycle loses the pushed data
- `+BUG=2` after 4 cycles of being full, in_ready sticks low until the next reset
- `+BUG=3` a reset that arrives while data is stored does not clear the write pointer

## Expected output

See `expected_output.txt`. Every line in it comes from a real run on Synopsys VCS X-2025.06-SP1 on EDA Playground.
