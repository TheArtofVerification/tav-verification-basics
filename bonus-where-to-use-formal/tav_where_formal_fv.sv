// tav_where_formal_fv.sv : one formal flow, three blocks, to see where formal fits
// Run on Yosys 0.33, yosys-smtbmc and Z3 4.8.12, 24 Nov 2026.
// The Art of Verification | theartofverification.com
//
// This is a formal harness, not a simulation testbench: run it with Yosys, not VCS.
// Pick a top (tav_fv_arb, tav_fv_fifo or tav_fv_mult) and a BUG value (0 = clean):
//   yosys -q -p "read_verilog -sv -formal tav_where_formal_fv.sv; \
//                chparam -set BUG 0 tav_fv_arb; prep -top tav_fv_arb; async2sync; dffunmap; \
//                write_smt2 -wires arb.smt2"
//   yosys-smtbmc -s z3 --unroll -t 20 arb.smt2       (bounded check, 20 cycles)
//   yosys-smtbmc -s z3 --unroll -i -t 20 arb.smt2    (induction: a full proof)
// For the multiplier, also set its width (chparam -set W 8 -set BUG 0 tav_fv_mult) and use -t 1:
// it has no state, so one step checks every a and b.
// --unroll matters: without it, this Z3 version stalled on the FIFO in my runs.

// ---------------------------------------------------------------------------
// Block 1: a 4-requester round-robin arbiter (control logic)
// Spec: gnt is one-hot or zero, gnt goes only to a requester that asked last cycle,
// someone is granted whenever anyone asked, and the search for the next winner
// starts just after the last winner.
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

module tav_fv_arb #(parameter int BUG = 0) (input logic clk, input logic [3:0] req);
  reg init = 1; always @(posedge clk) init <= 0;
  logic [3:0] gnt;
  tav_rr_arb4 dut (.clk(clk), .rst_n(!init), .req(req), .gnt(gnt), .bug(BUG));
  logic [3:0] req_q;  always @(posedge clk) req_q <= init ? 4'b0 : req;   // requests while in reset don't count
  // how long each requester has been asking without a grant
  logic [3:0] wait_cnt [4];
  always @(posedge clk) for (int i = 0; i < 4; i++)
    wait_cnt[i] <= (init || !req[i] || gnt[i]) ? 0 : (wait_cnt[i] == 15 ? 15 : wait_cnt[i] + 1);
  always @(posedge clk) if (!init) begin
    assert ((gnt & (gnt - 1)) == 0);                    // one-hot or zero
    assert ((gnt & ~req_q) == 0);                       // only to a requester that asked
    assert ((req_q == 0) || (gnt != 0));                // nobody left waiting when someone asked
    for (int i = 0; i < 4; i++) assert (wait_cnt[i] <= 4);   // fairness: served within 4 cycles
  end
`ifndef FORMAL
  // Yosys defines FORMAL for read_verilog -formal. Any simulator lands here instead.
  initial $fatal(1, "tav_where_formal_fv.sv is a formal harness: run it with Yosys (see the header), not in a simulator. For VCS, use tav_where_formal_uvm.sv.");
`endif
endmodule

// ---------------------------------------------------------------------------
// Block 2: an 8-deep, 8-bit FIFO (data movement)
// Spec: data comes out in the order it went in; full at 8, empty at 0;
// a push while full and a pop while empty are ignored.
// ---------------------------------------------------------------------------
module tav_fifo8 (input logic clk, rst_n, push, pop, input logic [7:0] din,
                  output logic [7:0] dout, output logic full, empty, output logic [3:0] count,
                  input int bug,
                  // debug view for the formal helper facts (not used by the design)
                  output logic [2:0] dbg_wp, dbg_rp, input logic [2:0] dbg_idx, output logic [7:0] dbg_word);
  logic [7:0] mem [8];
  logic [2:0] wp, rp;
  logic do_push, do_pop;
  assign full = (count == 8); assign empty = (count == 0);
  assign do_push = push && (!full || bug == 2);                    // BUG=2: a push while full is not ignored
  assign do_pop  = pop && !empty;
  assign dout = mem[rp];
  assign dbg_wp = wp; assign dbg_rp = rp; assign dbg_word = mem[dbg_idx];
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin wp <= 0; rp <= 0; count <= 0; end
    else begin
      if (do_push) begin mem[wp] <= din; wp <= wp + 1; end
      if (do_pop)  rp <= (bug == 1 && rp == 5) ? 3'd7 : rp + 1;   // BUG=1: read pointer skips entry 6
      count <= count + do_push - do_pop;
    end
endmodule

// The tracked-word trick: the tool picks one push to watch (any push, any time),
// counts how many words are ahead of it, and checks that word when it reaches the head.
module tav_fv_fifo #(parameter int BUG = 0)
  (input logic clk, input logic push, pop, input logic [7:0] din, input logic pick);
  reg init = 1; always @(posedge clk) init <= 0;
  logic [7:0] dout; logic full, empty; logic [3:0] count;
  logic [2:0] wp, rp; logic [7:0] word_at;
  logic       armed, done;
  logic [7:0] tdata;
  logic [3:0] ahead;          // words in front of the tracked word
  tav_fifo8 dut (.clk(clk), .rst_n(!init), .push(push), .pop(pop), .din(din),
                 .dout(dout), .full(full), .empty(empty), .count(count), .bug(BUG),
                 .dbg_wp(wp), .dbg_rp(rp), .dbg_idx(rp + ahead[2:0]), .dbg_word(word_at));
  wire do_push = push && !full, do_pop = pop && !empty;
  always @(posedge clk)
    if (init) begin armed <= 0; done <= 0; ahead <= 0; end
    else if (!armed && !done && pick && do_push) begin
      armed <= 1; tdata <= din; ahead <= count - do_pop;
    end else if (armed && do_pop) begin
      if (ahead == 0) begin armed <= 0; done <= 1; end else ahead <= ahead - 1;
    end
  // a model of how many words are stored
  logic [3:0] m_count;
  always @(posedge clk) m_count <= init ? 0 : m_count + do_push - do_pop;
  always @(posedge clk) if (!init) begin
    assert (count == m_count);                          // occupancy matches the model
    assert (full == (m_count == 8) && empty == (m_count == 0));
    if (armed && ahead == 0 && do_pop) assert (dout == tdata);   // the tracked word comes out intact, in order
    // helper facts for induction (true by construction, they stop the proof wandering into unreachable states)
    assert (m_count <= 8);
    if (armed) assert (ahead < m_count);
    if (armed) assert (word_at == tdata);
    assert (wp == rp + m_count[2:0]);
  end
`ifndef FORMAL
  // Yosys defines FORMAL for read_verilog -formal. Any simulator lands here instead.
  initial $fatal(1, "tav_where_formal_fv.sv is a formal harness: run it with Yosys (see the header), not in a simulator. For VCS, use tav_where_formal_uvm.sv.");
`endif
endmodule

// ---------------------------------------------------------------------------
// Block 3: a W x W multiplier built from shift-and-add (arithmetic)
// Spec: p == a * b for every a and b.
// ---------------------------------------------------------------------------
module tav_mult #(parameter int W = 8) (input logic [W-1:0] a, b, output logic [2*W-1:0] p,
                                        input int bug);
  always_comb begin
    p = 0;
    for (int i = 0; i < W; i++)
      if (b[i]) p = p + ({{W{1'b0}}, a} << i);
    // BUG=1: one input pair out of all of them gives a wrong answer: all ones times all ones
    if (bug == 1 && a == {W{1'b1}} && b == {W{1'b1}}) p[0] = ~p[0];
  end
endmodule

module tav_fv_mult #(parameter int W = 8, parameter int BUG = 0) (input logic clk, input logic [W-1:0] a, b);
  logic [2*W-1:0] p;
  tav_mult #(.W(W)) dut (.a(a), .b(b), .p(p), .bug(BUG));
  always @* assert (p == a * b);   // combinational: checked on every step
`ifndef FORMAL
  // Yosys defines FORMAL for read_verilog -formal. Any simulator lands here instead.
  initial $fatal(1, "tav_where_formal_fv.sv is a formal harness: run it with Yosys (see the header), not in a simulator. For VCS, use tav_where_formal_uvm.sv.");
`endif
endmodule
