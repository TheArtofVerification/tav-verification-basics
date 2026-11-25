# Bonus: UVM RAL, a Complete Guide With a Working APB Example

Read the post: https://theartofverification.com/uvm-ral/

One file holds a small APB register design (CTRL, ID, INT_STAT, INT_EN, SCRATCH, a 16-word buffer and two DMA channels), a full UVM RAL model for it (fields, registers, a register file, a memory, two IP blocks, a chip block with sub-maps and a second map), an APB agent, adapter and predictor, and a test in six phases:

| Phase | What runs |
|---|---|
| 0 | the tour: steps 0 to 17, every RAL method once, with desired, mirrored and design values printed |
| 1 | uvm_reg_hw_reset_seq |
| 2 | uvm_reg_bit_bash_seq |
| 3 | uvm_reg_mem_hdl_paths_seq, uvm_reg_access_seq, uvm_mem_walk_seq, uvm_reg_shared_access_seq |
| 4 | tav_w1c_seq (targeted) |
| 5 | tav_alias_seq (targeted) |

## Run it

1. Open [EDA Playground](https://www.edaplayground.com/) (free account).
2. Paste `tav_ral_apb_uvm.sv` into testbench.sv and leave design.sv empty.
3. Pick Synopsys VCS, UVM 1.2. Set the top module to `tav_top`.
4. Add `-debug_access+all` to Compile Options, or peek and poke cannot reach the design.
5. Run once with no option, then with `+BUG=1` to `+BUG=4`.

| Option | Bug |
|---|---|
| (none) | the clean design |
| `+BUG=1` | CTRL resets to 0x00 instead of 0x40 |
| `+BUG=2` | INT_STAT behaves as RW instead of W1C |
| `+BUG=3` | the read-only ID register can be written |
| `+BUG=4` | INT_EN decodes any address ending in 0xC (an alias) |

See `expected_output.txt`.

## The AI-written register model

`tav_ral_ai_check.sv` is the same bench with my register block swapped for an AI-written one, unedited. It is the version that ran for the post, from before tour step 17 was added, so its clean run shows 2 hw_reset errors from two DMA registers the tour left written. The post explains why. Run it the same way. See `expected_ai_output.txt`.

Both files ran on Synopsys VCS X-2025.06-SP1 (EDA Playground), 25 Nov 2026.
