// alu_think_demo.sv : turn a spec into checks, then prove them, on a 4-bit ALU
// The Art of Verification | theartofverification.com
//
// Run options (one per run):
//   (none)    the clean design: all 2,048 input combinations checked
//   +BUG=1    SUB sets carry the wrong way round
//   +BUG=2    INC never sets overflow
//   +BUG=3    SHR shifts in a 1 instead of a 0, but only when a == 15
//
// Run on Synopsys VCS X-2025.06-SP1 (EDA Playground), 23 Nov 2026.
//
// Spec (8 operations, 3-bit opcode):
//   000 ADD  r = a + b        carry = unsigned carry out, ovf = signed overflow
//   001 SUB  r = a - b        carry = 1 when a borrow happens (a < b), ovf = signed overflow
//   010 AND  r = a & b        carry = 0, ovf = 0
//   011 OR   r = a | b        carry = 0, ovf = 0
//   100 XOR  r = a ^ b        carry = 0, ovf = 0
//   101 INC  r = a + 1        carry = unsigned carry out, ovf = signed overflow
//   110 SHL  r = a << 1       carry = bit shifted out (a[3]), ovf = 0
//   111 SHR  r = a >> 1       carry = bit shifted out (a[0]), ovf = 0

`timescale 1ns/1ns

int BUG = 0;

// The design
module alu4 (input  logic [3:0] a, b, input logic [2:0] op,
             output logic [3:0] r, output logic carry, ovf);
  logic [4:0] w;
  always_comb begin
    w = '0; r = '0; carry = 0; ovf = 0;
    case (op)
      3'b000: begin w = a + b; r = w[3:0]; carry = w[4];
                    ovf = (a[3] == b[3]) && (r[3] != a[3]); end
      3'b001: begin w = {1'b0, a} - {1'b0, b}; r = w[3:0]; carry = w[4];
                    if (BUG == 1) carry = !carry;                          // BUG=1
                    ovf = (a[3] != b[3]) && (r[3] != a[3]); end
      3'b010: r = a & b;
      3'b011: r = a | b;
      3'b100: r = a ^ b;
      3'b101: begin w = a + 1; r = w[3:0]; carry = w[4];
                    ovf = (a == 4'b0111) && (BUG != 2); end                // BUG=2
      3'b110: begin r = a << 1; carry = a[3]; end
      3'b111: begin r = a >> 1; carry = a[0];
                    if (BUG == 3 && a == 4'hF) r[3] = 1'b1; end            // BUG=3
    endcase
  end
endmodule

// The testbench: a reference model written from the spec, an exhaustive
// sweep, a checker and functional coverage
module alu_tb;
  logic [3:0] a, b, r;
  logic [2:0] op;
  logic carry, ovf;
  int checked, errors;

  alu4 dut (.*);

  // Reference model, written from the spec table above, not from the RTL
  function automatic void model(input logic [3:0] a, b, input logic [2:0] op,
                                output logic [3:0] er, output logic ec, eo);
    int s;
    ec = 0; eo = 0;
    case (op)
      3'b000: begin s = a + b; er = s[3:0]; ec = (s > 15);
                    eo = ($signed(a) + $signed(b) > 7) || ($signed(a) + $signed(b) < -8); end
      3'b001: begin er = a - b; ec = (a < b);
                    eo = ($signed(a) - $signed(b) > 7) || ($signed(a) - $signed(b) < -8); end
      3'b010: er = a & b;
      3'b011: er = a | b;
      3'b100: er = a ^ b;
      3'b101: begin s = a + 1; er = s[3:0]; ec = (s > 15); eo = ($signed(a) == 7); end
      3'b110: begin er = a << 1; ec = a[3]; end
      3'b111: begin er = a >> 1; ec = a[0]; end
    endcase
  endfunction

  // Coverage: every opcode against the operand corners the scenario list names
  covergroup cg;
    cp_op: coverpoint op;
    cp_a:  coverpoint a { bins zero = {0}; bins max = {15}; bins sign = {8};
                          bins pos_max = {7}; bins other = default; }
    cp_c:  coverpoint carry;
    cp_v:  coverpoint ovf;
    x_op_a: cross cp_op, cp_a;
  endgroup
  cg cov = new();

  initial begin
    logic [3:0] er; logic ec, eo;
    void'($value$plusargs("BUG=%d", BUG));
    $display("Running with BUG=%0d", BUG);
    for (int o = 0; o < 8; o++)
      for (int i = 0; i < 16; i++)
        for (int j = 0; j < 16; j++) begin
          op = o; a = i; b = j;
          #1;
          model(a, b, op, er, ec, eo);
          cov.sample();
          checked++;
          if (r !== er || carry !== ec || ovf !== eo) begin
            errors++;
            if (errors <= 3)
              $display("MISMATCH op=%b a=%0d b=%0d : got r=%0d c=%b v=%b, expected r=%0d c=%b v=%b",
                       op, a, b, r, carry, ovf, er, ec, eo);
          end
        end
    $display("SUMMARY BUG=%0d checked=%0d errors=%0d coverage=%.2f%%",
             BUG, checked, errors, cov.get_coverage());
    $finish;
  end
endmodule
