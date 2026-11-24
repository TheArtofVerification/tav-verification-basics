// tav_debug_pipe_uvm.sv : three bugs, one symptom; clues and checkpoints find where each one lives (UVM 1.2)
// Run on Synopsys VCS X-2025.06-SP1 with UVM 1.2 (EDA Playground), 24 Nov 2026.
// The Art of Verification | theartofverification.com
//
// EDA Playground: Synopsys VCS, UVM 1.2, top module "tav_top".
// Paste this whole file into testbench.sv and leave design.sv empty.
//
// The design is a 3-stage packet pipeline: S1 framer, S2 accumulator, OUT formatter.
// For every packet it reports the length and the sum of its bytes.
// The test sends 300 random packets (1 to 40 bytes, 0 to 3 idle cycles between them).
// At the end the scoreboard prints three views of the same run:
//   E2E     the end-to-end check at the output: the symptom
//   CLUES   what the failing packets have in common: the detective's view
//   LOCATE  checkpoints between stages: which stage went wrong first
//
// Run options (one per run):
//   (none)    the clean design
//   +BUG=1    S1 drops the start-of-packet flag when a packet follows the previous one with no gap
//   +BUG=2    S2 counts length with 5 bits, so packets longer than 31 bytes report the wrong length
//   +BUG=3    OUT keeps its old value when two packets finish on back-to-back cycles
//
// Spec:
//   A packet is a run of beats with in_valid = 1, the first with in_sop = 1, the last with in_eop = 1.
//   A 1-byte packet has in_sop = in_eop = 1 on the same beat. Packets are 1 to 40 bytes.
//   For each packet, out_valid pulses once with out_len = number of bytes and out_sum = sum of bytes.
//   Results come out in packet order. out_len is never 0.
//   rst_n (async, active low) clears the pipeline.

`timescale 1ns/1ns
`include "uvm_macros.svh"
import uvm_pkg::*;

// ---------------------------------------------------------------------------
// The design
// ---------------------------------------------------------------------------
module tav_pkt_pipe (input  logic        clk, rst_n,
                     input  logic        in_valid, in_sop, in_eop,
                     input  logic [7:0]  in_data,
                     output logic        out_valid,
                     output logic [5:0]  out_len,
                     output logic [15:0] out_sum,
                     input  int          bug);
  // S1 framer: registers each beat
  logic       s1_valid, s1_sop, s1_eop, last_eop;
  logic [7:0] s1_data;
  // S2 accumulator: running length and sum, one result per packet
  logic [5:0]  acc_len, s2_len, nl;
  logic [15:0] acc_sum, s2_sum, ns;
  logic        s2_done;
  // OUT formatter
  logic        busy;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s1_valid <= 0; s1_sop <= 0; s1_eop <= 0; s1_data <= 0; last_eop <= 0;
    end else begin
      s1_valid <= in_valid;
      s1_sop   <= in_sop && !(bug == 1 && last_eop);                 // BUG=1
      s1_eop   <= in_eop;
      s1_data  <= in_data;
      last_eop <= in_valid && in_eop;
    end
  end

  always_comb begin
    nl = s1_sop ? 6'd1 : acc_len + 6'd1;
    if (bug == 2) nl = {1'b0, nl[4:0]};                               // BUG=2
    ns = s1_sop ? {8'd0, s1_data} : acc_sum + s1_data;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      acc_len <= 0; acc_sum <= 0; s2_done <= 0; s2_len <= 0; s2_sum <= 0;
    end else begin
      s2_done <= 0;
      if (s1_valid) begin
        acc_len <= nl; acc_sum <= ns;
        if (s1_eop) begin
          s2_done <= 1; s2_len <= nl; s2_sum <= ns;
        end
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_valid <= 0; out_len <= 0; out_sum <= 0; busy <= 0;
    end else begin
      out_valid <= s2_done;
      busy      <= s2_done;
      if (s2_done && !(bug == 3 && busy)) begin                       // BUG=3
        out_len <= s2_len; out_sum <= s2_sum;
      end
    end
  end
endmodule

// ---------------------------------------------------------------------------
// Interface: pins plus probes on the stage boundaries; the monitor samples before each edge
// ---------------------------------------------------------------------------
interface tav_pipe_if (input logic clk);
  logic        rst_n, in_valid, in_sop, in_eop, out_valid;
  logic [7:0]  in_data;
  logic [5:0]  out_len;
  logic [15:0] out_sum;
  // probes (driven from tav_top)
  logic        s1_valid, s1_sop, s1_eop, s2_done;
  logic [7:0]  s1_data;
  logic [5:0]  s2_len;
  logic [15:0] s2_sum;
  clocking mon_cb @(posedge clk);
    default input #1step;
    input rst_n, in_valid, in_sop, in_eop, in_data, out_valid, out_len, out_sum,
          s1_valid, s1_sop, s1_eop, s1_data, s2_done, s2_len, s2_sum;
  endclocking

  A_LEN_NONZERO: assert property (@(posedge clk) disable iff (!rst_n) out_valid |-> out_len != 0)
    else `uvm_error("SVA", $sformatf("A_LEN_NONZERO: out_valid with out_len=0 (out_sum=%0d)", $sampled(out_sum)))
  A_NO_X:        assert property (@(posedge clk) disable iff (!rst_n) !$isunknown(out_valid))
    else `uvm_error("SVA", "A_NO_X: out_valid is X")
endinterface

// ---------------------------------------------------------------------------
// Transactions: a packet for the driver, a cycle snapshot from the monitor
// ---------------------------------------------------------------------------
class tav_pkt_item extends uvm_sequence_item;
  rand int unsigned len, gap;
  rand bit [7:0]    data[];
  bit               rst;
  constraint c_len  { len dist {1 := 10, [2:31] :/ 60, [32:40] :/ 30}; }
  constraint c_gap  { gap dist {0 := 30, [1:3] :/ 70}; }
  constraint c_data { data.size() == len; }
  `uvm_object_utils(tav_pkt_item)
  function new(string name = "tav_pkt_item");
    super.new(name);
  endfunction
endclass

class tav_cycle_item extends uvm_object;
  bit          rst, in_valid, in_sop, in_eop, out_valid, s1_valid, s1_sop, s1_eop, s2_done;
  bit   [7:0]  in_data, s1_data;
  logic [5:0]  out_len, s2_len;
  logic [15:0] out_sum, s2_sum;
  `uvm_object_utils(tav_cycle_item)
  function new(string name = "tav_cycle_item");
    super.new(name);
  endfunction
endclass

// ---------------------------------------------------------------------------
// Sequences
// ---------------------------------------------------------------------------
class tav_reset_seq extends uvm_sequence #(tav_pkt_item);
  `uvm_object_utils(tav_reset_seq)
  function new(string name = "tav_reset_seq");
    super.new(name);
  endfunction
  task body();
    req = tav_pkt_item::type_id::create("req");
    start_item(req);
    req.rst = 1;
    finish_item(req);
  endtask
endclass

class tav_pkt_seq extends uvm_sequence #(tav_pkt_item);
  `uvm_object_utils(tav_pkt_seq)
  int unsigned n = 300;
  function new(string name = "tav_pkt_seq");
    super.new(name);
  endfunction
  task body();
    repeat (n) begin
      req = tav_pkt_item::type_id::create("req");
      start_item(req);
      if (!req.randomize()) `uvm_fatal("RAND", "randomize failed")
      finish_item(req);
    end
  endtask
endclass

// ---------------------------------------------------------------------------
// Driver: drives on the falling edge; gap idle cycles, then the packet's beats
// ---------------------------------------------------------------------------
class tav_pipe_driver extends uvm_driver #(tav_pkt_item);
  `uvm_component_utils(tav_pipe_driver)
  virtual tav_pipe_if vif;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(virtual tav_pipe_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "no virtual interface")
  endfunction
  task idle();
    @(negedge vif.clk);
    vif.in_valid <= 0; vif.in_sop <= 0; vif.in_eop <= 0;
  endtask
  task run_phase(uvm_phase phase);
    vif.rst_n <= 0; vif.in_valid <= 0; vif.in_sop <= 0; vif.in_eop <= 0; vif.in_data <= 0;
    forever begin
      seq_item_port.try_next_item(req);
      if (req == null) idle();
      else begin
        if (req.rst) begin
          @(negedge vif.clk);
          vif.rst_n <= 0; vif.in_valid <= 0; vif.in_sop <= 0; vif.in_eop <= 0;
          @(negedge vif.clk);
          vif.rst_n <= 1;
        end else begin
          repeat (req.gap) idle();
          foreach (req.data[i]) begin
            @(negedge vif.clk);
            vif.in_valid <= 1;
            vif.in_sop   <= (i == 0);
            vif.in_eop   <= (i == req.len - 1);
            vif.in_data  <= req.data[i];
          end
        end
        seq_item_port.item_done();
      end
    end
  endtask
endclass

// ---------------------------------------------------------------------------
// Monitor: one snapshot per clock of the pins and the stage probes
// ---------------------------------------------------------------------------
class tav_pipe_monitor extends uvm_monitor;
  `uvm_component_utils(tav_pipe_monitor)
  virtual tav_pipe_if vif;
  uvm_analysis_port #(tav_cycle_item) ap;
  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction
  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(virtual tav_pipe_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "no virtual interface")
  endfunction
  task run_phase(uvm_phase phase);
    forever begin
      tav_cycle_item t;
      @(vif.mon_cb);
      t = tav_cycle_item::type_id::create("t");
      t.rst       = (vif.mon_cb.rst_n !== 1'b1);
      t.in_valid  = vif.mon_cb.in_valid;  t.in_sop = vif.mon_cb.in_sop;  t.in_eop = vif.mon_cb.in_eop;
      t.in_data   = vif.mon_cb.in_data;
      t.s1_valid  = vif.mon_cb.s1_valid;  t.s1_sop = vif.mon_cb.s1_sop;  t.s1_eop = vif.mon_cb.s1_eop;
      t.s1_data   = vif.mon_cb.s1_data;
      t.s2_done   = vif.mon_cb.s2_done;   t.s2_len = vif.mon_cb.s2_len;  t.s2_sum = vif.mon_cb.s2_sum;
      t.out_valid = vif.mon_cb.out_valid; t.out_len = vif.mon_cb.out_len; t.out_sum = vif.mon_cb.out_sum;
      ap.write(t);
    end
  endtask
endclass

// ---------------------------------------------------------------------------
// Scoreboard: reference model from the spec, three views of the result
// ---------------------------------------------------------------------------
typedef struct { int len; int sum; int gap; int num; } tav_pkt_exp_t;

class tav_pipe_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(tav_pipe_scoreboard)
  uvm_analysis_imp #(tav_cycle_item, tav_pipe_scoreboard) imp;

  tav_pkt_exp_t q_s2[$], q_out[$];
  tav_cycle_item prev;
  int  cur_len, cur_sum, cur_gap, idle_run, pkt_num;
  int  packets, e2e_fails, shown;
  int  clue_b2b, clue_len1, clue_long;
  int  s1_fails, s2_fails, out_fails;
  time s1_first, s2_first, out_first;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    imp = new("imp", this);
    idle_run = 99;
  endfunction

  function void note(ref int fails, ref time first);
    if (fails == 0) first = $time;
    fails++;
  endfunction

  function void write(tav_cycle_item t);
    if (t.rst) begin
      q_s2.delete(); q_out.delete(); prev = null; idle_run = 99;
      return;
    end
    // Checkpoint S1: each beat should appear one cycle later, unchanged
    if (prev != null && (t.s1_valid !== prev.in_valid ||
        (prev.in_valid && (t.s1_sop !== prev.in_sop || t.s1_eop !== prev.in_eop || t.s1_data !== prev.in_data))))
      note(s1_fails, s1_first);
    // Checkpoint S2: one result per packet, in order
    if (t.s2_done) begin
      if (q_s2.size() == 0) note(s2_fails, s2_first);
      else begin
        tav_pkt_exp_t e = q_s2.pop_front();
        if (t.s2_len !== e.len[5:0] || t.s2_sum !== e.sum[15:0]) note(s2_fails, s2_first);
      end
    end
    // End to end at the output: this is the symptom a plain scoreboard reports
    if (t.out_valid) begin
      packets++;
      if (q_out.size() == 0) begin
        note(out_fails, out_first); e2e_fails++;
        `uvm_error("E2E", "out_valid with no packet expected")
      end else begin
        tav_pkt_exp_t e = q_out.pop_front();
        if (t.out_len !== e.len[5:0] || t.out_sum !== e.sum[15:0]) begin
          note(out_fails, out_first); e2e_fails++;
          if (e.gap == 0) clue_b2b++;
          if (e.len == 1) clue_len1++;
          if (e.len > 31) clue_long++;
          if (shown < 2) begin
            shown++;
            `uvm_error("E2E", $sformatf("packet %0d: out_len=%0d out_sum=%0d, expected len=%0d sum=%0d",
                       e.num, t.out_len, t.out_sum, e.len, e.sum))
          end
        end
      end
    end
    // Reference model from the spec, fed by the input pins
    if (t.in_valid) begin
      if (t.in_sop) begin cur_len = 1; cur_sum = t.in_data; cur_gap = idle_run; end
      else          begin cur_len++;   cur_sum += t.in_data; end
      if (t.in_eop) begin
        tav_pkt_exp_t e;
        pkt_num++;
        e.len = cur_len; e.sum = cur_sum; e.gap = cur_gap; e.num = pkt_num;
        q_s2.push_back(e); q_out.push_back(e);
        idle_run = 0;
      end
    end else if (idle_run < 99) idle_run++;
    prev = t;
  endfunction

  function void report_phase(uvm_phase phase);
    string where;
    int sva = uvm_report_server::get_server().get_id_count("SVA");
    `uvm_info("E2E", $sformatf("packets=%0d mismatches=%0d assertion_fails=%0d -> %s",
              packets, e2e_fails, sva, (e2e_fails == 0 && sva == 0) ? "PASS" : "FAIL"), UVM_NONE)
    `uvm_info("CLUES", $sformatf("failing packets=%0d: back_to_back=%0d one_byte=%0d longer_than_31=%0d",
              e2e_fails, clue_b2b, clue_len1, clue_long), UVM_NONE)
    if (s1_fails + s2_fails + out_fails == 0) where = "none, every checkpoint agrees with the model";
    else if (s1_fails > 0 && (s2_fails == 0 || s1_first <= s2_first) && (out_fails == 0 || s1_first <= out_first))
      where = $sformatf("S1 framer at %0t", s1_first);
    else if (s2_fails > 0 && (out_fails == 0 || s2_first <= out_first))
      where = $sformatf("S2 accumulator at %0t", s2_first);
    else where = $sformatf("OUT formatter at %0t", out_first);
    `uvm_info("LOCATE", $sformatf("checkpoint fails: S1=%0d S2=%0d OUT=%0d, first divergence: %s",
              s1_fails, s2_fails, out_fails, where), UVM_NONE)
  endfunction
endclass

// ---------------------------------------------------------------------------
// Agent, environment, test
// ---------------------------------------------------------------------------
class tav_pipe_agent extends uvm_agent;
  `uvm_component_utils(tav_pipe_agent)
  uvm_sequencer #(tav_pkt_item) sqr;
  tav_pipe_driver  drv;
  tav_pipe_monitor mon;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    sqr = uvm_sequencer#(tav_pkt_item)::type_id::create("sqr", this);
    drv = tav_pipe_driver::type_id::create("drv", this);
    mon = tav_pipe_monitor::type_id::create("mon", this);
  endfunction
  function void connect_phase(uvm_phase phase);
    drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction
endclass

class tav_pipe_env extends uvm_env;
  `uvm_component_utils(tav_pipe_env)
  tav_pipe_agent      agt;
  tav_pipe_scoreboard scb;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    agt = tav_pipe_agent::type_id::create("agt", this);
    scb = tav_pipe_scoreboard::type_id::create("scb", this);
  endfunction
  function void connect_phase(uvm_phase phase);
    agt.mon.ap.connect(scb.imp);
  endfunction
endclass

class tav_debug_test extends uvm_test;
  `uvm_component_utils(tav_debug_test)
  tav_pipe_env env;
  virtual tav_pipe_if vif;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    env = tav_pipe_env::type_id::create("env", this);
    if (!uvm_config_db#(virtual tav_pipe_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "no virtual interface")
  endfunction
  task run_phase(uvm_phase phase);
    tav_reset_seq r = tav_reset_seq::type_id::create("r");
    tav_pkt_seq   s = tav_pkt_seq::type_id::create("s");
    phase.raise_objection(this);
    r.start(env.agt.sqr);
    s.start(env.agt.sqr);
    repeat (6) @(vif.mon_cb);      // let the last packet drain through all three stages
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

  tav_pipe_if vif (clk);
  tav_pkt_pipe dut (.clk(clk), .rst_n(vif.rst_n), .in_valid(vif.in_valid), .in_sop(vif.in_sop),
                    .in_eop(vif.in_eop), .in_data(vif.in_data), .out_valid(vif.out_valid),
                    .out_len(vif.out_len), .out_sum(vif.out_sum), .bug(BUG));
  // stage-boundary probes for the checkpoints
  assign vif.s1_valid = dut.s1_valid;
  assign vif.s1_sop   = dut.s1_sop;
  assign vif.s1_eop   = dut.s1_eop;
  assign vif.s1_data  = dut.s1_data;
  assign vif.s2_done  = dut.s2_done;
  assign vif.s2_len   = dut.s2_len;
  assign vif.s2_sum   = dut.s2_sum;

  initial begin
    void'($value$plusargs("BUG=%d", BUG));
    `uvm_info("TOP", $sformatf("Running with BUG=%0d", BUG), UVM_NONE)
    uvm_config_db#(virtual tav_pipe_if)::set(null, "uvm_test_top", "vif", vif);
    uvm_config_db#(virtual tav_pipe_if)::set(null, "uvm_test_top.env.agt.*", "vif", vif);
    run_test("tav_debug_test");
  end
endmodule
