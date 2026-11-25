// tav_where_formal_uvm.sv : three blocks, one random UVM bench, to compare with the formal runs (UVM 1.2)
// Run on Synopsys VCS X-2025.06-SP1 with UVM 1.2 (EDA Playground), 25 Nov 2026.
// The Art of Verification | theartofverification.com
//
// EDA Playground: Synopsys VCS, UVM 1.2, top module "tav_top".
// Paste this whole file into testbench.sv and leave design.sv empty.
//
// The same three blocks as the formal harness tav_where_formal_fv.sv:
//   ARB   a 4-requester round-robin arbiter (control logic)
//   FIFO  an 8-deep, 8-bit FIFO (data movement)
//   MULT  a 16 x 16 shift-and-add multiplier (arithmetic)
// One test drives all three with 20,000 cycles of random stimulus. A spec model checks
// every output, SVA assertions check rules the formal harness also proves, and
// the scoreboard prints one RESULT line and one REACH line per block.
//
// Run options (one per run):
//   (none)    the clean design
//   +BUG=1    ARB: the pointer stays put after granting requester 2
//             FIFO: the read pointer skips entry 6
//             MULT: 0xFFFF x 0xFFFF gives a wrong answer (one input pair in 2^32)
//   +BUG=2    ARB: grants the last winner when nobody asks
//             FIFO: a push while full is not ignored
//             MULT: no bug
//
// Spec:
//   ARB   gnt is one-hot or zero, goes only to a requester that asked last cycle, someone is
//         granted whenever anyone asked, and the search starts just after the last winner
//         (requester 0 first after reset).
//   FIFO  data comes out in the order it went in; full at 8, empty at 0; a push while full
//         and a pop while empty are ignored. dout shows the oldest word.
//   MULT  p == a * b for every a and b.

`timescale 1ns/1ns
`include "uvm_macros.svh"
import uvm_pkg::*;

// ---------------------------------------------------------------------------
// The designs (the same logic as the formal harness; the formal copy of the FIFO adds a debug view)
// ---------------------------------------------------------------------------
module tav_rr_arb4 (input logic clk, rst_n, input logic [3:0] req,
                    output logic [3:0] gnt, input int bug);
  logic [1:0] last;
  logic [1:0] pick;
  logic       found;
  always_comb begin
    found = 0; pick = last;
    for (int k = 1; k <= 4; k++)
      if (!found && req[(last + k) % 4]) begin found = 1; pick = (last + k) % 4; end
  end
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin gnt <= 0; last <= 3; end
    else if (found) begin
      gnt  <= 4'b1 << pick;
      if (!(bug == 1 && pick == 2)) last <= pick;          // BUG=1: pointer stuck after granting 2
    end else gnt <= (bug == 2) ? (4'b1 << last) : 4'b0;   // BUG=2: grants with no request
endmodule

module tav_fifo8 (input logic clk, rst_n, push, pop, input logic [7:0] din,
                  output logic [7:0] dout, output logic full, empty, output logic [3:0] count,
                  input int bug);
  logic [7:0] mem [8];
  logic [2:0] wp, rp;
  logic do_push, do_pop;
  assign full = (count == 8); assign empty = (count == 0);
  assign do_push = push && (!full || bug == 2);                    // BUG=2: a push while full is not ignored
  assign do_pop  = pop && !empty;
  assign dout = mem[rp];
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin wp <= 0; rp <= 0; count <= 0; end
    else begin
      if (do_push) begin mem[wp] <= din; wp <= wp + 1; end
      if (do_pop)  rp <= (bug == 1 && rp == 5) ? 3'd7 : rp + 1;   // BUG=1: read pointer skips entry 6
      count <= count + do_push - do_pop;
    end
endmodule

module tav_mult #(parameter int W = 16) (input logic [W-1:0] a, b, output logic [2*W-1:0] p,
                                         input int bug);
  always_comb begin
    p = 0;
    for (int i = 0; i < W; i++)
      if (b[i]) p = p + ({{W{1'b0}}, a} << i);
    // BUG=1: one input pair out of all of them gives a wrong answer: all ones times all ones
    if (bug == 1 && a == {W{1'b1}} && b == {W{1'b1}}) p[0] = ~p[0];
  end
endmodule

// ---------------------------------------------------------------------------
// Interface: the pins of all three blocks, and the same rules the formal harness proves
// ---------------------------------------------------------------------------
interface tav_blocks_if (input logic clk);
  logic        rst_n;
  logic [3:0]  req, gnt;
  logic        push, pop, full, empty;
  logic [7:0]  din, dout;
  logic [3:0]  count;
  logic [15:0] a, b;
  logic [31:0] p;
  clocking mon_cb @(posedge clk);
    default input #1step;
    input rst_n, req, gnt, push, pop, full, empty, din, dout, count, a, b, p;
  endclocking

  // Each assertion reports its first 3 fails and then switches itself off, so a bug that
  // fires all the time cannot flood the log (EDA Playground stops at 5,000 lines).
  // The scoreboard still counts every mismatch.
  int tav_fails [4];   // A_ARB_ONEHOT, A_ARB_ASKED, A_FIFO_FLAGS, A_MULT

  A_ARB_ONEHOT: assert property (@(posedge clk) disable iff (!rst_n) $onehot0(gnt))
    else begin
      tav_fails[0]++; `uvm_error("SVA", $sformatf("A_ARB_ONEHOT: gnt=%b", $sampled(gnt)))
      if (tav_fails[0] == 3) $assertoff(0, A_ARB_ONEHOT);
    end
  A_ARB_ASKED: assert property (@(posedge clk) disable iff (!rst_n) $past(rst_n) |-> (gnt & ~$past(req)) == 0)
    else begin
      tav_fails[1]++; `uvm_error("SVA", $sformatf("A_ARB_ASKED: gnt=%b, req last cycle=%b", $sampled(gnt), $past(req)))
      if (tav_fails[1] == 3) $assertoff(0, A_ARB_ASKED);
    end
  A_FIFO_FLAGS: assert property (@(posedge clk) disable iff (!rst_n) count <= 8 && full == (count == 8) && empty == (count == 0))
    else begin
      tav_fails[2]++; `uvm_error("SVA", $sformatf("A_FIFO_FLAGS: count=%0d full=%b empty=%b", $sampled(count), $sampled(full), $sampled(empty)))
      if (tav_fails[2] == 3) $assertoff(0, A_FIFO_FLAGS);
    end
  A_MULT: assert property (@(posedge clk) disable iff (!rst_n) p == a * b)
    else begin
      tav_fails[3]++; `uvm_error("SVA", $sformatf("A_MULT: %h x %h gave %h", $sampled(a), $sampled(b), $sampled(p)))
      if (tav_fails[3] == 3) $assertoff(0, A_MULT);
    end
endinterface

// ---------------------------------------------------------------------------
// Transaction: one clock cycle of stimulus for all three blocks
// ---------------------------------------------------------------------------
class tav_blocks_item extends uvm_sequence_item;
  rand bit [3:0]  req;
  rand bit        push, pop;
  rand bit [7:0]  din;
  rand bit [15:0] a, b;
  bit             rst;
  `uvm_object_utils(tav_blocks_item)
  function new(string name = "tav_blocks_item");
    super.new(name);
  endfunction
endclass

class tav_blocks_cycle extends uvm_object;
  bit          rst;
  bit [3:0]    req;
  logic [3:0]  gnt;
  bit          push, pop;
  logic        full, empty;
  bit [7:0]    din;
  logic [7:0]  dout;
  logic [3:0]  count;
  bit [15:0]   a, b;
  logic [31:0] p;
  `uvm_object_utils(tav_blocks_cycle)
  function new(string name = "tav_blocks_cycle");
    super.new(name);
  endfunction
endclass

// ---------------------------------------------------------------------------
// Sequences
// ---------------------------------------------------------------------------
class tav_reset_seq extends uvm_sequence #(tav_blocks_item);
  `uvm_object_utils(tav_reset_seq)
  function new(string name = "tav_reset_seq");
    super.new(name);
  endfunction
  task body();
    req = tav_blocks_item::type_id::create("req");
    start_item(req);
    req.rst = 1;
    finish_item(req);
  endtask
endclass

class tav_random_seq extends uvm_sequence #(tav_blocks_item);
  `uvm_object_utils(tav_random_seq)
  int unsigned n = 20000;
  function new(string name = "tav_random_seq");
    super.new(name);
  endfunction
  task body();
    repeat (n) begin
      req = tav_blocks_item::type_id::create("req");
      start_item(req);
      if (!req.randomize()) `uvm_fatal("RAND", "randomize failed")
      finish_item(req);
    end
  endtask
endclass

// ---------------------------------------------------------------------------
// Driver: drives on the falling edge
// ---------------------------------------------------------------------------
class tav_blocks_driver extends uvm_driver #(tav_blocks_item);
  `uvm_component_utils(tav_blocks_driver)
  virtual tav_blocks_if vif;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(virtual tav_blocks_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "no virtual interface")
  endfunction
  task idle();
    vif.req <= 0; vif.push <= 0; vif.pop <= 0;
  endtask
  task run_phase(uvm_phase phase);
    vif.rst_n <= 0; idle(); vif.din <= 0; vif.a <= 0; vif.b <= 0;
    forever begin
      seq_item_port.get_next_item(req);
      @(negedge vif.clk);
      if (req.rst) begin
        vif.rst_n <= 0; idle();
        @(negedge vif.clk);
        vif.rst_n <= 1;
      end else begin
        vif.req <= req.req; vif.push <= req.push; vif.pop <= req.pop; vif.din <= req.din;
        vif.a <= req.a; vif.b <= req.b;
      end
      seq_item_port.item_done();
    end
  endtask
endclass

// ---------------------------------------------------------------------------
// Monitor: one snapshot of all pins per clock
// ---------------------------------------------------------------------------
class tav_blocks_monitor extends uvm_monitor;
  `uvm_component_utils(tav_blocks_monitor)
  virtual tav_blocks_if vif;
  uvm_analysis_port #(tav_blocks_cycle) ap;
  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction
  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(virtual tav_blocks_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "no virtual interface")
  endfunction
  task run_phase(uvm_phase phase);
    forever begin
      tav_blocks_cycle t;
      @(vif.mon_cb);
      t = tav_blocks_cycle::type_id::create("t");
      t.rst  = (vif.mon_cb.rst_n !== 1'b1);
      t.req  = vif.mon_cb.req;   t.gnt   = vif.mon_cb.gnt;
      t.push = vif.mon_cb.push;  t.pop   = vif.mon_cb.pop;   t.din = vif.mon_cb.din;
      t.dout = vif.mon_cb.dout;  t.full  = vif.mon_cb.full;  t.empty = vif.mon_cb.empty;
      t.count = vif.mon_cb.count;
      t.a = vif.mon_cb.a; t.b = vif.mon_cb.b; t.p = vif.mon_cb.p;
      ap.write(t);
    end
  endtask
endclass

// ---------------------------------------------------------------------------
// Scoreboard: a spec model for each block, and how far the stimulus reached
// ---------------------------------------------------------------------------
class tav_blocks_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(tav_blocks_scoreboard)
  uvm_analysis_imp #(tav_blocks_cycle, tav_blocks_scoreboard) imp;

  // models
  bit [3:0]  m_gnt;   bit [1:0] m_last;
  bit [7:0]  m_q[$];
  // counts per block: 0 = ARB, 1 = FIFO, 2 = MULT
  int checks[3], mism[3], shown[3];
  int cycles;
  // reach: did random stimulus get to the places where the bugs live?
  int arb_grant2_then_ask, fifo_full_cycles, fifo_push_while_full, mult_all_ones;
  int max_wait; int wait_cnt[4];

  function new(string name, uvm_component parent);
    super.new(name, parent);
    imp = new("imp", this);
  endfunction

  function void miss(int k, string msg);
    mism[k]++;
    if (shown[k] < 3) begin shown[k]++; `uvm_error("MISMATCH", msg) end
  endfunction

  function void write(tav_blocks_cycle t);
    if (t.rst) begin m_gnt = 0; m_last = 3; m_q.delete(); wait_cnt = '{0, 0, 0, 0}; return; end
    cycles++;
    // ARB: check this cycle's grant, then predict the next one from this cycle's requests
    checks[0]++;
    if (t.gnt !== m_gnt) miss(0, $sformatf("ARB cycle %0d: gnt=%b, expected %b", cycles, t.gnt, m_gnt));
    for (int i = 0; i < 4; i++) begin
      wait_cnt[i] = (t.req[i] && !t.gnt[i]) ? wait_cnt[i] + 1 : 0;
      if (wait_cnt[i] > max_wait) max_wait = wait_cnt[i];
    end
    if (m_gnt == 4'b0100 && t.req != 0) arb_grant2_then_ask++;
    begin
      bit found = 0;
      for (int k = 1; k <= 4 && !found; k++) begin
        int j = (m_last + k) % 4;
        if (t.req[j]) begin found = 1; m_gnt = 4'b1 << j; m_last = j; end
      end
      if (!found) m_gnt = 0;
    end
    // FIFO: flags, count and the oldest word, then apply this cycle's push and pop
    checks[1]++;
    if (t.count !== m_q.size() || t.full !== (m_q.size() == 8) || t.empty !== (m_q.size() == 0))
      miss(1, $sformatf("FIFO cycle %0d: count=%0d full=%b empty=%b, expected count=%0d", cycles, t.count, t.full, t.empty, m_q.size()));
    else if (m_q.size() > 0 && t.dout !== m_q[0])
      miss(1, $sformatf("FIFO cycle %0d: dout=%0d, expected %0d", cycles, t.dout, m_q[0]));
    if (m_q.size() == 8) begin fifo_full_cycles++; if (t.push) fifo_push_while_full++; end
    begin
      bit can_pop = m_q.size() > 0, can_push = m_q.size() < 8;
      if (t.pop && can_pop) begin void'(m_q.pop_front()); end
      if (t.push && can_push) m_q.push_back(t.din);
    end
    // MULT: combinational, checked every cycle
    checks[2]++;
    if (t.a == 16'hFFFF && t.b == 16'hFFFF) mult_all_ones++;
    if (t.p !== 32'(t.a) * 32'(t.b)) miss(2, $sformatf("MULT cycle %0d: %h x %h gave %h", cycles, t.a, t.b, t.p));
  endfunction

  function void tav_print_results(int f0, f1, f2, f3);   // not "report": that name is taken by uvm_component
    int sva[3] = '{f0 + f1, f2, f3};
    string nm[3] = '{"ARB ", "FIFO", "MULT"};
    for (int k = 0; k < 3; k++) begin
      string note = "";
      if (sva[k] >= 3) note = " (assertions switched off after 3)";
      `uvm_info("RESULT", $sformatf("%s checks=%0d mismatches=%0d assertion_fails=%0d%s -> %s",
                nm[k], checks[k], mism[k], sva[k], note, (mism[k] == 0 && sva[k] == 0) ? "PASS" : "FAIL"), UVM_NONE)
    end
    `uvm_info("REACH", $sformatf("ARB  longest wait=%0d cycles, grants to requester 2 followed by a request=%0d", max_wait, arb_grant2_then_ask), UVM_NONE)
    `uvm_info("REACH", $sformatf("FIFO cycles full=%0d, pushes while full=%0d", fifo_full_cycles, fifo_push_while_full), UVM_NONE)
    `uvm_info("REACH", $sformatf("MULT cycles=%0d, times a and b were both 0xFFFF=%0d", cycles, mult_all_ones), UVM_NONE)
  endfunction
endclass

// ---------------------------------------------------------------------------
// Agent, environment, test
// ---------------------------------------------------------------------------
class tav_blocks_agent extends uvm_agent;
  `uvm_component_utils(tav_blocks_agent)
  uvm_sequencer #(tav_blocks_item) sqr;
  tav_blocks_driver  drv;
  tav_blocks_monitor mon;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    sqr = uvm_sequencer#(tav_blocks_item)::type_id::create("sqr", this);
    drv = tav_blocks_driver::type_id::create("drv", this);
    mon = tav_blocks_monitor::type_id::create("mon", this);
  endfunction
  function void connect_phase(uvm_phase phase);
    drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction
endclass

class tav_blocks_env extends uvm_env;
  `uvm_component_utils(tav_blocks_env)
  tav_blocks_agent      agt;
  tav_blocks_scoreboard scb;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    agt = tav_blocks_agent::type_id::create("agt", this);
    scb = tav_blocks_scoreboard::type_id::create("scb", this);
  endfunction
  function void connect_phase(uvm_phase phase);
    agt.mon.ap.connect(scb.imp);
  endfunction
endclass

class tav_where_formal_test extends uvm_test;
  `uvm_component_utils(tav_where_formal_test)
  tav_blocks_env env;
  virtual tav_blocks_if vif;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    env = tav_blocks_env::type_id::create("env", this);
    if (!uvm_config_db#(virtual tav_blocks_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "no virtual interface")
  endfunction
  task run_phase(uvm_phase phase);
    tav_reset_seq  r = tav_reset_seq::type_id::create("r");
    tav_random_seq s = tav_random_seq::type_id::create("s");
    phase.raise_objection(this);
    r.start(env.agt.sqr);
    s.start(env.agt.sqr);
    repeat (2) @(vif.mon_cb);
    #1;
    env.scb.tav_print_results(vif.tav_fails[0], vif.tav_fails[1], vif.tav_fails[2], vif.tav_fails[3]);
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

  tav_blocks_if vif (clk);
  tav_rr_arb4 u_arb  (.clk(clk), .rst_n(vif.rst_n), .req(vif.req), .gnt(vif.gnt), .bug(BUG));
  tav_fifo8   u_fifo (.clk(clk), .rst_n(vif.rst_n), .push(vif.push), .pop(vif.pop), .din(vif.din),
                      .dout(vif.dout), .full(vif.full), .empty(vif.empty), .count(vif.count), .bug(BUG));
  tav_mult #(.W(16)) u_mult (.a(vif.a), .b(vif.b), .p(vif.p), .bug(BUG));

  initial begin
    void'($value$plusargs("BUG=%d", BUG));
    `uvm_info("TOP", $sformatf("Running with BUG=%0d", BUG), UVM_NONE)
    uvm_config_db#(virtual tav_blocks_if)::set(null, "uvm_test_top", "vif", vif);
    uvm_config_db#(virtual tav_blocks_if)::set(null, "uvm_test_top.env.agt.*", "vif", vif);
    run_test("tav_where_formal_test");
  end
endmodule
