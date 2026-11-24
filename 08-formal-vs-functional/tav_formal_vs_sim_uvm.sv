// tav_formal_vs_sim_uvm.sv : what random simulation reaches, and replaying a formal counterexample (UVM 1.2)
// Run on Synopsys VCS X-2025.06-SP1 with UVM 1.2 (EDA Playground), 24 Nov 2026.
// The Art of Verification | theartofverification.com
//
// EDA Playground: Synopsys VCS, UVM 1.2, top module "tav_top".
// Paste this whole file into testbench.sv and leave design.sv empty.
//
// The design is a 2-requester arbiter with a debug mode. Debug mode turns on after six
// configuration writes in a row: A, 5, C, 3, F, 0. The safety rule is: never grant both.
// One run does two phases, with a reset before each:
//   RANDOM  100,000 cycles of random requests and random config writes (cfg_wr 50%)
//   REPLAY  the 8-cycle counterexample a formal tool found for +BUG=1, driven as a directed test
// After each phase the scoreboard prints mismatches against the spec model, cycles where both
// were granted, assertion fails reported (A_MUTEX stops after 3 per phase), how far the random config writes got into the unlock sequence, and whether debug mode was reached.
//
// Run options (one per run):
//   (none)    the clean design
//   +BUG=1    a deep bug: in debug mode the arbiter grants every request, so both can be granted
//   +BUG=2    a shallow bug: when both request right after an idle cycle and requester 1 won last,
//             both are granted
//
// Spec:
//   gnt is one-hot or zero: never both. A requester alone gets the grant on the next cycle.
//   When both request, the grant goes to the requester that did not win most recently
//   (a grant to a requester alone counts as a win). After reset, requester 0 goes first.
//   Debug mode must not change how requests are granted.
//   rst_n (async, active low) clears everything, including debug mode.

`timescale 1ns/1ns
`include "uvm_macros.svh"
import uvm_pkg::*;

// ---------------------------------------------------------------------------
// The design
// ---------------------------------------------------------------------------
module tav_mutex_arb (input  logic       clk, rst_n,
                      input  logic [1:0] req,
                      input  logic       cfg_wr,
                      input  logic [3:0] cfg_data,
                      output logic [1:0] gnt,
                      input  int         bug);
  // Debug mode unlocks after six config writes in a row: A 5 C 3 F 0
  logic [2:0] step;
  logic       debug_mode;
  logic       last;          // which requester won last time
  logic [3:0] magic;
  always_comb case (step)
    3'd0: magic = 4'hA; 3'd1: magic = 4'h5; 3'd2: magic = 4'hC;
    3'd3: magic = 4'h3; 3'd4: magic = 4'hF; default: magic = 4'h0;
  endcase
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      step <= 0; debug_mode <= 0; last <= 1; gnt <= 0;
    end else begin
      if (cfg_wr && !debug_mode) begin
        if (cfg_data == magic) begin
          if (step == 3'd5) debug_mode <= 1; else step <= step + 1;
        end else step <= (cfg_data == 4'hA) ? 3'd1 : 3'd0;
      end
      if (bug == 1 && debug_mode) gnt <= req;                       // BUG=1
      else if (req == 2'b11) begin
        if (bug == 2 && gnt == 2'b00 && last == 1'b1) gnt <= 2'b11;   // BUG=2
        else begin gnt <= last ? 2'b01 : 2'b10; last <= ~last; end
      end
      else if (req[0]) begin gnt <= 2'b01; last <= 0; end
      else if (req[1]) begin gnt <= 2'b10; last <= 1; end
      else gnt <= 2'b00;
    end
  end
endmodule

// ---------------------------------------------------------------------------
// Interface: pins plus two probes for coverage; the same safety property formal proves
// ---------------------------------------------------------------------------
interface tav_arb_if (input logic clk);
  logic       rst_n, cfg_wr;
  logic [1:0] req, gnt;
  logic [3:0] cfg_data;
  logic [2:0] step;          // probe: how far into the unlock sequence
  logic       debug_mode;    // probe
  clocking mon_cb @(posedge clk);
    default input #1step;
    input rst_n, cfg_wr, req, gnt, cfg_data, step, debug_mode;
  endclocking

  // A bug that fires every few cycles would flood the log (EDA Playground stops at 5000 lines),
  // so A_MUTEX reports its first 3 fails in a phase and then switches itself off.
  // The scoreboard still counts every cycle where both are granted.
  int tav_sva_fails;
  A_MUTEX: assert property (@(posedge clk) disable iff (!rst_n) gnt != 2'b11)
    else begin
      tav_sva_fails++;
      `uvm_error("SVA", $sformatf("A_MUTEX: both requesters granted (req=%b)", $sampled(req)))
      if (tav_sva_fails == 3) begin
        `uvm_info("SVA_OFF", "A_MUTEX switched off for the rest of this phase after 3 fails", UVM_NONE)
        $assertoff(0, A_MUTEX);
      end
    end

  function void tav_sva_rearm();   // called at the start of each phase
    tav_sva_fails = 0;
    $asserton(0, A_MUTEX);
  endfunction
endinterface

// ---------------------------------------------------------------------------
// Transaction: one clock cycle at the pins
// ---------------------------------------------------------------------------
class tav_arb_item extends uvm_sequence_item;
  rand bit [1:0] req;
  rand bit       cfg_wr;
  rand bit [3:0] cfg_data;
  bit            rst;
  constraint c_wr { cfg_wr dist {1 := 50, 0 := 50}; }
  `uvm_object_utils(tav_arb_item)
  function new(string name = "tav_arb_item");
    super.new(name);
  endfunction
endclass

class tav_arb_cycle extends uvm_object;
  bit       rst, cfg_wr, debug_mode;
  bit [1:0] req;
  logic [1:0] gnt;
  bit [3:0] cfg_data;
  bit [2:0] step;
  `uvm_object_utils(tav_arb_cycle)
  function new(string name = "tav_arb_cycle");
    super.new(name);
  endfunction
endclass

// ---------------------------------------------------------------------------
// Sequences
// ---------------------------------------------------------------------------
class tav_arb_base_seq extends uvm_sequence #(tav_arb_item);
  `uvm_object_utils(tav_arb_base_seq)
  function new(string name = "tav_arb_base_seq");
    super.new(name);
  endfunction
  task cyc(bit [1:0] r, bit w, bit [3:0] d);
    req = tav_arb_item::type_id::create("req");
    start_item(req);
    req.req = r; req.cfg_wr = w; req.cfg_data = d;
    finish_item(req);
  endtask
endclass

class tav_reset_seq extends tav_arb_base_seq;
  `uvm_object_utils(tav_reset_seq)
  function new(string name = "tav_reset_seq");
    super.new(name);
  endfunction
  task body();
    req = tav_arb_item::type_id::create("req");
    start_item(req);
    req.rst = 1;
    finish_item(req);
  endtask
endclass

class tav_random_seq extends tav_arb_base_seq;
  `uvm_object_utils(tav_random_seq)
  int unsigned n = 100000;
  function new(string name = "tav_random_seq");
    super.new(name);
  endfunction
  task body();
    repeat (n) begin
      req = tav_arb_item::type_id::create("req");
      start_item(req);
      if (!req.randomize()) `uvm_fatal("RAND", "randomize failed")
      finish_item(req);
    end
  endtask
endclass

// The counterexample from the formal run on +BUG=1, cycle by cycle after reset
class tav_replay_seq extends tav_arb_base_seq;
  `uvm_object_utils(tav_replay_seq)
  function new(string name = "tav_replay_seq");
    super.new(name);
  endfunction
  task body();
    //  req     cfg_wr cfg_data
    cyc(2'b01, 1, 4'hA);
    cyc(2'b00, 1, 4'h5);
    cyc(2'b00, 1, 4'hC);
    cyc(2'b00, 1, 4'h3);
    cyc(2'b01, 1, 4'hF);
    cyc(2'b01, 1, 4'h0);    // sixth write: debug mode turns on
    cyc(2'b11, 0, 4'hA);    // both request
    cyc(2'b00, 0, 4'h0);
  endtask
endclass

// ---------------------------------------------------------------------------
// Driver: drives on the falling edge; idles when there is no item
// ---------------------------------------------------------------------------
class tav_arb_driver extends uvm_driver #(tav_arb_item);
  `uvm_component_utils(tav_arb_driver)
  virtual tav_arb_if vif;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(virtual tav_arb_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "no virtual interface")
  endfunction
  task run_phase(uvm_phase phase);
    vif.rst_n <= 0; vif.req <= 0; vif.cfg_wr <= 0; vif.cfg_data <= 0;
    forever begin
      seq_item_port.try_next_item(req);
      if (req == null) begin
        @(negedge vif.clk);
        vif.req <= 0; vif.cfg_wr <= 0;
      end else begin
        if (req.rst) begin
          @(negedge vif.clk);
          vif.rst_n <= 0; vif.req <= 0; vif.cfg_wr <= 0;
          @(negedge vif.clk);
          vif.rst_n <= 1;
        end else begin
          @(negedge vif.clk);
          vif.req <= req.req; vif.cfg_wr <= req.cfg_wr; vif.cfg_data <= req.cfg_data;
        end
        seq_item_port.item_done();
      end
    end
  endtask
endclass

// ---------------------------------------------------------------------------
// Monitor: one snapshot per clock
// ---------------------------------------------------------------------------
class tav_arb_monitor extends uvm_monitor;
  `uvm_component_utils(tav_arb_monitor)
  virtual tav_arb_if vif;
  uvm_analysis_port #(tav_arb_cycle) ap;
  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction
  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(virtual tav_arb_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "no virtual interface")
  endfunction
  task run_phase(uvm_phase phase);
    forever begin
      tav_arb_cycle t;
      @(vif.mon_cb);
      t = tav_arb_cycle::type_id::create("t");
      t.rst        = (vif.mon_cb.rst_n !== 1'b1);
      t.req        = vif.mon_cb.req;
      t.cfg_wr     = vif.mon_cb.cfg_wr;
      t.cfg_data   = vif.mon_cb.cfg_data;
      t.gnt        = vif.mon_cb.gnt;
      t.step       = vif.mon_cb.step;
      t.debug_mode = vif.mon_cb.debug_mode;
      ap.write(t);
    end
  endtask
endclass

// ---------------------------------------------------------------------------
// Scoreboard: spec model of the grants, and how deep the stimulus got
// ---------------------------------------------------------------------------
class tav_arb_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(tav_arb_scoreboard)
  uvm_analysis_imp #(tav_arb_cycle, tav_arb_scoreboard) imp;

  bit [1:0] m_gnt;
  bit       m_last;
  int       cycles, mismatches, shown, both, max_step;
  bit       debug_seen;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    imp = new("imp", this);
  endfunction

  function void start_phase(string name);
    `uvm_info("PHASE", name, UVM_NONE)
    cycles = 0; mismatches = 0; shown = 0; both = 0; max_step = 0; debug_seen = 0;
  endfunction

  function void write(tav_arb_cycle t);
    if (t.rst) begin m_gnt = 0; m_last = 1; return; end
    cycles++;
    // how far the config writes have got into the unlock sequence (6 = debug mode)
    if (t.debug_mode) begin debug_seen = 1; max_step = 6; end
    else if (t.step > max_step) max_step = t.step;
    if (t.gnt == 2'b11) both++;
    // check this cycle's grant against the spec model
    if (t.gnt !== m_gnt) begin
      mismatches++;
      if (shown < 3) begin
        shown++;
        `uvm_error("MISMATCH", $sformatf("cycle %0d: gnt=%b, expected %b", cycles, t.gnt, m_gnt))
      end
    end
    // spec model: the grant for the next cycle, from this cycle's requests
    if (t.req == 2'b11) begin m_gnt = m_last ? 2'b01 : 2'b10; m_last = ~m_last; end
    else if (t.req[0])  begin m_gnt = 2'b01; m_last = 0; end
    else if (t.req[1])  begin m_gnt = 2'b10; m_last = 1; end
    else                      m_gnt = 2'b00;
  endfunction

  function void end_phase(string name, int sva);
    `uvm_info("RESULT", $sformatf("%s: cycles=%0d mismatches=%0d both_granted=%0d assertion_fails=%0d%s -> %s",
              name, cycles, mismatches, both, sva, (sva >= 3) ? " (then switched off)" : "",
              (mismatches == 0 && both == 0 && sva == 0) ? "PASS" : "FAIL"), UVM_NONE)
    `uvm_info("DEPTH", $sformatf("%s: deepest unlock step reached=%0d of 6, debug mode reached=%s",
              name, max_step, debug_seen ? "yes" : "no"), UVM_NONE)
  endfunction
endclass

// ---------------------------------------------------------------------------
// Agent, environment, test
// ---------------------------------------------------------------------------
class tav_arb_agent extends uvm_agent;
  `uvm_component_utils(tav_arb_agent)
  uvm_sequencer #(tav_arb_item) sqr;
  tav_arb_driver  drv;
  tav_arb_monitor mon;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    sqr = uvm_sequencer#(tav_arb_item)::type_id::create("sqr", this);
    drv = tav_arb_driver::type_id::create("drv", this);
    mon = tav_arb_monitor::type_id::create("mon", this);
  endfunction
  function void connect_phase(uvm_phase phase);
    drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction
endclass

class tav_arb_env extends uvm_env;
  `uvm_component_utils(tav_arb_env)
  tav_arb_agent      agt;
  tav_arb_scoreboard scb;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    agt = tav_arb_agent::type_id::create("agt", this);
    scb = tav_arb_scoreboard::type_id::create("scb", this);
  endfunction
  function void connect_phase(uvm_phase phase);
    agt.mon.ap.connect(scb.imp);
  endfunction
endclass

class tav_formal_vs_sim_test extends uvm_test;
  `uvm_component_utils(tav_formal_vs_sim_test)
  tav_arb_env env;
  virtual tav_arb_if vif;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    env = tav_arb_env::type_id::create("env", this);
    if (!uvm_config_db#(virtual tav_arb_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "no virtual interface")
  endfunction

  task run_one(string name, tav_arb_base_seq s);
    tav_reset_seq r = tav_reset_seq::type_id::create("r");
    r.start(env.agt.sqr);
    vif.tav_sva_rearm();
    env.scb.start_phase(name);
    s.start(env.agt.sqr);
    repeat (2) @(vif.mon_cb);
    #1;
    env.scb.end_phase(name, vif.tav_sva_fails);
  endtask

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    run_one("RANDOM 100k cycles", tav_random_seq::type_id::create("rnd"));
    run_one("REPLAY formal trace", tav_replay_seq::type_id::create("rep"));
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

  tav_arb_if vif (clk);
  tav_mutex_arb dut (.clk(clk), .rst_n(vif.rst_n), .req(vif.req), .cfg_wr(vif.cfg_wr),
                     .cfg_data(vif.cfg_data), .gnt(vif.gnt), .bug(BUG));
  assign vif.step       = dut.step;
  assign vif.debug_mode = dut.debug_mode;

  initial begin
    void'($value$plusargs("BUG=%d", BUG));
    `uvm_info("TOP", $sformatf("Running with BUG=%0d", BUG), UVM_NONE)
    uvm_config_db#(virtual tav_arb_if)::set(null, "uvm_test_top", "vif", vif);
    uvm_config_db#(virtual tav_arb_if)::set(null, "uvm_test_top.env.agt.*", "vif", vif);
    run_test("tav_formal_vs_sim_test");
  end
endmodule
