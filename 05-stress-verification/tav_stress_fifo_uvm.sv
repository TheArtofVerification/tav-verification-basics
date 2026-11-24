// tav_stress_fifo_uvm.sv : normal random passes, stress finds the bugs, on a valid/ready FIFO (UVM 1.2)
// Run on Synopsys VCS X-2025.06-SP1 with UVM 1.2 (EDA Playground), 24 Nov 2026.
// The Art of Verification | theartofverification.com
//
// EDA Playground: Synopsys VCS, UVM 1.2, top module "tav_top".
// Paste this whole file into testbench.sv and leave design.sv empty.
//
// One run does five phases, with a reset before each:
//   A  normal random:          1,000 cycles, in_valid 40%, out_ready 90%
//   B1 stress, throughput:     300 cycles at full rate in and out
//   B2 stress, back-pressure:  the receiver stalls for 20 cycles, five times
//   B3 stress, squeeze:        500 cycles, in_valid 90%, out_ready 50%
//   B4 stress, reset mid-flow: resets while data is still in the FIFO
// After each phase the scoreboard prints pushes, pops, mismatches, assertion fails,
// the longest stall and which stress corners were hit.
//
// Run options (one per run):
//   (none)    the clean design
//   +BUG=1    when full, a push and a pop in the same cycle loses the pushed data
//   +BUG=2    after 4 cycles of being full, in_ready sticks low until the next reset
//   +BUG=3    a reset that arrives while data is stored does not clear the write pointer
//
// Spec (4-entry FIFO, valid/ready on both sides):
//   in_ready  = 1 when fewer than 4 entries are stored, or when full and out_ready is 1
//   push      = in_valid and in_ready.   pop = out_valid and out_ready
//   out_valid = 1 when at least 1 entry is stored. out_data is the oldest entry.
//   Data leaves in the order it came in, none lost, none repeated.
//   rst_n (async, active low) empties the FIFO.

`timescale 1ns/1ns
`include "uvm_macros.svh"
import uvm_pkg::*;

// ---------------------------------------------------------------------------
// The design
// ---------------------------------------------------------------------------
module tav_vr_fifo (input  logic       clk, rst_n,
                    input  logic       in_valid,
                    input  logic [7:0] in_data,
                    output logic       in_ready,
                    output logic       out_valid,
                    output logic [7:0] out_data,
                    input  logic       out_ready,
                    input  int         bug);
  logic [7:0] mem [4];
  logic [1:0] wp, rp;
  logic [2:0] count;
  logic       stuck, dirty;
  logic [2:0] full_run;
  logic       push, pop, full;

  assign full      = (count == 3'd4);
  assign out_valid = (count != 0);
  assign out_data  = mem[rp];
  assign in_ready  = stuck ? 1'b0 : (!full || out_ready);              // BUG=2 uses stuck
  assign push      = in_valid && in_ready;
  assign pop       = out_valid && out_ready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rp <= 0; count <= 0; stuck <= 0; full_run <= 0;
      // BUG=3: if data was stored when reset arrived, the write pointer keeps its value
      if (bug == 3 && (count != 0) === 1'b1) dirty <= 1'b1;
      if (!(bug == 3 && ((count != 0) === 1'b1 || dirty === 1'b1))) wp <= 0;
    end else begin
      dirty <= 1'b0;
      if (push && !(bug == 1 && full && pop)) begin                    // BUG=1
        mem[wp] <= in_data;
        wp <= wp + 1;
      end
      if (pop) rp <= rp + 1;
      count <= count + push - pop;
      full_run <= full ? ((full_run == 3'd7) ? full_run : full_run + 1) : 3'd0;
      if (bug == 2 && full_run >= 3'd4) stuck <= 1'b1;                 // BUG=2
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

  A_EMPTY_READY: assert property (@(posedge clk) disable iff (!rst_n) !out_valid |-> in_ready)
    else `uvm_error("SVA", "A_EMPTY_READY: FIFO is empty but in_ready is low")
  A_HOLD_OUT:    assert property (@(posedge clk) disable iff (!rst_n)
                                  (out_valid && !out_ready) |=> (out_valid && $stable(out_data)))
    else `uvm_error("SVA", "A_HOLD_OUT: out_valid dropped or out_data changed while stalled")
  A_NO_X:        assert property (@(posedge clk) disable iff (!rst_n) !$isunknown({in_ready, out_valid}))
    else `uvm_error("SVA", "A_NO_X: in_ready or out_valid is X")
endinterface

// ---------------------------------------------------------------------------
// Transaction: one clock cycle at the FIFO pins
// ---------------------------------------------------------------------------
class tav_fifo_item extends uvm_sequence_item;
  rand bit       in_valid, out_ready;
  bit      [7:0] in_data;
  bit            rst;            // 1 = pulse reset instead
  // filled in by the monitor
  logic          in_ready, out_valid;
  logic    [7:0] out_data;
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
  // One cycle with fixed valid/ready
  task cyc(bit v, bit r, int n = 1);
    repeat (n) begin
      req = tav_fifo_item::type_id::create("req");
      start_item(req);
      req.in_valid = v; req.out_ready = r; req.in_data = next_data++;
      finish_item(req);
    end
  endtask
  // n cycles with random valid/ready at the given percentages
  task rnd(int n, int v_pct, int r_pct);
    repeat (n) begin
      req = tav_fifo_item::type_id::create("req");
      start_item(req);
      if (!req.randomize() with { in_valid  dist {1 := v_pct, 0 := 100 - v_pct};
                                  out_ready dist {1 := r_pct, 0 := 100 - r_pct}; })
        `uvm_fatal("RAND", "randomize failed")
      req.in_data = next_data++;
      finish_item(req);
    end
  endtask
  task reset_pulse();
    req = tav_fifo_item::type_id::create("req");
    start_item(req);
    req.rst = 1;
    finish_item(req);
  endtask
endclass

class tav_reset_seq extends tav_fifo_base_seq;
  `uvm_object_utils(tav_reset_seq)
  function new(string name = "tav_reset_seq");
    super.new(name);
  endfunction
  task body();
    reset_pulse();
  endtask
endclass

// Phase A: the kind of random traffic most first tests use
class tav_normal_seq extends tav_fifo_base_seq;
  `uvm_object_utils(tav_normal_seq)
  function new(string name = "tav_normal_seq");
    super.new(name);
  endfunction
  task body();
    rnd(1000, 40, 90);
  endtask
endclass

// Phase B1, throughput: full rate in and out, no gaps
class tav_throughput_seq extends tav_fifo_base_seq;
  `uvm_object_utils(tav_throughput_seq)
  function new(string name = "tav_throughput_seq");
    super.new(name);
  endfunction
  task body();
    cyc(1, 1, 300);
  endtask
endclass

// Phase B2, back-pressure: the receiver stalls for 20 cycles at a time
class tav_backpressure_seq extends tav_fifo_base_seq;
  `uvm_object_utils(tav_backpressure_seq)
  function new(string name = "tav_backpressure_seq");
    super.new(name);
  endfunction
  task body();
    repeat (5) begin
      cyc(1, 0, 20);
      cyc(1, 1, 20);
    end
  endtask
endclass

// Phase B3, squeeze: heavy input, slow output, the FIFO lives near full
class tav_squeeze_seq extends tav_fifo_base_seq;
  `uvm_object_utils(tav_squeeze_seq)
  function new(string name = "tav_squeeze_seq");
    super.new(name);
  endfunction
  task body();
    rnd(500, 90, 50);
  endtask
endclass

// Phase B4, reset in the middle of traffic
class tav_reset_traffic_seq extends tav_fifo_base_seq;
  `uvm_object_utils(tav_reset_traffic_seq)
  function new(string name = "tav_reset_traffic_seq");
    super.new(name);
  endfunction
  task body();
    repeat (5) begin
      rnd(30, 90, 50);
      reset_pulse();
    end
    rnd(30, 90, 50);
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
// Scoreboard: queue model from the spec, stall watchdog, stress corners
// ---------------------------------------------------------------------------
class tav_fifo_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(tav_fifo_scoreboard)
  uvm_analysis_imp #(tav_fifo_item, tav_fifo_scoreboard) imp;

  bit [7:0] q[$];
  int pushes, pops, mismatches, shown, stall, max_stall, bp_run, sva_at_start;
  int c_full, c_full_push_pop, c_long_bp, c_reset_data;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    imp = new("imp", this);
  endfunction

  function void start_phase(string name);
    `uvm_info("PHASE", name, UVM_NONE)
    pushes = 0; pops = 0; mismatches = 0; shown = 0; stall = 0; max_stall = 0; bp_run = 0;
    c_full = 0; c_full_push_pop = 0; c_long_bp = 0; c_reset_data = 0;
    sva_at_start = uvm_report_server::get_server().get_id_count("SVA");
  endfunction

  function void err(string msg);
    mismatches++;
    if (shown < 2) begin
      shown++;
      `uvm_error("MISMATCH", msg)
    end
  endfunction

  function void write(tav_fifo_item t);
    bit e_ready, e_valid, push, pop;
    if (t.rst) begin
      if (q.size() > 0) c_reset_data++;
      q.delete(); stall = 0; bp_run = 0;
      return;
    end
    // Expected handshake signals, from the spec
    e_valid = (q.size() > 0);
    e_ready = (q.size() < 4) || t.out_ready;
    if (t.out_valid !== e_valid)
      err($sformatf("out_valid=%b, expected %b with %0d stored", t.out_valid, e_valid, q.size()));
    if (t.in_ready !== e_ready)
      err($sformatf("in_ready=%b, expected %b with %0d stored, out_ready=%b", t.in_ready, e_ready, q.size(), t.out_ready));
    // Stress corners
    if (q.size() == 4) c_full++;
    push = t.in_valid && t.in_ready;
    pop  = t.out_valid && t.out_ready;
    if (q.size() == 4 && push && pop) c_full_push_pop++;
    if (t.out_valid && !t.out_ready) bp_run++; else bp_run = 0;
    if (bp_run == 10) c_long_bp++;
    // Stall watchdog: how long has valid input waited without being accepted?
    if (t.in_valid && !t.in_ready) stall++; else stall = 0;
    if (stall > max_stall) max_stall = stall;
    // Data: pop first, then push, as the hardware does at the edge
    if (pop) begin
      pops++;
      if (q.size() == 0)                err($sformatf("popped data=%0d but nothing was stored", t.out_data));
      else if (t.out_data !== q[0])     err($sformatf("popped data=%0d, expected %0d", t.out_data, q[0]));
      if (q.size() > 0) void'(q.pop_front());
    end
    if (push) begin
      pushes++;
      q.push_back(t.in_data);
    end
  endfunction

  function void end_phase(string name);
    int sva, corners;
    sva = uvm_report_server::get_server().get_id_count("SVA") - sva_at_start;
    corners = (c_full > 0) + (c_full_push_pop > 0) + (c_long_bp > 0) + (c_reset_data > 0);
    `uvm_info("RESULT", $sformatf("%s: pushes=%0d pops=%0d mismatches=%0d assertion_fails=%0d max_stall=%0d -> %s",
              name, pushes, pops, mismatches, sva, max_stall,
              (mismatches == 0 && sva == 0) ? "PASS" : "FAIL"), UVM_NONE)
    `uvm_info("CORNERS", $sformatf("%s: full=%0d full_push_pop=%0d long_backpressure=%0d reset_with_data=%0d (%0d of 4 stress corners hit)",
              name, c_full, c_full_push_pop, c_long_bp, c_reset_data, corners), UVM_NONE)
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
// Test: normal random first, then four kinds of stress
// ---------------------------------------------------------------------------
class tav_stress_test extends uvm_test;
  `uvm_component_utils(tav_stress_test)
  tav_fifo_env env;
  virtual tav_fifo_if vif;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    env = tav_fifo_env::type_id::create("env", this);
    if (!uvm_config_db#(virtual tav_fifo_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "no virtual interface")
  endfunction

  task run_one(string name, tav_fifo_base_seq s);
    tav_reset_seq r = tav_reset_seq::type_id::create("r");
    env.scb.start_phase(name);
    r.start(env.agt.sqr);
    s.start(env.agt.sqr);
    repeat (2) @(vif.mon_cb);      // let the monitor see the last cycle
    #1;
    env.scb.end_phase(name);
  endtask

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    run_one("A  normal random",          tav_normal_seq::type_id::create("a"));
    run_one("B1 stress: throughput",     tav_throughput_seq::type_id::create("b1"));
    run_one("B2 stress: back-pressure",  tav_backpressure_seq::type_id::create("b2"));
    run_one("B3 stress: squeeze",        tav_squeeze_seq::type_id::create("b3"));
    run_one("B4 stress: reset mid-flow", tav_reset_traffic_seq::type_id::create("b4"));
    phase.drop_objection(this);
  endtask
endclass

// ---------------------------------------------------------------------------
// Top
// ---------------------------------------------------------------------------
module tav_top;
  logic clk = 0;
  int   BUG = 0;
  always #5 clk = ~clk;

  tav_fifo_if vif (clk);
  tav_vr_fifo dut (.clk(clk), .rst_n(vif.rst_n), .in_valid(vif.in_valid), .in_data(vif.in_data),
                   .in_ready(vif.in_ready), .out_valid(vif.out_valid), .out_data(vif.out_data),
                   .out_ready(vif.out_ready), .bug(BUG));

  initial begin
    void'($value$plusargs("BUG=%d", BUG));
    `uvm_info("TOP", $sformatf("Running with BUG=%0d", BUG), UVM_NONE)
    uvm_config_db#(virtual tav_fifo_if)::set(null, "uvm_test_top", "vif", vif);
    uvm_config_db#(virtual tav_fifo_if)::set(null, "uvm_test_top.env.agt.*", "vif", vif);
    run_test("tav_stress_test");
  end
endmodule
