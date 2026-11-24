# Lesson 7: How to Solve a Complex Verification Issue: Reproduce, Shrink and Isolate a Rare Bug

Read the lesson: https://theartofverification.com/intermittent-bug-debugging/

## Run it

1. Open [EDA Playground](https://www.edaplayground.com/) (free account).
2. Paste `tav_shrink_fifo_uvm.sv` into testbench.sv and leave design.sv empty.
3. Pick Synopsys VCS, UVM 1.2. Set the top module to `tav_top`.
4. Run once with no option, then once for each option below (add it to Run Options).

EDA Playground link: (coming soon)

## Run options

- `(none)` the clean design
- `+BUG=1` a rare bug: right after a stall, with one word stored and the write pointer at 7, a push and a pop in the same cycle lose the pushed word
- `+BUG=2` a loud bug: out_valid stays low while exactly one word is stored

## Expected output

See `expected_output.txt`. Every line in it comes from a real run on Synopsys VCS X-2025.06-SP1 on EDA Playground.
