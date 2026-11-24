# Lesson 8: Formal vs Functional Verification: What Each One Proves, With a Real Example

Read the lesson: https://theartofverification.com/formal-vs-functional-verification/

## Run it

1. Open [EDA Playground](https://www.edaplayground.com/) (free account).
2. Paste `tav_formal_vs_sim_uvm.sv` into testbench.sv and leave design.sv empty.
3. Pick Synopsys VCS, UVM 1.2. Set the top module to `tav_top`.
4. Run once with no option, then once for each option below (add it to Run Options).

EDA Playground link: (coming soon)

## Run options

- `(none)` the clean design
- `+BUG=1` a deep bug: in debug mode the arbiter grants every request, so both can be granted
- `+BUG=2` a shallow bug: when both request right after an idle cycle and requester 1 won last, both are granted

## Expected output

See `expected_output.txt`. Every line in it comes from a real run on Synopsys VCS X-2025.06-SP1 on EDA Playground.

## The formal harness

`tav_formal_vs_sim_fv.sv` is not a simulation testbench, so do not run it in VCS. Run it with open-source Yosys:

```sh
yosys -q -p "read_verilog -sv -formal tav_formal_vs_sim_fv.sv; chparam -set BUG 1 tav_fv_top; prep -top tav_fv_top; async2sync; dffunmap; write_smt2 -wires arb.smt2"
yosys-smtbmc -s z3 -t 20 --dump-vcd cex.vcd arb.smt2   # bounded check, 20 cycles
yosys-smtbmc -s z3 -i -t 20 arb.smt2                    # induction: a full proof
```

Tested with Yosys 0.33, yosys-smtbmc and Z3 4.8.12. See `expected_formal_output.txt`.
