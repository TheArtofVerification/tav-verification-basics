// tav_riscv_iss_uvm.sv : a tiny RV32I core checked instruction by instruction against an ISS (UVM 1.2)
// Run on Synopsys VCS X-2025.06-SP1 with UVM 1.2 (EDA Playground), 25 Nov 2026.
// The Art of Verification | theartofverification.com
//
// EDA Playground: Synopsys VCS, UVM 1.2, top module "tav_top".
// Paste this whole file into testbench.sv and leave design.sv empty.
//
// The design is a single-cycle core for a subset of RV32I:
//   ADD SUB SLL SLT SLTU XOR SRL SRA OR AND, ADDI SLTI SLTIU XORI ORI ANDI SLLI SRLI SRAI,
//   LUI, LW, SW, BEQ BNE BLT BGE, and ECALL. ECALL, and any encoding outside this
//   subset, stops the core.
// Every cycle it reports what it retired (pc, instruction, register write, memory write,
// next pc). The scoreboard runs an instruction set simulator (ISS) written from the RISC-V
// spec on the same program and compares every retired instruction. This is lock-step
// comparison, the same idea real RISC-V teams use with a golden model.
//
// Phase 1 runs one hand-written program: sum 1 to 10 in a loop, store it, load it back.
// Phase 2 runs 20 random programs of 200 instructions each. The random generator only
// makes forward branches, so every program ends.
// Phase 3 runs 200 one-instruction programs with random bits in every field except the
// opcode, to check that anything outside the subset stops the core.
//
// Run options (one per run):
//   (none)    the clean design
//   +BUG=1    SLT and SLTI compare as unsigned, so -1 < 1 comes out false
//   +BUG=2    a write to x0 is not ignored, so x0 stops reading as zero
//   +BUG=3    the branch offset is not sign-extended, so a backward branch jumps forward
//   +BUG=4    loose decode: encodings outside the subset (LB, SH, a bad funct7 ...) run instead
//             of stopping the core
//
// Memory: 256 instruction words from address 0, 64 data words (loads and stores use x0 as
// the base, so addresses are 0 to 252). Registers and data memory start at zero.

`timescale 1ns/1ns
`include "uvm_macros.svh"
import uvm_pkg::*;

// ---------------------------------------------------------------------------
// The design: a single-cycle RV32I subset core with a retirement (commit) port
// ---------------------------------------------------------------------------
module tav_rv_core (input logic clk, rst_n,
                    input logic iw_en, input logic [7:0] iw_addr, input logic [31:0] iw_data,
                    output logic c_valid, output logic [31:0] c_pc, c_insn,
                    output logic c_rd_we, output logic [4:0] c_rd, output logic [31:0] c_rd_wdata,
                    output logic c_mem_we, output logic [31:0] c_mem_addr, c_mem_wdata,
                    output logic [31:0] c_next_pc, output logic halted, input int bug);
  logic [31:0] imem [256];
  logic [31:0] dmem [64];
  logic [31:0] x [32];
  logic [31:0] pc, insn, a, b, imm_i, imm_s, imm_b, imm_u, wdata, maddr, npc;
  logic [6:0]  opcode, f7;
  logic [4:0]  rd, rs1, rs2;
  logic [2:0]  f3;
  logic        we, mwe, taken, stop, legal;

  always_ff @(posedge clk) if (iw_en) imem[iw_addr] <= iw_data;   // program load port

  always_comb begin
    insn   = imem[pc[9:2]];
    opcode = insn[6:0];  rd = insn[11:7];  f3 = insn[14:12];
    rs1    = insn[19:15]; rs2 = insn[24:20]; f7 = insn[31:25];
    a      = x[rs1];  b = x[rs2];
    imm_i  = {{20{insn[31]}}, insn[31:20]};
    imm_s  = {{20{insn[31]}}, insn[31:25], insn[11:7]};
    imm_b  = {{19{insn[31]}}, insn[31], insn[7], insn[30:25], insn[11:8], 1'b0};
    if (bug == 3) imm_b[31:13] = '0;                    // BUG=3: no sign extension
    imm_u  = {insn[31:12], 12'b0};
    we = 0; wdata = 0; mwe = 0; maddr = 0; taken = 0; stop = 0;
    npc = pc + 4;
    case (opcode)
      7'b0110011: begin                                  // register-register
        we = 1;
        case (f3)
          3'd0: wdata = f7[5] ? a - b : a + b;
          3'd1: wdata = a << b[4:0];
          3'd2: wdata = (bug == 1) ? 32'(a < b) : 32'($signed(a) < $signed(b));   // BUG=1
          3'd3: wdata = 32'(a < b);
          3'd4: wdata = a ^ b;
          3'd5: if (f7[5]) wdata = $signed(a) >>> b[4:0]; else wdata = a >> b[4:0];
          3'd6: wdata = a | b;
          3'd7: wdata = a & b;
        endcase
      end
      7'b0010011: begin                                  // register-immediate
        we = 1;
        case (f3)
          3'd0: wdata = a + imm_i;
          3'd1: wdata = a << insn[24:20];
          3'd2: wdata = (bug == 1) ? 32'(a < imm_i) : 32'($signed(a) < $signed(imm_i));   // BUG=1
          3'd3: wdata = 32'(a < imm_i);
          3'd4: wdata = a ^ imm_i;
          3'd5: if (insn[30]) wdata = $signed(a) >>> insn[24:20]; else wdata = a >> insn[24:20];
          3'd6: wdata = a | imm_i;
          3'd7: wdata = a & imm_i;
        endcase
      end
      7'b0110111: begin we = 1; wdata = imm_u; end      // LUI
      7'b0000011: begin we = 1; maddr = a + imm_i; wdata = dmem[maddr[7:2]]; end   // LW
      7'b0100011: begin mwe = 1; maddr = a + imm_s; end  // SW
      7'b1100011: begin                                  // branches
        case (f3)
          3'd0: taken = (a == b);
          3'd1: taken = (a != b);
          3'd4: taken = ($signed(a) < $signed(b));
          3'd5: taken = ($signed(a) >= $signed(b));
          default: stop = 1;
        endcase
        if (taken) npc = pc + imm_b;
      end
      default: stop = 1;                                 // ECALL, or anything not supported
    endcase
    // only the encodings in the subset may run; any other funct3 or funct7 stops the core
    case (opcode)
      7'b0110011:             legal = (f7 == 7'h00) || (f7 == 7'h20 && (f3 == 3'd0 || f3 == 3'd5));
      7'b0010011:             legal = (f3 == 3'd1) ? (f7 == 7'h00) :
                                      (f3 == 3'd5) ? (f7 == 7'h00 || f7 == 7'h20) : 1'b1;
      7'b0000011, 7'b0100011: legal = (f3 == 3'd2);
      default:                legal = 1'b1;
    endcase
    if (!legal && bug != 4) begin                        // BUG=4: loose decode
      we = 0; mwe = 0; npc = pc + 4; stop = 1;
    end
  end

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      pc <= 0; halted <= 0;
      foreach (x[i])    x[i]    <= 0;
      foreach (dmem[i]) dmem[i] <= 0;
    end else if (!halted) begin
      if (we && (rd != 0 || bug == 2)) x[rd] <= wdata;  // BUG=2: x0 gets written
      if (mwe) dmem[maddr[7:2]] <= b;
      pc <= npc;
      if (stop) halted <= 1;
    end

  // what this cycle retires
  assign c_valid     = rst_n && !halted;
  assign c_pc        = pc;
  assign c_insn      = insn;
  assign c_rd_we     = we && (rd != 0 || bug == 2);
  assign c_rd        = rd;
  assign c_rd_wdata  = wdata;
  assign c_mem_we    = mwe;
  assign c_mem_addr  = maddr;
  assign c_mem_wdata = b;
  assign c_next_pc   = npc;
endmodule

// ---------------------------------------------------------------------------
// Interface
// ---------------------------------------------------------------------------
interface tav_rv_if (input logic clk);
  logic        rst_n, iw_en;
  logic [7:0]  iw_addr;
  logic [31:0] iw_data;
  logic        c_valid, c_rd_we, c_mem_we, halted;
  logic [4:0]  c_rd;
  logic [31:0] c_pc, c_insn, c_rd_wdata, c_mem_addr, c_mem_wdata, c_next_pc;
  clocking mon_cb @(posedge clk);
    default input #1step;
    input c_valid, c_pc, c_insn, c_rd_we, c_rd, c_rd_wdata, c_mem_we, c_mem_addr, c_mem_wdata, c_next_pc;
  endclocking
endinterface

// ---------------------------------------------------------------------------
// Encoders: turn an instruction into its 32-bit RV32I encoding
// ---------------------------------------------------------------------------
class tav_rv_asm;
  static function bit [31:0] r(bit [6:0] f7, bit [4:0] rs2, rs1, bit [2:0] f3, bit [4:0] rd);
    return {f7, rs2, rs1, f3, rd, 7'b0110011};
  endfunction
  static function bit [31:0] i(bit [6:0] op, int imm, bit [4:0] rs1, bit [2:0] f3, bit [4:0] rd);
    bit [11:0] im = imm;
    return {im, rs1, f3, rd, op};
  endfunction
  static function bit [31:0] s(int imm, bit [4:0] rs2, rs1);
    bit [11:0] im = imm;
    return {im[11:5], rs2, rs1, 3'b010, im[4:0], 7'b0100011};
  endfunction
  static function bit [31:0] br(bit [2:0] f3, bit [4:0] rs1, rs2, int off);
    bit [12:0] im = off;
    return {im[12], im[10:5], rs2, rs1, f3, im[4:1], im[11], 7'b1100011};
  endfunction
  static function bit [31:0] lui(bit [4:0] rd, bit [19:0] imm);
    return {imm, rd, 7'b0110111};
  endfunction
  static function bit [31:0] ecall();
    return 32'h0000_0073;
  endfunction
endclass

// ---------------------------------------------------------------------------
// Transactions
// ---------------------------------------------------------------------------
class tav_rv_prog extends uvm_sequence_item;          // one program to run
  bit [31:0] code[$];
  string     name;
  int        phase;
  bit        is_end, timed_out;                        // set by the driver when it finishes
  `uvm_object_utils(tav_rv_prog)
  function new(string name = "tav_rv_prog");
    super.new(name);
  endfunction
endclass

class tav_rv_commit extends uvm_object;               // one retired instruction
  bit [31:0] pc, insn, rd_wdata, mem_addr, mem_wdata, next_pc;
  bit [4:0]  rd;
  bit        rd_we, mem_we;
  `uvm_object_utils(tav_rv_commit)
  function new(string name = "tav_rv_commit");
    super.new(name);
  endfunction
  function string show();
    string s = $sformatf("pc=%08h insn=%08h", pc, insn);
    if (rd_we)  s = {s, $sformatf(" x%0d<=%08h", rd, rd_wdata)};
    if (mem_we) s = {s, $sformatf(" mem[%08h]<=%08h", mem_addr, mem_wdata)};
    return {s, $sformatf(" next_pc=%08h", next_pc)};
  endfunction
endclass

// ---------------------------------------------------------------------------
// The ISS: the golden model, written from the RISC-V spec, one instruction at a time
// ---------------------------------------------------------------------------
class tav_rv_iss;
  bit [31:0] x[32], mem[64], prog[$], pc;
  bit        halted;
  // what it saw, for the REACH report
  int n_slt_neg, n_x0_dest, n_back_taken, n_fwd_taken, n_outside;

  function void load(bit [31:0] code[$]);
    prog = code; pc = 0; halted = 0;
    foreach (x[k])   x[k]   = 0;
    foreach (mem[k]) mem[k] = 0;
  endfunction

  function int sx(bit [31:0] v, int bits);             // sign-extend the low "bits" bits
    return int'(v << (32 - bits)) >>> (32 - bits);
  endfunction

  function tav_rv_commit step();
    tav_rv_commit c = new("exp");
    bit [31:0] in = (pc[31:2] < prog.size()) ? prog[pc[31:2]] : 32'h0;
    bit [6:0] op = in[6:0];
    bit [4:0] rd = in[11:7], rs1 = in[19:15], rs2 = in[24:20];
    bit [2:0] f3 = in[14:12];
    int  sa = x[rs1], sb = x[rs2];                     // signed views
    bit [31:0] ua = x[rs1], ub = x[rs2];               // unsigned views
    int  imm;
    bit [31:0] res, uimm;
    bit  wr = 0, ok = 1;
    c.pc = pc; c.insn = in; c.next_pc = pc + 4;
    // the subset: any other funct3 or funct7 is outside it and stops the model
    case (op)
      7'h33:        ok = (in[31:25] == 0) || (in[31:25] == 7'h20 && (f3 == 0 || f3 == 5));
      7'h13:        if (f3 == 1) ok = (in[31:25] == 0);
                    else if (f3 == 5) ok = (in[31:25] == 0 || in[31:25] == 7'h20);
      7'h03, 7'h23: ok = (f3 == 2);
    endcase
    if (!ok) begin halted = 1; n_outside++; return c; end
    case (op)
      7'h33: begin
        wr = 1;
        case (f3)
          0: res = in[30] ? ua - ub : ua + ub;
          1: res = ua << ub[4:0];
          2: begin res = (sa < sb); if (sa < 0 || sb < 0) n_slt_neg++; end
          3: res = (ua < ub);
          4: res = ua ^ ub;
          5: if (in[30]) res = sa >>> ub[4:0]; else res = ua >> ub[4:0];
          6: res = ua | ub;
          7: res = ua & ub;
        endcase
      end
      7'h13: begin
        wr = 1; imm = sx(in[31:20], 12);
        case (f3)
          0: res = sa + imm;
          1: res = ua << in[24:20];
          2: begin res = (sa < imm); if (sa < 0 || imm < 0) n_slt_neg++; end
          3: begin uimm = imm; res = (ua < uimm); end
          4: res = ua ^ imm;
          5: if (in[30]) res = sa >>> in[24:20]; else res = ua >> in[24:20];
          6: res = ua | imm;
          7: res = ua & imm;
        endcase
      end
      7'h37: begin wr = 1; res = {in[31:12], 12'b0}; end
      7'h03: begin wr = 1; imm = sx(in[31:20], 12); res = mem[((sa + imm) >> 2) & 63]; end
      7'h23: begin
        imm = sx({in[31:25], in[11:7]}, 12);
        c.mem_we = 1; c.mem_addr = sa + imm; c.mem_wdata = ub;
        mem[(c.mem_addr >> 2) & 63] = ub;
      end
      7'h63: begin
        bit t;
        imm = sx({in[31], in[7], in[30:25], in[11:8], 1'b0}, 13);
        case (f3)
          0: t = (ua == ub);
          1: t = (ua != ub);
          4: t = (sa < sb);
          5: t = (sa >= sb);
          default: halted = 1;
        endcase
        if (t) begin
          c.next_pc = pc + imm;
          if (imm < 0) n_back_taken++; else n_fwd_taken++;
        end
      end
      default: halted = 1;                              // ECALL ends the program
    endcase
    if (wr && rd == 0) n_x0_dest++;
    if (wr && rd != 0) begin x[rd] = res; c.rd_we = 1; c.rd = rd; c.rd_wdata = res; end
    if (!halted) pc = c.next_pc;
    return c;
  endfunction
endclass

// ---------------------------------------------------------------------------
// Sequences: one hand-written program, then random programs
// ---------------------------------------------------------------------------
class tav_directed_seq extends uvm_sequence #(tav_rv_prog);
  `uvm_object_utils(tav_directed_seq)
  function new(string name = "tav_directed_seq");
    super.new(name);
  endfunction
  task body();
    req = tav_rv_prog::type_id::create("req");
    start_item(req);
    req.name = "sum 1 to 10"; req.phase = 1;
    req.code = '{ tav_rv_asm::i(7'h13, 10, 0, 0, 1),     //  0: addi x1, x0, 10
                  tav_rv_asm::i(7'h13, 0, 0, 0, 2),      //  4: addi x2, x0, 0
                  tav_rv_asm::r(0, 1, 2, 0, 2),          //  8: add  x2, x2, x1
                  tav_rv_asm::i(7'h13, -1, 1, 0, 1),     // 12: addi x1, x1, -1
                  tav_rv_asm::br(1, 1, 0, -8),           // 16: bne  x1, x0, 8 (back)
                  tav_rv_asm::s(0, 2, 0),                // 20: sw   x2, 0(x0)
                  tav_rv_asm::i(7'h03, 0, 0, 2, 3),      // 24: lw   x3, 0(x0)
                  tav_rv_asm::i(7'h13, -55, 3, 0, 4),    // 28: addi x4, x3, -55
                  tav_rv_asm::ecall() };                 // 32: ecall
    finish_item(req);
  endtask
endclass

class tav_random_seq extends uvm_sequence #(tav_rv_prog);
  `uvm_object_utils(tav_random_seq)
  int n_progs = 20, n_insns = 200;
  function new(string name = "tav_random_seq");
    super.new(name);
  endfunction

  // one random instruction at position k of n; registers x0 to x7 so results get reused
  function bit [31:0] one(int k, int n);
    bit [4:0] rd = $urandom_range(7), rs1 = $urandom_range(7), rs2 = $urandom_range(7);
    int pick = $urandom_range(99);
    if (pick < 30) begin                                 // register-register
      bit [2:0] f3 = $urandom_range(7);
      bit [6:0] f7 = ((f3 == 0 || f3 == 5) && $urandom_range(1)) ? 7'h20 : 7'h00;
      return tav_rv_asm::r(f7, rs2, rs1, f3, rd);
    end else if (pick < 55) begin                        // register-immediate
      bit [2:0] f3 = $urandom_range(7);
      int imm = $urandom_range(4095) - 2048;
      if (f3 == 1 || f3 == 5) imm = $urandom_range(31) | (($urandom_range(1) && f3 == 5) ? 32'h400 : 0);
      return tav_rv_asm::i(7'h13, imm, rs1, f3, rd);
    end else if (pick < 65) begin                        // LUI: big and negative values
      return tav_rv_asm::lui(rd, $urandom());
    end else if (pick < 75) begin                        // LW, base x0
      return tav_rv_asm::i(7'h03, 4 * $urandom_range(63), 0, 2, rd);
    end else if (pick < 85) begin                        // SW, base x0
      return tav_rv_asm::s(4 * $urandom_range(63), rs2, 0);
    end else begin                                       // forward branch, stays inside the program
      bit [2:0] f3s[4] = '{0, 1, 4, 5};
      int room = n - k;                                  // instructions left, counting the ecall
      int skip = $urandom_range((room < 8) ? room : 8, 1);
      return tav_rv_asm::br(f3s[$urandom_range(3)], rs1, rs2, 4 * skip);
    end
  endfunction

  task body();
    for (int p = 0; p < n_progs; p++) begin
      req = tav_rv_prog::type_id::create("req");
      start_item(req);
      req.name = $sformatf("random %0d", p + 1); req.phase = 2;
      for (int k = 0; k < n_insns; k++) req.code.push_back(one(k, n_insns));
      req.code.push_back(tav_rv_asm::ecall());
      finish_item(req);
    end
  endtask
endclass

class tav_outside_seq extends uvm_sequence #(tav_rv_prog);
  `uvm_object_utils(tav_outside_seq)
  int n_progs = 200;
  function new(string name = "tav_outside_seq");
    super.new(name);
  endfunction
  task body();
    bit [6:0] ops[6] = '{7'h33, 7'h13, 7'h37, 7'h03, 7'h23, 7'h73};   // branches left out
    for (int p = 0; p < n_progs; p++) begin
      bit [31:0] w = $urandom();
      w[6:0] = ops[$urandom_range(5)];
      req = tav_rv_prog::type_id::create("req");
      start_item(req);
      req.name = $sformatf("one-instruction %0d (%08h)", p + 1, w); req.phase = 3;
      req.code = '{ tav_rv_asm::i(7'h13, 1, 0, 0, 1),     // addi x1, x0, 1
                    tav_rv_asm::i(7'h13, -1, 0, 0, 2),    // addi x2, x0, -1
                    w,
                    tav_rv_asm::ecall() };
      finish_item(req);
    end
  endtask
endclass

// ---------------------------------------------------------------------------
// Driver: reset, load the program, release reset, wait for the core to stop
// ---------------------------------------------------------------------------
class tav_rv_driver extends uvm_driver #(tav_rv_prog);
  `uvm_component_utils(tav_rv_driver)
  virtual tav_rv_if vif;
  uvm_analysis_port #(tav_rv_prog) ap;                 // tells the scoreboard: start, end
  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction
  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(virtual tav_rv_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "no virtual interface")
  endfunction
  task run_phase(uvm_phase phase);
    vif.rst_n <= 0; vif.iw_en <= 0;
    forever begin
      tav_rv_prog done;
      int cycles = 0, limit;
      seq_item_port.get_next_item(req);
      @(negedge vif.clk);
      vif.rst_n <= 0;
      for (int k = 0; k < 256; k++) begin
        @(negedge vif.clk);
        vif.iw_en <= 1; vif.iw_addr <= k; vif.iw_data <= (k < req.code.size()) ? req.code[k] : 32'h0;
      end
      @(negedge vif.clk);
      vif.iw_en <= 0;
      ap.write(req);                                     // start
      @(negedge vif.clk);
      vif.rst_n <= 1;
      limit = 4 * req.code.size() + 50;
      while (!vif.halted && cycles < limit) begin @(negedge vif.clk); cycles++; end
      done = tav_rv_prog::type_id::create("done");
      done.name = req.name; done.phase = req.phase; done.is_end = 1; done.timed_out = !vif.halted;
      ap.write(done);                                    // end
      seq_item_port.item_done();
    end
  endtask
endclass

// ---------------------------------------------------------------------------
// Monitor: one commit per retired instruction
// ---------------------------------------------------------------------------
class tav_rv_monitor extends uvm_monitor;
  `uvm_component_utils(tav_rv_monitor)
  virtual tav_rv_if vif;
  uvm_analysis_port #(tav_rv_commit) ap;
  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction
  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(virtual tav_rv_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "no virtual interface")
  endfunction
  task run_phase(uvm_phase phase);
    forever begin
      @(vif.mon_cb);
      if (vif.mon_cb.c_valid === 1'b1) begin
        tav_rv_commit c = tav_rv_commit::type_id::create("c");
        c.pc = vif.mon_cb.c_pc; c.insn = vif.mon_cb.c_insn; c.next_pc = vif.mon_cb.c_next_pc;
        c.rd_we = vif.mon_cb.c_rd_we;
        if (c.rd_we) begin c.rd = vif.mon_cb.c_rd; c.rd_wdata = vif.mon_cb.c_rd_wdata; end
        c.mem_we = vif.mon_cb.c_mem_we;
        if (c.mem_we) begin c.mem_addr = vif.mon_cb.c_mem_addr; c.mem_wdata = vif.mon_cb.c_mem_wdata; end
        ap.write(c);
      end
    end
  endtask
endclass

// ---------------------------------------------------------------------------
// Scoreboard: lock-step compare of every retired instruction against the ISS
// ---------------------------------------------------------------------------
`uvm_analysis_imp_decl(_prog)
`uvm_analysis_imp_decl(_commit)
class tav_rv_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(tav_rv_scoreboard)
  uvm_analysis_imp_prog   #(tav_rv_prog,   tav_rv_scoreboard) prog_imp;
  uvm_analysis_imp_commit #(tav_rv_commit, tav_rv_scoreboard) commit_imp;
  tav_rv_iss iss = new();
  string cur;
  int    cur_phase, retired, shown;
  bit    failed;
  int    progs[4], fails[4], compared[4];
  int    p1[4];                                       // REACH counts at the end of phase 1

  function new(string name, uvm_component parent);
    super.new(name, parent);
    prog_imp = new("prog_imp", this);
    commit_imp = new("commit_imp", this);
  endfunction

  function void fail(string why);
    failed = 1;
    if (shown < 3) begin
      shown++;
      `uvm_error("MISMATCH", $sformatf("%s, instruction %0d: %s", cur, retired, why))
    end
  endfunction

  function void write_prog(tav_rv_prog p);
    if (!p.is_end) begin
      iss.load(p.code); cur = p.name; cur_phase = p.phase; retired = 0; failed = 0;
      return;
    end
    progs[p.phase]++;
    if (!failed && p.timed_out) fail("core did not stop");
    else if (!failed && !iss.halted) fail("core stopped before the ISS did");
    if (failed) fails[p.phase]++;
    if (p.phase == 1) p1 = '{iss.n_slt_neg, iss.n_x0_dest, iss.n_fwd_taken, iss.n_back_taken};
  endfunction

  function void write_commit(tav_rv_commit got);
    tav_rv_commit exp;
    if (failed) return;                                 // after the first mismatch the states differ
    if (iss.halted) begin fail({"core kept going after the ISS stopped: ", got.show()}); return; end
    exp = iss.step();
    retired++; compared[cur_phase]++;
    if (got.pc !== exp.pc || got.insn !== exp.insn || got.next_pc !== exp.next_pc ||
        got.rd_we !== exp.rd_we || got.rd !== exp.rd || got.rd_wdata !== exp.rd_wdata ||
        got.mem_we !== exp.mem_we || got.mem_addr !== exp.mem_addr || got.mem_wdata !== exp.mem_wdata)
      fail($sformatf("core %s | ISS %s", got.show(), exp.show()));
  endfunction

  function void tav_print_results();
    `uvm_info("RESULT", $sformatf("Phase 1 directed: programs=%0d failed=%0d instructions compared=%0d -> %s",
              progs[1], fails[1], compared[1], fails[1] == 0 ? "PASS" : "FAIL"), UVM_NONE)
    `uvm_info("RESULT", $sformatf("Phase 2 random:   programs=%0d failed=%0d instructions compared=%0d -> %s",
              progs[2], fails[2], compared[2], fails[2] == 0 ? "PASS" : "FAIL"), UVM_NONE)
    `uvm_info("RESULT", $sformatf("Phase 3 encodings: programs=%0d failed=%0d instructions compared=%0d -> %s",
              progs[3], fails[3], compared[3], fails[3] == 0 ? "PASS" : "FAIL"), UVM_NONE)
    `uvm_info("REACH", $sformatf("Phase 1: SLT/SLTI with a negative operand=%0d, results aimed at x0=%0d, branches taken forward=%0d, backward=%0d",
              p1[0], p1[1], p1[2], p1[3]), UVM_NONE)
    `uvm_info("REACH", $sformatf("Phase 2: SLT/SLTI with a negative operand=%0d, results aimed at x0=%0d, branches taken forward=%0d, backward=%0d",
              iss.n_slt_neg - p1[0], iss.n_x0_dest - p1[1], iss.n_fwd_taken - p1[2], iss.n_back_taken - p1[3]), UVM_NONE)
    `uvm_info("REACH", $sformatf("Phase 3: encodings outside the subset=%0d of %0d", iss.n_outside, progs[3]), UVM_NONE)
  endfunction
endclass

// ---------------------------------------------------------------------------
// Agent, environment, test
// ---------------------------------------------------------------------------
class tav_rv_env extends uvm_env;
  `uvm_component_utils(tav_rv_env)
  uvm_sequencer #(tav_rv_prog) sqr;
  tav_rv_driver     drv;
  tav_rv_monitor    mon;
  tav_rv_scoreboard scb;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    sqr = uvm_sequencer#(tav_rv_prog)::type_id::create("sqr", this);
    drv = tav_rv_driver::type_id::create("drv", this);
    mon = tav_rv_monitor::type_id::create("mon", this);
    scb = tav_rv_scoreboard::type_id::create("scb", this);
  endfunction
  function void connect_phase(uvm_phase phase);
    drv.seq_item_port.connect(sqr.seq_item_export);
    drv.ap.connect(scb.prog_imp);
    mon.ap.connect(scb.commit_imp);
  endfunction
endclass

class tav_riscv_test extends uvm_test;
  `uvm_component_utils(tav_riscv_test)
  tav_rv_env env;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    env = tav_rv_env::type_id::create("env", this);
  endfunction
  task run_phase(uvm_phase phase);
    tav_directed_seq d = tav_directed_seq::type_id::create("d");
    tav_random_seq   r = tav_random_seq::type_id::create("r");
    tav_outside_seq  o = tav_outside_seq::type_id::create("o");
    phase.raise_objection(this);
    d.start(env.sqr);
    r.start(env.sqr);
    o.start(env.sqr);
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

  tav_rv_if vif (clk);
  tav_rv_core u_core (.clk(clk), .rst_n(vif.rst_n),
                      .iw_en(vif.iw_en), .iw_addr(vif.iw_addr), .iw_data(vif.iw_data),
                      .c_valid(vif.c_valid), .c_pc(vif.c_pc), .c_insn(vif.c_insn),
                      .c_rd_we(vif.c_rd_we), .c_rd(vif.c_rd), .c_rd_wdata(vif.c_rd_wdata),
                      .c_mem_we(vif.c_mem_we), .c_mem_addr(vif.c_mem_addr), .c_mem_wdata(vif.c_mem_wdata),
                      .c_next_pc(vif.c_next_pc), .halted(vif.halted), .bug(BUG));

  initial begin
    void'($value$plusargs("BUG=%d", BUG));
    `uvm_info("TOP", $sformatf("Running with BUG=%0d", BUG), UVM_NONE)
    uvm_config_db#(virtual tav_rv_if)::set(null, "uvm_test_top.env.*", "vif", vif);
    run_test("tav_riscv_test");
  end
endmodule
