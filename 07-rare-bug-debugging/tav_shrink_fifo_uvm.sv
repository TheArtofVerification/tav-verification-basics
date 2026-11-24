// tav_shrink_fifo_uvm.sv : a bug that fails on only some seeds; sweep, shrink, isolate, lock in (UVM 1.2)
// Run on Synopsys VCS X-2025.06-SP1 with UVM 1.2 (EDA Playground), 24 Nov 2026.
// The Art of Verification | theartofverification.com
//
// EDA Playground: Synopsys VCS, UVM 1.2, top module "tav_top".
// Paste this whole file into testbench.sv and leave design.sv empty.
//
// The design is an 8-entry valid/ready FIFO. One run of the test does four steps:
//   SWEEP     30 short random trials, each with its own seed (seeds 100 to 129), 50 cycles each
//   SHRINK    takes the first failing seed and finds the shortest prefix of it that still fails
//   WINDOW    prints the state of the FIFO in the last cycles of that shortest failing prefix
//   DIRECTED  a short directed test built from those conditions, so the bug fails every time
// Each trial starts with a reset and ends with 10 drain cycles, so a lost word always surfaces.
//
// Run options (one per run):
//   (none)    the clean design
//   +BUG=1    a rare bug: right after a stall, with one word stored and the write pointer at 7,
//             a push and a pop in the same cycle lose the pushed word
//   +BUG=2    a loud bug: out_valid stays low while exactly one word is stored
//
// Spec (8-entry FIFO):
//   in_ready  = 1 when fewer than 8 words are stored.   push = in_valid and in_ready
//   out_valid = 1 when at least 1 word is stored.       pop  = out_valid and out_ready
//   out_data is the oldest word. Words leave in order, none lost, none repeated.
//   rst_n (async, active low) empties the FIFO.

`timescale 1ns/1ns
`include "uvm_macros.svh"
import uvm_pkg::*;

// ---------------------------------------------------------------------------
// The design
// ---------------------------------------------------------------------------
module tav_ring_fifo (input  logic       clk, rst_n,
                      input  logic       in_valid,
                      input  logic [7:0] in_data,
                      output logic       in_ready,
                      output logic       out_valid,
                      output logic [7:0] out_data,
                      input  logic       out_ready,
                      input  int         bug);
  logic [7:0] mem [8];
  logic [2:0] wp, rp;
  logic [3:0] count;
  logic       push, pop, stalled;

  assign in_ready  = (count != 4'd8);
  assign out_valid = (bug == 2) ? (count > 4'd1) : (count != 4'd0);    // BUG=2
  assign out_data  = mem[rp];
  assign push      = in_valid && in_ready;
  assign pop       = out_valid && out_ready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wp <= 0; rp <= 0; count <= 0; stalled <= 0;
    end else begin
      stalled <= out_valid && !out_ready;
      if (push && !(bug == 1 && pop && stalled && count == 4'd1 && wp == 3'd7)) begin   // BUG=1
        mem[wp] <= in_data;
        wp <= wp + 1;
      end
      if (pop) rp <= rp + 1;
      count <= count + push - pop;
    end
  end
endmodule

// ---------------------------------------------------------------------------
// Interface: the monitor samples just before each rising edge; assertions live here
// ---------------------------------------------------------------------------
interface tav_fifo_if (input logic clk);
  logic       rst_n, in_valid, in_ready, out_valid, out_ready;
  logic [7:0] in_data, out_data;
  clocking mon_cb @(posedge clk);
    default input #1step;
    input rst_n, in_valid, in_ready, in_data, out_valid, out_ready, out_data;
  endclocking

  A_HOLD_OUT: assert property (@(posedge clk) disable iff (!rst_n)
                               (out_valid && !out_ready) |=> (out_valid && $stable(out_data)))
    else `uvm_error("SVA", "A_HOLD_OUT: out_valid dropped or out_data changed while stalled")
  A_NO_X:     assert property (@(posedge clk) disable iff (!rst_n) !$isunknown({in_ready, out_valid}))
    else `uvm_error("SVA", "A_NO_X: in_ready or out_valid is X")
endinterface

// ---------------------------------------------------------------------------
// Transaction: one clock cycle at the FIFO pins
// ---------------------------------------------------------------------------
class tav_fifo_item extends uvm_sequence_item;
  bit       in_valid, out_ready, rst;
  bit [7:0] in_data;
  logic     in_ready, out_valid;
  logic [7:0] out_data;
  `uvm_object_utils(tav_fifo_item)
  function new(string name = "tav_fifo_item");
    super.new(name);
  endfunction
endclass

// ---------------------------------------------------------------------------
// Sequences
// ---------------------------------------------------------------------------
class tav_fifo_base_seq extends uvm_sequence #(tav_fifo_item);
  `uvm_object_utils(tav_fifo_base_seq)
  bit [7:0] next_data = 1;
  function new(string name = "tav_fifo_base_seq");
    super.new(name);
  endfunction
  task cyc(bit v, bit r, int n = 1);
    repeat (n) begin
      req = tav_fifo_item::type_id::create("req");
      start_item(req);
      req.in_valid = v; req.out_ready = r; req.in_data = next_data++;
      finish_item(req);
    end
  endtask
  task drain();
    cyc(0, 1, 10);
  endtask
endclass

class tav_reset_seq extends tav_fifo_base_seq;
  `uvm_object_utils(tav_reset_seq)
  function new(string name = "tav_reset_seq");
    super.new(name);
  endfunction
  task body();
    req = tav_fifo_item::type_id::create("req");
    start_item(req);
    req.rst = 1;
    finish_item(req);
  endtask
endclass

// Random traffic from a fixed seed: the same seed always gives the same cycles,
// so the first n cycles of a seed are a true prefix of its longer run
class tav_seeded_seq extends tav_fifo_base_seq;
  `uvm_object_utils(tav_seeded_seq)
  int unsigned seed, n;
  function new(string name = "tav_seeded_seq");
    super.new(name);
  endfunction
  task body();
    process::self().srandom(seed);
    for (int i = 0; i < n; i++)
      cyc($urandom_range(99) < 50, $urandom_range(99) < 70);   // in_valid 50%, out_ready 70%
    drain();
  endtask
endclass

// Built from the WINDOW conditions: one word stored, write pointer at 7, a stall, then push and pop
class tav_directed_seq extends tav_fifo_base_seq;
  `uvm_object_utils(tav_directed_seq)
  function new(string name = "tav_directed_seq");
    super.new(name);
  endfunction
  task body();
    cyc(1, 0);        // push one word: 1 stored, write pointer 1
    cyc(1, 1, 6);     // push and pop together 6 times: still 1 stored, write pointer 7
    cyc(0, 0);        // stall: the receiver is not ready
    cyc(1, 1);        // push and pop together right after the stall
    drain();
  endtask
endclass

// ---------------------------------------------------------------------------
// Driver: drives on the falling edge, idles when there is no item
// ---------------------------------------------------------------------------
class tav_fifo_driver extends uvm_driver #(tav_fifo_item);
  `uvm_component_utils(tav_fifo_driver)
  virtual tav_fifo_if vif;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(virtual tav_fifo_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "no virtual interface")
  endfunction
  task run_phase(uvm_phase phase);
    vif.rst_n <= 0; vif.in_valid <= 0; vif.out_ready <= 0; vif.in_data <= 0;
    forever begin
      seq_item_port.try_next_item(req);
      if (req == null) begin
        @(negedge vif.clk);
        vif.in_valid <= 0; vif.out_ready <= 1;
      end else begin
        if (req.rst) begin
          @(negedge vif.clk);
          vif.rst_n <= 0; vif.in_valid <= 0; vif.out_ready <= 0;
          @(negedge vif.clk);
          vif.rst_n <= 1;
        end else begin
          @(negedge vif.clk);
          vif.in_valid <= req.in_valid; vif.out_ready <= req.out_ready; vif.in_data <= req.in_data;
        end
        seq_item_port.item_done();
      end
    end
  endtask
endclass

// ---------------------------------------------------------------------------
// Monitor: one transaction per clock, sampled just before the edge
// ---------------------------------------------------------------------------
class tav_fifo_monitor extends uvm_monitor;
  `uvm_component_utils(tav_fifo_monitor)
  virtual tav_fifo_if vif;
  uvm_analysis_port #(tav_fifo_item) ap;
  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction
  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(virtual tav_fifo_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "no virtual interface")
  endfunction
  task run_phase(uvm_phase phase);
    forever begin
      tav_fifo_item t;
      @(vif.mon_cb);
      t = tav_fifo_item::type_id::create("t");
      t.rst       = (vif.mon_cb.rst_n !== 1'b1);
      t.in_valid  = vif.mon_cb.in_valid;
      t.in_ready  = vif.mon_cb.in_ready;
      t.in_data   = vif.mon_cb.in_data;
      t.out_valid = vif.mon_cb.out_valid;
      t.out_ready = vif.mon_cb.out_ready;
      t.out_data  = vif.mon_cb.out_data;
      ap.write(t);
    end
  endtask
endclass

// ---------------------------------------------------------------------------
// Scoreboard: queue model from the spec, per-trial results, a window of recent cycles
// ---------------------------------------------------------------------------
class tav_fifo_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(tav_fifo_scoreboard)
  uvm_analysis_imp #(tav_fifo_item, tav_fifo_scoreboard) imp;

  bit [7:0] q[$];
  int    mismatches, cycle, pushes_total;
  bit    quiet, prev_stall;
  string trial_name, first_msg;
  string hist[$];                 // one line per cycle of the current trial

  function new(string name, uvm_component parent);
    super.new(name, parent);
    imp = new("imp", this);
  endfunction

  function void start_trial(string name, bit be_quiet);
    trial_name = name; quiet = be_quiet;
    mismatches = 0; cycle = 0; pushes_total = 0; prev_stall = 0; first_msg = "";
    hist.delete();
  endfunction

  function void err(string msg);
    mismatches++;
    if (mismatches == 1) begin
      first_msg = $sformatf("cycle %0d: %s", cycle, msg);
      if (!quiet) `uvm_error("MISMATCH", $sformatf("%s, %s", trial_name, first_msg))
    end
  endfunction

  function void write(tav_fifo_item t);
    bit e_ready, e_valid, push, pop;
    if (t.rst) begin
      q.delete(); prev_stall = 0;
      return;
    end
    cycle++;
    e_valid = (q.size() > 0);
    e_ready = (q.size() < 8);
    if (t.out_valid !== e_valid) err($sformatf("out_valid=%b, expected %b with %0d stored", t.out_valid, e_valid, q.size()));
    if (t.in_ready  !== e_ready) err($sformatf("in_ready=%b, expected %b with %0d stored", t.in_ready, e_ready, q.size()));
    push = t.in_valid && t.in_ready;
    pop  = t.out_valid && t.out_ready;
    // what the cycle looked like, from the spec's point of view
    hist.push_back($sformatf("cycle %0d: stored=%0d write_ptr=%0d stalled_before=%0d push=%0d pop=%0d",
                   cycle, q.size(), pushes_total % 8, prev_stall, push, pop));
    if (pop) begin
      if (q.size() == 0)            err($sformatf("popped data=%0d but nothing was stored", t.out_data));
      else if (t.out_data !== q[0]) err($sformatf("popped data=%0d, expected %0d", t.out_data, q[0]));
      if (q.size() > 0) void'(q.pop_front());
    end
    if (push) begin
      q.push_back(t.in_data);
      pushes_total++;
    end
    prev_stall = t.out_valid && !t.out_ready;
  endfunction

  // the cycles around the end of the random part of the trial
  function void print_window(int last_cycle);
    for (int i = last_cycle - 3; i <= last_cycle + 1; i++)
      if (i >= 0 && i < hist.size()) `uvm_info("WINDOW", hist[i], UVM_NONE)
  endfunction
endclass

// ---------------------------------------------------------------------------
// Agent and environment
// ---------------------------------------------------------------------------
class tav_fifo_agent extends uvm_agent;
  `uvm_component_utils(tav_fifo_agent)
  uvm_sequencer #(tav_fifo_item) sqr;
  tav_fifo_driver  drv;
  tav_fifo_monitor mon;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    sqr = uvm_sequencer#(tav_fifo_item)::type_id::create("sqr", this);
    drv = tav_fifo_driver::type_id::create("drv", this);
    mon = tav_fifo_monitor::type_id::create("mon", this);
  endfunction
  function void connect_phase(uvm_phase phase);
    drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction
endclass

class tav_fifo_env extends uvm_env;
  `uvm_component_utils(tav_fifo_env)
  tav_fifo_agent      agt;
  tav_fifo_scoreboard scb;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    agt = tav_fifo_agent::type_id::create("agt", this);
    scb = tav_fifo_scoreboard::type_id::create("scb", this);
  endfunction
  function void connect_phase(uvm_phase phase);
    agt.mon.ap.connect(scb.imp);
  endfunction
endclass

// ---------------------------------------------------------------------------
// Test: sweep, shrink, window, directed
// ---------------------------------------------------------------------------
class tav_shrink_test extends uvm_test;
  `uvm_component_utils(tav_shrink_test)
  tav_fifo_env env;
  virtual tav_fifo_if vif;
  int unsigned seed_base = 100, n_trials = 30, n_cycles = 50;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    env = tav_fifo_env::type_id::create("env", this);
    if (!uvm_config_db#(virtual tav_fifo_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "no virtual interface")
  endfunction

  // one trial: reset, the traffic, then let the monitor see the last cycle
  task run_seq(string name, tav_fifo_base_seq s, bit quiet, output int fails);
    tav_reset_seq r = tav_reset_seq::type_id::create("r");
    r.start(env.agt.sqr);
    env.scb.start_trial(name, quiet);     // start counting only after the reset, so nothing left
                                          // over from the previous trial is counted in this one
    s.start(env.agt.sqr);
    repeat (2) @(vif.mon_cb);
    #1;
    fails = env.scb.mismatches;
  endtask

  task run_seed(int unsigned seed, int unsigned n, bit quiet, output int fails);
    tav_seeded_seq s = tav_seeded_seq::type_id::create("s");
    s.seed = seed; s.n = n;
    run_seq($sformatf("seed %0d", seed), s, quiet, fails);
  endtask

  task run_phase(uvm_phase phase);
    int fails, failing[$], lo, hi, mid, runs;
    string list;
    tav_directed_seq d;
    phase.raise_objection(this);

    // SWEEP: many short trials, each with its own seed
    for (int i = 0; i < n_trials; i++) begin
      run_seed(seed_base + i, n_cycles, 0, fails);
      if (fails > 0) begin failing.push_back(seed_base + i); list = {list, $sformatf(" %0d", seed_base + i)}; end
    end
    `uvm_info("SWEEP", $sformatf("trials=%0d cycles_each=%0d failing=%0d seeds:%s", n_trials, n_cycles,
              failing.size(), failing.size() ? list : " none"), UVM_NONE)

    // SHRINK: the shortest prefix of the first failing seed that still fails (binary search)
    if (failing.size() > 0) begin
      lo = 1; hi = n_cycles; runs = 0;
      while (lo < hi) begin
        mid = (lo + hi) / 2;
        run_seed(failing[0], mid, 1, fails); runs++;
        if (fails > 0) hi = mid; else lo = mid + 1;
      end
      `uvm_info("SHRINK", $sformatf("seed %0d: fails in %0d cycles, still fails in the first %0d (found in %0d extra runs)",
                failing[0], n_cycles, lo, runs), UVM_NONE)
      // WINDOW: rerun the shortest failing prefix and show its last cycles
      run_seed(failing[0], lo, 1, fails);
      `uvm_info("WINDOW", $sformatf("seed %0d, first %0d cycles, first error: %s", failing[0], lo, env.scb.first_msg), UVM_NONE)
      env.scb.print_window(lo);
    end else
      `uvm_info("SHRINK", "nothing to shrink: no trial failed", UVM_NONE)

    // DIRECTED: the conditions from the window, every time
    d = tav_directed_seq::type_id::create("d");
    run_seq("directed", d, 0, fails);
    `uvm_info("DIRECTED", $sformatf("stall, then push and pop with 1 stored and write pointer 7: %0d cycles -> %s",
              env.scb.cycle, fails ? "FAIL" : "PASS"), UVM_NONE)
    phase.drop_objection(this);
  endtask

  function void report_phase(uvm_phase phase);
    `uvm_info("SUMMARY", $sformatf("assertion_fails=%0d", uvm_report_server::get_server().get_id_count("SVA")), UVM_NONE)
  endfunction
endclass

// ---------------------------------------------------------------------------
// Top
// ---------------------------------------------------------------------------
module tav_top;
  logic clk = 0;
  int   BUG = 0;
  always #5 clk = ~clk;

  tav_fifo_if vif (clk);
  tav_ring_fifo dut (.clk(clk), .rst_n(vif.rst_n), .in_valid(vif.in_valid), .in_data(vif.in_data),
                     .in_ready(vif.in_ready), .out_valid(vif.out_valid), .out_data(vif.out_data),
                     .out_ready(vif.out_ready), .bug(BUG));

  initial begin
    void'($value$plusargs("BUG=%d", BUG));
    `uvm_info("TOP", $sformatf("Running with BUG=%0d", BUG), UVM_NONE)
    uvm_config_db#(virtual tav_fifo_if)::set(null, "uvm_test_top", "vif", vif);
    uvm_config_db#(virtual tav_fifo_if)::set(null, "uvm_test_top.env.agt.*", "vif", vif);
    run_test("tav_shrink_test");
  end
endmodule
