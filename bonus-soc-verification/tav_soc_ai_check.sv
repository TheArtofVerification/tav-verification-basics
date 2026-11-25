// tav_soc_ai_check.sv : an AI-written SoC integration test, run against the same SoC and the same bugs
// Run on Synopsys VCS X-2025.06-SP1 (EDA Playground), 25 Nov 2026.
// The Art of Verification | theartofverification.com
//
// EDA Playground: Synopsys VCS, top module "tav_ai_top". UVM not needed.
// Paste this whole file into testbench.sv and leave design.sv empty.
//
// tb_tav_mini_soc below is the AI answer exactly as it came back, not edited. It ties the
// DUT's bug port to 0, so tav_ai_top forces that port from +BUG=n instead of changing the
// AI's code. The SoC is the same as in tav_soc_integration_uvm.sv.
//
// Run options (one per run):
//   (none), +BUG=1, +BUG=2, +BUG=3, +BUG=4   (the same bugs as the UVM bench)

`timescale 1ns/1ps

// ---------------------------------------------------------------------------
// The SoC (copied from tav_soc_integration_uvm.sv)
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
// The AI answer, unedited
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

// ----------------------------------------------------------------------------
// tb_tav_mini_soc : chip-level integration test (plain SystemVerilog, no UVM)
// Checks: address decode, reset values, RO/RW behaviour, unmapped space,
//         pin mux routing (both directions), interrupt wiring, IRQ mask, irq_n
// Run:    +SEED=<n> to change the random phase seed
// ----------------------------------------------------------------------------
module tb_tav_mini_soc;

  // ---------------- DUT signals ----------------
  logic        clk   = 1'b0;
  logic        rst_n = 1'b0;
  logic        bus_req = 1'b0, bus_we = 1'b0;
  logic [7:0]  bus_addr  = '0;
  logic [31:0] bus_wdata = '0;
  logic [31:0] bus_rdata;
  logic [1:0]  pad_out;
  logic [1:0]  pad_in = '0;
  logic        irq_n;

  tav_mini_soc dut (
    .clk       (clk),
    .rst_n     (rst_n),
    .bus_req   (bus_req),
    .bus_we    (bus_we),
    .bus_addr  (bus_addr),
    .bus_wdata (bus_wdata),
    .bus_rdata (bus_rdata),
    .pad_out   (pad_out),
    .pad_in    (pad_in),
    .irq_n     (irq_n),
    .bug       (0)
  );

  always #5 clk = ~clk;   // 100 MHz

  // ---------------- Spec constants ----------------
  localparam logic [7:0]  BASE     [3] = '{8'h00, 8'h40, 8'h80};      // UART, SPI, TIMER
  localparam logic [7:0]  CTRL_RST [3] = '{8'h10, 8'h20, 8'h30};
  localparam logic [15:0] ID_VAL   [3] = '{16'h5541, 16'h5350, 16'h544D};
  localparam logic [7:0]  A_PINMUX  = 8'hC0;
  localparam logic [7:0]  A_IRQSTAT = 8'hC4;
  localparam logic [7:0]  A_IRQMASK = 8'hC8;
  localparam logic [7:0]  MAPPED [12] = '{8'h00, 8'h04, 8'h08,
                                          8'h40, 8'h44, 8'h48,
                                          8'h80, 8'h84, 8'h88,
                                          8'hC0, 8'hC4, 8'hC8};
  localparam int MAX_PRINT = 40;

  // ---------------- Reference model ----------------
  logic [7:0] m_ctrl [3];
  logic [1:0] m_pinmux;
  logic [2:0] m_mask;

  int unsigned n_checks = 0;
  int unsigned n_errors = 0;
  int unsigned seed     = 1;

  function automatic void model_reset();
    for (int b = 0; b < 3; b++) m_ctrl[b] = CTRL_RST[b];
    m_pinmux = 2'd0;
    m_mask   = 3'd0;
  endfunction

  function automatic void model_write(logic [7:0] a, logic [31:0] d);
    case (a)
      8'h00:     m_ctrl[0] = d[7:0];
      8'h40:     m_ctrl[1] = d[7:0];
      8'h80:     m_ctrl[2] = d[7:0];
      A_PINMUX:  m_pinmux  = d[1:0];
      A_IRQMASK: m_mask    = d[2:0];
      default:   ;   // RO or unmapped: ignored
    endcase
  endfunction

  // {TIMER, SPI, UART}
  function automatic logic [2:0] exp_irqs();
    return {m_ctrl[2][1], m_ctrl[1][1], m_ctrl[0][1]};
  endfunction

  // Block input pins {TIMER, SPI, UART}: routed pad, else 0
  function automatic logic [2:0] exp_block_in();
    case (m_pinmux)
      2'd0:    return {1'b0,      pad_in[1], pad_in[0]}; // UART<-pad0, SPI<-pad1
      2'd1:    return {pad_in[1], pad_in[0], 1'b0     }; // SPI<-pad0, TIMER<-pad1
      2'd2:    return {pad_in[0], 1'b0,      pad_in[1]}; // TIMER<-pad0, UART<-pad1
      default: return 3'b000;
    endcase
  endfunction

  // {pad1, pad0}
  function automatic logic [1:0] exp_pad_out();
    logic [2:0] o;
    o = {m_ctrl[2][0], m_ctrl[1][0], m_ctrl[0][0]};
    case (m_pinmux)
      2'd0:    return {o[1], o[0]};   // pad0=UART,  pad1=SPI
      2'd1:    return {o[2], o[1]};   // pad0=SPI,   pad1=TIMER
      2'd2:    return {o[0], o[2]};   // pad0=TIMER, pad1=UART
      default: return 2'b00;
    endcase
  endfunction

  function automatic logic exp_irq_n();
    return ~|(exp_irqs() & m_mask);
  endfunction

  function automatic logic [31:0] exp_read(logic [7:0] a);
    logic [2:0] ins, irqs;
    ins  = exp_block_in();
    irqs = exp_irqs();
    for (int b = 0; b < 3; b++) begin
      if (a == BASE[b])         return {24'h0, m_ctrl[b]};
      if (a == BASE[b] + 8'h4)  return {30'h0, irqs[b], ins[b]};
      if (a == BASE[b] + 8'h8)  return {16'h0, ID_VAL[b]};
    end
    case (a)
      A_PINMUX:  return {30'h0, m_pinmux};
      A_IRQSTAT: return {29'h0, irqs};
      A_IRQMASK: return {29'h0, m_mask};
      default:   return 32'h0;
    endcase
  endfunction

  function automatic bit is_mapped(logic [7:0] a);
    foreach (MAPPED[i]) if (MAPPED[i] == a) return 1'b1;
    return 1'b0;
  endfunction

  function automatic string reg_name(logic [7:0] a);
    case (a)
      8'h00: return "UART.CTRL";   8'h04: return "UART.STATUS";  8'h08: return "UART.ID";
      8'h40: return "SPI.CTRL";    8'h44: return "SPI.STATUS";   8'h48: return "SPI.ID";
      8'h80: return "TIMER.CTRL";  8'h84: return "TIMER.STATUS"; 8'h88: return "TIMER.ID";
      8'hC0: return "PINMUX";      8'hC4: return "IRQ_STATUS";   8'hC8: return "IRQ_MASK";
      default: return $sformatf("UNMAPPED[0x%02h]", a);
    endcase
  endfunction

  // ---------------- Checking ----------------
  task automatic chk(input string tag, input string what,
                     input logic [31:0] got, input logic [31:0] exp);
    n_checks++;
    if (got !== exp) begin
      n_errors++;
      if (n_errors <= MAX_PRINT)
        $display("ERROR [%0t] %s | %s : got 0x%08h exp 0x%08h (pinmux=%0d mask=%03b pad_in=%02b)",
                 $time, tag, what, got, exp, m_pinmux, m_mask, pad_in);
      else if (n_errors == MAX_PRINT + 1)
        $display("ERROR ... further error messages suppressed");
    end
  endtask

  // ---------------- Bus driver ----------------
  // Drive on negedge, hold for exactly one rising edge.
  task automatic bus_write(input logic [7:0] addr, input logic [31:0] data);
    @(negedge clk);
    bus_req   = 1'b1;
    bus_we    = 1'b1;
    bus_addr  = addr;
    bus_wdata = data;
    @(posedge clk);
    model_write(addr, data);
    @(negedge clk);
    bus_req   = 1'b0;
    bus_we    = 1'b0;
    bus_wdata = '0;
  endtask

  // Read: rdata is combinational, sample mid-cycle. Junk on wdata proves reads never write.
  task automatic bus_read(input logic [7:0] addr, output logic [31:0] data);
    @(negedge clk);
    bus_req   = 1'b1;
    bus_we    = 1'b0;
    bus_addr  = addr;
    bus_wdata = $urandom();
    #1 data   = bus_rdata;
    @(negedge clk);
    bus_req   = 1'b0;
    bus_wdata = '0;
  endtask

  task automatic set_pads(input logic [1:0] v);
    @(negedge clk);
    pad_in = v;
  endtask

  task automatic check_reg(input string tag, input logic [7:0] a);
    logic [31:0] d;
    bus_read(a, d);
    chk(tag, reg_name(a), d, exp_read(a));
  endtask

  task automatic check_pins(input string tag);
    #1;
    chk(tag, "pad_out", {30'h0, pad_out}, {30'h0, exp_pad_out()});
    chk(tag, "irq_n",   {31'h0, irq_n},   {31'h0, exp_irq_n()});
  endtask

  // All mapped registers + chip pins
  task automatic check_all(input string tag);
    check_pins(tag);
    foreach (MAPPED[i]) check_reg(tag, MAPPED[i]);
    check_pins(tag);
  endtask

  // Full 256-address read sweep (decode + unmapped reads 0)
  task automatic sweep(input string tag);
    for (int a = 0; a < 256; a++) check_reg(tag, 8'(a));
  endtask

  task automatic do_reset();
    @(negedge clk);
    rst_n   = 1'b0;
    bus_req = 1'b0;
    bus_we  = 1'b0;
    model_reset();
    repeat (3) @(posedge clk);
    check_pins("in reset");
    @(negedge clk);
    rst_n = 1'b1;
  endtask

  // ---------------- Test sequence ----------------
  initial begin
    if ($value$plusargs("SEED=%d", seed)) ;
    void'($urandom(seed));
    $display("==== tav_mini_soc integration test, seed=%0d ====", seed);

    // T1: reset values, IDs, full decode sweep
    do_reset();
    check_all("T1 reset");
    sweep("T1 sweep");

    // T2: per-block decode, unique CTRL values, unused upper bits ignored
    bus_write(BASE[0], 32'hFFFF_FF5C);  check_all("T2 UART.CTRL write");
    bus_write(BASE[1], 32'h1234_56A4);  check_all("T2 SPI.CTRL write");
    bus_write(BASE[2], 32'hDEAD_BE78);  check_all("T2 TIMER.CTRL write");
    bus_write(A_PINMUX,  32'hFFFF_FFFC); check_all("T2 PINMUX upper bits");
    bus_write(A_IRQMASK, 32'hFFFF_FFF8); check_all("T2 IRQ_MASK upper bits");
    sweep("T2 sweep");

    // T3: RO registers ignore writes; no write without bus_req
    for (int b = 0; b < 3; b++) begin
      bus_write(BASE[b] + 8'h4, 32'hFFFF_FFFF);
      bus_write(BASE[b] + 8'h8, 32'hFFFF_FFFF);
    end
    bus_write(A_IRQSTAT, 32'hFFFF_FFFF);
    check_all("T3 RO writes");

    @(negedge clk);
    bus_req = 1'b0; bus_we = 1'b1; bus_addr = BASE[0]; bus_wdata = 32'hFF;
    @(negedge clk);
    bus_we = 1'b0; bus_wdata = '0;
    check_all("T3 we without req");

    // T4: writes to every unmapped address are ignored
    for (int a = 0; a < 256; a++) begin
      if (!is_mapped(8'(a))) begin
        bus_write(8'(a), 32'hFFFF_FFFF);
        check_all($sformatf("T4 after write to 0x%02h", a));
      end
    end
    sweep("T4 sweep");

    // T5: pin mux, outputs and inputs, every mode x every output pattern x every pad_in
    for (int mode = 0; mode < 4; mode++) begin
      bus_write(A_PINMUX, mode);
      for (int outs = 0; outs < 8; outs++) begin
        for (int b = 0; b < 3; b++)
          bus_write(BASE[b], {24'h0, m_ctrl[b][7:1], outs[b]});
        for (int p = 0; p < 4; p++) begin
          set_pads(2'(p));
          check_all($sformatf("T5 mode=%0d outs=%03b pad_in=%02b", mode, outs, p));
        end
      end
    end

    // T6: interrupt wiring, IRQ_STATUS bit order, mask, irq_n, in every mux mode
    set_pads(2'b00);
    for (int mode = 0; mode < 4; mode++) begin
      bus_write(A_PINMUX, mode);
      for (int irqs = 0; irqs < 8; irqs++) begin
        for (int b = 0; b < 3; b++)
          bus_write(BASE[b], {24'h0, m_ctrl[b][7:2], irqs[b], m_ctrl[b][0]});
        for (int mask = 0; mask < 8; mask++) begin
          bus_write(A_IRQMASK, mask);
          check_all($sformatf("T6 mode=%0d irqs=%03b mask=%03b", mode, irqs, mask));
        end
      end
    end

    // T7: reset in the middle of activity returns everything to reset values
    for (int b = 0; b < 3; b++) bus_write(BASE[b], 32'hFF);
    bus_write(A_PINMUX, 2);
    bus_write(A_IRQMASK, 7);
    set_pads(2'b11);
    check_all("T7 before reset");
    do_reset();
    check_all("T7 after reset");
    sweep("T7 sweep");

    // T8: random mix of reads/writes, mapped and unmapped, with pad_in toggling
    for (int i = 0; i < 1000; i++) begin
      logic [7:0]  a;
      logic [31:0] d;
      a = $urandom_range(1) ? MAPPED[$urandom_range(11)] : 8'($urandom());
      if ($urandom_range(3) == 0) set_pads(2'($urandom_range(3)));
      if ($urandom_range(1)) begin
        d = $urandom();
        bus_write(a, d);
        check_all($sformatf("T8 #%0d write 0x%08h to %s", i, d, reg_name(a)));
      end else begin
        check_reg($sformatf("T8 #%0d read", i), a);
        check_pins($sformatf("T8 #%0d", i));
      end
    end

    // ---------------- Summary ----------------
    $display("==================================================");
    $display(" tav_mini_soc integration test summary");
    $display("   checks : %0d", n_checks);
    $display("   errors : %0d", n_errors);
    if (n_errors == 0) $display(" RESULT : PASS");
    else               $display(" RESULT : FAIL");
    $display("==================================================");
    $finish;
  end

  // Watchdog
  initial begin
    #20ms;
    $display("ERROR: watchdog timeout");
    $display(" RESULT : FAIL (timeout, errors so far = %0d)", n_errors);
    $finish;
  end

endmodule

// ---------------------------------------------------------------------------
// Top: runs the AI test and plants the bug without editing it
// ---------------------------------------------------------------------------
module tav_ai_top;
  int BUG = 0;
  tb_tav_mini_soc u_ai ();
  initial begin
    void'($value$plusargs("BUG=%d", BUG));
    $display("Running with BUG=%0d", BUG);
    force u_ai.dut.bug = BUG;
  end
endmodule
