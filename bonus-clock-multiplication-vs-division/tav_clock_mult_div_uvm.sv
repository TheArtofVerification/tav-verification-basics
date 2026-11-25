// tav_clock_mult_div_uvm.sv : checking a divided clock and a multiplied clock in one UVM bench (UVM 1.2)
// Run on Synopsys VCS X-2025.06-SP1 with UVM 1.2 (EDA Playground), 25 Nov 2026.
// The Art of Verification | theartofverification.com
//
// EDA Playground: Synopsys VCS, UVM 1.2, top module "tav_top".
// Paste this whole file into testbench.sv and leave design.sv empty.
//
// Two clock sources run from the same 100 MHz reference (10 ns period):
//   DIV  an RTL divider: div_out = ref / N, N from 2 to 15
//   PLL  a behavioural PLL model: pll_out = ref x M, M from 1 to 8, with a lock signal
// The bench checks them in two different ways, and that difference is the lesson:
//   DIV  every edge lands on a reference edge, so each period must be exactly N x 10 ns.
//   PLL  edges land between reference edges, so each period is measured in time, checked
//        against 10 ns / M with a small tolerance, and only once the PLL says it is locked.
//
// Run options (one per run):
//   (none)    the clean design
//   +BUG=1    DIV: counts one reference cycle too many, so it divides by N + 1
//   +BUG=2    DIV: a new ratio takes effect at once instead of at the end of the current period
//   +BUG=3    PLL: the lock detector fires 3 reference cycles before the output has settled
//
// Spec:
//   DIV  A period starts on a rising edge of div_out. The ratio N is read at that edge and
//        holds for the whole period. div_out is high for (N + 1) / 2 reference cycles
//        (integer divide) and low for the rest. Ratios below 2 count as 2. The first period
//        starts on the first reference edge after reset.
//   PLL  After reset, or after pll_m changes, pll_locked goes low on the next reference edge
//        and comes back high within 16 reference cycles. While pll_locked is high, every
//        period of pll_out is 10 ns / M and the duty cycle is 50%, both within 2 ps.
//        M = 0 counts as 1.
//
// Phase 1 holds N = 4 and M = 4 for 300 reference cycles. Phase 2 changes the settings
// 80 times at random. The scoreboard prints mismatches for each phase.

`timescale 1ns/1ps
`include "uvm_macros.svh"
import uvm_pkg::*;

// ---------------------------------------------------------------------------
// The designs
// ---------------------------------------------------------------------------
module tav_clk_div (input logic ref_clk, rst_n, input logic [3:0] div_n,
                    output logic div_out, input int bug);
  logic [3:0] cnt, cur_n;
  int nn, use_n;
  always_comb begin
    nn    = (div_n < 2) ? 2 : div_n;
    use_n = (bug == 2) ? nn : cur_n;                  // BUG=2: the new ratio is used at once
  end
  always_ff @(posedge ref_clk or negedge rst_n)
    if (!rst_n) begin cnt <= 15; cur_n <= 2; div_out <= 0; end   // so the first edge starts a period
    else if (cnt >= use_n - 1 + ((bug == 1) ? 1 : 0)) begin   // BUG=1: one extra cycle per period
      cnt <= 0; cur_n <= nn; div_out <= 1;           // a new period starts and reads the ratio
    end else begin
      cnt     <= cnt + 1;
      div_out <= (cnt + 1) < ((use_n + 1) / 2);
    end
endmodule

// A PLL is analog. In a testbench it is a behavioural model like this one: it measures the
// reference period, runs an oscillator at ref / M, starts about 25% slow after a change and
// settles over 8 reference cycles, then raises pll_locked.
module tav_pll_model #(parameter int SETTLE = 8)
                     (input logic ref_clk, rst_n, input logic [3:0] pll_m,
                      output logic pll_out, pll_locked, input int bug);
  int      cur_m, mm, settle;
  realtime last_t = -1, tref = 10.0, half = 5.0;

  initial pll_out = 0;
  always #(half) pll_out = ~pll_out;                 // the oscillator

  always @(posedge ref_clk or negedge rst_n)
    if (!rst_n) begin
      cur_m = 1; settle = SETTLE; pll_locked <= 0;
    end else begin
      if (last_t >= 0) tref = $realtime - last_t;    // measure the reference
      last_t = $realtime;
      mm = (pll_m == 0) ? 1 : pll_m;
      if (mm != cur_m) begin cur_m = mm; settle = SETTLE; end
      else if (settle > 0) settle--;
      pll_locked <= (bug == 3) ? (settle <= 3) : (settle == 0);   // BUG=3: lock fires 3 cycles early
      half = tref / (2.0 * cur_m) * (1.0 + settle / 32.0);
    end
endmodule

// ---------------------------------------------------------------------------
// Interface: the pins, plus the lock handshake rules as assertions
// ---------------------------------------------------------------------------
interface tav_clk_if (input logic ref_clk);
  logic       rst_n;
  logic [3:0] div_n, pll_m;
  logic       div_out, pll_out, pll_locked;

  // Each assertion reports its first 3 fails and then switches itself off.
  int tav_fails [2];   // A_LOCK_DROP, A_LOCK_TIME

  A_LOCK_DROP: assert property (@(posedge ref_clk) disable iff (!rst_n)
                 $changed(pll_m) |=> !pll_locked)
    else begin
      tav_fails[0]++; `uvm_error("SVA", "A_LOCK_DROP: pll_m changed but pll_locked stayed high")
      if (tav_fails[0] == 3) $assertoff(0, A_LOCK_DROP);
    end
  A_LOCK_TIME: assert property (@(posedge ref_clk) disable iff (!rst_n)
                 ($rose(rst_n) || $changed(pll_m)) |-> ##[1:16] (pll_locked || $changed(pll_m)))
    else begin
      tav_fails[1]++; `uvm_error("SVA", "A_LOCK_TIME: no lock within 16 reference cycles")
      if (tav_fails[1] == 3) $assertoff(0, A_LOCK_TIME);
    end
endinterface

// The test sets this so every measurement knows which phase it came from.
int tav_phase = 0;

// ---------------------------------------------------------------------------
// Stimulus item: one setting of both clocks, held for some reference cycles
// ---------------------------------------------------------------------------
class tav_clk_item extends uvm_sequence_item;
  rand bit [3:0] div_n;
  rand bit [3:0] pll_m;
  rand bit       chg_pll;
  rand int       hold;
  constraint c_range { div_n inside {[2:15]}; pll_m inside {[1:8]}; hold inside {[3:40]};
                       chg_pll dist {1 := 3, 0 := 7}; }
  `uvm_object_utils(tav_clk_item)
  function new(string name = "tav_clk_item");
    super.new(name);
  endfunction
endclass

// ---------------------------------------------------------------------------
// Measurement: one full period of one clock
// ---------------------------------------------------------------------------
class tav_clk_meas extends uvm_object;
  bit      is_pll;     // 0 = DIV, 1 = PLL
  realtime t_end, period, high;
  int      ratio;      // N for DIV, M for PLL
  int      phase;
  `uvm_object_utils(tav_clk_meas)
  function new(string name = "tav_clk_meas");
    super.new(name);
  endfunction
endclass

// ---------------------------------------------------------------------------
// Sequences
// ---------------------------------------------------------------------------
class tav_hold_seq extends uvm_sequence #(tav_clk_item);
  `uvm_object_utils(tav_hold_seq)
  function new(string name = "tav_hold_seq");
    super.new(name);
  endfunction
  task body();
    req = tav_clk_item::type_id::create("req");
    start_item(req);
    req.div_n = 4; req.pll_m = 4; req.hold = 300;
    finish_item(req);
  endtask
endclass

class tav_random_seq extends uvm_sequence #(tav_clk_item);
  `uvm_object_utils(tav_random_seq)
  int n_items = 80;
  function new(string name = "tav_random_seq");
    super.new(name);
  endfunction
  task body();
    bit [3:0] prev_m = 4;
    repeat (n_items) begin
      req = tav_clk_item::type_id::create("req");
      start_item(req);
      if (!req.randomize() with { chg_pll -> pll_m != local::prev_m;
                                  !chg_pll -> pll_m == local::prev_m; })
        `uvm_fatal("RAND", "randomize failed")
      prev_m = req.pll_m;
      finish_item(req);
    end
  endtask
endclass

// ---------------------------------------------------------------------------
// Driver: holds reset for 5 cycles, then changes settings on the falling reference edge
// ---------------------------------------------------------------------------
class tav_clk_driver extends uvm_driver #(tav_clk_item);
  `uvm_component_utils(tav_clk_driver)
  virtual tav_clk_if vif;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(virtual tav_clk_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "no virtual interface")
  endfunction
  task run_phase(uvm_phase phase);
    vif.rst_n <= 0; vif.div_n <= 4; vif.pll_m <= 4;
    repeat (5) @(negedge vif.ref_clk);
    vif.rst_n <= 1;
    forever begin
      seq_item_port.get_next_item(req);
      @(negedge vif.ref_clk);
      vif.div_n <= req.div_n; vif.pll_m <= req.pll_m;
      repeat (req.hold - 1) @(negedge vif.ref_clk);
      seq_item_port.item_done();
    end
  endtask
endclass

// ---------------------------------------------------------------------------
// Monitor: turns edges into period measurements
// ---------------------------------------------------------------------------
class tav_clk_monitor extends uvm_monitor;
  `uvm_component_utils(tav_clk_monitor)
  virtual tav_clk_if vif;
  uvm_analysis_port #(tav_clk_meas) ap;
  // reach counts
  int div_ratio_changed_inside, pll_skipped_unlocked, lock_events;
  int lock_m;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction
  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(virtual tav_clk_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "no virtual interface")
  endfunction

  function void send(bit is_pll, realtime t_end, period, high, int ratio);
    tav_clk_meas m = tav_clk_meas::type_id::create("m");
    m.is_pll = is_pll; m.t_end = t_end; m.period = period; m.high = high;
    m.ratio = ratio; m.phase = tav_phase;
    ap.write(m);
  endfunction

  // DIV: the ratio for a period is the one on div_n at the rising edge that starts it
  task watch_div();
    realtime prev_rise = -1, fall_t = -1;
    int prev_n, n_now;
    forever begin
      @(vif.div_out or negedge vif.rst_n);
      if (vif.rst_n !== 1'b1) begin prev_rise = -1; fall_t = -1; end
      else if (vif.div_out === 1'b1) begin
        n_now = (vif.div_n < 2) ? 2 : vif.div_n;
        if (prev_rise >= 0 && fall_t > prev_rise) begin
          send(0, $realtime, $realtime - prev_rise, fall_t - prev_rise, prev_n);
          if (n_now != prev_n) div_ratio_changed_inside++;
        end
        prev_rise = $realtime; prev_n = n_now;
      end else fall_t = $realtime;
    end
  endtask

  // PLL: check a period only if pll_locked was high at the rising edge before it, at its
  // own start and at its end. That keeps out every period the oscillator was still settling in.
  task watch_pll();
    realtime r0 = -1, r1 = -1, fall_t = -1;
    bit l0, l1, l2;
    fork
      forever begin @(negedge vif.pll_out); fall_t = $realtime; end
      forever begin @(posedge vif.pll_locked); lock_m = (vif.pll_m == 0) ? 1 : vif.pll_m; lock_events++; end
    join_none
    forever begin
      @(posedge vif.pll_out);
      l2 = (vif.pll_locked === 1'b1);
      if (r0 >= 0) begin
        if (l0 && l1 && l2 && fall_t > r1) send(1, $realtime, $realtime - r1, fall_t - r1, lock_m);
        else pll_skipped_unlocked++;
      end
      r0 = r1; l0 = l1; r1 = $realtime; l1 = l2;
    end
  endtask

  task run_phase(uvm_phase phase);
    fork
      watch_div();
      watch_pll();
    join
  endtask
endclass

// ---------------------------------------------------------------------------
// Scoreboard: the expected period and high time, from the spec
// ---------------------------------------------------------------------------
class tav_clk_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(tav_clk_scoreboard)
  uvm_analysis_imp #(tav_clk_meas, tav_clk_scoreboard) imp;
  realtime TREF = 10.0;    // the reference period in the spec
  realtime TOL  = 0.002;   // 2 ps
  int checks[2], mism[2], shown[2];
  int mism_ph[2][3];       // [DIV/PLL][phase]
  realtime worst_pll_err;  // largest |error| on a passing PLL period
  bit div_seen[16], pll_seen[9];

  function new(string name, uvm_component parent);
    super.new(name, parent);
    imp = new("imp", this);
  endfunction

  function realtime tav_abs(realtime x);
    return (x < 0) ? -x : x;
  endfunction

  function void write(tav_clk_meas m);
    realtime exp_p, exp_h, tol;
    string nm = m.is_pll ? "PLL" : "DIV";
    if (m.is_pll) begin
      exp_p = TREF / m.ratio; exp_h = exp_p / 2.0; tol = TOL;
      pll_seen[m.ratio] = 1;
    end else begin
      exp_p = TREF * m.ratio; exp_h = TREF * ((m.ratio + 1) / 2); tol = 0.0005;   // exact
      div_seen[m.ratio] = 1;
    end
    checks[m.is_pll]++;
    if (tav_abs(m.period - exp_p) > tol || tav_abs(m.high - exp_h) > tol) begin
      mism[m.is_pll]++; mism_ph[m.is_pll][m.phase]++;
      if (shown[m.is_pll] < 3) begin
        shown[m.is_pll]++;
        `uvm_error("MISMATCH", $sformatf("%s period ending %0.3f ns, ratio %0d: period %0.3f ns, high %0.3f ns; expected %0.3f and %0.3f",
                   nm, m.t_end, m.ratio, m.period, m.high, exp_p, exp_h))
      end
    end else if (m.is_pll) begin
      if (tav_abs(m.period - exp_p) > worst_pll_err) worst_pll_err = tav_abs(m.period - exp_p);
    end
  endfunction

  function void tav_print_results(tav_clk_monitor mon, int f0, f1);
    int nd = 0, np = 0;
    foreach (div_seen[i]) nd += div_seen[i];
    foreach (pll_seen[i]) np += pll_seen[i];
    `uvm_info("RESULT", $sformatf("DIV periods checked=%0d mismatches=%0d (phase 1: %0d, phase 2: %0d) -> %s",
              checks[0], mism[0], mism_ph[0][1], mism_ph[0][2], (mism[0] == 0) ? "PASS" : "FAIL"), UVM_NONE)
    `uvm_info("RESULT", $sformatf("PLL periods checked=%0d mismatches=%0d (phase 1: %0d, phase 2: %0d) -> %s",
              checks[1], mism[1], mism_ph[1][1], mism_ph[1][2], (mism[1] == 0) ? "PASS" : "FAIL"), UVM_NONE)
    `uvm_info("RESULT", $sformatf("Lock assertions: A_LOCK_DROP fails=%0d, A_LOCK_TIME fails=%0d -> %s",
              f0, f1, (f0 + f1 == 0) ? "PASS" : "FAIL"), UVM_NONE)
    `uvm_info("REACH", $sformatf("DIV ratios seen=%0d of 14, periods with a ratio change inside=%0d",
              nd, mon.div_ratio_changed_inside), UVM_NONE)
    `uvm_info("REACH", $sformatf("PLL ratios seen=%0d of 8, lock events=%0d, periods skipped while unlocked=%0d, worst passing error=%0.1f ps",
              np, mon.lock_events, mon.pll_skipped_unlocked, worst_pll_err * 1000.0), UVM_NONE)
  endfunction
endclass

// ---------------------------------------------------------------------------
// Agent, environment, test
// ---------------------------------------------------------------------------
class tav_clk_agent extends uvm_agent;
  `uvm_component_utils(tav_clk_agent)
  uvm_sequencer #(tav_clk_item) sqr;
  tav_clk_driver  drv;
  tav_clk_monitor mon;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    sqr = uvm_sequencer#(tav_clk_item)::type_id::create("sqr", this);
    drv = tav_clk_driver::type_id::create("drv", this);
    mon = tav_clk_monitor::type_id::create("mon", this);
  endfunction
  function void connect_phase(uvm_phase phase);
    drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction
endclass

class tav_clk_env extends uvm_env;
  `uvm_component_utils(tav_clk_env)
  tav_clk_agent      agt;
  tav_clk_scoreboard scb;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    agt = tav_clk_agent::type_id::create("agt", this);
    scb = tav_clk_scoreboard::type_id::create("scb", this);
  endfunction
  function void connect_phase(uvm_phase phase);
    agt.mon.ap.connect(scb.imp);
  endfunction
endclass

class tav_clock_test extends uvm_test;
  `uvm_component_utils(tav_clock_test)
  tav_clk_env env;
  virtual tav_clk_if vif;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    env = tav_clk_env::type_id::create("env", this);
    if (!uvm_config_db#(virtual tav_clk_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "no virtual interface")
  endfunction
  task run_phase(uvm_phase phase);
    tav_hold_seq   h = tav_hold_seq::type_id::create("h");
    tav_random_seq s = tav_random_seq::type_id::create("s");
    phase.raise_objection(this);
    tav_phase = 1;
    h.start(env.agt.sqr);
    tav_phase = 2;
    s.start(env.agt.sqr);
    repeat (40) @(negedge vif.ref_clk);   // let the last periods finish
    env.scb.tav_print_results(env.agt.mon, vif.tav_fails[0], vif.tav_fails[1]);
    phase.drop_objection(this);
  endtask
endclass

// ---------------------------------------------------------------------------
// Top
// ---------------------------------------------------------------------------
module tav_top;
  logic ref_clk = 0;
  int   BUG = 0;
  always #5 ref_clk = ~ref_clk;   // 100 MHz reference

  tav_clk_if vif (ref_clk);
  tav_clk_div   u_div (.ref_clk(ref_clk), .rst_n(vif.rst_n), .div_n(vif.div_n),
                       .div_out(vif.div_out), .bug(BUG));
  tav_pll_model u_pll (.ref_clk(ref_clk), .rst_n(vif.rst_n), .pll_m(vif.pll_m),
                       .pll_out(vif.pll_out), .pll_locked(vif.pll_locked), .bug(BUG));

  initial begin
    void'($value$plusargs("BUG=%d", BUG));
    `uvm_info("TOP", $sformatf("Running with BUG=%0d", BUG), UVM_NONE)
    uvm_config_db#(virtual tav_clk_if)::set(null, "uvm_test_top", "vif", vif);
    uvm_config_db#(virtual tav_clk_if)::set(null, "uvm_test_top.env.agt.*", "vif", vif);
    run_test("tav_clock_test");
  end
endmodule
