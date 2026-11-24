# Lesson 3: How to Build a Strong Verification Plan: From Spec to Sign-Off

Read the lesson: https://theartofverification.com/verification-plan/

## Run it

1. Open [EDA Playground](https://www.edaplayground.com/) (free account).
2. Paste `tav_plan_counter_uvm.sv` into testbench.sv and leave design.sv empty.
3. Pick Synopsys VCS, UVM 1.2. Set the top module to `tav_top`.
4. Run once with no option, then once for each option below (add it to Run Options).

EDA Playground link: (coming soon)

## Run options

- `(none)` the clean design
- `+BUG=1` load is ignored when enable is high at the same time
- `+BUG=2` ovf fires one count early (at 254 -> 255 instead of 255 -> 0)
- `+BUG=3` load beats clear when both are high

## Expected output

See `expected_output.txt`. Every line in it comes from a real run on Synopsys VCS X-2025.06-SP1 on EDA Playground.
