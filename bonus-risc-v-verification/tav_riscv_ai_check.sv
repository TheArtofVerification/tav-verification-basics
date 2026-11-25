// tav_riscv_ai_check.sv : my first ISS, my fixed ISS and an AI-written ISS, compared on the same stimulus
// Run on Synopsys VCS X-2025.06-SP1 (EDA Playground), 25 Nov 2026.
// The Art of Verification | theartofverification.com
//
// EDA Playground: Synopsys VCS, top module "tav_ai_top". UVM not needed.
// Paste this whole file into testbench.sv and leave design.sv empty. No run options.
//
// Three golden models for the same RV32I subset, each in its own package:
//   tav_first_pkg  my first ISS, as it was when the UVM bench first passed
//   tav_fixed_pkg  my ISS after the fix, the one in tav_riscv_iss_uvm.sv
//   tav_ai_pkg     the ISS an AI tool wrote from the spec, exactly as it came back
//                  (the package wrapper is mine; the code inside is not edited, so its
//                  names follow its own style)
// Test A runs 20 random programs (the same generator as the UVM bench) through all three.
// Test B runs 20,000 single instructions: a supported opcode with random bits in every
// other field, after x1 = 1 and x2 = -1. A difference is any field of the retired
// instruction, or the stop decision, that does not match.

`timescale 1ns/1ns

package tav_first_pkg;
class tav_rv_commit;                                  // one retired instruction (no UVM here)
  bit [31:0] pc, insn, rd_wdata, mem_addr, mem_wdata, next_pc;
  bit [4:0]  rd;
  bit        rd_we, mem_we;
  function new(string name = "");
  endfunction
endclass

class tav_rv_iss;
  bit [31:0] x[32], mem[64], prog[$], pc;
  bit        halted;
  // what it saw, for the REACH report
  int n_slt_neg, n_x0_dest, n_back_taken, n_fwd_taken;

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
    bit  wr = 0;
    c.pc = pc; c.insn = in; c.next_pc = pc + 4;
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
endpackage

package tav_fixed_pkg;
class tav_rv_commit;                                  // one retired instruction (no UVM here)
  bit [31:0] pc, insn, rd_wdata, mem_addr, mem_wdata, next_pc;
  bit [4:0]  rd;
  bit        rd_we, mem_we;
  function new(string name = "");
  endfunction
endclass

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

class tav_rv_gen;                                     // the random program generator from the UVM bench
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
endclass
endpackage

package tav_ai_pkg;
// ---------------------------------------------------------------------------
// tav_rv_commit : one retired instruction, as seen by the scoreboard
// ---------------------------------------------------------------------------
class tav_rv_commit;
  bit [31:0] pc, insn, rd_wdata, mem_addr, mem_wdata, next_pc;
  bit [4:0]  rd;
  bit        rd_we, mem_we;
endclass

// ---------------------------------------------------------------------------
// tav_rv_iss : RV32I-subset golden model (ISS) for a UVM scoreboard
// ---------------------------------------------------------------------------
class tav_rv_iss;
  bit [31:0] x[32], mem[64], prog[$], pc;
  bit        halted;

  // Program at address 0, pc = 0, registers and memory cleared
  function void load(bit [31:0] code[$]);
    prog   = code;
    pc     = 32'h0;
    halted = 1'b0;
    foreach (x[i])   x[i]   = 32'h0;
    foreach (mem[i]) mem[i] = 32'h0;
  endfunction

  // Execute the instruction at pc, return what it retired
  function tav_rv_commit step();
    tav_rv_commit c = new();
    int unsigned  idx;
    bit [31:0]    insn, a, b, res, addr;
    bit [31:0]    imm_i, imm_s, imm_b, imm_u;
    bit [6:0]     opcode, funct7;
    bit [2:0]     funct3;
    bit [4:0]     rd, rs1, rs2, shamt;
    bit           wr   = 1'b0;   // instruction writes rd
    bit           take = 1'b0;   // branch taken
    bit           ill  = 1'b0;   // ECALL or unsupported encoding -> halt

    // ---------------- fetch ----------------
    idx  = pc >> 2;
    insn = (idx < prog.size()) ? prog[idx] : 32'h0;

    // ---------------- decode ---------------
    opcode = insn[6:0];
    rd     = insn[11:7];
    funct3 = insn[14:12];
    rs1    = insn[19:15];
    rs2    = insn[24:20];
    funct7 = insn[31:25];
    shamt  = insn[24:20];

    imm_i = {{20{insn[31]}}, insn[31:20]};
    imm_s = {{20{insn[31]}}, insn[31:25], insn[11:7]};
    imm_b = {{19{insn[31]}}, insn[31], insn[7], insn[30:25], insn[11:8], 1'b0};
    imm_u = {insn[31:12], 12'h000};

    a = x[rs1];
    b = x[rs2];

    // ---------------- execute --------------
    case (opcode)
      // R-type ALU
      7'b0110011: begin
        wr = 1'b1;
        case ({funct7, funct3})
          {7'h00, 3'b000}: res = a + b;                                  // ADD
          {7'h20, 3'b000}: res = a - b;                                  // SUB
          {7'h00, 3'b001}: res = a << b[4:0];                            // SLL
          {7'h00, 3'b010}: res = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0; // SLT
          {7'h00, 3'b011}: res = (a < b) ? 32'd1 : 32'd0;                // SLTU
          {7'h00, 3'b100}: res = a ^ b;                                  // XOR
          {7'h00, 3'b101}: res = a >> b[4:0];                            // SRL
          {7'h20, 3'b101}: res = $signed(a) >>> b[4:0];                  // SRA
          {7'h00, 3'b110}: res = a | b;                                  // OR
          {7'h00, 3'b111}: res = a & b;                                  // AND
          default:         ill = 1'b1;
        endcase
      end

      // I-type ALU
      7'b0010011: begin
        wr = 1'b1;
        case (funct3)
          3'b000: res = a + imm_i;                                       // ADDI
          3'b010: res = ($signed(a) < $signed(imm_i)) ? 32'd1 : 32'd0;   // SLTI
          3'b011: res = (a < imm_i) ? 32'd1 : 32'd0;                     // SLTIU
          3'b100: res = a ^ imm_i;                                       // XORI
          3'b110: res = a | imm_i;                                       // ORI
          3'b111: res = a & imm_i;                                       // ANDI
          3'b001: begin                                                  // SLLI
            if (funct7 == 7'h00) res = a << shamt;
            else                 ill = 1'b1;
          end
          3'b101: begin                                                  // SRLI / SRAI
            if      (funct7 == 7'h00) res = a >> shamt;
            else if (funct7 == 7'h20) res = $signed(a) >>> shamt;
            else                      ill = 1'b1;
          end
        endcase
      end

      // LUI
      7'b0110111: begin
        wr  = 1'b1;
        res = imm_u;
      end

      // LW
      7'b0000011: begin
        if (funct3 == 3'b010) begin
          wr   = 1'b1;
          addr = a + imm_i;
          res  = mem[(addr >> 2) & 63];
        end
        else ill = 1'b1;
      end

      // SW
      7'b0100011: begin
        if (funct3 == 3'b010) begin
          addr                  = a + imm_s;
          mem[(addr >> 2) & 63] = b;
          c.mem_we              = 1'b1;
          c.mem_addr            = addr;
          c.mem_wdata           = b;
        end
        else ill = 1'b1;
      end

      // Branches
      7'b1100011: begin
        case (funct3)
          3'b000:  take = (a == b);                                      // BEQ
          3'b001:  take = (a != b);                                      // BNE
          3'b100:  take = ($signed(a) <  $signed(b));                    // BLT
          3'b101:  take = ($signed(a) >= $signed(b));                    // BGE
          default: ill  = 1'b1;
        endcase
      end

      // ECALL (32'h00000073) and every other encoding
      default: ill = 1'b1;
    endcase

    // ---------------- retire ---------------
    c.pc   = pc;
    c.insn = insn;

    if (ill) begin
      // Halt: no register write, no memory write, pc not advanced
      halted    = 1'b1;
      c.next_pc = pc + 32'd4;
      return c;
    end

    if (wr && rd != 5'd0) begin
      x[rd]      = res;
      c.rd_we    = 1'b1;
      c.rd       = rd;
      c.rd_wdata = res;
    end
    x[0] = 32'h0;

    c.next_pc = take ? (pc + imm_b) : (pc + 32'd4);
    pc        = c.next_pc;
    return c;
  endfunction
endclass
endpackage

module tav_ai_top;
  // compare two retired instructions and the stop decision
  function automatic bit tav_same(bit [31:0] p1, i1, w1d, ma1, mw1, n1, bit [4:0] r1, bit w1, m1, h1,
                                  bit [31:0] p2, i2, w2d, ma2, mw2, n2, bit [4:0] r2, bit w2, m2, h2);
    return p1 == p2 && i1 == i2 && n1 == n2 && w1 == w2 && r1 == r2 && w1d == w2d &&
           m1 == m2 && ma1 == ma2 && mw1 == mw2 && h1 == h2;
  endfunction

  initial begin
    tav_first_pkg::tav_rv_iss f = new();
    tav_fixed_pkg::tav_rv_iss x = new();
    tav_ai_pkg::tav_rv_iss    a = new();
    tav_fixed_pkg::tav_rv_gen g = new();
    bit [31:0] q[$];
    bit [6:0]  ops[6] = '{7'h33, 7'h13, 7'h37, 7'h03, 7'h23, 7'h73};
    int n, d_first_ai, d_fixed_ai, ran_first_stopped_ai, other;
    // Declared once here and assigned in the loops: a variable declared with an initial
    // value inside a loop of a module's initial block is static, so the initial value
    // would be computed only once, at time 0.
    tav_first_pkg::tav_rv_commit cf;
    tav_fixed_pkg::tav_rv_commit cx;
    tav_ai_pkg::tav_rv_commit    ca;
    bit [31:0] w;

    // Test A: valid random programs
    n = 0; d_first_ai = 0; d_fixed_ai = 0;
    for (int p = 0; p < 20; p++) begin
      q.delete();
      for (int k = 0; k < 200; k++) q.push_back(g.one(k, 200));
      q.push_back(tav_fixed_pkg::tav_rv_asm::ecall());
      f.load(q); x.load(q); a.load(q);
      while (!x.halted) begin
        cf = f.step();
        cx = x.step();
        ca = a.step();
        n++;
        if (!tav_same(cf.pc, cf.insn, cf.rd_wdata, cf.mem_addr, cf.mem_wdata, cf.next_pc, cf.rd, cf.rd_we, cf.mem_we, f.halted,
                      ca.pc, ca.insn, ca.rd_wdata, ca.mem_addr, ca.mem_wdata, ca.next_pc, ca.rd, ca.rd_we, ca.mem_we, a.halted)) d_first_ai++;
        if (!tav_same(cx.pc, cx.insn, cx.rd_wdata, cx.mem_addr, cx.mem_wdata, cx.next_pc, cx.rd, cx.rd_we, cx.mem_we, x.halted,
                      ca.pc, ca.insn, ca.rd_wdata, ca.mem_addr, ca.mem_wdata, ca.next_pc, ca.rd, ca.rd_we, ca.mem_we, a.halted)) d_fixed_ai++;
      end
    end
    $display("Test A, 20 random programs: instructions=%0d  first vs AI differences=%0d  fixed vs AI differences=%0d",
             n, d_first_ai, d_fixed_ai);

    // Test B: random encodings of the supported opcodes
    n = 0; d_first_ai = 0; d_fixed_ai = 0; ran_first_stopped_ai = 0; other = 0;
    for (int t = 0; t < 20000; t++) begin
      w = $urandom();
      w[6:0] = ops[$urandom_range(5)];
      q = '{tav_fixed_pkg::tav_rv_asm::i(7'h13, 1, 0, 0, 1), tav_fixed_pkg::tav_rv_asm::i(7'h13, -1, 0, 0, 2), w};
      f.load(q); x.load(q); a.load(q);
      repeat (2) begin void'(f.step()); void'(x.step()); void'(a.step()); end
      begin
        cf = f.step();
        cx = x.step();
        ca = a.step();
        n++;
        if (!tav_same(cf.pc, cf.insn, cf.rd_wdata, cf.mem_addr, cf.mem_wdata, cf.next_pc, cf.rd, cf.rd_we, cf.mem_we, f.halted,
                      ca.pc, ca.insn, ca.rd_wdata, ca.mem_addr, ca.mem_wdata, ca.next_pc, ca.rd, ca.rd_we, ca.mem_we, a.halted)) begin
          d_first_ai++;
          if (!f.halted && a.halted) ran_first_stopped_ai++; else other++;
        end
        if (!tav_same(cx.pc, cx.insn, cx.rd_wdata, cx.mem_addr, cx.mem_wdata, cx.next_pc, cx.rd, cx.rd_we, cx.mem_we, x.halted,
                      ca.pc, ca.insn, ca.rd_wdata, ca.mem_addr, ca.mem_wdata, ca.next_pc, ca.rd, ca.rd_we, ca.mem_we, a.halted)) d_fixed_ai++;
      end
    end
    $display("Test B, random encodings: instructions=%0d  first vs AI differences=%0d (first ran it, AI stopped=%0d, other=%0d)  fixed vs AI differences=%0d",
             n, d_first_ai, ran_first_stopped_ai, other, d_fixed_ai);
    $finish;
  end
endmodule
