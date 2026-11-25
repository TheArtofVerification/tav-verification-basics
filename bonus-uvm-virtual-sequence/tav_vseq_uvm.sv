// tav_vseq_uvm.sv : UVM virtual sequences and virtual sequencers, a complete working example (UVM 1.2)
// The Art of Verification | theartofverification.com
// Run on Synopsys VCS X-2025.06-SP1 with UVM 1.2 (EDA Playground), 25 Nov 2026.
// EDA Playground: Synopsys VCS, UVM 1.2, top module "tav_top".
// Paste this whole file into testbench.sv and leave design.sv empty.
//
// What is in here:
//   the design       tav_merge: an APB config port (CTRL, KEY, CNT_A, CNT_B) and two stream inputs,
//                    A and B, merged round robin onto one output. Each byte leaves XORed with KEY.
//   three agents     an APB agent (config) and two stream agents (A and B), each with its own
//                    sequencer, driver and monitor, plus a passive output monitor
//   a scoreboard     predicts every output byte from what went in and the KEY seen on the bus
//   a virtual        tav_vsqr: no driver, just handles to the three real sequencers
//   sequencer
//   the tour         steps 0 to 8, one idea per step:
//     0  default_sequence   tav_init_vseq starts by itself in configure_phase: setup, then traffic
//     1  approach 1         tav_handles_vseq: the sequence holds the sequencer handles, start(null)
//     2  approach 2         tav_p_vseq: runs on the virtual sequencer and uses p_sequencer
//     3  serial vs fork     A then B, against A and B in fork/join. Compare the times.
//     4  join_any           carry on when the short stream ends, then wait fork for the long one
//     5  nested             a top virtual sequence starts two child virtual sequences
//     6  lock               a 3-write re-key with and without lock() while a poll sequence runs
//     7  grab vs lock       grab() jumps ahead of a lock() that asked first
//     8  join_none          start A and B, do other work, wait fork, then check the counters
//
// Register map (APB, byte addresses):
//   0x00 CTRL   en [0] RW. Reset 0. While en is 0 the block takes input and drops it.
//   0x04 KEY    key [7:0] RW. Reset 0. Every output byte is the input byte XOR KEY.
//   0x08 CNT_A  [15:0] RO. Bytes from A that came out.
//   0x0C CNT_B  [15:0] RO. Bytes from B that came out.
//
// Run options (one per run). All four are bench mistakes, not design bugs:
//   (none)    the clean bench
//   +BUG=1    the virtual sequencer's b_sqr handle is never set
//   +BUG=2    tav_init_vseq forks setup and traffic instead of running them in order
//   +BUG=3    step 8 uses join_none and forgets wait fork
//   +BUG=4    b_sqr points at agent A's sequencer (a copy-paste slip in connect_phase)

`timescale 1ns/1ns
`include "uvm_macros.svh"
import uvm_pkg::*;

int tav_bug = 0;   // set from +BUG=n in the test's build_phase

// ---------------------------------------------------------------------------
// The design: two streams merged onto one output, set up over APB
// ---------------------------------------------------------------------------
module tav_merge (input  logic        clk, rst_n,
                  // APB config port
                  input  logic        psel, penable, pwrite,
                  input  logic [7:0]  paddr,
                  input  logic [31:0] pwdata,
                  output logic [31:0] prdata,
                  output logic        pready,
                  // stream A and stream B
                  input  logic        a_valid, b_valid,
                  input  logic [7:0]  a_data, b_data,
                  output logic        a_ready, b_ready,
                  // merged output
                  output logic        o_valid,
                  output logic [7:0]  o_data,
                  output logic        o_src);          // 0 = from A, 1 = from B
  logic        en, rr, pick_b;
  logic [7:0]  key;
  logic [15:0] cnt_a, cnt_b;

  // Round robin: when both are waiting, take turns. rr = 1 means B goes next.
  assign pick_b  = b_valid && (!a_valid || rr);
  assign a_ready = a_valid && !pick_b;
  assign b_ready = pick_b;
  assign pready  = 1'b1;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      en <= 0; key <= 0; rr <= 0; cnt_a <= 0; cnt_b <= 0;
      o_valid <= 0; o_data <= 0; o_src <= 0;
    end else begin
      if (psel && penable && pwrite) begin
        if (paddr == 8'h00) en  <= pwdata[0];
        if (paddr == 8'h04) key <= pwdata[7:0];
      end
      o_valid <= 0;
      if (a_valid || b_valid) begin
        if (en) begin                                   // enabled: pass it on
          o_valid <= 1;
          o_data  <= (pick_b ? b_data : a_data) ^ key;
          o_src   <= pick_b;
          if (pick_b) cnt_b <= cnt_b + 1; else cnt_a <= cnt_a + 1;
        end                                             // disabled: taken and dropped
        if (a_valid && b_valid) rr <= !pick_b;
      end
    end

  always_comb
    case (paddr)
      8'h00:   prdata = {31'h0, en};
      8'h04:   prdata = {24'h0, key};
      8'h08:   prdata = {16'h0, cnt_a};
      8'h0C:   prdata = {16'h0, cnt_b};
      default: prdata = 32'h0;
    endcase
endmodule

// ---------------------------------------------------------------------------
// Interfaces
// ---------------------------------------------------------------------------
interface tav_apb_if (input logic clk, input logic rst_n);
  logic        psel, penable, pwrite, pready;
  logic [7:0]  paddr;
  logic [31:0] pwdata, prdata;
endinterface

interface tav_strm_if (input logic clk, input logic rst_n);
  logic       valid, ready;
  logic [7:0] data;
endinterface

interface tav_out_if (input logic clk, input logic rst_n);
  logic       valid, src;
  logic [7:0] data;
endinterface

// ---------------------------------------------------------------------------
// Lesson bookkeeping: counters the tour prints. Not part of a normal bench.
// ---------------------------------------------------------------------------
class tav_tally;
  static int    sent_a, sent_b;      // bytes the virtual sequences meant for A and for B
  static int    polls;               // poll reads granted so far
  static string out_order = "";      // "A" or "B" per output byte, cleared by each step
  static string lock_order[$];       // which re-key sequence got the APB sequencer first
endclass

// ---------------------------------------------------------------------------
// Transactions
// ---------------------------------------------------------------------------
class tav_apb_item extends uvm_sequence_item;
  bit [7:0]  addr;
  bit [31:0] data;
  bit        write;
  `uvm_object_utils(tav_apb_item)
  function new(string name = "tav_apb_item"); super.new(name); endfunction
  function string convert2string();
    return $sformatf("%s 0x%02h data 0x%02h", write ? "WR" : "RD", addr, data);
  endfunction
endclass

class tav_strm_item extends uvm_sequence_item;
  bit [7:0] data;
  bit       src;                     // filled by the monitors: 0 = A, 1 = B
  `uvm_object_utils(tav_strm_item)
  function new(string name = "tav_strm_item"); super.new(name); endfunction
endclass

typedef uvm_sequencer #(tav_apb_item)  tav_apb_sqr;
typedef uvm_sequencer #(tav_strm_item) tav_strm_sqr;

// ---------------------------------------------------------------------------
// APB agent
// ---------------------------------------------------------------------------
class tav_apb_drv extends uvm_driver #(tav_apb_item);
  `uvm_component_utils(tav_apb_drv)
  virtual tav_apb_if vif;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(virtual tav_apb_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "no APB vif")
  endfunction
  task run_phase(uvm_phase phase);
    vif.psel = 0; vif.penable = 0; vif.pwrite = 0; vif.paddr = 0; vif.pwdata = 0;
    wait (vif.rst_n === 1'b1);
    forever begin
      seq_item_port.get_next_item(req);
      @(negedge vif.clk);                                   // setup phase
      vif.psel = 1; vif.penable = 0; vif.pwrite = req.write;
      vif.paddr = req.addr; vif.pwdata = req.data;
      @(negedge vif.clk) vif.penable = 1;                   // access phase
      @(posedge vif.clk);
      while (!vif.pready) @(posedge vif.clk);
      if (!req.write) req.data = vif.prdata;
      @(negedge vif.clk) begin vif.psel = 0; vif.penable = 0; end
      seq_item_port.item_done();
    end
  endtask
endclass

class tav_apb_mon extends uvm_monitor;
  `uvm_component_utils(tav_apb_mon)
  virtual tav_apb_if vif;
  uvm_analysis_port #(tav_apb_item) ap;
  function new(string name, uvm_component parent); super.new(name, parent); ap = new("ap", this); endfunction
  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(virtual tav_apb_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "no APB vif")
  endfunction
  task run_phase(uvm_phase phase);
    forever begin
      @(posedge vif.clk);
      if (vif.rst_n && vif.psel && vif.penable && vif.pready) begin
        tav_apb_item t = tav_apb_item::type_id::create("t");
        t.addr = vif.paddr; t.write = vif.pwrite;
        t.data = vif.pwrite ? vif.pwdata : vif.prdata;
        #1 ap.write(t);      // a write takes effect at this edge, so tell the scoreboard just after it
      end
    end
  endtask
endclass

class tav_apb_agent extends uvm_agent;
  `uvm_component_utils(tav_apb_agent)
  tav_apb_sqr sqr; tav_apb_drv drv; tav_apb_mon mon;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    sqr = tav_apb_sqr::type_id::create("sqr", this);
    drv = tav_apb_drv::type_id::create("drv", this);
    mon = tav_apb_mon::type_id::create("mon", this);
  endfunction
  function void connect_phase(uvm_phase phase);
    drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction
endclass

// ---------------------------------------------------------------------------
// Stream agent (used twice: A and B)
// ---------------------------------------------------------------------------
class tav_strm_drv extends uvm_driver #(tav_strm_item);
  `uvm_component_utils(tav_strm_drv)
  virtual tav_strm_if vif;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(virtual tav_strm_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "no stream vif")
  endfunction
  task run_phase(uvm_phase phase);
    vif.valid = 0; vif.data = 0;
    wait (vif.rst_n === 1'b1);
    forever begin
      seq_item_port.get_next_item(req);
      @(negedge vif.clk) begin vif.valid = 1; vif.data = req.data; end
      @(posedge vif.clk);
      while (!vif.ready) @(posedge vif.clk);                // the byte is taken at this edge
      @(negedge vif.clk) vif.valid = 0;
      seq_item_port.item_done();
    end
  endtask
endclass

class tav_strm_mon extends uvm_monitor;
  `uvm_component_utils(tav_strm_mon)
  virtual tav_strm_if vif;
  bit is_b;
  uvm_analysis_port #(tav_strm_item) ap;
  function new(string name, uvm_component parent); super.new(name, parent); ap = new("ap", this); endfunction
  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(virtual tav_strm_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "no stream vif")
  endfunction
  task run_phase(uvm_phase phase);
    forever begin
      @(posedge vif.clk);
      if (vif.rst_n && vif.valid && vif.ready) begin
        tav_strm_item t = tav_strm_item::type_id::create("t");
        t.data = vif.data; t.src = is_b;
        ap.write(t);
      end
    end
  endtask
endclass

class tav_strm_agent extends uvm_agent;
  `uvm_component_utils(tav_strm_agent)
  tav_strm_sqr sqr; tav_strm_drv drv; tav_strm_mon mon;
  bit is_b;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    sqr = tav_strm_sqr::type_id::create("sqr", this);
    drv = tav_strm_drv::type_id::create("drv", this);
    mon = tav_strm_mon::type_id::create("mon", this);
    mon.is_b = is_b;
  endfunction
  function void connect_phase(uvm_phase phase);
    drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction
endclass

// Passive monitor on the merged output
class tav_out_mon extends uvm_monitor;
  `uvm_component_utils(tav_out_mon)
  virtual tav_out_if vif;
  uvm_analysis_port #(tav_strm_item) ap;
  function new(string name, uvm_component parent); super.new(name, parent); ap = new("ap", this); endfunction
  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(virtual tav_out_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "no output vif")
  endfunction
  task run_phase(uvm_phase phase);
    forever begin
      @(posedge vif.clk);
      if (vif.rst_n && vif.valid) begin
        tav_strm_item t = tav_strm_item::type_id::create("t");
        string        c = vif.src ? "B" : "A";
        t.data = vif.data; t.src = vif.src;
        tav_tally::out_order = {tav_tally::out_order, c};
        ap.write(t);
      end
    end
  endtask
endclass

// ---------------------------------------------------------------------------
// Scoreboard
// ---------------------------------------------------------------------------
`uvm_analysis_imp_decl(_apb)
`uvm_analysis_imp_decl(_in)
`uvm_analysis_imp_decl(_out)

class tav_sb extends uvm_scoreboard;
  `uvm_component_utils(tav_sb)
  uvm_analysis_imp_apb #(tav_apb_item,  tav_sb) apb_imp;
  uvm_analysis_imp_in  #(tav_strm_item, tav_sb) in_imp;
  uvm_analysis_imp_out #(tav_strm_item, tav_sb) out_imp;
  bit       en;                      // the block's state, as seen on the APB bus
  bit [7:0] key;
  bit [7:0] exp_q[2][$];             // expected output bytes, one queue per source
  int n_in[2], n_ok, n_bad, n_drop;
  function new(string name, uvm_component parent);
    super.new(name, parent);
    apb_imp = new("apb_imp", this); in_imp = new("in_imp", this); out_imp = new("out_imp", this);
  endfunction
  function void write_apb(tav_apb_item t);
    if (!t.write) return;
    if (t.addr == 8'h00) en  = t.data[0];
    if (t.addr == 8'h04) key = t.data[7:0];
  endfunction
  function void write_in(tav_strm_item t);
    n_in[t.src]++;
    if (!en) begin
      n_drop++;
      `uvm_error("SB", $sformatf("%s byte 0x%02h went in while CTRL.en was 0, so the block dropped it. Traffic started before setup finished.",
                 t.src ? "B" : "A", t.data))
      return;
    end
    exp_q[t.src].push_back(t.data ^ key);
  endfunction
  function void write_out(tav_strm_item t);
    bit [7:0] exp;
    if (exp_q[t.src].size() == 0) begin
      n_bad++;
      `uvm_error("SB", $sformatf("unexpected output 0x%02h from %s", t.data, t.src ? "B" : "A"))
      return;
    end
    exp = exp_q[t.src].pop_front();
    if (t.data == exp) n_ok++;
    else begin
      n_bad++;
      `uvm_error("SB", $sformatf("%s: expected 0x%02h, got 0x%02h", t.src ? "B" : "A", exp, t.data))
    end
  endfunction
  function void check_phase(uvm_phase phase);
    foreach (exp_q[s])
      if (exp_q[s].size() != 0)
        `uvm_error("SB", $sformatf("%0d bytes from %s went in and never came out", exp_q[s].size(), s ? "B" : "A"))
  endfunction
  function void report_phase(uvm_phase phase);
    `uvm_info("SB", $sformatf("in: A=%0d B=%0d | out checked: %0d ok, %0d bad | dropped: %0d",
              n_in[0], n_in[1], n_ok, n_bad, n_drop), UVM_NONE)
  endfunction
endclass

// ---------------------------------------------------------------------------
// The virtual sequencer: no driver, only handles to the real sequencers
// ---------------------------------------------------------------------------
class tav_vsqr extends uvm_sequencer;
  `uvm_component_utils(tav_vsqr)
  tav_apb_sqr  apb_sqr;
  tav_strm_sqr a_sqr, b_sqr;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  // Catch a missing handle at time 0, before any sequence trips over it.
  function void end_of_elaboration_phase(uvm_phase phase);
    if (apb_sqr == null) `uvm_fatal("VSQR", "apb_sqr handle is null. Set it in the env's connect_phase.")
    if (a_sqr   == null) `uvm_fatal("VSQR", "a_sqr handle is null. Set it in the env's connect_phase.")
    if (b_sqr   == null) `uvm_fatal("VSQR", "b_sqr handle is null. Set it in the env's connect_phase.")
  endfunction
endclass

// ---------------------------------------------------------------------------
// Env
// ---------------------------------------------------------------------------
class tav_env extends uvm_env;
  `uvm_component_utils(tav_env)
  tav_apb_agent  apb_agt;
  tav_strm_agent a_agt, b_agt;
  tav_out_mon    out_mon;
  tav_sb         sb;
  tav_vsqr       vsqr;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    apb_agt = tav_apb_agent::type_id::create("apb_agt", this);
    a_agt   = tav_strm_agent::type_id::create("a_agt", this);
    b_agt   = tav_strm_agent::type_id::create("b_agt", this);
    b_agt.is_b = 1;
    out_mon = tav_out_mon::type_id::create("out_mon", this);
    sb      = tav_sb::type_id::create("sb", this);
    vsqr    = tav_vsqr::type_id::create("vsqr", this);
  endfunction
  function void connect_phase(uvm_phase phase);
    apb_agt.mon.ap.connect(sb.apb_imp);
    a_agt.mon.ap.connect(sb.in_imp);
    b_agt.mon.ap.connect(sb.in_imp);
    out_mon.ap.connect(sb.out_imp);
    // Fill the virtual sequencer's handles
    vsqr.apb_sqr = apb_agt.sqr;
    vsqr.a_sqr   = a_agt.sqr;
    if (tav_bug == 4)      vsqr.b_sqr = a_agt.sqr;          // BUG=4: copy-paste slip
    else if (tav_bug != 1) vsqr.b_sqr = b_agt.sqr;          // BUG=1: never set
  endfunction
endclass

// ---------------------------------------------------------------------------
// Real sequences: one per agent type
// ---------------------------------------------------------------------------
// n bytes on one stream: base, base+1, base+2, ...
class tav_strm_seq extends uvm_sequence #(tav_strm_item);
  `uvm_object_utils(tav_strm_seq)
  int       n = 4;
  bit [7:0] base;
  function new(string name = "tav_strm_seq"); super.new(name); endfunction
  task body();
    for (int i = 0; i < n; i++) begin
      req = tav_strm_item::type_id::create("req");
      start_item(req);
      req.data = base + i;
      finish_item(req);
    end
  endtask
endclass

// One APB read or write
class tav_apb_rw_seq extends uvm_sequence #(tav_apb_item);
  `uvm_object_utils(tav_apb_rw_seq)
  bit [7:0]  addr;
  bit [31:0] data;
  bit        write;
  function new(string name = "tav_apb_rw_seq"); super.new(name); endfunction
  task body();
    req = tav_apb_item::type_id::create("req");
    start_item(req);
    req.addr = addr; req.write = write; req.data = data;
    finish_item(req);
    data = req.data;
  endtask
endclass

// Reads CNT_A over and over until told to stop (the background traffic for steps 6 and 7)
class tav_apb_poll_seq extends uvm_sequence #(tav_apb_item);
  `uvm_object_utils(tav_apb_poll_seq)
  bit stop;
  function new(string name = "tav_apb_poll_seq"); super.new(name); endfunction
  task body();
    while (!stop) begin
      req = tav_apb_item::type_id::create("req");
      start_item(req);
      tav_tally::polls++;                                   // counted when granted
      req.addr = 8'h08; req.write = 0;
      finish_item(req);
    end
  endtask
endclass

// Re-key: CTRL.en=0, KEY=k, CTRL.en=1. These three writes belong together.
class tav_apb_rekey_seq extends uvm_sequence #(tav_apb_item);
  `uvm_object_utils(tav_apb_rekey_seq)
  bit [7:0] key;
  bit       use_lock, use_grab;
  int       p_first, p_last;         // poll reads granted so far, at the first and the last write
  function new(string name = "tav_apb_rekey_seq"); super.new(name); endfunction
  task body();
    bit [7:0]  addr[3] = '{8'h00, 8'h04, 8'h00};
    bit [31:0] data[3];
    data = '{32'h0, {24'h0, key}, 32'h1};
    if (use_grab) grab(); else if (use_lock) lock();
    tav_tally::lock_order.push_back(get_name());
    for (int i = 0; i < 3; i++) begin
      req = tav_apb_item::type_id::create("req");
      start_item(req);
      if (i == 0) p_first = tav_tally::polls;
      if (i == 2) p_last  = tav_tally::polls;
      req.addr = addr[i]; req.write = 1; req.data = data[i];
      finish_item(req);
    end
    if (use_grab) ungrab(); else if (use_lock) unlock();
  endtask
endclass

// ---------------------------------------------------------------------------
// Helpers both approaches share: start a real sequence on a real sequencer
// ---------------------------------------------------------------------------
class tav_vs;
  // intent_b says which stream the caller means. The tally counts intent, not what happened.
  static task send(tav_strm_sqr sqr, bit intent_b, int n, bit [7:0] base, uvm_sequence_base parent);
    tav_strm_seq s = tav_strm_seq::type_id::create(intent_b ? "b_seq" : "a_seq");
    s.n = n; s.base = base;
    if (intent_b) tav_tally::sent_b += n; else tav_tally::sent_a += n;
    s.start(sqr, parent);
  endtask
  static task wr(tav_apb_sqr sqr, bit [7:0] addr, bit [31:0] data, uvm_sequence_base parent);
    tav_apb_rw_seq s = tav_apb_rw_seq::type_id::create("wr");
    s.addr = addr; s.data = data; s.write = 1;
    s.start(sqr, parent);
  endtask
  static task rd(tav_apb_sqr sqr, bit [7:0] addr, output bit [31:0] data, input uvm_sequence_base parent);
    tav_apb_rw_seq s = tav_apb_rw_seq::type_id::create("rd");
    s.addr = addr; s.write = 0;
    s.start(sqr, parent);
    data = s.data;
  endtask
  static function void step(string title);
    tav_tally::out_order = "";
    `uvm_info("STEP", $sformatf("---- %s ----", title), UVM_NONE)
  endfunction
  static task done(string what);
    #20;                                                    // let the last byte reach the output
    `uvm_info("STEP", $sformatf("%s | output order: %s", what, tav_tally::out_order), UVM_NONE)
  endtask
endclass

// ---------------------------------------------------------------------------
// Approach 1: the virtual sequence holds the handles itself. Start it with start(null).
// ---------------------------------------------------------------------------
class tav_handles_vseq extends uvm_sequence;
  `uvm_object_utils(tav_handles_vseq)
  tav_apb_sqr  apb_sqr;              // the test fills these in before start(null)
  tav_strm_sqr a_sqr, b_sqr;
  function new(string name = "tav_handles_vseq"); super.new(name); endfunction
  task body();
    `uvm_info("STEP", $sformatf("m_sequencer is %s. This sequence runs on no sequencer.",
              m_sequencer == null ? "null" : m_sequencer.get_full_name()), UVM_NONE)
    tav_vs::send(a_sqr, 0, 4, 8'h10, this);
    tav_vs::send(b_sqr, 1, 4, 8'h90, this);
    tav_vs::done($sformatf("step 1 done at %0t", $time));
  endtask
endclass

// ---------------------------------------------------------------------------
// Approach 2: virtual sequences that run on tav_vsqr and reach the handles through p_sequencer
// ---------------------------------------------------------------------------
class tav_base_vseq extends uvm_sequence;
  `uvm_object_utils(tav_base_vseq)
  `uvm_declare_p_sequencer(tav_vsqr)
  function new(string name = "tav_base_vseq"); super.new(name); endfunction
  task send_a(int n, bit [7:0] base); tav_vs::send(p_sequencer.a_sqr, 0, n, base, this); endtask
  task send_b(int n, bit [7:0] base); tav_vs::send(p_sequencer.b_sqr, 1, n, base, this); endtask
  task setup(bit [7:0] key);
    tav_vs::wr(p_sequencer.apb_sqr, 8'h04, key, this);
    tav_vs::wr(p_sequencer.apb_sqr, 8'h00, 1, this);
  endtask
endclass

// Step 0: the default_sequence. Setup first, then traffic.
class tav_init_vseq extends tav_base_vseq;
  `uvm_object_utils(tav_init_vseq)
  function new(string name = "tav_init_vseq");
    super.new(name);
    set_automatic_phase_objection(1);                   // keeps configure_phase open while it runs
  endfunction
  task body();
    uvm_phase ph = get_starting_phase();
    tav_vs::step($sformatf("0. default_sequence: started by itself in %s", ph == null ? "?" : ph.get_name()));
    if (tav_bug == 2)
      fork                                              // BUG=2: setup and traffic race
        setup(8'h3C);
        begin send_a(4, 8'h00); send_b(4, 8'h80); end
      join
    else begin
      setup(8'h3C);
      send_a(4, 8'h00);
      send_b(4, 8'h80);
    end
    tav_vs::done($sformatf("step 0 done at %0t", $time));
  endtask
endclass

// Step 2: same traffic as step 1, now through p_sequencer
class tav_p_vseq extends tav_base_vseq;
  `uvm_object_utils(tav_p_vseq)
  function new(string name = "tav_p_vseq"); super.new(name); endfunction
  task body();
    `uvm_info("STEP", $sformatf("m_sequencer is %s, p_sequencer is a %s",
              m_sequencer.get_full_name(), p_sequencer.get_type_name()), UVM_NONE)
    send_a(4, 8'h20);
    send_b(4, 8'hA0);
    tav_vs::done($sformatf("step 2 done at %0t", $time));
  endtask
endclass

// Step 3: serial, then parallel
class tav_order_vseq extends tav_base_vseq;
  `uvm_object_utils(tav_order_vseq)
  function new(string name = "tav_order_vseq"); super.new(name); endfunction
  task body();
    time t0;
    t0 = $time;
    send_a(8, 8'h30);
    send_b(8, 8'hB0);
    tav_vs::done($sformatf("step 3a serial (A then B, 16 bytes) took %0t", $time - t0));
    tav_tally::out_order = "";
    t0 = $time;
    fork
      send_a(8, 8'h40);
      send_b(8, 8'hC0);
    join
    tav_vs::done($sformatf("step 3b fork/join (A and B together, 16 bytes) took %0t", $time - t0));
  endtask
endclass

// Step 4: join_any, then wait fork
class tav_any_vseq extends tav_base_vseq;
  `uvm_object_utils(tav_any_vseq)
  function new(string name = "tav_any_vseq"); super.new(name); endfunction
  task body();
    fork
      send_a(3, 8'h50);
      send_b(9, 8'hD0);
    join_any
    `uvm_info("STEP", $sformatf("join_any returned at %0t: A (3 bytes) is done, B (9 bytes) is still sending. Output so far: %s",
              $time, tav_tally::out_order), UVM_NONE)
    wait fork;
    tav_vs::done($sformatf("step 4 wait fork returned at %0t", $time));
  endtask
endclass

// Step 5: virtual sequences inside a virtual sequence
class tav_rekey_vseq extends tav_base_vseq;
  `uvm_object_utils(tav_rekey_vseq)
  bit [7:0] key = 8'h5A;
  function new(string name = "tav_rekey_vseq"); super.new(name); endfunction
  task body(); setup(key); endtask
endclass

class tav_traffic_vseq extends tav_base_vseq;
  `uvm_object_utils(tav_traffic_vseq)
  function new(string name = "tav_traffic_vseq"); super.new(name); endfunction
  task body();
    fork send_a(4, 8'h60); send_b(4, 8'hE0); join
  endtask
endclass

class tav_top_vseq extends tav_base_vseq;
  `uvm_object_utils(tav_top_vseq)
  function new(string name = "tav_top_vseq"); super.new(name); endfunction
  task body();
    tav_rekey_vseq   rk = tav_rekey_vseq::type_id::create("rk");
    tav_traffic_vseq tr = tav_traffic_vseq::type_id::create("tr");
    rk.start(p_sequencer, this);                        // child 1 on the same virtual sequencer
    tr.start(p_sequencer, this);                        // child 2, only after child 1 is done
    `uvm_info("STEP", $sformatf("children ran as %s and %s", rk.get_full_name(), tr.get_full_name()), UVM_NONE)
    tav_vs::done($sformatf("step 5 done at %0t", $time));
  endtask
endclass

// Step 6: three writes that belong together, while another sequence keeps reading
class tav_lock_vseq extends tav_base_vseq;
  `uvm_object_utils(tav_lock_vseq)
  function new(string name = "tav_lock_vseq"); super.new(name); endfunction
  task body();
    tav_apb_poll_seq  poll  = tav_apb_poll_seq::type_id::create("poll");
    tav_apb_rekey_seq plain = tav_apb_rekey_seq::type_id::create("rekey_plain");
    tav_apb_rekey_seq held  = tav_apb_rekey_seq::type_id::create("rekey_locked");
    plain.key = 8'h66;
    held.key  = 8'h77; held.use_lock = 1;
    fork poll.start(p_sequencer.apb_sqr, this); join_none
    #40;
    plain.start(p_sequencer.apb_sqr, this);
    held.start(p_sequencer.apb_sqr, this);
    poll.stop = 1;
    wait fork;
    `uvm_info("STEP", $sformatf("without lock: %0d poll reads got in between the 3 re-key writes",
              plain.p_last - plain.p_first), UVM_NONE)
    `uvm_info("STEP", $sformatf("with lock:    %0d poll reads got in between the 3 re-key writes",
              held.p_last - held.p_first), UVM_NONE)
    if (held.p_last != held.p_first)
      `uvm_error("LOCK", "a poll read got in while the lock was held")
    tav_vs::done($sformatf("step 6 done at %0t, %0d poll reads in all", $time, tav_tally::polls));
  endtask
endclass

// Step 7: a grab goes to the front of the line, but it still waits for a lock that is already held
class tav_grab_vseq extends tav_base_vseq;
  `uvm_object_utils(tav_grab_vseq)
  function new(string name = "tav_grab_vseq"); super.new(name); endfunction
  task body();
    tav_apb_poll_seq  poll = tav_apb_poll_seq::type_id::create("poll");
    tav_apb_rekey_seq lk   = tav_apb_rekey_seq::type_id::create("lock_first");
    tav_apb_rekey_seq gb   = tav_apb_rekey_seq::type_id::create("grab_later");
    int p_before;
    lk.key = 8'h11; lk.use_lock = 1;
    gb.key = 8'h22; gb.use_grab = 1;
    tav_tally::lock_order.delete();
    p_before = tav_tally::polls;
    fork begin #5; poll.start(p_sequencer.apb_sqr, this); end join_none   // poll asks at +5 ns
    fork
      lk.start(p_sequencer.apb_sqr, this);                                 // lock taken at +0 ns
      begin #25; gb.start(p_sequencer.apb_sqr, this); end                  // grab asks at +25 ns
    join
    `uvm_info("STEP", $sformatf("order the APB sequencer was given out: %s, %s, then the poll (waiting since +5 ns)",
              tav_tally::lock_order[0], tav_tally::lock_order[1]), UVM_NONE)
    `uvm_info("STEP", $sformatf("poll reads granted from the start of step 7 until the grab's last write: %0d",
              gb.p_last - p_before), UVM_NONE)
    if (tav_tally::lock_order[0] != "lock_first" || tav_tally::lock_order[1] != "grab_later" || gb.p_last != p_before)
      `uvm_error("GRAB", "the APB sequencer was not given out in the expected order")
    poll.stop = 1;
    wait fork;
    tav_vs::done($sformatf("step 7 done at %0t", $time));
  endtask
endclass

// Step 8: start traffic, do other work, then wait fork before checking the counters
class tav_none_vseq extends tav_base_vseq;
  `uvm_object_utils(tav_none_vseq)
  function new(string name = "tav_none_vseq"); super.new(name); endfunction
  task body();
    bit [31:0] key, ca, cb;
    fork
      send_a(10, 8'h70);
      send_b(10, 8'hF0);
    join_none
    tav_vs::rd(p_sequencer.apb_sqr, 8'h04, key, this);                    // other work meanwhile
    `uvm_info("STEP", $sformatf("join_none returned at once. Meanwhile KEY reads 0x%02h at %0t", key, $time), UVM_NONE)
    if (tav_bug != 3) wait fork;                                           // BUG=3: forgotten
    tav_vs::rd(p_sequencer.apb_sqr, 8'h08, ca, this);
    tav_vs::rd(p_sequencer.apb_sqr, 8'h0C, cb, this);
    `uvm_info("STEP", $sformatf("at %0t: CNT_A=%0d (meant %0d), CNT_B=%0d (meant %0d)",
              $time, ca, tav_tally::sent_a, cb, tav_tally::sent_b), UVM_NONE)
    if (ca != tav_tally::sent_a)
      `uvm_error("CHECK", $sformatf("CNT_A is %0d but the virtual sequences sent %0d bytes to A", ca, tav_tally::sent_a))
    if (cb != tav_tally::sent_b)
      `uvm_error("CHECK", $sformatf("CNT_B is %0d but the virtual sequences sent %0d bytes to B", cb, tav_tally::sent_b))
    tav_vs::done($sformatf("step 8 done at %0t", $time));
  endtask
endclass

// ---------------------------------------------------------------------------
// The test
// ---------------------------------------------------------------------------
class tav_vseq_test extends uvm_test;
  `uvm_component_utils(tav_vseq_test)
  tav_env env;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    void'($value$plusargs("BUG=%d", tav_bug));
    `uvm_info("TEST", $sformatf("Running with BUG=%0d", tav_bug), UVM_NONE)
    env = tav_env::type_id::create("env", this);
    // Step 0: the virtual sequencer starts tav_init_vseq by itself in configure_phase
    uvm_config_db#(uvm_object_wrapper)::set(this, "env.vsqr.configure_phase", "default_sequence",
                                            tav_init_vseq::type_id::get());
    uvm_top.set_timeout(200us, 1);
  endfunction
  task main_phase(uvm_phase phase);
    tav_handles_vseq s1 = tav_handles_vseq::type_id::create("s1");
    tav_p_vseq       s2 = tav_p_vseq::type_id::create("s2");
    tav_order_vseq   s3 = tav_order_vseq::type_id::create("s3");
    tav_any_vseq     s4 = tav_any_vseq::type_id::create("s4");
    tav_top_vseq     s5 = tav_top_vseq::type_id::create("s5");
    tav_lock_vseq    s6 = tav_lock_vseq::type_id::create("s6");
    tav_grab_vseq    s7 = tav_grab_vseq::type_id::create("s7");
    tav_none_vseq    s8 = tav_none_vseq::type_id::create("s8");
    phase.raise_objection(this);
    tav_vs::step("1. approach 1: the sequence holds the handles, start(null)");
    s1.apb_sqr = env.apb_agt.sqr; s1.a_sqr = env.a_agt.sqr; s1.b_sqr = env.b_agt.sqr;
    s1.start(null);
    tav_vs::step("2. approach 2: a virtual sequencer, reached through p_sequencer");
    s2.start(env.vsqr);
    tav_vs::step("3. serial vs fork/join");
    s3.start(env.vsqr);
    tav_vs::step("4. fork/join_any, then wait fork");
    s4.start(env.vsqr);
    tav_vs::step("5. nested virtual sequences");
    s5.start(env.vsqr);
    tav_vs::step("6. lock(): keep three writes together");
    s6.start(env.vsqr);
    tav_vs::step("7. grab() vs lock()");
    s7.start(env.vsqr);
    tav_vs::step("8. fork/join_none, then wait fork, then check the counters");
    s8.start(env.vsqr);
    #1us;                                                   // let any bytes still in flight finish
    phase.drop_objection(this);
  endtask
  function void report_phase(uvm_phase phase);
    uvm_report_server rs = uvm_report_server::get_server();
    int n = rs.get_severity_count(UVM_ERROR) + rs.get_severity_count(UVM_FATAL);
    `uvm_info("RESULT", $sformatf("%s: %0d errors", n == 0 ? "PASS" : "FAIL", n), UVM_NONE)
  endfunction
endclass

// ---------------------------------------------------------------------------
// Top
// ---------------------------------------------------------------------------
module tav_top;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  initial begin repeat (3) @(negedge clk); rst_n = 1; end

  tav_apb_if  apb_if (clk, rst_n);
  tav_strm_if a_if   (clk, rst_n);
  tav_strm_if b_if   (clk, rst_n);
  tav_out_if  o_if   (clk, rst_n);

  tav_merge dut (.clk(clk), .rst_n(rst_n),
                 .psel(apb_if.psel), .penable(apb_if.penable), .pwrite(apb_if.pwrite),
                 .paddr(apb_if.paddr), .pwdata(apb_if.pwdata), .prdata(apb_if.prdata),
                 .pready(apb_if.pready),
                 .a_valid(a_if.valid), .a_data(a_if.data), .a_ready(a_if.ready),
                 .b_valid(b_if.valid), .b_data(b_if.data), .b_ready(b_if.ready),
                 .o_valid(o_if.valid), .o_data(o_if.data), .o_src(o_if.src));

  initial begin
    uvm_config_db#(virtual tav_apb_if)::set(null, "uvm_test_top.env.apb_agt*", "vif", apb_if);
    uvm_config_db#(virtual tav_strm_if)::set(null, "uvm_test_top.env.a_agt*", "vif", a_if);
    uvm_config_db#(virtual tav_strm_if)::set(null, "uvm_test_top.env.b_agt*", "vif", b_if);
    uvm_config_db#(virtual tav_out_if)::set(null, "uvm_test_top.env.out_mon", "vif", o_if);
    run_test("tav_vseq_test");
  end
endmodule
