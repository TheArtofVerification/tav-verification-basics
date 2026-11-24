# Lesson 1: How to Think Like a Verification Engineer: From Spec to Scenarios

Read the lesson: https://theartofverification.com/how-to-think-like-a-verification-engineer/

## Run it

1. Open [EDA Playground](https://www.edaplayground.com/) (free account).
2. Paste `alu_think_demo.sv` into testbench.sv and leave design.sv empty.
3. Pick Synopsys VCS. Set the top module to `alu_tb`.
4. Run once with no option, then once for each option below (add it to Run Options).

EDA Playground link: (coming soon)

## Run options

- `(none)` the clean design, all 2,048 input combinations checked
- `+BUG=1` SUB sets carry the wrong way round
- `+BUG=2` INC never sets overflow
- `+BUG=3` SHR shifts in a 1 instead of a 0, but only when a == 15

## Expected output

See `expected_output.txt`. Every line in it comes from a real run on Synopsys VCS X-2025.06-SP1 on EDA Playground.
