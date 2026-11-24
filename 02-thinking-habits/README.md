# Lesson 2: The Thought Process Behind Great Verification: 5 Habits That Find Real Bugs

Read the lesson: https://theartofverification.com/verification-thinking-habits/

## Run it

1. Open [EDA Playground](https://www.edaplayground.com/) (free account).
2. Paste `tav_fifo_think_uvm.sv` into testbench.sv and leave design.sv empty.
3. Pick Synopsys VCS, UVM 1.2. Set the top module to `tav_top`.
4. Run once with no option, then once for each option below (add it to Run Options).

EDA Playground link: (coming soon)

## Run options

- `(none)` the clean design
- `+BUG=1` full goes high at 15 entries instead of 16
- `+BUG=2` a write while full is not blocked, it overwrites the oldest entry
- `+BUG=3` the read pointer wraps to 1 instead of 0

## Expected output

See `expected_output.txt`. Every line in it comes from a real run on Synopsys VCS X-2025.06-SP1 on EDA Playground.
