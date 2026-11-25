// tav_soc_integration_uvm.sv : checking how blocks are wired together in a tiny SoC (UVM 1.2)
// Run on Synopsys VCS X-2025.06-SP1 with UVM 1.2 (EDA Playground), 25 Nov 2026.
// The Art of Verification | theartofverification.com
//
// EDA Playground: Synopsys VCS, UVM 1.2, top module "tav_top".
// Paste this whole file into testbench.sv and leave design.sv empty.
//
// The SoC has three small IP blocks (UART, SPI, TIMER) that are already verified on their
// own. This bench checks only what the SoC team adds: address decode, the pin mux, the
// interrupt wiring and the chip interrupt pin. A spec model in the scoreboard predicts every
// register read, both pads and the interrupt pin on every cycle.
//
// Register map (32-bit bus, byte addresses):
//   0x00 UART, 0x40 SPI, 0x80 TIMER. Each block has:
//     +0x0 CTRL   RW, bits [7:0]. bit 0 drives the block's output pin, bit 1 raises its
//                 interrupt. Reset value: UART 0x10, SPI 0x20, TIMER 0x30.
//     +0x4 STATUS RO. bit 0 = the block's input pin, bit 1 = its interrupt.
//     +0x8 ID     RO. UART 0x5541, SPI 0x5350, TIMER 0x544D.
//   0xC0 PINMUX     RW, bits [1:0], reset 0.
//   0xC4 IRQ_STATUS RO, bits [2:0] = UART, SPI, TIMER interrupts.
//   0xC8 IRQ_MASK   RW, bits [2:0], reset 0.
//   Any other address reads 0 and ignores writes.
// Pin mux (pad 0 / pad 1):
//   mode 0: UART / SPI    mode 1: SPI / TIMER    mode 2: TIMER / UART    mode 3: both pads 0
//   A block's input pin is the pad it is routed to, or 0 if it is not routed.
// Chip interrupt pin irq_n is active low: irq_n = 0 when any (IRQ_STATUS & IRQ_MASK) bit is 1.
//
// The test runs five phases: a smoke test, a register test, an alias test, a pin-mux test
// and an interrupt test. The scoreboard counts mismatches per phase and per kind.
//
// Run options (one per run):
//   (none)    the clean SoC
//   +BUG=1    pin mux mode 2 routes SPI to pad 1 instead of UART
//   +BUG=2    the SPI and TIMER interrupt lines are swapped going into IRQ_STATUS
//   +BUG=3    the chip interrupt pin is active high instead of active low
//   +BUG=4    a write to TIMER also writes SPI (address bit 7 left out of the SPI decode)

`timescale 1ns/1ns
`include "uvm_macros.svh"
import uvm_pkg::*;

// ---------------------------------------------------------------------------
// One IP block: CTRL, STATUS, ID. This is the "already verified" part.
// ---------------------------------------------------------------------------
module tav_ip #(parameter logic [7:0] RESET_CTRL = 8'h00, parameter logic [15:0] ID = 16'h0000)
              (input logic clk, rst_n, sel, we, input logic [5:0] off, input logic [31:0] wdata,
               output logic [31:0] rdata, output logic out_pin, irq, input logic in_pin);
  logic [7:0] ctrl;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) ctrl <= RESET_CTRL;
    else if (sel && we && off == 6'h0) ctrl <= wdata[7:0];
  assign out_pin = ctrl[0];
  assign irq     = ctrl[1];
  always_comb
    case (off)
      6'h0:    rdata = {24'h0, ctrl};
      6'h4:    rdata = {30'h0, irq, in_pin};
      6'h8:    rdata = {16'h0, ID};
      default: rdata = 32'h0;
    endcase
endmodule

// ---------------------------------------------------------------------------
// The SoC: the glue the SoC team wrote (decode, pin mux, interrupt controller)
// ---------------------------------------------------------------------------
module tav_mini_soc (input logic clk, rst_n,
                     input logic bus_req, bus_we, input logic [7:0] bus_addr,
                     input logic [31:0] bus_wdata, output logic [31:0] bus_rdata,
                     output logic [1:0] pad_out, input logic [1:0] pad_in,
                     output logic irq_n, input int bug);
  logic [2:0]  sel, out_pin, irq_ip, in_pin, irq_status;
  logic [31:0] rd [3];
  logic [1:0]  pinmux;
  logic [2:0]  mask;
  logic        soc_sel, any;

  // address decode: addr[7:6] picks the block
  always_comb begin
    sel[0]  = bus_req && bus_addr[7:6] == 2'd0;
    sel[1]  = bus_req && bus_addr[7:6] == 2'd1;
    sel[2]  = bus_req && bus_addr[7:6] == 2'd2;
    soc_sel = bus_req && bus_addr[7:6] == 2'd3;
    if (bug == 4 && bus_req && bus_we && bus_addr[6:0] == 7'h00 && bus_addr[7])
      sel[1] = 1;                                        // BUG=4: SPI decode ignores addr[7]
  end

  tav_ip #(8'h10, 16'h5541) u_uart  (clk, rst_n, sel[0], bus_we, bus_addr[5:0], bus_wdata, rd[0], out_pin[0], irq_ip[0], in_pin[0]);
  tav_ip #(8'h20, 16'h5350) u_spi   (clk, rst_n, sel[1], bus_we, bus_addr[5:0], bus_wdata, rd[1], out_pin[1], irq_ip[1], in_pin[1]);
  tav_ip #(8'h30, 16'h544D) u_timer (clk, rst_n, sel[2], bus_we, bus_addr[5:0], bus_wdata, rd[2], out_pin[2], irq_ip[2], in_pin[2]);

  // SoC registers
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin pinmux <= 0; mask <= 0; end
    else if (soc_sel && bus_we) begin
      if (bus_addr[5:0] == 6'h00) pinmux <= bus_wdata[1:0];
      if (bus_addr[5:0] == 6'h08) mask   <= bus_wdata[2:0];
    end

  // pin mux: outputs to the pads, pads back to the inputs
  always_comb begin
    pad_out = 2'b00; in_pin = 3'b000;
    case (pinmux)
      2'd0: begin pad_out = {out_pin[1], out_pin[0]}; in_pin[0] = pad_in[0]; in_pin[1] = pad_in[1]; end
      2'd1: begin pad_out = {out_pin[2], out_pin[1]}; in_pin[1] = pad_in[0]; in_pin[2] = pad_in[1]; end
      2'd2: begin
        if (bug == 1) begin pad_out = {out_pin[1], out_pin[2]}; in_pin[2] = pad_in[0]; in_pin[1] = pad_in[1]; end  // BUG=1
        else          begin pad_out = {out_pin[0], out_pin[2]}; in_pin[2] = pad_in[0]; in_pin[0] = pad_in[1]; end
      end
      default: ;                                         // mode 3: pads low, nothing routed
    endcase
  end

  // interrupt controller
  always_comb begin
    irq_status = (bug == 2) ? {irq_ip[1], irq_ip[2], irq_ip[0]} : irq_ip;   // BUG=2: SPI and TIMER swapped
    any        = |(irq_status & mask);
    irq_n      = (bug == 3) ? any : !any;                // BUG=3: wrong polarity
  end

  // read mux
  always_comb begin
    bus_rdata = 32'h0;
    if (bus_req && !bus_we)
      case (bus_addr[7:6])
        2'd0: bus_rdata = rd[0];
        2'd1: bus_rdata = rd[1];
        2'd2: bus_rdata = rd[2];
        2'd3: case (bus_addr[5:0])
                6'h00: bus_rdata = {30'h0, pinmux};
                6'h04: bus_rdata = {29'h0, irq_status};
                6'h08: bus_rdata = {29'h0, mask};
                default: bus_rdata = 32'h0;
              endcase
      endcase
  end
endmodule

// ---------------------------------------------------------------------------
// Interface
// ---------------------------------------------------------------------------
interface tav_soc_if (input logic clk);
  logic        rst_n, bus_req, bus_we, irq_n;
  logic [7:0]  bus_addr;
  logic [31:0] bus_wdata, bus_rdata;
  logic [1:0]  pad_out, pad_in;
  clocking mon_cb @(posedge clk);
    default input #1step;
    input rst_n, bus_req, bus_we, bus_addr, bus_wdata, bus_rdata, pad_out, pad_in, irq_n;
  endclocking
endinterface

// The test sets this so every mismatch knows which phase it came from.
int tav_phase = 0;

// ---------------------------------------------------------------------------
// Transactions
// ---------------------------------------------------------------------------
typedef enum {TAV_WR, TAV_RD, TAV_PAD, TAV_IDLE} tav_op_e;

class tav_soc_item extends uvm_sequence_item;         // one bus or pad operation
  tav_op_e     op;
  bit [7:0]    addr;
  bit [31:0]   data;                                   // write data, or pad value for TAV_PAD
  `uvm_object_utils(tav_soc_item)
  function new(string name = "tav_soc_item");
    super.new(name);
  endfunction
endclass

class tav_soc_cycle extends uvm_object;               // what the monitor saw in one cycle
  bit        rst, req, we, irq_n;
  bit [7:0]  addr;
  bit [31:0] wdata, rdata;
  bit [1:0]  pad_out, pad_in;
  `uvm_object_utils(tav_soc_cycle)
  function new(string name = "tav_soc_cycle");
    super.new(name);
  endfunction
endclass

// ---------------------------------------------------------------------------
// Sequences: the five phases
// ---------------------------------------------------------------------------
class tav_base_seq extends uvm_sequence #(tav_soc_item);
  `uvm_object_utils(tav_base_seq)
  function new(string name = "tav_base_seq");
    super.new(name);
  endfunction
  task do_op(tav_op_e op, bit [7:0] addr = 0, bit [31:0] data = 0);
    req = tav_soc_item::type_id::create("req");
    start_item(req);
    req.op = op; req.addr = addr; req.data = data;
    finish_item(req);
  endtask
  task wr(bit [7:0] a, bit [31:0] d); do_op(TAV_WR, a, d); endtask
  task rd(bit [7:0] a);               do_op(TAV_RD, a);    endtask
  task pad(bit [1:0] v);              do_op(TAV_PAD, 0, v); endtask
  task idle();                        do_op(TAV_IDLE);     endtask
endclass

// Phase 1: what a first "it boots" test looks like: UART in the default mode
class tav_smoke_seq extends tav_base_seq;
  `uvm_object_utils(tav_smoke_seq)
  function new(string name = "tav_smoke_seq");
    super.new(name);
  endfunction
  task body();
    rd(8'h08);                                           // UART ID
    wr(8'hC0, 0);                                        // pin mux mode 0
    wr(8'h00, 32'h11); idle(); wr(8'h00, 32'h10); idle(); // toggle the UART output pin
    pad(2'b01); rd(8'h04); pad(2'b00); rd(8'h04);         // UART input pin
    rd(8'h00);
  endtask
endclass

// Phase 2: reset values, then write and read back each RW register on its own
class tav_reg_seq extends tav_base_seq;
  `uvm_object_utils(tav_reg_seq)
  function new(string name = "tav_reg_seq");
    super.new(name);
  endfunction
  task body();
    bit [7:0] all[12] = '{8'h00, 8'h04, 8'h08, 8'h40, 8'h44, 8'h48, 8'h80, 8'h84, 8'h88, 8'hC0, 8'hC4, 8'hC8};
    bit [7:0] rw[5]   = '{8'h00, 8'h40, 8'h80, 8'hC0, 8'hC8};
    bit [31:0] pat[3] = '{32'hFC, 32'h00, 32'hA4};       // bits 0 and 1 kept low: no pins, no interrupts
    foreach (all[k]) rd(all[k]);
    foreach (rw[k]) foreach (pat[p]) begin wr(rw[k], pat[p]); rd(rw[k]); end
  endtask
endclass

// Phase 3: write a different value to every RW register, then read them all back
class tav_alias_seq extends tav_base_seq;
  `uvm_object_utils(tav_alias_seq)
  function new(string name = "tav_alias_seq");
    super.new(name);
  endfunction
  task body();
    bit [7:0] rw[5]   = '{8'h00, 8'h40, 8'h80, 8'hC0, 8'hC8};
    bit [31:0] val[5] = '{32'h14, 32'h28, 32'h3C, 32'h00, 32'h00};
    foreach (rw[k]) wr(rw[k], val[k]);
    foreach (rw[k]) rd(rw[k]);
  endtask
endclass

// Phase 4: every pin-mux mode, every block's output pin, every pad input
class tav_pinmux_seq extends tav_base_seq;
  `uvm_object_utils(tav_pinmux_seq)
  function new(string name = "tav_pinmux_seq");
    super.new(name);
  endfunction
  task body();
    bit [7:0] base[3] = '{8'h00, 8'h40, 8'h80};
    foreach (base[b]) wr(base[b], 0);                    // all output pins low
    for (int m = 0; m < 4; m++) begin
      wr(8'hC0, m);
      foreach (base[b]) begin wr(base[b], 1); idle(); wr(base[b], 0); idle(); end
      for (int v = 0; v < 4; v++) begin
        pad(v);
        foreach (base[b]) rd(base[b] + 8'h04);           // each block's STATUS
      end
      pad(0);
    end
  endtask
endclass

// Phase 5: each interrupt with the mask open, then with it closed
class tav_irq_seq extends tav_base_seq;
  `uvm_object_utils(tav_irq_seq)
  function new(string name = "tav_irq_seq");
    super.new(name);
  endfunction
  task body();
    bit [7:0] base[3] = '{8'h00, 8'h40, 8'h80};
    bit [2:0] masks[2] = '{3'b111, 3'b000};
    foreach (base[b]) wr(base[b], 0);
    foreach (masks[k]) begin
      wr(8'hC8, masks[k]);
      foreach (base[b]) begin
        wr(base[b], 2); idle();                          // raise this block's interrupt
        rd(8'hC4); rd(base[b] + 8'h04);
        wr(base[b], 0); idle();                          // clear it
        rd(8'hC4);
      end
    end
  endtask
endclass

// ---------------------------------------------------------------------------
// Driver: one operation per clock, driven on the falling edge
// ---------------------------------------------------------------------------
class tav_soc_driver extends uvm_driver #(tav_soc_item);
  `uvm_component_utils(tav_soc_driver)
  virtual tav_soc_if vif;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(virtual tav_soc_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "no virtual interface")
  endfunction
  task run_phase(uvm_phase phase);
    vif.rst_n <= 0; vif.bus_req <= 0; vif.bus_we <= 0; vif.bus_addr <= 0; vif.bus_wdata <= 0; vif.pad_in <= 0;
    repeat (3) @(negedge vif.clk);
    vif.rst_n <= 1;
    forever begin
      seq_item_port.get_next_item(req);
      @(negedge vif.clk);
      vif.bus_req <= 0; vif.bus_we <= 0;
      case (req.op)
        TAV_WR:  begin vif.bus_req <= 1; vif.bus_we <= 1; vif.bus_addr <= req.addr; vif.bus_wdata <= req.data; end
        TAV_RD:  begin vif.bus_req <= 1; vif.bus_we <= 0; vif.bus_addr <= req.addr; end
        TAV_PAD: vif.pad_in <= req.data[1:0];
        default: ;
      endcase
      @(posedge vif.clk); #1;                            // done once the monitor has seen it
      vif.bus_req <= 0; vif.bus_we <= 0;
      seq_item_port.item_done();
    end
  endtask
endclass

// ---------------------------------------------------------------------------
// Monitor: one snapshot of the bus and the pins per clock
// ---------------------------------------------------------------------------
class tav_soc_monitor extends uvm_monitor;
  `uvm_component_utils(tav_soc_monitor)
  virtual tav_soc_if vif;
  uvm_analysis_port #(tav_soc_cycle) ap;
  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction
  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(virtual tav_soc_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "no virtual interface")
  endfunction
  task run_phase(uvm_phase phase);
    forever begin
      tav_soc_cycle c;
      @(vif.mon_cb);
      c = tav_soc_cycle::type_id::create("c");
      c.rst = (vif.mon_cb.rst_n !== 1'b1);
      c.req = vif.mon_cb.bus_req; c.we = vif.mon_cb.bus_we; c.addr = vif.mon_cb.bus_addr;
      c.wdata = vif.mon_cb.bus_wdata; c.rdata = vif.mon_cb.bus_rdata;
      c.pad_out = vif.mon_cb.pad_out; c.pad_in = vif.mon_cb.pad_in; c.irq_n = vif.mon_cb.irq_n;
      ap.write(c);
    end
  endtask
endclass

// ---------------------------------------------------------------------------
// Scoreboard: a spec model of the SoC, checked on every cycle
// ---------------------------------------------------------------------------
class tav_soc_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(tav_soc_scoreboard)
  uvm_analysis_imp #(tav_soc_cycle, tav_soc_scoreboard) imp;

  // the model, from the register map in the header
  bit [7:0]  ctrl[3];
  bit [1:0]  pinmux;
  bit [2:0]  mask;
  bit [7:0]  reset_ctrl[3] = '{8'h10, 8'h20, 8'h30};
  bit [15:0] id[3]         = '{16'h5541, 16'h5350, 16'h544D};
  // which block drives each pad in each mode; 3 = nothing
  int        route[4][2]   = '{'{0, 1}, '{1, 2}, '{2, 0}, '{3, 3}};

  // results: [phase 1..5][kind 0 = register read, 1 = pads, 2 = interrupt pin]
  int mism[6][3], checks[6][3], shown[3];
  string kind_name[3] = '{"REG", "PIN", "IRQ"};
  // reach
  bit mode_toggled[4]; bit irq_seen[3];

  function new(string name, uvm_component parent);
    super.new(name, parent);
    imp = new("imp", this);
  endfunction

  function void model_reset();
    ctrl = reset_ctrl; pinmux = 0; mask = 0;
  endfunction

  function bit [2:0] irqs();
    return {ctrl[2][1], ctrl[1][1], ctrl[0][1]};
  endfunction

  function bit in_pin(int blk, bit [1:0] pad_in);
    for (int p = 0; p < 2; p++) if (route[pinmux][p] == blk) return pad_in[p];
    return 0;
  endfunction

  function bit [31:0] exp_read(bit [7:0] a, bit [1:0] pad_in);
    int blk = a[7:6];
    bit [2:0] irq_now = irqs();
    if (blk < 3)
      case (a[5:0])
        6'h0: return ctrl[blk];
        6'h4: return {irq_now[blk], in_pin(blk, pad_in)};
        6'h8: return id[blk];
        default: return 0;
      endcase
    case (a[5:0])
      6'h00: return pinmux;
      6'h04: return irqs();
      6'h08: return mask;
      default: return 0;
    endcase
  endfunction

  function void tav_check(int k, bit ok, string msg);   // not "check": uvm_component already has check()
    checks[tav_phase][k]++;
    if (!ok) begin
      mism[tav_phase][k]++;
      if (shown[k] < 3) begin shown[k]++; `uvm_error("MISMATCH", $sformatf("phase %0d %s: %s", tav_phase, kind_name[k], msg)) end
    end
  endfunction

  function void write(tav_soc_cycle c);
    bit [1:0] exp_pad;
    bit       exp_irq_n;
    if (c.rst) begin model_reset(); return; end
    // pins, from the model state before this cycle's write
    for (int p = 0; p < 2; p++) exp_pad[p] = (route[pinmux][p] < 3) ? ctrl[route[pinmux][p]][0] : 1'b0;
    exp_irq_n = !(|(irqs() & mask));
    tav_check(1, c.pad_out == exp_pad, $sformatf("mode %0d: pads=%b, expected %b", pinmux, c.pad_out, exp_pad));
    tav_check(2, c.irq_n == exp_irq_n, $sformatf("IRQ_STATUS=%b mask=%b: irq_n=%b, expected %b", irqs(), mask, c.irq_n, exp_irq_n));
    // reads
    if (c.req && !c.we) begin
      bit [31:0] e = exp_read(c.addr, c.pad_in);
      tav_check(0, c.rdata == e, $sformatf("read 0x%02h (mode %0d, pads in %b) = 0x%0h, expected 0x%0h", c.addr, pinmux, c.pad_in, c.rdata, e));
    end
    // writes update the model
    if (c.req && c.we) begin
      if (c.addr[7:6] < 3 && c.addr[5:0] == 0) begin
        ctrl[c.addr[7:6]] = c.wdata[7:0];
        if (c.wdata[0]) mode_toggled[pinmux] = 1;
        if (c.wdata[1]) irq_seen[c.addr[7:6]] = 1;
      end
      if (c.addr == 8'hC0) pinmux = c.wdata[1:0];
      if (c.addr == 8'hC8) mask   = c.wdata[2:0];
    end
  endfunction

  function void tav_print_results();
    string nm[6] = '{"", "smoke  ", "regs   ", "alias  ", "pin mux", "irq    "};
    for (int p = 1; p <= 5; p++)
      `uvm_info("RESULT", $sformatf("Phase %0d %s: reads=%0d wrong=%0d | pad cycles=%0d wrong=%0d | irq pin cycles=%0d wrong=%0d -> %s",
                p, nm[p], checks[p][0], mism[p][0], checks[p][1], mism[p][1], checks[p][2], mism[p][2],
                (mism[p][0] + mism[p][1] + mism[p][2] == 0) ? "PASS" : "FAIL"), UVM_NONE)
    `uvm_info("REACH", $sformatf("pin-mux modes with an output toggled=%0d of 4, blocks that raised an interrupt=%0d of 3",
              int'(mode_toggled[0]) + mode_toggled[1] + mode_toggled[2] + mode_toggled[3],
              int'(irq_seen[0]) + irq_seen[1] + irq_seen[2]), UVM_NONE)
  endfunction
endclass

// ---------------------------------------------------------------------------
// Environment and test
// ---------------------------------------------------------------------------
class tav_soc_env extends uvm_env;
  `uvm_component_utils(tav_soc_env)
  uvm_sequencer #(tav_soc_item) sqr;
  tav_soc_driver     drv;
  tav_soc_monitor    mon;
  tav_soc_scoreboard scb;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    sqr = uvm_sequencer#(tav_soc_item)::type_id::create("sqr", this);
    drv = tav_soc_driver::type_id::create("drv", this);
    mon = tav_soc_monitor::type_id::create("mon", this);
    scb = tav_soc_scoreboard::type_id::create("scb", this);
  endfunction
  function void connect_phase(uvm_phase phase);
    drv.seq_item_port.connect(sqr.seq_item_export);
    mon.ap.connect(scb.imp);
  endfunction
endclass

class tav_soc_test extends uvm_test;
  `uvm_component_utils(tav_soc_test)
  tav_soc_env env;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    env = tav_soc_env::type_id::create("env", this);
  endfunction
  task run_phase(uvm_phase phase);
    tav_smoke_seq  s1 = tav_smoke_seq::type_id::create("s1");
    tav_reg_seq    s2 = tav_reg_seq::type_id::create("s2");
    tav_alias_seq  s3 = tav_alias_seq::type_id::create("s3");
    tav_pinmux_seq s4 = tav_pinmux_seq::type_id::create("s4");
    tav_irq_seq    s5 = tav_irq_seq::type_id::create("s5");
    phase.raise_objection(this);
    tav_phase = 1; s1.start(env.sqr);
    tav_phase = 2; s2.start(env.sqr);
    tav_phase = 3; s3.start(env.sqr);
    tav_phase = 4; s4.start(env.sqr);
    tav_phase = 5; s5.start(env.sqr);
    repeat (3) @(posedge env.drv.vif.clk);
    env.scb.tav_print_results();
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

  tav_soc_if vif (clk);
  tav_mini_soc u_soc (.clk(clk), .rst_n(vif.rst_n), .bus_req(vif.bus_req), .bus_we(vif.bus_we),
                      .bus_addr(vif.bus_addr), .bus_wdata(vif.bus_wdata), .bus_rdata(vif.bus_rdata),
                      .pad_out(vif.pad_out), .pad_in(vif.pad_in), .irq_n(vif.irq_n), .bug(BUG));

  initial begin
    void'($value$plusargs("BUG=%d", BUG));
    `uvm_info("TOP", $sformatf("Running with BUG=%0d", BUG), UVM_NONE)
    uvm_config_db#(virtual tav_soc_if)::set(null, "uvm_test_top.env.*", "vif", vif);
    run_test("tav_soc_test");
  end
endmodule
