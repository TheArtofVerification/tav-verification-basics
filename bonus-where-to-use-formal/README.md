# Bonus: Where to Use Formal Verification

Read the post: https://theartofverification.com/where-to-use-formal-verification/

One free formal flow and one UVM bench, on three blocks: a round-robin arbiter (control), an 8-deep FIFO (data movement) and a shift-and-add multiplier (arithmetic).

## Run the UVM bench

1. Open [EDA Playground](https://www.edaplayground.com/) (free account).
2. Paste `tav_where_formal_uvm.sv` into testbench.sv and leave design.sv empty.
3. Pick Synopsys VCS, UVM 1.2. Set the top module to `tav_top`.
4. Run once with no option, then with `+BUG=1` and `+BUG=2`. Each option switches a bug on in all three blocks at once.

See `expected_output.txt`.

## Run the formal harness

`tav_where_formal_fv.sv` is not a simulation testbench, so do not run it in VCS. Run it with open-source Yosys:

```sh
yosys -q -p "read_verilog -sv -formal tav_where_formal_fv.sv; chparam -set BUG 0 tav_fv_arb; prep -top tav_fv_arb; async2sync; dffunmap; write_smt2 -wires arb.smt2"
yosys-smtbmc -s z3 --unroll -t 20 arb.smt2      # bounded check, 20 cycles
yosys-smtbmc -s z3 --unroll -i -t 20 arb.smt2   # induction: a full proof
```

Use `tav_fv_fifo` or `tav_fv_mult` as the top for the other blocks. For the multiplier, also set its width (`chparam -set W 8 -set BUG 0 tav_fv_mult`) and use `-t 1`. Tested with Yosys 0.33, yosys-smtbmc and Z3 4.8.12. See `expected_formal_output.txt`.
