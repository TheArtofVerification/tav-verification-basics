# Lesson 4: The Stages of IP Verification: From Plan to Sign-Off (With a UVM Example)

Read the lesson: https://theartofverification.com/ip-verification-stages/

## Run it

1. Open [EDA Playground](https://www.edaplayground.com/) (free account).
2. Paste `tav_ip_stages_uvm.sv` into testbench.sv and leave design.sv empty.
3. Pick Synopsys VCS, UVM 1.2. Set the top module to `tav_top`.
4. Run once with no option, then once for each option below (add it to Run Options).

EDA Playground link: (coming soon)

## Run options

- `(none)` the clean design
- `+BUG=1` the pointer does not move after granting requester 2 (starvation)
- `+BUG=2` with no request at all, the arbiter still grants the last winner
- `+BUG=3` with requests 1101 and last winner 3, it grants requester 2 instead of 0

## Expected output

See `expected_output.txt`. Every line in it comes from a real run on Synopsys VCS X-2025.06-SP1 on EDA Playground.
