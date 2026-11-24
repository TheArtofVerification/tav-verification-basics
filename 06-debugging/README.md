# Lesson 6: Debugging in Verification: The Art and Science of Finding the Real Bug

Read the lesson: https://theartofverification.com/debugging-in-verification/

## Run it

1. Open [EDA Playground](https://www.edaplayground.com/) (free account).
2. Paste `tav_debug_pipe_uvm.sv` into testbench.sv and leave design.sv empty.
3. Pick Synopsys VCS, UVM 1.2. Set the top module to `tav_top`.
4. Run once with no option, then once for each option below (add it to Run Options).

EDA Playground link: (coming soon)

## Run options

- `(none)` the clean design
- `+BUG=1` S1 drops the start-of-packet flag when a packet follows the previous one with no gap
- `+BUG=2` S2 counts length with 5 bits, so packets longer than 31 bytes report the wrong length
- `+BUG=3` OUT keeps its old value when two packets finish on back-to-back cycles

## Expected output

See `expected_output.txt`. Every line in it comes from a real run on Synopsys VCS X-2025.06-SP1 on EDA Playground.
