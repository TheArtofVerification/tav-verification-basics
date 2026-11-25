# Bonus: UVM Virtual Sequence and Virtual Sequencer, a Complete Guide With a Working Example

Read the post: https://theartofverification.com/uvm-virtual-sequence/

One file holds a small merge block (`tav_merge`: an APB config port and two byte streams, A and B, merged round robin onto one output), three UVM agents (APB, A and B), an output monitor, a scoreboard, a virtual sequencer (`tav_vsqr`) and a test that walks through every virtual sequence idea in 9 steps:

| Step | What runs |
|---|---|
| 0 | `default_sequence`: `tav_init_vseq` starts by itself in configure_phase |
| 1 | approach 1: handles inside the sequence, `start(null)` |
| 2 | approach 2: virtual sequencer and `p_sequencer` |
| 3 | serial vs `fork`/`join` (320 ns vs 170 ns for the same 16 bytes) |
| 4 | `join_any`, then `wait fork` |
| 5 | nested virtual sequences |
| 6 | `lock()`: three writes kept together while another sequence polls |
| 7 | `grab()` goes to the front of the line |
| 8 | `join_none`, other work, `wait fork`, then a per-port counter check |

## Run it

1. Open [EDA Playground](https://www.edaplayground.com/) (free account).
2. Paste `tav_vseq_uvm.sv` into testbench.sv and leave design.sv empty.
3. Pick Synopsys VCS, UVM 1.2. Set the top module to `tav_top`.
4. Run once with no option, then with `+BUG=1` to `+BUG=4`.

| Option | Planted bench mistake |
|---|---|
| (none) | the clean bench |
| `+BUG=1` | the virtual sequencer's `b_sqr` handle is never set |
| `+BUG=2` | the start-up sequence forks setup and traffic |
| `+BUG=3` | step 8 uses `join_none` and forgets `wait fork` |
| `+BUG=4` | `b_sqr` points at agent A's sequencer |

See `expected_output.txt`. Ran on Synopsys VCS X-2025.06-SP1 (EDA Playground), 25 Nov 2026.
