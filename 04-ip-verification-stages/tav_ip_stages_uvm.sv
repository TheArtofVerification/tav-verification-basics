// tav_ip_stages_uvm.sv : one IP, three verification stages, three bugs, each found at a different stage (UVM 1.2)
// Run on Synopsys VCS X-2025.06-SP1 with UVM 1.2 (EDA Playground), 24 Nov 2026.
// The Art of Verification | theartofverification.com
//
// EDA Playground: Synopsys VCS, UVM 1.2, top module "tav_top".
// Paste this whole file into testbench.sv and leave design.sv empty.
//
// One run walks the IP through three stages, with a reset before each:
//   Stage 1, sanity:   each requester alone, with idle cycles in between (8 cycles)
//   Stage 2, feature:  directed rotation and pair patterns, then 300 random cycles
//                      with at most two requesters at a time
//   Stage 3, closure:  2,000 dense random cycles, chasing every request pattern
// After each stage the scoreboard prints checks, mismatches, assertion fails,
// the longest wait seen and the request-pattern coverage.
//
// Run options (one per run):
//   (none)    the clean design
//   +BUG=1    the pointer does not move after granting requester 2 (starvation)
//   +BUG=2    with no request at all, the arbiter still grants the last winner
//   +BUG=3    with requests 1101 and last winner 3, it grants requester 2 instead of 0
//
// Spec (4 requesters, round robin):
//   gnt is one-hot or zero. gnt[i] is 1 only if req[i] is 1.
//   If any request is high, exactly one grant is given.
//   The search starts just after the last requester that was granted, so a request
//   that stays high is granted within 4 cycles (it waits at most 3).
//   After reset the last winner is 3, so requester 0 has first priority.

`timescale 1ns/1ns
`include "uvm_macros.svh"
import uvm_pkg::*;

// ---------------------------------------------------------------------------
// The design: a 4-way round-robin arbiter
// ---------------------------------------------------------------------------
module tav_rr_arbiter (input  logic       clk, rst_n,
                       input  logic [3:0] req,
                       output logic [3:0] gnt,
                       input  int         bug);
  logic [1:0] last;

  always_comb begin
    gnt = '0;
    for (int k = 1; k <= 4; k++) begin
      int idx;
      idx = (last + k) % 4;
      if (req[idx] && gnt == 0) gnt[idx] = 1'b1;
    end
    if (bug == 2 && req == 4'b0000) gnt = 4'b0001 << last;                 // BUG=2
    if (bug == 3 && req == 4'b1101 && last == 2'd3) gnt = 4'b0100;         // BUG=3
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      last <= 2'd3;
    else if (gnt != 0 && !(bug == 1 && gnt[2]))                          // BUG=1
      for (int i = 0; i < 4; i++) if (gnt[i]) last <= i;
  end
endmodule

// ---------------------------------------------------------------------------
// Interface: the monitor samples just before each rising edge; assertions live here
// ---------------------------------------------------------------------------
interface tav_arb_if (input logic clk);
  logic       rst_n;
  logic [3:0] req, gnt;
  clocking mon_cb @(posedge clk);
    default input #1step;
    input rst_n, req, gnt;
  endclocking

  A_ONE_HOT:   assert property (@(posedge clk) disable iff (!rst_n) $onehot0(gnt))
    else `uvm_error("SVA", $sformatf("A_ONE_HOT: gnt=%b", $sampled(gnt)))
  A_GNT_REQ:   assert property (@(posedge clk) disable iff (!rst_n) (gnt & ~req) == 4'b0000)
    else `uvm_error("SVA", $sformatf("A_GNT_REQ: gnt=%b without req=%b", $sampled(gnt), $sampled(req)))
  A_NO_IDLE:   assert property (@(posedge clk) disable iff (!rst_n) (req != 0) |-> (gnt != 0))
    else `uvm_error("SVA", $sformatf("A_NO_IDLE: req=%b but no grant", $sampled(req)))
endinterface

// Coverage: every request pattern against every last winner (16 x 4 = 64 bins)
covergroup tav_arb_cg with function sample(bit [3:0] req, bit [1:0] last);
  option.per_instance = 1;
  cp_req:  coverpoint req  { bins r[] = {[0:15]}; }
  cp_last: coverpoint last { bins l[] = {[0:3]}; }
  x_req_last: cross cp_req, cp_last;
endgroup

// ---------------------------------------------------------------------------
// Transaction: one clock cycle at the arbiter pins
// ---------------------------------------------------------------------------
class tav_arb_item extends uvm_sequence_item;
  rand bit [3:0] req;
  bit            rst;            // 1 = pulse reset instead
  logic [3:0]    gnt;            // filled in by the monitor
  `uvm_object_utils(tav_arb_item)
  function new(string name = "tav_arb_item");
    super.new(name);
  endfunction
endclass

// ---------------------------------------------------------------------------
// Sequences: one per stage
// ---------------------------------------------------------------------------
class tav_arb_base_seq extends uvm_sequence #(tav_arb_item);
  `uvm_object_utils(tav_arb_base_seq)
  function new(string name = "tav_arb_base_seq");
    super.new(name);
  endfunction
  task cyc(bit [3:0] r, int n = 1);
    repeat (n) begin
      req = tav_arb_item::type_id::create("req");
      start_item(req);
      req.req = r;
      finish_item(req);
    end
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

// Stage 1, sanity: does the plumbing work at all?
class tav_sanity_seq extends tav_arb_base_seq;
  `uvm_object_utils(tav_sanity_seq)
  function new(string name = "tav_sanity_seq");
    super.new(name);
  endfunction
  task body();
    cyc(4'b0001); cyc(4'b0000);
    cyc(4'b0010); cyc(4'b0000);
    cyc(4'b0100); cyc(4'b0000);
    cyc(4'b1000); cyc(4'b0000);
  endtask
endclass

// Stage 2, feature: the behaviour the spec names, plus random light traffic
class tav_feature_seq extends tav_arb_base_seq;
  `uvm_object_utils(tav_feature_seq)
  function new(string name = "tav_feature_seq");
    super.new(name);
  endfunction
  task body();
    cyc(4'b1111, 8);                       // full rotation, twice
    cyc(4'b0101, 4); cyc(4'b1010, 4);      // pairs
    cyc(4'b0110, 4); cyc(4'b1001, 4);
    repeat (300) begin
      req = tav_arb_item::type_id::create("req");
      start_item(req);
      if (!req.randomize() with { $countones(req) <= 2; })
        `uvm_fatal("RAND", "randomize failed")
      finish_item(req);
    end
  endtask
endclass

// Stage 3, closure: dense random traffic until every pattern is seen
class tav_closure_seq extends tav_arb_base_seq;
  `uvm_object_utils(tav_closure_seq)
  function new(string name = "tav_closure_seq");
    super.new(name);
  endfunction
  task body();
    repeat (2000) begin
      req = tav_arb_item::type_id::create("req");
      start_item(req);
      if (!req.randomize() with {
            req[0] dist {1 := 70, 0 := 30};
            req[1] dist {1 := 70, 0 := 30};
            req[2] dist {1 := 70, 0 := 30};
            req[3] dist {1 := 70, 0 := 30}; })
        `uvm_fatal("RAND", "randomize failed")
      finish_item(req);
    end
  endtask
endclass

// ---------------------------------------------------------------------------
// Driver: drives on the falling edge, idles when there is no item
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
    vif.rst_n <= 0; vif.req <= 0;
    forever begin
      seq_item_port.try_next_item(req);
      if (req == null) begin
        @(negedge vif.clk);
        vif.req <= 0;
      end else begin
        if (req.rst) begin
          @(negedge vif.clk);
          vif.rst_n <= 0; vif.req <= 0;
          @(negedge vif.clk);
          vif.rst_n <= 1;
        end else begin
          @(negedge vif.clk);
          vif.req <= req.req;
        end
        seq_item_port.item_done();
      end
    end
  endtask
endclass

// ---------------------------------------------------------------------------
// Monitor: one transaction per clock, sampled just before the edge
// ---------------------------------------------------------------------------
class tav_arb_monitor extends uvm_monitor;
  `uvm_component_utils(tav_arb_monitor)
  virtual tav_arb_if vif;
  uvm_analysis_port #(tav_arb_item) ap;
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
      tav_arb_item t;
      @(vif.mon_cb);
      t = tav_arb_item::type_id::create("t");
      t.rst = (vif.mon_cb.rst_n !== 1'b1);
      t.req = vif.mon_cb.req;
      t.gnt = vif.mon_cb.gnt;
      ap.write(t);
    end
  endtask
endclass

// ---------------------------------------------------------------------------
// Scoreboard: reference model from the spec, fairness check, stage report
// ---------------------------------------------------------------------------
class tav_arb_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(tav_arb_scoreboard)
  uvm_analysis_imp #(tav_arb_item, tav_arb_scoreboard) imp;

  bit [1:0]  m_last;
  int        wait_cyc [4];
  int        checks, mismatches, shown, max_wait, unfair, sva_at_start;
  tav_arb_cg cg;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    imp = new("imp", this);
  endfunction

  // Round robin, written from the spec: search from the requester after the last winner
  function bit [3:0] expected(bit [3:0] r, bit [1:0] last);
    for (int k = 1; k <= 4; k++) begin
      int idx;
      idx = (last + k) % 4;
      if (r[idx]) return 4'b0001 << idx;
    end
    return 4'b0000;
  endfunction

  function void start_stage(string name);
    `uvm_info("STAGE", name, UVM_NONE)
    checks = 0; mismatches = 0; shown = 0; max_wait = 0; unfair = 0;
    foreach (wait_cyc[i]) wait_cyc[i] = 0;
    sva_at_start = uvm_report_server::get_server().get_id_count("SVA");
    cg = new();
  endfunction

  function void write(tav_arb_item t);
    bit [3:0] e;
    if (t.rst) begin
      m_last = 2'd3;
      foreach (wait_cyc[i]) wait_cyc[i] = 0;
      return;
    end
    e = expected(t.req, m_last);
    checks++;
    if (cg != null) cg.sample(t.req, m_last);
    if (t.gnt !== e) begin
      mismatches++;
      if (shown < 2) begin
        shown++;
        `uvm_error("MISMATCH", $sformatf("req=%b last=%0d: gnt=%b (exp %b)", t.req, m_last, t.gnt, e))
      end
    end
    // Fairness: how long has each requester waited, using what the design really did
    for (int i = 0; i < 4; i++) begin
      if (t.req[i] && !t.gnt[i]) wait_cyc[i]++;
      else                       wait_cyc[i] = 0;
      if (wait_cyc[i] > max_wait) max_wait = wait_cyc[i];
      if (wait_cyc[i] == 4) unfair++;            // waited longer than the spec allows
    end
    // Follow the spec: the last winner is whoever the spec says should have won
    if (e != 0)
      for (int i = 0; i < 4; i++) if (e[i]) m_last = i;
  endfunction

  function void end_stage(string name);
    int  sva;
    real cov;
    sva = uvm_report_server::get_server().get_id_count("SVA") - sva_at_start;
    cov = cg.x_req_last.get_inst_coverage();
    `uvm_info("RESULT", $sformatf("%s: checks=%0d mismatches=%0d assertion_fails=%0d max_wait=%0d (limit 3) fairness_violations=%0d pattern_coverage=%.2f%% -> %s",
              name, checks, mismatches, sva, max_wait, unfair, cov,
              (mismatches == 0 && sva == 0 && unfair == 0) ? "PASS" : "FAIL"), UVM_NONE)
  endfunction
endclass

// ---------------------------------------------------------------------------
// Agent and environment
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

// ---------------------------------------------------------------------------
// Test: reset, run one stage, report, three times
// ---------------------------------------------------------------------------
class tav_ip_stages_test extends uvm_test;
  `uvm_component_utils(tav_ip_stages_test)
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
    env.scb.start_stage(name);
    r.start(env.agt.sqr);
    s.start(env.agt.sqr);
    repeat (2) @(vif.mon_cb);      // let the monitor see the last cycle
    #1;
    env.scb.end_stage(name);
  endtask

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    run_one("Stage 1, sanity",  tav_sanity_seq::type_id::create("s1"));
    run_one("Stage 2, feature", tav_feature_seq::type_id::create("s2"));
    run_one("Stage 3, closure", tav_closure_seq::type_id::create("s3"));
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
  tav_rr_arbiter dut (.clk(clk), .rst_n(vif.rst_n), .req(vif.req), .gnt(vif.gnt), .bug(BUG));

  initial begin
    void'($value$plusargs("BUG=%d", BUG));
    `uvm_info("TOP", $sformatf("Running with BUG=%0d", BUG), UVM_NONE)
    uvm_config_db#(virtual tav_arb_if)::set(null, "uvm_test_top", "vif", vif);
    uvm_config_db#(virtual tav_arb_if)::set(null, "uvm_test_top.env.agt.*", "vif", vif);
    run_test("tav_ip_stages_test");
  end
endmodule
