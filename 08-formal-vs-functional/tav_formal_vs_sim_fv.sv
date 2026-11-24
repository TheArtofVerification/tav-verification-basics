// tav_formal_vs_sim_fv.sv : formal harness for tav_mutex_arb (open-source Yosys + yosys-smtbmc)
// Run on Yosys 0.33, yosys-smtbmc and Z3 4.8.12, 24 Nov 2026.
// The Art of Verification | theartofverification.com
//
// This is a formal harness, not a simulation testbench: run it with Yosys, not VCS.
// It carries its own copy of tav_mutex_arb, identical to the one in tav_formal_vs_sim_uvm.sv.
// Run (Yosys 0.33, Z3), with BUG = 0, 1 or 2:
//   yosys -q -p "read_verilog -sv -formal tav_formal_vs_sim_fv.sv; \
//                chparam -set BUG 1 tav_fv_top; prep -top tav_fv_top; async2sync; dffunmap; \
//                write_smt2 -wires arb.smt2"
//   yosys-smtbmc -s z3 -t 20 --dump-vcd cex.vcd arb.smt2      (bounded check, 20 cycles)
//   yosys-smtbmc -s z3 -i -t 20 arb.smt2                      (induction: a full proof)
// The tool chooses req, cfg_wr and cfg_data freely on every cycle. Reset is held for cycle 0.

module tav_mutex_arb (input  logic       clk, rst_n,
                      input  logic [1:0] req,
                      input  logic       cfg_wr,
                      input  logic [3:0] cfg_data,
                      output logic [1:0] gnt,
                      input  int         bug);
  // Debug mode unlocks after six config writes in a row: A 5 C 3 F 0
  logic [2:0] step;
  logic       debug_mode;
  logic       last;          // which requester won last time
  logic [3:0] magic;
  always_comb case (step)
    3'd0: magic = 4'hA; 3'd1: magic = 4'h5; 3'd2: magic = 4'hC;
    3'd3: magic = 4'h3; 3'd4: magic = 4'hF; default: magic = 4'h0;
  endcase
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      step <= 0; debug_mode <= 0; last <= 1; gnt <= 0;
    end else begin
      if (cfg_wr && !debug_mode) begin
        if (cfg_data == magic) begin
          if (step == 3'd5) debug_mode <= 1; else step <= step + 1;
        end else step <= (cfg_data == 4'hA) ? 3'd1 : 3'd0;
      end
      if (bug == 1 && debug_mode) gnt <= req;                       // BUG=1
      else if (req == 2'b11) begin
        if (bug == 2 && gnt == 2'b00 && last == 1'b1) gnt <= 2'b11;   // BUG=2
        else begin gnt <= last ? 2'b01 : 2'b10; last <= ~last; end
      end
      else if (req[0]) begin gnt <= 2'b01; last <= 0; end
      else if (req[1]) begin gnt <= 2'b10; last <= 1; end
      else gnt <= 2'b00;
    end
  end
endmodule

module tav_fv_top #(parameter int BUG = 0)
  (input logic clk, input logic [1:0] req, input logic cfg_wr, input logic [3:0] cfg_data);
  logic rst_n;
  logic [1:0] gnt;
  reg init = 1;
  always @(posedge clk) init <= 0;
  assign rst_n = !init;
  tav_mutex_arb dut (.clk(clk), .rst_n(rst_n), .req(req), .cfg_wr(cfg_wr), .cfg_data(cfg_data),
                     .gnt(gnt), .bug(BUG));
  // the same rule as A_MUTEX in the UVM bench: never grant both
  always @(posedge clk) if (!init) assert (gnt != 2'b11);

`ifndef FORMAL
  // Yosys defines FORMAL for read_verilog -formal. Any simulator lands here instead.
  initial $fatal(1, "tav_formal_vs_sim_fv.sv is a formal harness: run it with Yosys and yosys-smtbmc (see the header), not in a simulator. For VCS, use tav_formal_vs_sim_uvm.sv.");
`endif
endmodule
