// tav_clock_ai_check.sv : the AI-written PLL checker, run against the same PLL model (no UVM)
// Run on Synopsys VCS X-2025.06-SP1 (EDA Playground), 25 Nov 2026.
// The Art of Verification | theartofverification.com
//
// EDA Playground: Synopsys VCS, top module "tav_ai_top". UVM not needed.
// Paste this whole file into testbench.sv and leave design.sv empty.
//
// pll_out_checker below is the AI answer exactly as it came back, not edited. That is why
// its names do not start with tav_. The designs are the same as in tav_clock_mult_div_uvm.sv.
// The stimulus follows the same plan: phase 1 holds M = 4 for 300 cycles, phase 2 makes 80
// random changes (M changes in about 3 of 10).
//
// Run options:
//   (none)    the clean PLL model: every error the checker prints here is a false alarm
//   +BUG=3    the lock detector fires 3 reference cycles early: a real bug

`timescale 1ns/1ps

// ---------------------------------------------------------------------------
// The designs (copied from tav_clock_mult_div_uvm.sv)
// ---------------------------------------------------------------------------
module tav_clk_div (input logic ref_clk, rst_n, input logic [3:0] div_n,
                    output logic div_out, input int bug);
  logic [3:0] cnt, cur_n;
  int nn, use_n;
  always_comb begin
    nn    = (div_n < 2) ? 2 : div_n;
    use_n = (bug == 2) ? nn : cur_n;                  // BUG=2: the new ratio is used at once
  end
  always_ff @(posedge ref_clk or negedge rst_n)
    if (!rst_n) begin cnt <= 15; cur_n <= 2; div_out <= 0; end   // so the first edge starts a period
    else if (cnt >= use_n - 1 + ((bug == 1) ? 1 : 0)) begin   // BUG=1: one extra cycle per period
      cnt <= 0; cur_n <= nn; div_out <= 1;           // a new period starts and reads the ratio
    end else begin
      cnt     <= cnt + 1;
      div_out <= (cnt + 1) < ((use_n + 1) / 2);
    end
endmodule

// A PLL is analog. In a testbench it is a behavioural model like this one: it measures the
// reference period, runs an oscillator at ref / M, starts about 25% slow after a change and
// settles over 8 reference cycles, then raises pll_locked.
module tav_pll_model #(parameter int SETTLE = 8)
                     (input logic ref_clk, rst_n, input logic [3:0] pll_m,
                      output logic pll_out, pll_locked, input int bug);
  int      cur_m, mm, settle;
  realtime last_t = -1, tref = 10.0, half = 5.0;

  initial pll_out = 0;
  always #(half) pll_out = ~pll_out;                 // the oscillator

  always @(posedge ref_clk or negedge rst_n)
    if (!rst_n) begin
      cur_m = 1; settle = SETTLE; pll_locked <= 0;
    end else begin
      if (last_t >= 0) tref = $realtime - last_t;    // measure the reference
      last_t = $realtime;
      mm = (pll_m == 0) ? 1 : pll_m;
      if (mm != cur_m) begin cur_m = mm; settle = SETTLE; end
      else if (settle > 0) settle--;
      pll_locked <= (bug == 3) ? (settle <= 3) : (settle == 0);   // BUG=3: lock fires 3 cycles early
      half = tref / (2.0 * cur_m) * (1.0 + settle / 32.0);
    end
endmodule

// ---------------------------------------------------------------------------
// The AI answer, unedited
// ---------------------------------------------------------------------------
// pll_out_checker.sv
// Checks a behavioural PLL: pll_out period = REF_PERIOD / M with 50% duty
// while pll_locked is high, and pll_locked coming back high within 16
// ref_clk cycles after reset or after pll_m changes.

module pll_out_checker #(
  parameter real         REF_PERIOD_NS = 10.0,   // ref_clk period (100 MHz)
  parameter real         TOL_NS        = 0.005,  // +/-5 ps, covers 1 ps rounding of 10/M in the model
  parameter int unsigned LOCK_CYCLES   = 16      // max ref_clk cycles allowed to (re)lock
)(
  input logic       ref_clk,
  input logic       rst_n,
  input logic [3:0] pll_m,
  input logic       pll_out,
  input logic       pll_locked
);

  timeunit      1ns;
  timeprecision 1ps;

  // ------------------------------------------------------------------
  // Counters
  // ------------------------------------------------------------------
  int unsigned n_periods     = 0;  // full periods checked
  int unsigned n_period_err  = 0;  // wrong period
  int unsigned n_duty_err    = 0;  // wrong high time
  int unsigned n_stall_err   = 0;  // clock stopped while locked
  int unsigned n_lock_events = 0;  // reset releases + pll_m changes seen
  int unsigned n_lock_err    = 0;  // lock not regained in time
  int unsigned n_cfg_err     = 0;  // pll_m outside 1..8

  // ------------------------------------------------------------------
  // Measurement state
  // ------------------------------------------------------------------
  realtime last_rise;
  realtime last_edge;
  bit      rise_valid    = 0;  // last_rise was taken while locked with the current M
  bit      stall_flagged = 0;

  // Lock window state
  bit          lock_pending = 0;
  bit          lock_saw_low = 0;
  int unsigned lock_cnt     = 0;
  string       lock_why;

  // ------------------------------------------------------------------
  // Helpers
  // ------------------------------------------------------------------
  function automatic bit m_ok(logic [3:0] m);
    return !$isunknown(m) && (m >= 4'd1) && (m <= 4'd8);
  endfunction

  function automatic real exp_period(logic [3:0] m);
    return REF_PERIOD_NS / real'(m);
  endfunction

  function automatic real absr(real x);
    return (x < 0.0) ? -x : x;
  endfunction

  // Period/duty checks are only active in this state
  function automatic bit checking();
    return (rst_n === 1'b1) && (pll_locked === 1'b1) && m_ok(pll_m);
  endfunction

  initial $timeformat(-9, 3, " ns", 12);

  // ------------------------------------------------------------------
  // Restart period measurement whenever the reference becomes invalid
  // ------------------------------------------------------------------
  always @(negedge rst_n or negedge pll_locked or pll_m) begin
    rise_valid    = 0;
    stall_flagged = 0;
  end

  // Illegal multiply ratio
  always @(pll_m) begin
    if (rst_n === 1'b1 && !m_ok(pll_m)) begin
      n_cfg_err++;
      $error("[PLL_CHK] %t: pll_m = %0d is outside the legal range 1..8", $realtime, pll_m);
    end
  end

  // ------------------------------------------------------------------
  // Period check: rising edge to rising edge
  // ------------------------------------------------------------------
  always @(posedge pll_out) begin
    realtime now, period, expd;
    now           = $realtime;
    last_edge     = now;
    stall_flagged = 0;

    if (pll_out !== 1'b1 || !checking()) begin
      rise_valid = 0;
    end
    else begin
      if (rise_valid) begin
        period = now - last_rise;
        expd   = exp_period(pll_m);
        n_periods++;
        if (absr(period - expd) > TOL_NS) begin
          n_period_err++;
          $error("[PLL_CHK] %t: bad pll_out period %0.4f ns, expected %0.4f ns (M=%0d)",
                 now, period, expd, pll_m);
        end
      end
      last_rise  = now;
      rise_valid = 1;
    end
  end

  // ------------------------------------------------------------------
  // Duty check: rising edge to falling edge = half period
  // (period OK + high time OK  =>  low time OK)
  // ------------------------------------------------------------------
  always @(negedge pll_out) begin
    realtime now, high, expd;
    now           = $realtime;
    last_edge     = now;
    stall_flagged = 0;

    if (pll_out !== 1'b0 || !checking()) begin
      rise_valid = 0;
    end
    else if (rise_valid) begin
      high = now - last_rise;
      expd = exp_period(pll_m) / 2.0;
      if (absr(high - expd) > TOL_NS) begin
        n_duty_err++;
        $error("[PLL_CHK] %t: bad pll_out high time %0.4f ns, expected %0.4f ns (duty %0.1f%%, M=%0d)",
               now, high, expd, 100.0 * high / exp_period(pll_m), pll_m);
      end
    end
  end

  // ------------------------------------------------------------------
  // Stall check: clock stopped while locked (would otherwise go unseen)
  // ------------------------------------------------------------------
  always @(posedge ref_clk) begin
    if (checking() && rise_valid && !stall_flagged &&
        (($realtime - last_edge) > exp_period(pll_m) + TOL_NS)) begin
      stall_flagged = 1;
      n_stall_err++;
      $error("[PLL_CHK] %t: no pll_out edge for %0.4f ns while locked (expected period %0.4f ns, M=%0d)",
             $realtime, $realtime - last_edge, exp_period(pll_m), pll_m);
    end
  end

  // ------------------------------------------------------------------
  // Lock check: after reset release or pll_m change, pll_locked must
  // drop and come back high within LOCK_CYCLES ref_clk cycles
  // ------------------------------------------------------------------
  function automatic void open_lock_window(string why);
    lock_pending = 1;
    lock_saw_low = (pll_locked !== 1'b1);
    lock_cnt     = 0;
    lock_why     = why;
    n_lock_events++;
  endfunction

  always @(posedge rst_n) open_lock_window("reset release");

  always @(negedge rst_n) lock_pending = 0;

  always @(pll_m) begin
    if (rst_n === 1'b1)
      open_lock_window($sformatf("pll_m change to %0d", pll_m));
  end

  always @(negedge pll_locked) begin
    if (lock_pending) lock_saw_low = 1;
  end

  always @(posedge pll_locked) begin
    if (lock_pending && lock_saw_low && rst_n === 1'b1) begin
      lock_pending = 0;
      $display("[PLL_CHK] %t: pll_locked high after %0d ref_clk cycles (%s)",
               $realtime, lock_cnt, lock_why);
    end
  end

  always @(posedge ref_clk) begin
    if (rst_n === 1'b1 && lock_pending) begin
      if (lock_cnt >= LOCK_CYCLES) begin
        n_lock_err++;
        lock_pending = 0;
        if (!lock_saw_low)
          $error("[PLL_CHK] %t: pll_locked never went low after %s", $realtime, lock_why);
        else
          $error("[PLL_CHK] %t: pll_locked not back high within %0d ref_clk cycles after %s",
                 $realtime, LOCK_CYCLES, lock_why);
      end
      else begin
        lock_cnt++;
      end
    end
  end

  // ------------------------------------------------------------------
  // Summary
  // ------------------------------------------------------------------
  final begin
    int unsigned total;
    total = n_period_err + n_duty_err + n_stall_err + n_lock_err + n_cfg_err;

    $display("");
    $display("==================== PLL_CHK SUMMARY ====================");
    $display("  Periods checked        : %0d", n_periods);
    $display("  Period errors          : %0d", n_period_err);
    $display("  Duty-cycle errors      : %0d", n_duty_err);
    $display("  Stall errors           : %0d", n_stall_err);
    $display("  Lock events seen       : %0d", n_lock_events);
    $display("  Lock errors            : %0d", n_lock_err);
    $display("  Illegal pll_m errors   : %0d", n_cfg_err);
    $display("  TOTAL ERRORS           : %0d", total);
    if (lock_pending)
      $display("  NOTE: sim ended while waiting for lock (%s, %0d cycles)", lock_why, lock_cnt);
    if (n_periods == 0)
      $display("  WARNING: no pll_out periods were checked");
    $display("  RESULT                 : %s", (total == 0 && n_periods > 0) ? "PASS" : "FAIL");
    $display("=========================================================");
  end

endmodule

// ---------------------------------------------------------------------------
// Top: the same stimulus plan as the UVM test
// ---------------------------------------------------------------------------
module tav_ai_top;
  logic       ref_clk = 0;
  logic       rst_n;
  logic [3:0] div_n, pll_m;
  logic       div_out, pll_out, pll_locked;
  int         BUG = 0, m_changes = 0;
  always #5 ref_clk = ~ref_clk;

  tav_clk_div   u_div (.ref_clk(ref_clk), .rst_n(rst_n), .div_n(div_n), .div_out(div_out), .bug(BUG));
  tav_pll_model u_pll (.ref_clk(ref_clk), .rst_n(rst_n), .pll_m(pll_m),
                       .pll_out(pll_out), .pll_locked(pll_locked), .bug(BUG));
  pll_out_checker u_ai (.ref_clk(ref_clk), .rst_n(rst_n), .pll_m(pll_m),
                        .pll_out(pll_out), .pll_locked(pll_locked));

  initial begin
    int m, prev_m, hold;
    void'($value$plusargs("BUG=%d", BUG));
    $display("Running with BUG=%0d", BUG);
    rst_n = 0; div_n = 4; pll_m = 4; prev_m = 4;
    repeat (5) @(negedge ref_clk);
    rst_n = 1;
    @(negedge ref_clk); repeat (299) @(negedge ref_clk);          // phase 1
    repeat (80) begin                                              // phase 2
      hold = $urandom_range(40, 3);
      m = prev_m;
      if ($urandom_range(9, 0) < 3) begin
        do m = $urandom_range(8, 1); while (m == prev_m);
        m_changes++;
      end
      @(negedge ref_clk);
      div_n = $urandom_range(15, 2); pll_m = m; prev_m = m;
      repeat (hold - 1) @(negedge ref_clk);
    end
    repeat (40) @(negedge ref_clk);
    $display("pll_m changed %0d times in phase 2", m_changes);
    $finish;
  end
endmodule
