// tav_plan_counter_uvm.sv : a verification plan built into the bench, on an 8-bit counter (UVM 1.2)
// Run on Synopsys VCS X-2025.06-SP1 with UVM 1.2 (EDA Playground), 24 Nov 2026.
// The Art of Verification | theartofverification.com
//
// EDA Playground: Synopsys VCS, UVM 1.2, top module "tav_top".
// Paste this whole file into testbench.sv and leave design.sv empty.
//
// One run does two things:
//   Phase A: a "first test" written without a plan (random enable only, 300 cycles)
//   Phase B: tests written from the plan (directed corners + 2000 constrained-random cycles)
// After each phase the scoreboard prints the plan status: every feature (F1 to F8), its
// priority (High, Med, Low), checks, failures and MET, HOLE or FAIL, then the sign-off verdict.
// Checks come from two places, as the plan says: a scoreboard (reference model) and
// three assertions (SVA) in the interface.
//
// Run options (one per run):
//   (none)    the clean design
//   +BUG=1    load is ignored when enable is high at the same time
//   +BUG=2    ovf fires one count early (at 254 -> 255 instead of 255 -> 0)
//   +BUG=3    load beats clear when both are high
//
// Spec:
//   8-bit counter, synchronous controls, priority clr > ld > en.
//   clr: count goes to 0.            ld: count takes ld_val.
//   en:  count goes up by 1; from 255 it wraps to 0 and ovf is 1 for exactly that one cycle.
//   No control: count holds. ovf is 0 in every cycle except the wrap.
//   rst_n (async, active low): count = 0, ovf = 0.

`timescale 1ns/1ns
`include "uvm_macros.svh"
import uvm_pkg::*;

// ---------------------------------------------------------------------------
// The design
// ---------------------------------------------------------------------------
module tav_counter8 (input  logic       clk, rst_n,
                     input  logic       en, ld, clr,
                     input  logic [7:0] ld_val,
                     output logic [7:0] cnt,
                     output logic       ovf,
                     input  int         bug);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cnt <= 0; ovf <= 0;
    end else begin
      ovf <= 0;
      if (clr && !(bug == 3 && ld))                   // BUG=3
        cnt <= 0;
      else if (ld && !(bug == 1 && en))               // BUG=1
        cnt <= ld_val;
      else if (en) begin
        if (cnt == 8'd255) begin
          cnt <= 0;
          ovf <= (bug != 2);                          // BUG=2
        end else begin
          cnt <= cnt + 1;
          if (bug == 2 && cnt == 8'd254) ovf <= 1;    // BUG=2
        end
      end
    end
  end
endmodule

// ---------------------------------------------------------------------------
// Interface: the monitor samples just before each rising edge
// ---------------------------------------------------------------------------
interface tav_counter_if (input logic clk);
  logic       rst_n, en, ld, clr;
  logic [7:0] ld_val, cnt;
  logic       ovf;
  clocking mon_cb @(posedge clk);
    default input #1step;
    input rst_n, en, ld, clr, ld_val, cnt, ovf;
  endclocking

  // Assertions plan: rules that must hold in every cycle, checked where the signals live
  A_OVF_ONE_CYCLE: assert property (@(posedge clk) disable iff (!rst_n) ovf |=> !ovf)
    else `uvm_error("SVA", "A_OVF_ONE_CYCLE: ovf was high for more than one cycle")
  A_OVF_AT_ZERO:   assert property (@(posedge clk) disable iff (!rst_n) ovf |-> cnt == 8'd0)
    else `uvm_error("SVA", $sformatf("A_OVF_AT_ZERO: ovf is high but cnt=%0d", $sampled(cnt)))
  A_NO_X:          assert property (@(posedge clk) disable iff (!rst_n) !$isunknown({cnt, ovf}))
    else `uvm_error("SVA", "A_NO_X: cnt or ovf is X after reset")
endinterface

// ---------------------------------------------------------------------------
// The verification plan's feature list, as data: one entry per feature
// ---------------------------------------------------------------------------
typedef enum int {F_NONE, F1_RESET, F2_COUNT, F3_HOLD, F4_LOAD, F5_LOAD_EN,
                  F6_WRAP, F7_CLEAR, F8_CLEAR_LD} tav_feature_e;

// Coverage plan: which features were exercised, and which load values
covergroup tav_plan_cg with function sample(int op, bit [7:0] v, bit is_load);
  option.per_instance = 1;
  cp_op: coverpoint op {
    bins reset    = {F1_RESET};
    bins count    = {F2_COUNT};
    bins hold     = {F3_HOLD};
    bins load     = {F4_LOAD};
    bins load_en  = {F5_LOAD_EN};
    bins wrap     = {F6_WRAP};
    bins clear    = {F7_CLEAR};
    bins clear_ld = {F8_CLEAR_LD};
  }
  cp_ld_val: coverpoint v iff (is_load) {
    bins zero     = {0};
    bins mid      = {[1:253]};
    bins near_max = {254};
    bins max      = {255};
  }
endgroup

// ---------------------------------------------------------------------------
// Transaction: one clock cycle at the counter pins
// ---------------------------------------------------------------------------
class tav_counter_item extends uvm_sequence_item;
  rand bit       en, ld, clr;
  rand bit [7:0] ld_val;
  bit            rst;            // 1 = pulse reset instead
  // filled in by the monitor
  logic [7:0]    cnt;
  logic          ovf;
  `uvm_object_utils(tav_counter_item)
  function new(string name = "tav_counter_item");
    super.new(name);
  endfunction
endclass

// ---------------------------------------------------------------------------
// Sequences
// ---------------------------------------------------------------------------
class tav_counter_base_seq extends uvm_sequence #(tav_counter_item);
  `uvm_object_utils(tav_counter_base_seq)
  function new(string name = "tav_counter_base_seq");
    super.new(name);
  endfunction
  task cyc(bit en, bit ld, bit clr, bit [7:0] v = 0);
    req = tav_counter_item::type_id::create("req");
    start_item(req);
    req.en = en; req.ld = ld; req.clr = clr; req.ld_val = v;
    finish_item(req);
  endtask
endclass

class tav_reset_seq extends tav_counter_base_seq;
  `uvm_object_utils(tav_reset_seq)
  function new(string name = "tav_reset_seq");
    super.new(name);
  endfunction
  task body();
    req = tav_counter_item::type_id::create("req");
    start_item(req);
    req.rst = 1;
    finish_item(req);
  endtask
endclass

// Phase A: what a first test often looks like. Random enable, nothing else.
class tav_no_plan_seq extends tav_counter_base_seq;
  `uvm_object_utils(tav_no_plan_seq)
  function new(string name = "tav_no_plan_seq");
    super.new(name);
  endfunction
  task body();
    repeat (300) begin
      req = tav_counter_item::type_id::create("req");
      start_item(req);
      if (!req.randomize() with { ld == 0; clr == 0; })
        `uvm_fatal("RAND", "randomize failed")
      finish_item(req);
    end
  endtask
endclass

// Phase B: the test plan's tests. Directed corners first, then weighted random.
class tav_plan_seq extends tav_counter_base_seq;
  `uvm_object_utils(tav_plan_seq)
  function new(string name = "tav_plan_seq");
    super.new(name);
  endfunction
  task body();
    // F4: load the corner values
    cyc(0, 1, 0, 8'd0);   cyc(0, 1, 0, 8'd254);  cyc(0, 1, 0, 8'd255);
    // F6: load 250, then count through the wrap
    cyc(0, 1, 0, 8'd250);
    repeat (8) cyc(1, 0, 0);
    // F5: load and enable together, also at the top value
    cyc(1, 1, 0, 8'd100); cyc(1, 1, 0, 8'd255);  cyc(1, 0, 0);
    // F7 and F8: clear alone, and clear together with load
    cyc(1, 0, 0);         cyc(0, 0, 1);
    cyc(0, 1, 1, 8'd77);  cyc(1, 1, 1, 8'd200);
    // F3: hold
    repeat (3) cyc(0, 0, 0);
    // Weighted random for the mixes nobody listed
    repeat (2000) begin
      req = tav_counter_item::type_id::create("req");
      start_item(req);
      if (!req.randomize() with {
            clr dist {1 := 3,  0 := 97};
            ld  dist {1 := 10, 0 := 90};
            en  dist {1 := 80, 0 := 20};
            ld_val dist {255 := 10, 254 := 10, 0 := 10, [1:253] := 70}; })
        `uvm_fatal("RAND", "randomize failed")
      finish_item(req);
    end
  endtask
endclass

// ---------------------------------------------------------------------------
// Driver: drives on the falling edge, idles when there is no item
// ---------------------------------------------------------------------------
class tav_counter_driver extends uvm_driver #(tav_counter_item);
  `uvm_component_utils(tav_counter_driver)
  virtual tav_counter_if vif;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(virtual tav_counter_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "no virtual interface")
  endfunction
  task run_phase(uvm_phase phase);
    vif.rst_n <= 0; vif.en <= 0; vif.ld <= 0; vif.clr <= 0; vif.ld_val <= 0;
    forever begin
      seq_item_port.try_next_item(req);
      if (req == null) begin
        @(negedge vif.clk);
        vif.en <= 0; vif.ld <= 0; vif.clr <= 0;
      end else begin
        if (req.rst) begin
          @(negedge vif.clk);
          vif.rst_n <= 0; vif.en <= 0; vif.ld <= 0; vif.clr <= 0;
          @(negedge vif.clk);
          vif.rst_n <= 1;
        end else begin
          @(negedge vif.clk);
          vif.en <= req.en; vif.ld <= req.ld; vif.clr <= req.clr; vif.ld_val <= req.ld_val;
        end
        seq_item_port.item_done();
      end
    end
  endtask
endclass

// ---------------------------------------------------------------------------
// Monitor: one transaction per clock, sampled just before the edge
// ---------------------------------------------------------------------------
class tav_counter_monitor extends uvm_monitor;
  `uvm_component_utils(tav_counter_monitor)
  virtual tav_counter_if vif;
  uvm_analysis_port #(tav_counter_item) ap;
  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction
  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(virtual tav_counter_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "no virtual interface")
  endfunction
  task run_phase(uvm_phase phase);
    forever begin
      tav_counter_item t;
      @(vif.mon_cb);
      t = tav_counter_item::type_id::create("t");
      t.rst    = (vif.mon_cb.rst_n !== 1'b1);
      t.en     = vif.mon_cb.en;
      t.ld     = vif.mon_cb.ld;
      t.clr    = vif.mon_cb.clr;
      t.ld_val = vif.mon_cb.ld_val;
      t.cnt    = vif.mon_cb.cnt;
      t.ovf    = vif.mon_cb.ovf;
      ap.write(t);
    end
  endtask
endclass

// ---------------------------------------------------------------------------
// Scoreboard: checkers plan (reference model from the spec), plan status and sign-off
// ---------------------------------------------------------------------------
class tav_counter_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(tav_counter_scoreboard)
  uvm_analysis_imp #(tav_counter_item, tav_counter_scoreboard) imp;

  string        item_name [tav_feature_e];
  string        prio      [tav_feature_e];
  int           goal      [tav_feature_e];
  int           checks    [tav_feature_e];
  int           fails     [tav_feature_e];
  bit [7:0]     m_cnt;
  bit           m_ovf;
  tav_feature_e prev;
  int           shown, total_fails, sva_at_start;
  tav_plan_cg   cg;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    imp = new("imp", this);
    item_name[F1_RESET]    = "F1 reset clears count and ovf"; prio[F1_RESET]    = "High"; goal[F1_RESET]    = 1;
    item_name[F2_COUNT]    = "F2 enable counts up by 1";      prio[F2_COUNT]    = "Med"; goal[F2_COUNT]    = 20;
    item_name[F3_HOLD]     = "F3 no control: count holds";    prio[F3_HOLD]     = "Low"; goal[F3_HOLD]     = 10;
    item_name[F4_LOAD]     = "F4 load takes ld_val";          prio[F4_LOAD]     = "High"; goal[F4_LOAD]     = 5;
    item_name[F5_LOAD_EN]  = "F5 load beats enable";          prio[F5_LOAD_EN]  = "High"; goal[F5_LOAD_EN]  = 5;
    item_name[F6_WRAP]     = "F6 wrap 255->0, ovf one cycle"; prio[F6_WRAP]     = "High"; goal[F6_WRAP]     = 2;
    item_name[F7_CLEAR]    = "F7 clear sets count to 0";      prio[F7_CLEAR]    = "Med"; goal[F7_CLEAR]    = 3;
    item_name[F8_CLEAR_LD] = "F8 clear beats load";           prio[F8_CLEAR_LD] = "High"; goal[F8_CLEAR_LD] = 2;
  endfunction

  function void start_phase(string name);
    `uvm_info("PHASE", name, UVM_NONE)
    foreach (item_name[i]) begin checks[i] = 0; fails[i] = 0; end
    prev = F_NONE; shown = 0;
    sva_at_start = uvm_report_server::get_server().get_id_count("SVA");
    cg = new();
  endfunction

  function void write(tav_counter_item t);
    tav_feature_e op;
    if (t.rst) begin
      m_cnt = 0; m_ovf = 0; prev = F1_RESET;
      if (cg != null) cg.sample(F1_RESET, 0, 0);
      return;
    end
    // 1. Check the outputs: they show the result of the previous cycle's operation
    if (prev != F_NONE) begin
      checks[prev]++;
      if (t.cnt !== m_cnt || t.ovf !== m_ovf) begin
        fails[prev]++;
        if (shown < 2) begin
          shown++;
          `uvm_error("MISMATCH", $sformatf("after %s: cnt=%0d(exp %0d) ovf=%b(exp %b)",
                     item_name[prev], t.cnt, m_cnt, t.ovf, m_ovf))
        end
        m_cnt = t.cnt; m_ovf = t.ovf;   // resync, so the next check is judged on its own
      end
    end
    // 2. Predict this cycle's result from the spec: clr > ld > en
    m_ovf = 0;
    if (t.clr) begin
      op = t.ld ? F8_CLEAR_LD : F7_CLEAR;
      m_cnt = 0;
    end else if (t.ld) begin
      op = t.en ? F5_LOAD_EN : F4_LOAD;
      m_cnt = t.ld_val;
    end else if (t.en) begin
      if (m_cnt == 8'd255) begin
        op = F6_WRAP; m_cnt = 0; m_ovf = 1;
      end else begin
        op = F2_COUNT; m_cnt = m_cnt + 1;
      end
    end else begin
      op = F3_HOLD;
    end
    cg.sample(op, t.ld_val, t.ld && !t.clr);
    prev = op;
  endfunction

  function void end_phase(string name);
    int met, holes, failed, f, sva, hm_open;
    real cov;
    foreach (item_name[i]) begin
      string status;
      if (fails[i] > 0)              begin status = "FAIL"; failed++; end
      else if (checks[i] < goal[i])  begin status = "HOLE"; holes++;  end
      else                           begin status = "MET";  met++;    end
      if (status != "MET" && prio[i] != "Low") hm_open++;
      f += fails[i];
      `uvm_info("PLAN", $sformatf("%-30s %-4s checks=%5d goal=%3d fails=%4d  %s",
                item_name[i], prio[i], checks[i], goal[i], fails[i], status), UVM_NONE)
    end
    total_fails += f;
    sva = uvm_report_server::get_server().get_id_count("SVA") - sva_at_start;
    cov = cg.get_inst_coverage();
    `uvm_info("VERDICT", $sformatf("%s: %0d MET, %0d HOLE, %0d FAIL, assertion fails=%0d, coverage=%.2f%%",
              name, met, holes, failed, sva, cov), UVM_NONE)
    `uvm_info("SIGNOFF", $sformatf("%s: high/medium open=%0d, assertion fails=%0d, coverage=%.2f%% -> %s",
              name, hm_open, sva, cov,
              (hm_open == 0 && sva == 0 && cov >= 100.0) ? "SIGN-OFF MET" : "NOT READY"), UVM_NONE)
    // Execution phases from the plan: P1 sanity clean, P2 coverage >= 80%, P3 closure
    // (P3 also needs a waveform review of the critical scenarios, which is done by eye, not here)
    `uvm_info("PHASES", $sformatf("%s: P1 sanity clean=%s, P2 coverage>=80%%=%s, P3 closure=%s",
              name, (f == 0 && sva == 0) ? "yes" : "no", (cov >= 80.0) ? "yes" : "no",
              (hm_open == 0 && sva == 0 && cov >= 100.0) ? "yes" : "no"), UVM_NONE)
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("SUMMARY", $sformatf("total_fails=%0d assertion_fails=%0d", total_fails,
              uvm_report_server::get_server().get_id_count("SVA")), UVM_NONE)
  endfunction
endclass

// ---------------------------------------------------------------------------
// Agent and environment
// ---------------------------------------------------------------------------
class tav_counter_agent extends uvm_agent;
  `uvm_component_utils(tav_counter_agent)
  uvm_sequencer #(tav_counter_item) sqr;
  tav_counter_driver  drv;
  tav_counter_monitor mon;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    sqr = uvm_sequencer#(tav_counter_item)::type_id::create("sqr", this);
    drv = tav_counter_driver::type_id::create("drv", this);
    mon = tav_counter_monitor::type_id::create("mon", this);
  endfunction
  function void connect_phase(uvm_phase phase);
    drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction
endclass

class tav_counter_env extends uvm_env;
  `uvm_component_utils(tav_counter_env)
  tav_counter_agent      agt;
  tav_counter_scoreboard scb;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    agt = tav_counter_agent::type_id::create("agt", this);
    scb = tav_counter_scoreboard::type_id::create("scb", this);
  endfunction
  function void connect_phase(uvm_phase phase);
    agt.mon.ap.connect(scb.imp);
  endfunction
endclass

// ---------------------------------------------------------------------------
// Test: phase A without a plan, phase B from the plan
// ---------------------------------------------------------------------------
class tav_plan_test extends uvm_test;
  `uvm_component_utils(tav_plan_test)
  tav_counter_env env;
  virtual tav_counter_if vif;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    env = tav_counter_env::type_id::create("env", this);
    if (!uvm_config_db#(virtual tav_counter_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "no virtual interface")
  endfunction

  task run_one(string name, tav_counter_base_seq s);
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
    run_one("Phase A, no plan",   tav_no_plan_seq::type_id::create("a"));
    run_one("Phase B, from plan", tav_plan_seq::type_id::create("b"));
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

  tav_counter_if vif (clk);
  tav_counter8 dut (.clk(clk), .rst_n(vif.rst_n), .en(vif.en), .ld(vif.ld), .clr(vif.clr),
                    .ld_val(vif.ld_val), .cnt(vif.cnt), .ovf(vif.ovf), .bug(BUG));

  initial begin
    void'($value$plusargs("BUG=%d", BUG));
    `uvm_info("TOP", $sformatf("Running with BUG=%0d", BUG), UVM_NONE)
    uvm_config_db#(virtual tav_counter_if)::set(null, "uvm_test_top", "vif", vif);
    uvm_config_db#(virtual tav_counter_if)::set(null, "uvm_test_top.env.agt.*", "vif", vif);
    run_test("tav_plan_test");
  end
endmodule
