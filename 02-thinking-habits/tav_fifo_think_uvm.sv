// tav_fifo_think_uvm.sv : five thinking habits, one 16-deep FIFO, three hidden bugs (UVM 1.2)
// Run on Synopsys VCS X-2025.06-SP1 with UVM 1.2 (EDA Playground), 24 Nov 2026.
// The Art of Verification | theartofverification.com
//
// EDA Playground: Synopsys VCS, UVM 1.2, top module "tav_top".
// Paste this whole file into testbench.sv and leave design.sv empty.
//
// Run options (one per run):
//   (none)    the clean design
//   +BUG=1    full goes high at 15 entries instead of 16
//   +BUG=2    a write while full is not blocked, it overwrites the oldest entry
//   +BUG=3    the read pointer wraps to 1 instead of 0
//
// Spec:
//   16 entries of 8 bits. First word fall through: dout always shows the oldest entry.
//   full  = 1 when 16 entries are stored. empty = 1 when 0 entries are stored.
//   A write when full is dropped. A read when empty is dropped.
//   Read and write in the same cycle are both allowed, judged on the flags
//   before the clock edge.

`timescale 1ns/1ns
`include "uvm_macros.svh"
import uvm_pkg::*;

// ---------------------------------------------------------------------------
// The design
// ---------------------------------------------------------------------------
module tav_fifo16 (input  logic       clk, rst_n,
               input  logic       wr_en, rd_en,
               input  logic [7:0] din,
               output logic [7:0] dout,
               output logic       full, empty,
               input  int         bug);
  logic [7:0] mem [16];
  logic [3:0] wp, rp;
  logic [4:0] count;
  logic do_wr, do_rd;

  assign full  = (bug == 1) ? (count >= 15) : (count == 16);   // BUG=1
  assign empty = (count == 0);
  assign dout  = mem[rp];
  assign do_wr = wr_en && (!full || bug == 2);                 // BUG=2
  assign do_rd = rd_en && !empty;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wp <= 0; rp <= 0; count <= 0;
    end else begin
      if (do_wr) begin
        mem[wp] <= din;
        wp <= wp + 1;
      end
      if (do_rd)
        rp <= (rp == 15) ? ((bug == 3) ? 4'd1 : 4'd0) : rp + 1;  // BUG=3
      if (do_wr && !do_rd && count != 16) count <= count + 1;
      else if (do_rd && !do_wr)           count <= count - 1;
    end
  end
endmodule

// ---------------------------------------------------------------------------
// Interface: the monitor samples just before each rising edge
// ---------------------------------------------------------------------------
interface tav_fifo_if (input logic clk);
  logic       rst_n, wr_en, rd_en;
  logic [7:0] din, dout;
  logic       full, empty;
  clocking mon_cb @(posedge clk);
    default input #1step;
    input rst_n, wr_en, rd_en, din, dout, full, empty;
  endclocking
endinterface

// ---------------------------------------------------------------------------
// Transaction: one clock cycle at the FIFO pins
// ---------------------------------------------------------------------------
class tav_fifo_item extends uvm_sequence_item;
  rand bit   wr, rd;          // what the driver asks for this cycle
  bit  [7:0] din;
  bit        rst;             // 1 = pulse reset instead
  // filled in by the monitor
  logic [7:0] dout;
  logic       full, empty;
  `uvm_object_utils(tav_fifo_item)
  function new(string name = "tav_fifo_item");
    super.new(name);
  endfunction
endclass

// ---------------------------------------------------------------------------
// Sequences: one per scenario, each from one habit
// ---------------------------------------------------------------------------
class tav_fifo_base_seq extends uvm_sequence #(tav_fifo_item);
  `uvm_object_utils(tav_fifo_base_seq)
  bit [7:0] next_val = 1;     // writes carry 1, 2, 3 and so on, so a skipped entry shows
  function new(string name = "tav_fifo_base_seq");
    super.new(name);
  endfunction
  task cyc(bit wr, bit rd);
    req = tav_fifo_item::type_id::create("req");
    start_item(req);
    req.wr = wr; req.rd = rd; req.din = next_val;
    finish_item(req);
    if (wr) next_val++;
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

// T1: the happy path. Write 4, read 4.
class tav_happy_seq extends tav_fifo_base_seq;
  `uvm_object_utils(tav_happy_seq)
  function new(string name = "tav_happy_seq");
    super.new(name);
  endfunction
  task body();
    repeat (4) cyc(1, 0);
    repeat (4) cyc(0, 1);
  endtask
endclass

// T2, habit 2: the designer's number. Fill to exactly 16 and watch full.
class tav_fill_seq extends tav_fifo_base_seq;
  `uvm_object_utils(tav_fill_seq)
  function new(string name = "tav_fill_seq");
    super.new(name);
  endfunction
  task body();
    repeat (16) cyc(1, 0);
    cyc(0, 0);
  endtask
endclass

// T3, habit 3: past the happy path. Write 3 more while full, then drain.
class tav_overfill_seq extends tav_fifo_base_seq;
  `uvm_object_utils(tav_overfill_seq)
  function new(string name = "tav_overfill_seq");
    super.new(name);
  endfunction
  task body();
    repeat (16) cyc(1, 0);
    repeat (3)  cyc(1, 0);
    repeat (16) cyc(0, 1);
  endtask
endclass

// T4, habit 3: the other edge. Read 3 times while empty.
class tav_underflow_seq extends tav_fifo_base_seq;
  `uvm_object_utils(tav_underflow_seq)
  function new(string name = "tav_underflow_seq");
    super.new(name);
  endfunction
  task body();
    repeat (3) cyc(0, 1);
    cyc(1, 0);
    cyc(0, 1);
  endtask
endclass

// T5, habit 1: the whole system. Long traffic, so the pointers wrap.
class tav_wrap_seq extends tav_fifo_base_seq;
  `uvm_object_utils(tav_wrap_seq)
  function new(string name = "tav_wrap_seq");
    super.new(name);
  endfunction
  task body();
    repeat (8)  cyc(1, 0);
    repeat (40) cyc(1, 1);
    repeat (8)  cyc(0, 1);
  endtask
endclass

// T6, habit 4: constrained random mix, 2000 cycles
class tav_random_seq extends tav_fifo_base_seq;
  `uvm_object_utils(tav_random_seq)
  function new(string name = "tav_random_seq");
    super.new(name);
  endfunction
  task body();
    repeat (2000) begin
      req = tav_fifo_item::type_id::create("req");
      start_item(req);
      if (!req.randomize()) `uvm_fatal("RAND", "randomize failed")
      req.din = next_val;
      finish_item(req);
      if (req.wr) next_val++;
    end
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
    vif.rst_n <= 0; vif.wr_en <= 0; vif.rd_en <= 0; vif.din <= 0;
    forever begin
      seq_item_port.try_next_item(req);
      if (req == null) begin
        @(negedge vif.clk);
        vif.wr_en <= 0; vif.rd_en <= 0;
      end else begin
        if (req.rst) begin
          @(negedge vif.clk);
          vif.rst_n <= 0; vif.wr_en <= 0; vif.rd_en <= 0;
          @(negedge vif.clk);
          vif.rst_n <= 1;
        end else begin
          @(negedge vif.clk);
          vif.wr_en <= req.wr; vif.rd_en <= req.rd; vif.din <= req.din;
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
      t.rst   = (vif.mon_cb.rst_n !== 1'b1);
      t.wr    = vif.mon_cb.wr_en;
      t.rd    = vif.mon_cb.rd_en;
      t.din   = vif.mon_cb.din;
      t.dout  = vif.mon_cb.dout;
      t.full  = vif.mon_cb.full;
      t.empty = vif.mon_cb.empty;
      ap.write(t);
    end
  endtask
endclass

// ---------------------------------------------------------------------------
// Scoreboard: the reference model is a plain queue, written from the spec
// ---------------------------------------------------------------------------
class tav_fifo_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(tav_fifo_scoreboard)
  uvm_analysis_imp #(tav_fifo_item, tav_fifo_scoreboard) imp;
  bit [7:0] q[$];
  int errors, shown, total_errors, reads;
  int hit_full, hit_wr_full, hit_rd_empty, hit_both, hit_wrap;
  function new(string name, uvm_component parent);
    super.new(name, parent);
    imp = new("imp", this);
  endfunction

  function void start_test(string name);
    `uvm_info("TEST", name, UVM_NONE)
    errors = 0; shown = 0;
  endfunction

  function void end_test();
    `uvm_info("RESULT", $sformatf("%s, %0d mismatches", errors == 0 ? "PASS" : "FAIL", errors), UVM_NONE)
    total_errors += errors;
  endfunction

  function void write(tav_fifo_item t);
    bit m_full, m_empty;
    if (t.rst) begin
      q.delete(); reads = 0;
      return;
    end
    m_full  = (q.size() == 16);
    m_empty = (q.size() == 0);
    if (t.full !== m_full || t.empty !== m_empty || (!m_empty && t.dout !== q[0])) begin
      errors++;
      if (shown < 2) begin
        shown++;
        `uvm_error("MISMATCH", $sformatf("stored=%0d full=%b(exp %b) empty=%b(exp %b) dout=%0d(exp %0d)",
                   q.size(), t.full, m_full, t.empty, m_empty, t.dout, m_empty ? 0 : q[0]))
      end
    end
    if (t.wr && m_full)  hit_wr_full++;
    if (t.rd && m_empty) hit_rd_empty++;
    if (t.wr && t.rd && !m_full && !m_empty) hit_both++;
    if (m_full) hit_full++;
    if (t.rd && !m_empty) begin
      void'(q.pop_front());
      reads++;
      if (reads % 16 == 0) hit_wrap++;
    end
    if (t.wr && !m_full) q.push_back(t.din);
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("CORNERS", $sformatf("full=%0d write_while_full=%0d read_while_empty=%0d both_same_cycle=%0d pointer_wraps=%0d",
              hit_full, hit_wr_full, hit_rd_empty, hit_both, hit_wrap), UVM_NONE)
    `uvm_info("SUMMARY", $sformatf("total_mismatches=%0d", total_errors), UVM_NONE)
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
// Test: reset, run one scenario, report, six times
// ---------------------------------------------------------------------------
class tav_fifo_test extends uvm_test;
  `uvm_component_utils(tav_fifo_test)
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
    env.scb.start_test(name);
    r.start(env.agt.sqr);
    s.start(env.agt.sqr);
    repeat (2) @(vif.mon_cb);      // let the monitor see the last cycle
    #1;
    env.scb.end_test();
  endtask

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    run_one("T1 happy path (4 in, 4 out)",        tav_happy_seq::type_id::create("t1"));
    run_one("T2 fill to 16, check full",          tav_fill_seq::type_id::create("t2"));
    run_one("T3 write while full, then drain",    tav_overfill_seq::type_id::create("t3"));
    run_one("T4 read while empty",                tav_underflow_seq::type_id::create("t4"));
    run_one("T5 48 items through, pointers wrap", tav_wrap_seq::type_id::create("t5"));
    run_one("T6 random mix, 2000 cycles",         tav_random_seq::type_id::create("t6"));
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
  tav_fifo16 dut (.clk(clk), .rst_n(vif.rst_n), .wr_en(vif.wr_en), .rd_en(vif.rd_en),
              .din(vif.din), .dout(vif.dout), .full(vif.full), .empty(vif.empty), .bug(BUG));

  initial begin
    void'($value$plusargs("BUG=%d", BUG));
    `uvm_info("TOP", $sformatf("Running with BUG=%0d", BUG), UVM_NONE)
    uvm_config_db#(virtual tav_fifo_if)::set(null, "uvm_test_top", "vif", vif);
    uvm_config_db#(virtual tav_fifo_if)::set(null, "uvm_test_top.env.agt.*", "vif", vif);
    run_test("tav_fifo_test");
  end
endmodule
