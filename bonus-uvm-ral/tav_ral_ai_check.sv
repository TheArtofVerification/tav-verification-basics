// tav_ral_ai_check.sv : the same bench and design as tav_ral_apb_uvm.sv, with my RAL model
// swapped for an AI-written one
// Run on Synopsys VCS X-2025.06-SP1 with UVM 1.2 (EDA Playground), 25 Nov 2026, as this version (before tour step 17).
// The Art of Verification | theartofverification.com
// EDA Playground: Synopsys VCS, UVM 1.2, top module "tav_top", compile option -debug_access+all.
// Run with no option, then +BUG=1 to +BUG=4, exactly like tav_ral_apb_uvm.sv.
//
// tav_reg_pkg below is the AI answer exactly as it came back, not edited. The only change to the
// rest of the bench is the "import tav_reg_pkg::*;" line after it.
//
`timescale 1ns/1ns
`include "uvm_macros.svh"
import uvm_pkg::*;

// ---------------------------------------------------------------------------
// The design: an APB register block
// ---------------------------------------------------------------------------
// One DMA channel's registers. Two instances, u_ch0 and u_ch1, give the register file its HDL level.
module tav_dma_chan (input logic pclk, presetn, wr_src, wr_len, input logic [31:0] wdata,
                     output logic [31:0] src, output logic [15:0] len);
  always_ff @(posedge pclk or negedge presetn)
    if (!presetn) begin src <= 32'h0; len <= 16'h0040; end
    else begin
      if (wr_src) src <= wdata;
      if (wr_len) len <= wdata[15:0];
    end
endmodule

module tav_apb_regs (input  logic        pclk, presetn,
                     input  logic        psel, penable, pwrite,
                     input  logic [7:0]  paddr,
                     input  logic [31:0] pwdata,
                     output logic [31:0] prdata,
                     output logic        pready, pslverr,
                     input  logic [3:0]  ev,
                     input  int          bug);
  logic [7:0]  ctrl;
  logic [15:0] id;
  logic [3:0]  int_stat, int_en;
  logic [31:0] scratch;
  logic [31:0] mem [16];                                                     // BUF
  logic        wr, hit_int_en, mapped;
  logic [31:0] ch0_src, ch1_src;
  logic [15:0] ch0_len, ch1_len;

  assign wr         = psel && penable && pwrite;
  assign hit_int_en = (bug == 4) ? (paddr[3:0] == 4'hC) : (paddr == 8'h0C);   // BUG=4: alias
  assign mapped     = paddr inside {8'h00, 8'h04, 8'h08, 8'h0C, 8'h1C, 8'h80, 8'h84, 8'h90, 8'h94}
                      || paddr[7:6] == 2'b01;
  assign pready     = 1'b1;                                                   // no wait states
  assign pslverr    = psel && penable && !mapped;

  tav_dma_chan u_ch0 (pclk, presetn, wr && paddr == 8'h80, wr && paddr == 8'h84, pwdata, ch0_src, ch0_len);
  tav_dma_chan u_ch1 (pclk, presetn, wr && paddr == 8'h90, wr && paddr == 8'h94, pwdata, ch1_src, ch1_len);

  always_ff @(posedge pclk or negedge presetn)
    if (!presetn) begin
      ctrl     <= (bug == 1) ? 8'h00 : 8'h40;                                 // BUG=1: reset value
      id       <= 16'h5A01;
      int_stat <= 4'h0;
      int_en   <= 4'h0;
      scratch  <= 32'h0;
    end
    else begin
      if (wr && paddr == 8'h00) ctrl <= {pwdata[7:4], 1'b0, pwdata[2:0]};
      if (wr && paddr == 8'h04 && bug == 3) id <= pwdata[15:0];             // BUG=3: RO is writable
      if (wr && hit_int_en)     int_en  <= pwdata[3:0];
      if (wr && paddr == 8'h1C) scratch <= pwdata;
      if (wr && paddr[7:6] == 2'b01) mem[paddr[5:2]] <= pwdata;
      if (wr && paddr == 8'h08)
        int_stat <= (bug == 2) ? (pwdata[3:0] | ev)                           // BUG=2: acts as RW
                               : ((int_stat & ~pwdata[3:0]) | ev);            // W1C; a new event wins
      else
        int_stat <= int_stat | ev;
    end

  always_comb
    case (paddr)
      8'h00:   prdata = {24'h0, ctrl};
      8'h04:   prdata = {16'h0, id};
      8'h08:   prdata = {28'h0, int_stat};
      8'h0C:   prdata = {28'h0, int_en};
      8'h1C:   prdata = scratch;
      8'h80:   prdata = ch0_src;
      8'h84:   prdata = {16'h0, ch0_len};
      8'h90:   prdata = ch1_src;
      8'h94:   prdata = {16'h0, ch1_len};
      default: prdata = (paddr[7:6] == 2'b01) ? mem[paddr[5:2]] : 32'h0;
    endcase
endmodule

// ---------------------------------------------------------------------------
// Interface
// ---------------------------------------------------------------------------
interface tav_apb_if (input logic pclk);
  logic        presetn, psel, penable, pwrite, pready, pslverr;
  logic [7:0]  paddr;
  logic [31:0] pwdata, prdata;
  logic [3:0]  ev;                     // hardware interrupt events, driven by the test
endinterface

// The test sets tav_phase so every error and every bus access knows which phase it belongs to.
int tav_phase = 0;
int tav_n_rd[6], tav_n_wr[6];          // APB reads and writes seen by the monitor, per phase

// ---------------------------------------------------------------------------
// RAL model of the first IP block: the AI answer, unedited
// ---------------------------------------------------------------------------
// tav_reg_pkg.sv  (UVM 1.2)
package tav_reg_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  // ------------------------------------------------------------------
  // 0x00 CTRL : en[0] RW, mode[2:1] RW, prescale[7:4] RW, reset 0x40
  //             bit 3 and [31:8] are unmapped (read 0)
  // ------------------------------------------------------------------
  class tav_ctrl_reg extends uvm_reg;
    `uvm_object_utils(tav_ctrl_reg)
    `uvm_register_cb(tav_ctrl_reg, uvm_reg_cbs)

    rand uvm_reg_field en;
    rand uvm_reg_field mode;
    rand uvm_reg_field prescale;

    function new(string name = "tav_ctrl_reg");
      super.new(name, 32, UVM_NO_COVERAGE);
    endfunction

    virtual function void build();
      en       = uvm_reg_field::type_id::create("en");
      mode     = uvm_reg_field::type_id::create("mode");
      prescale = uvm_reg_field::type_id::create("prescale");
      //                 parent size lsb acc   vol reset has_rst rand indiv
      en.configure      (this, 1,   0,  "RW", 0,  1'h0,  1,      1,   0);
      mode.configure    (this, 2,   1,  "RW", 0,  2'h0,  1,      1,   0);
      prescale.configure(this, 4,   4,  "RW", 0,  4'h4,  1,      1,   0);
    endfunction
  endclass

  // ------------------------------------------------------------------
  // 0x04 ID : id[15:0] RO, 0x5A01
  // ------------------------------------------------------------------
  class tav_id_reg extends uvm_reg;
    `uvm_object_utils(tav_id_reg)

    uvm_reg_field id;

    function new(string name = "tav_id_reg");
      super.new(name, 32, UVM_NO_COVERAGE);
    endfunction

    virtual function void build();
      id = uvm_reg_field::type_id::create("id");
      id.configure(this, 16, 0, "RO", 0, 16'h5A01, 1, 0, 0);
    endfunction
  endclass

  // ------------------------------------------------------------------
  // 0x08 INT_STAT : pending[3:0] W1C, set by hardware -> volatile
  // ------------------------------------------------------------------
  class tav_int_stat_reg extends uvm_reg;
    `uvm_object_utils(tav_int_stat_reg)

    uvm_reg_field pending;

    function new(string name = "tav_int_stat_reg");
      super.new(name, 32, UVM_NO_COVERAGE);
    endfunction

    virtual function void build();
      pending = uvm_reg_field::type_id::create("pending");
      pending.configure(this, 4, 0, "W1C", 1, 4'h0, 1, 0, 0);
    endfunction
  endclass

  // ------------------------------------------------------------------
  // 0x0C INT_EN : enable[3:0] RW
  // ------------------------------------------------------------------
  class tav_int_en_reg extends uvm_reg;
    `uvm_object_utils(tav_int_en_reg)

    rand uvm_reg_field enable;

    function new(string name = "tav_int_en_reg");
      super.new(name, 32, UVM_NO_COVERAGE);
    endfunction

    virtual function void build();
      enable = uvm_reg_field::type_id::create("enable");
      enable.configure(this, 4, 0, "RW", 0, 4'h0, 1, 1, 0);
    endfunction
  endclass

  // ------------------------------------------------------------------
  // 0x1C SCRATCH : data[31:0] RW
  // ------------------------------------------------------------------
  class tav_scratch_reg extends uvm_reg;
    `uvm_object_utils(tav_scratch_reg)

    rand uvm_reg_field data;

    function new(string name = "tav_scratch_reg");
      super.new(name, 32, UVM_NO_COVERAGE);
    endfunction

    virtual function void build();
      data = uvm_reg_field::type_id::create("data");
      data.configure(this, 32, 0, "RW", 0, 32'h0, 1, 1, 0);
    endfunction
  endclass

  // ------------------------------------------------------------------
  // 0x40-0x7C BUF : 16 x 32 RAM
  // ------------------------------------------------------------------
  class tav_buffer_mem extends uvm_mem;
    `uvm_object_utils(tav_buffer_mem)

    function new(string name = "tav_buffer_mem");
      super.new(name, 16, 32, "RW", UVM_NO_COVERAGE);
    endfunction
  endclass

  // ------------------------------------------------------------------
  // Register block
  // ------------------------------------------------------------------
  class tav_reg_block extends uvm_reg_block;
    `uvm_object_utils(tav_reg_block)

    rand tav_ctrl_reg     ctrl;
         tav_id_reg       id;
         tav_int_stat_reg int_stat;
    rand tav_int_en_reg   int_en;
    rand tav_scratch_reg  scratch;
         tav_buffer_mem   buffer;

    function new(string name = "tav_reg_block");
      super.new(name, UVM_NO_COVERAGE);
    endfunction

    virtual function void build();
      // name, base, n_bytes, endian, byte_addressing
      default_map = create_map("default_map", 'h0, 4, UVM_LITTLE_ENDIAN, 1);

      add_hdl_path("tav_top.dut", "RTL");

      ctrl = tav_ctrl_reg::type_id::create("ctrl");
      ctrl.configure(this, null, "ctrl");          // tav_top.dut.ctrl[7:0]
      ctrl.build();

      id = tav_id_reg::type_id::create("id");
      id.configure(this, null, "id");              // tav_top.dut.id[15:0]
      id.build();

      int_stat = tav_int_stat_reg::type_id::create("int_stat");
      int_stat.configure(this, null, "int_stat");  // tav_top.dut.int_stat[3:0]
      int_stat.build();

      int_en = tav_int_en_reg::type_id::create("int_en");
      int_en.configure(this, null, "int_en");      // tav_top.dut.int_en[3:0]
      int_en.build();

      scratch = tav_scratch_reg::type_id::create("scratch");
      scratch.configure(this, null, "scratch");    // tav_top.dut.scratch[31:0]
      scratch.build();

      buffer = tav_buffer_mem::type_id::create("buffer");
      buffer.configure(this, "mem");               // tav_top.dut.mem[i]

      // Map rights stay "RW" for all. Field access (RO, W1C) sets the behavior,
      // so the built-in sequences can still write to ID without an access error.
      default_map.add_reg(ctrl,     'h00, "RW");
      default_map.add_reg(id,       'h04, "RW");
      default_map.add_reg(int_stat, 'h08, "RW");
      default_map.add_reg(int_en,   'h0C, "RW");
      default_map.add_reg(scratch,  'h1C, "RW");
      default_map.add_mem(buffer,   'h40, "RW");

      // uvm_reg_access_seq cannot test a register with RO fields (it warns and skips)
      uvm_resource_db#(bit)::set({"REG::", id.get_full_name()},
                                 "NO_REG_ACCESS_TEST", 1, this);

      lock_model();
    endfunction
  endclass

endpackage
import tav_reg_pkg::*;

// ---------------------------------------------------------------------------
// A second IP block: two DMA channels, each a register file, reachable through two maps
// ---------------------------------------------------------------------------
class tav_dma_src_reg extends uvm_reg;
  `uvm_object_utils(tav_dma_src_reg)
  rand uvm_reg_field data;
  function new(string name = "tav_dma_src_reg");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction
  virtual function void build();
    data = uvm_reg_field::type_id::create("data");
    data.configure(this, 32, 0, "RW", 0, 32'h0, 1, 1, 0);
  endfunction
endclass

class tav_dma_len_reg extends uvm_reg;
  `uvm_object_utils(tav_dma_len_reg)
  rand uvm_reg_field len;
  function new(string name = "tav_dma_len_reg");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction
  virtual function void build();
    len = uvm_reg_field::type_id::create("len");
    len.configure(this, 16, 0, "RW", 0, 16'h0040, 1, 1, 0);
  endfunction
endclass

// A register file groups the registers that repeat once per channel. It adds one level to the
// register's name (dma.ch1.len) and to its HDL path (tav_top.dut.u_ch1.len).
class tav_dma_chan_rf extends uvm_reg_file;
  `uvm_object_utils(tav_dma_chan_rf)
  rand tav_dma_src_reg src;
  rand tav_dma_len_reg len;
  function new(string name = "tav_dma_chan_rf");
    super.new(name);
  endfunction
  virtual function void build();
    src = tav_dma_src_reg::type_id::create("src");
    len = tav_dma_len_reg::type_id::create("len");
    src.configure(get_block(), this);  src.build();  src.add_hdl_path_slice("src", 0, 32);
    len.configure(get_block(), this);  len.build();  len.add_hdl_path_slice("len", 0, 16);
  endfunction
  // place both registers in a map, starting at this register file's offset
  function void tav_map(uvm_reg_map mp, uvm_reg_addr_t offset);
    mp.add_reg(src, offset + 'h0, "RW");
    mp.add_reg(len, offset + 'h4, "RW");
  endfunction
endclass

// Two maps over the same registers: the CPU reaches them through cpu_map, a debug port through
// dbg_map. In this bench both maps end up on the same APB agent.
class tav_dma_block extends uvm_reg_block;
  `uvm_object_utils(tav_dma_block)
  rand tav_dma_chan_rf ch0, ch1;
  uvm_reg_map          cpu_map, dbg_map;
  function new(string name = "tav_dma_block");
    super.new(name, UVM_NO_COVERAGE);
  endfunction
  virtual function void build();
    cpu_map = create_map("cpu_map", 'h0, 4, UVM_LITTLE_ENDIAN);   // the first map is the default_map
    dbg_map = create_map("dbg_map", 'h0, 4, UVM_LITTLE_ENDIAN);
    add_hdl_path("tav_top.dut", "RTL");
    ch0 = tav_dma_chan_rf::type_id::create("ch0");
    ch1 = tav_dma_chan_rf::type_id::create("ch1");
    ch0.configure(this, null, "u_ch0");  ch0.build();
    ch1.configure(this, null, "u_ch1");  ch1.build();
    ch0.tav_map(cpu_map, 'h00);  ch1.tav_map(cpu_map, 'h10);
    ch0.tav_map(dbg_map, 'h00);  ch1.tav_map(dbg_map, 'h10);
  endfunction
endclass

// ---------------------------------------------------------------------------
// The chip-level block: two IP blocks, each map added as a sub-map at its base address
// ---------------------------------------------------------------------------
class tav_chip_block extends uvm_reg_block;
  `uvm_object_utils(tav_chip_block)
  rand tav_reg_block ip;      // CTRL, ID, INT_STAT, INT_EN, SCRATCH, BUF at base 0x00
  rand tav_dma_block dma;     // two DMA channels at base 0x80
  uvm_reg_map        dbg_map;
  function new(string name = "tav_chip_block");
    super.new(name, UVM_NO_COVERAGE);
  endfunction
  virtual function void build();
    default_map = create_map("default_map", 'h0, 4, UVM_LITTLE_ENDIAN);
    dbg_map     = create_map("dbg_map",     'h0, 4, UVM_LITTLE_ENDIAN);
    set_hdl_path_root("", "RTL");            // each IP block carries its own full HDL path
    ip  = tav_reg_block::type_id::create("ip");
    dma = tav_dma_block::type_id::create("dma");
    ip.configure(this);   ip.build();
    dma.configure(this);  dma.build();
    default_map.add_submap(ip.default_map, 'h00);
    default_map.add_submap(dma.cpu_map,    'h80);
    dbg_map.add_submap(dma.dbg_map,        'h80);
    lock_model();
  endfunction
endclass

// ---------------------------------------------------------------------------
// APB agent: item, driver, monitor
// ---------------------------------------------------------------------------
class tav_apb_item extends uvm_sequence_item;
  `uvm_object_utils(tav_apb_item)
  bit [7:0]  addr;
  bit [31:0] data;
  bit        write;
  bit        slverr;
  function new(string name = "tav_apb_item");
    super.new(name);
  endfunction
endclass

class tav_apb_driver extends uvm_driver #(tav_apb_item);
  `uvm_component_utils(tav_apb_driver)
  virtual tav_apb_if vif;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(virtual tav_apb_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "no virtual interface")
  endfunction
  task run_phase(uvm_phase phase);
    vif.psel <= 0; vif.penable <= 0; vif.pwrite <= 0; vif.paddr <= 0; vif.pwdata <= 0;
    forever begin
      seq_item_port.get_next_item(req);
      @(posedge vif.pclk);                                   // SETUP: select, address, direction
      vif.psel   <= 1; vif.penable <= 0; vif.pwrite <= req.write;
      vif.paddr  <= req.addr; vif.pwdata <= req.write ? req.data : 32'h0;
      @(posedge vif.pclk);                                   // ACCESS: enable
      vif.penable <= 1;
      do @(posedge vif.pclk); while (vif.pready !== 1'b1);   // transfer ends when PREADY is high
      if (!req.write) req.data = vif.prdata;
      req.slverr = vif.pslverr;
      vif.psel <= 0; vif.penable <= 0;
      #1 seq_item_port.item_done();                          // after the monitor has seen it
    end
  endtask
endclass

class tav_apb_monitor extends uvm_monitor;
  `uvm_component_utils(tav_apb_monitor)
  virtual tav_apb_if vif;
  uvm_analysis_port #(tav_apb_item) ap;
  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction
  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(virtual tav_apb_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "no virtual interface")
  endfunction
  task run_phase(uvm_phase phase);
    tav_apb_item t;
    forever begin
      @(posedge vif.pclk);
      if (vif.presetn === 1'b1 && vif.psel === 1'b1 && vif.penable === 1'b1 && vif.pready === 1'b1) begin
        t = tav_apb_item::type_id::create("t");
        t.addr   = vif.paddr;
        t.write  = vif.pwrite;
        t.data   = vif.pwrite ? vif.pwdata : vif.prdata;
        t.slverr = vif.pslverr;
        if (t.write) tav_n_wr[tav_phase]++; else tav_n_rd[tav_phase]++;
        ap.write(t);
      end
    end
  endtask
endclass

class tav_apb_agent extends uvm_agent;
  `uvm_component_utils(tav_apb_agent)
  uvm_sequencer #(tav_apb_item) sqr;
  tav_apb_driver                drv;
  tav_apb_monitor               mon;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    sqr = uvm_sequencer#(tav_apb_item)::type_id::create("sqr", this);
    drv = tav_apb_driver::type_id::create("drv", this);
    mon = tav_apb_monitor::type_id::create("mon", this);
  endfunction
  function void connect_phase(uvm_phase phase);
    drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction
endclass

// ---------------------------------------------------------------------------
// Adapter: RAL's generic read/write <-> one APB transfer
// ---------------------------------------------------------------------------
class tav_apb_adapter extends uvm_reg_adapter;
  `uvm_object_utils(tav_apb_adapter)
  function new(string name = "tav_apb_adapter");
    super.new(name);
    supports_byte_enable = 0;          // APB3 has no byte strobes
    provides_responses   = 0;          // the driver puts read data into the same item
  endfunction
  virtual function uvm_sequence_item reg2bus(const ref uvm_reg_bus_op rw);
    tav_apb_item item = tav_apb_item::type_id::create("item");
    item.addr  = rw.addr;
    item.write = (rw.kind == UVM_WRITE || rw.kind == UVM_BURST_WRITE);   // bursts arrive as UVM_BURST_WRITE
    item.data  = rw.data;
    return item;
  endfunction
  virtual function void bus2reg(uvm_sequence_item bus_item, ref uvm_reg_bus_op rw);
    tav_apb_item item;
    if (!$cast(item, bus_item)) `uvm_fatal("ADAPTER", "not a tav_apb_item")
    rw.kind   = item.write ? UVM_WRITE : UVM_READ;
    rw.addr   = item.addr;
    rw.data   = item.data;
    rw.status = item.slverr ? UVM_NOT_OK : UVM_IS_OK;
  endfunction
endclass

// ---------------------------------------------------------------------------
// Report catcher: counts errors per phase and shows only the first two of each phase
// ---------------------------------------------------------------------------
class tav_err_catcher extends uvm_report_catcher;
  int n_err[6], shown[6];
  function new(string name = "tav_err_catcher");
    super.new(name);
  endfunction
  function action_e catch();
    if (get_severity() != UVM_ERROR) return THROW;
    n_err[tav_phase]++;
    if (shown[tav_phase] < 2) begin
      shown[tav_phase]++;
      set_message({$sformatf("[phase %0d] ", tav_phase), get_message()});
      return THROW;
    end
    return CAUGHT;
  endfunction
endclass

// ---------------------------------------------------------------------------
// Register callback: UVM calls post_write() after every write to the register it is added to
// ---------------------------------------------------------------------------
class tav_ctrl_cb extends uvm_reg_cbs;
  `uvm_object_utils(tav_ctrl_cb)
  static int n_writes;
  function new(string name = "tav_ctrl_cb");
    super.new(name);
  endfunction
  virtual task post_write(uvm_reg_item rw);
    n_writes++;
    if (tav_phase == 0)
      `uvm_info("CALLBACK", $sformatf("   post_write: CTRL written with 0x%0h through the %s (write %0d)",
                rw.value[0], rw.path == UVM_BACKDOOR ? "backdoor" : "frontdoor", n_writes), UVM_NONE)
  endtask
endclass

// ---------------------------------------------------------------------------
// Register sequences
// ---------------------------------------------------------------------------
class tav_base_reg_seq extends uvm_reg_sequence;
  `uvm_object_utils(tav_base_reg_seq)
  tav_reg_block      rm;
  virtual tav_apb_if vif;
  function new(string name = "tav_base_reg_seq");
    super.new(name);
  endfunction
  // frontdoor read, compared with what the spec says
  task tav_expect(uvm_reg r, uvm_reg_data_t exp, string why);
    uvm_status_e   status;
    uvm_reg_data_t got;
    r.read(status, got);
    if (got !== exp)
      `uvm_error("TAV_CHECK", $sformatf("%s: %s read 0x%0h, expected 0x%0h", why, r.get_name(), got, exp))
  endtask
  // one-cycle pulse on the hardware event inputs
  task pulse(bit [3:0] e);
    @(negedge vif.pclk) vif.ev = e;
    @(negedge vif.pclk) vif.ev = 0;
  endtask
endclass

// A plain APB write that does not go through the register model,
// like a write from another bus master or from embedded software
class tav_apb_raw_write_seq extends uvm_sequence #(tav_apb_item);
  `uvm_object_utils(tav_apb_raw_write_seq)
  bit [7:0]  addr;
  bit [31:0] data;
  function new(string name = "tav_apb_raw_write_seq");
    super.new(name);
  endfunction
  task body();
    req = tav_apb_item::type_id::create("req");
    start_item(req);
    req.addr = addr; req.data = data; req.write = 1;
    finish_item(req);
  endtask
endclass

// Phase 0: every RAL method once. Each step prints the model (desired and mirrored values)
// and the design value read straight from the RTL with uvm_hdl_read().
class tav_tour_seq extends tav_base_reg_seq;
  `uvm_object_utils(tav_tour_seq)
  uvm_sequencer #(tav_apb_item) sqr;
  tav_chip_block                chip;                  // the whole model: ip, dma and both maps
  int w0, r0;                                          // bus counters at the start of a step
  function new(string name = "tav_tour_seq");
    super.new(name);
  endfunction
  function void step(string title);
    w0 = tav_n_wr[0]; r0 = tav_n_rd[0];
    `uvm_info("TOUR", {"---- ", title}, UVM_NONE)
  endfunction
  function int n_dbg_regs();
    uvm_reg r[$];
    chip.dbg_map.get_registers(r);
    return r.size();
  endfunction
  function void bus();
    `uvm_info("TOUR", $sformatf("   APB traffic in this step: %0d write(s), %0d read(s)",
              tav_n_wr[0] - w0, tav_n_rd[0] - r0), UVM_NONE)
  endfunction
  // Prints the model and the design side by side. The design value comes from uvm_hdl_read(),
  // not peek(): peek() would also update the model (step 5 shows why that matters).
  function void show(uvm_reg r, string hdl = "");
    uvm_hdl_data_t dut;
    if (hdl == "") hdl = {"tav_top.dut.", r.get_name()};
    if (!uvm_hdl_read(hdl, dut)) `uvm_error("TOUR", "uvm_hdl_read failed")
    `uvm_info("TOUR", $sformatf("   %-8s desired=0x%08h  mirrored=0x%08h  design=0x%08h",
              r.get_name(), r.get(), r.get_mirrored_value(), dut[31:0]), UVM_NONE)
  endfunction
  task body();
    uvm_status_e          status;
    uvm_reg_data_t        v;
    uvm_reg_data_t        wburst[], rburst[];
    tav_apb_raw_write_seq raw;
    uvm_hdl_path_concat   hp[$];
    uvm_reg               regs[$];
    uvm_mem               mems[$];

    step("0. What the model looks like: every register in the chip's default_map, with every field");
    chip.default_map.get_registers(regs);
    foreach (regs[i]) begin
      uvm_reg_field flds[$];
      string        line;
      regs[i].get_fields(flds);
      line = $sformatf("   0x%02h  %-22s", regs[i].get_address(chip.default_map), regs[i].get_full_name());
      foreach (flds[f])
        line = {line, $sformatf(" | %s [%0d:%0d] %s reset 0x%0h%s", flds[f].get_name(),
                flds[f].get_lsb_pos() + flds[f].get_n_bits() - 1, flds[f].get_lsb_pos(),
                flds[f].get_access(), flds[f].get_reset(), flds[f].is_volatile() ? " volatile" : "")};
      `uvm_info("TOUR", line, UVM_NONE)
    end
    chip.default_map.get_memories(mems);
    foreach (mems[i])
      `uvm_info("TOUR", $sformatf("   0x%02h  %-22s | memory, %0d words of %0d bits, %s", mems[i].get_address(0, chip.default_map),
                mems[i].get_full_name(), mems[i].get_size(), mems[i].get_n_bits(), mems[i].get_access()), UVM_NONE)
    `uvm_info("TOUR", $sformatf("   default_map: %0d-byte bus, base 0x%0h; dbg_map holds %0d registers",
              chip.default_map.get_n_bytes(), chip.default_map.get_base_addr(), n_dbg_regs()), UVM_NONE)

    step("1. Right after build() the model holds 0, not the reset values. regmodel.reset() loads them");
    show(rm.ctrl);
    rm.reset();
    show(rm.ctrl);
    `uvm_info("TOUR", $sformatf("   ctrl.get_reset() = 0x%0h", rm.ctrl.get_reset()), UVM_NONE)
    tav_expect(rm.ctrl, 'h40, "step 1, read after reset");
    bus();

    step("2. write() and read(): one APB transfer each, the mirror follows");
    rm.ctrl.write(status, 'h13);
    show(rm.ctrl);
    tav_expect(rm.ctrl, 'h13, "step 2, read back");
    bus();

    step("3. Field write: ctrl.prescale.write(9). APB cannot write part of a register, so RAL writes all of CTRL");
    rm.ctrl.prescale.write(status, 'h9);
    show(rm.ctrl);
    tav_expect(rm.ctrl, 'h93, "step 3, read back");
    bus();

    step("4. set() changes only the model (desired); ctrl.update() writes it when desired != mirrored");
    rm.ctrl.mode.set(2'b10);
    show(rm.ctrl);
    `uvm_info("TOUR", $sformatf("   ctrl.needs_update() = %0d", rm.ctrl.needs_update()), UVM_NONE)
    rm.ctrl.update(status);
    show(rm.ctrl);
    `uvm_info("TOUR", $sformatf("   ctrl.needs_update() = %0d", rm.ctrl.needs_update()), UVM_NONE)
    bus();

    step("5. Careful: peek() is not only a look. It also updates desired and mirrored from the design");
    rm.ctrl.mode.set(2'b01);
    show(rm.ctrl);
    rm.ctrl.peek(status, v);
    `uvm_info("TOUR", $sformatf("   ctrl.peek() = 0x%0h", v), UVM_NONE)
    show(rm.ctrl);
    `uvm_info("TOUR", (rm.ctrl.mode.get() == 2'b01) ? "   the set(2'b01) above survived the peek()"
                       : "   the set(2'b01) above is gone: peek() overwrote the desired value", UVM_NONE)
    bus();

    step("6. randomize() the model, then regmodel.update(): writes every register whose desired value changed");
    if (!rm.randomize()) `uvm_error("TOUR", "randomize failed")
    show(rm.ctrl); show(rm.int_en); show(rm.scratch);
    rm.update(status);
    rm.ctrl.mirror(status, UVM_CHECK);
    rm.int_en.mirror(status, UVM_CHECK);
    rm.scratch.mirror(status, UVM_CHECK);
    show(rm.ctrl); show(rm.int_en); show(rm.scratch);
    bus();

    step("7. Hardware sets INT_STAT behind the model's back; mirror() reads it and refreshes the mirror");
    pulse(4'b0011);
    show(rm.int_stat);
    rm.int_stat.mirror(status, UVM_NO_CHECK);
    show(rm.int_stat);
    rm.int_stat.write(status, 'h1);                    // W1C: clears bit 0 only
    show(rm.int_stat);
    tav_expect(rm.int_stat, 'h2, "step 7, after writing 1 to bit 0");
    bus();

    step("8. predict() tells the model a value without touching the bus");
    pulse(4'b0100);
    void'(rm.int_stat.predict('h6));
    show(rm.int_stat);
    bus();
    rm.int_stat.write(status, 'h6);                    // clear both
    tav_expect(rm.int_stat, 'h0, "step 8, after writing 1 to bits 1 and 2");

    step("9. Backdoor: poke() and peek() reach the design directly, in zero time, no APB");
    rm.scratch.poke(status, 'hDEAD_BEEF);
    show(rm.scratch);
    rm.id.peek(status, v);
    `uvm_info("TOUR", $sformatf("   id.peek() = 0x%0h", v), UVM_NONE)
    rm.ctrl.read(status, v, UVM_BACKDOOR);
    `uvm_info("TOUR", $sformatf("   ctrl.read(UVM_BACKDOOR) = 0x%0h", v), UVM_NONE)
    bus();
    tav_expect(rm.scratch, 'hDEAD_BEEF, "step 9, frontdoor read of the poked value");

    step("10. Explicit prediction: a raw APB write, not from the model, still updates the mirror");
    raw = tav_apb_raw_write_seq::type_id::create("raw");
    raw.addr = 'h1C; raw.data = 'h0000_CAFE;
    raw.start(sqr);
    show(rm.scratch);
    bus();

    step("11. Hardware reset, then regmodel.reset(): model and design both back to reset values");
    @(negedge vif.pclk) vif.presetn = 0;
    repeat (2) @(negedge vif.pclk);
    vif.presetn = 1;
    rm.reset();
    show(rm.ctrl); show(rm.scratch);
    rm.ctrl.mirror(status, UVM_CHECK);
    rm.int_en.mirror(status, UVM_CHECK);
    rm.scratch.mirror(status, UVM_CHECK);
    bus();

    step("12. Memory (uvm_mem): read and write by offset, burst access, peek and poke. A memory has no mirror");
    rm.buffer.write(status, 3, 'h1111_0003);
    rm.buffer.read(status, 3, v);
    `uvm_info("TOUR", $sformatf("   buffer.write(3, 0x11110003), then buffer.read(3) = 0x%0h", v), UVM_NONE)
    wburst = '{'hA0, 'hA1, 'hA2, 'hA3};
    rburst = new[4];
    rm.buffer.burst_write(status, 8, wburst);
    rm.buffer.burst_read(status, 8, rburst);
    `uvm_info("TOUR", $sformatf("   buffer.burst_write(8, 4 words), burst_read(8) = %p", rburst), UVM_NONE)
    rm.buffer.poke(status, 15, 'h0000_BEEF);
    rm.buffer.peek(status, 15, v);
    `uvm_info("TOUR", $sformatf("   buffer.poke(15, 0xBEEF), then buffer.peek(15) = 0x%0h", v), UVM_NONE)
    bus();
    rm.buffer.read(status, 15, v);
    if (v !== 'h0000_BEEF) `uvm_error("TAV_CHECK", $sformatf("step 12: buffer[15] read 0x%0h, expected 0xbeef", v))

    step("13. Callbacks: tav_ctrl_cb::post_write() ran after every CTRL write above (the CALLBACK lines)");
    `uvm_info("TOUR", $sformatf("   CTRL writes seen by the callback so far: %0d", tav_ctrl_cb::n_writes), UVM_NONE)

    step("14. Register file: dma.ch1 groups SRC and LEN, adding a level to the name and the HDL path");
    chip.dma.ch1.len.write(status, 'h0200);
    show(chip.dma.ch1.len, "tav_top.dut.u_ch1.len");
    `uvm_info("TOUR", $sformatf("   full name: %s", chip.dma.ch1.len.get_full_name()), UVM_NONE)
    chip.dma.ch1.len.get_full_hdl_path(hp);
    `uvm_info("TOUR", $sformatf("   HDL path:  %s", hp[0].slices[0].path), UVM_NONE)
    tav_expect(chip.dma.ch1.len, 'h0200, "step 14, read back");
    bus();

    step("15. Sub-blocks: one chip block holds both IP blocks; each IP map sits in the chip map at its base");
    regs.delete();
    chip.get_registers(regs);
    `uvm_info("TOUR", $sformatf("   registers in the chip model: %0d", regs.size()), UVM_NONE)
    `uvm_info("TOUR", $sformatf("   ip.ctrl at 0x%02h, dma.ch0.src at 0x%02h, dma.ch1.len at 0x%02h in default_map",
              chip.ip.ctrl.get_address(chip.default_map), chip.dma.ch0.src.get_address(chip.default_map),
              chip.dma.ch1.len.get_address(chip.default_map)), UVM_NONE)

    step("16. Two maps: write DMA ch0 SRC through the debug map, read it back through the CPU map");
    chip.dma.ch0.src.write(status, 'hA5A5_0001, UVM_FRONTDOOR, chip.dbg_map);
    chip.dma.ch0.src.read(status, v, UVM_FRONTDOOR, chip.default_map);
    `uvm_info("TOUR", $sformatf("   write via dbg_map, read via default_map = 0x%0h", v), UVM_NONE)
    if (v !== 'hA5A5_0001) `uvm_error("TAV_CHECK", $sformatf("step 16: read 0x%0h, expected 0xa5a50001", v))
    bus();
  endtask
endclass

// Phase 4: does INT_STAT really set on events and clear only the bits written as 1?
class tav_w1c_seq extends tav_base_reg_seq;
  `uvm_object_utils(tav_w1c_seq)
  function new(string name = "tav_w1c_seq");
    super.new(name);
  endfunction
  task body();
    uvm_status_e status;
    rm.int_stat.write(status, 4'hF);                   // start clean
    tav_expect(rm.int_stat, 4'h0, "after writing 1 to every bit");
    pulse(4'b0101);
    tav_expect(rm.int_stat, 4'h5, "after events 0 and 2");
    rm.int_stat.write(status, 4'b0001);
    tav_expect(rm.int_stat, 4'h4, "after writing 1 to bit 0 only");
    rm.int_stat.write(status, 4'b0000);
    tav_expect(rm.int_stat, 4'h4, "after writing 0 (must change nothing)");
    rm.int_stat.write(status, 4'b0100);
    tav_expect(rm.int_stat, 4'h0, "after writing 1 to bit 2");
  endtask
endclass

// Phase 5: does any write land somewhere it should not?
class tav_alias_seq extends tav_base_reg_seq;
  `uvm_object_utils(tav_alias_seq)
  function new(string name = "tav_alias_seq");
    super.new(name);
  endfunction
  task body();
    uvm_status_e status;
    uvm_reg      regs[$];
    rm.ctrl.write(status,    32'h35);
    rm.int_en.write(status,  32'hA);
    rm.scratch.write(status, 32'h1234_5678);
    rm.get_registers(regs);
    foreach (regs[i]) regs[i].mirror(status, UVM_CHECK);   // every register, against the model
  endtask
endclass

// ---------------------------------------------------------------------------
// Environment and test
// ---------------------------------------------------------------------------
class tav_env extends uvm_env;
  `uvm_component_utils(tav_env)
  tav_chip_block                    regmodel;
  tav_apb_adapter                   adapter;
  uvm_reg_predictor #(tav_apb_item) predictor;
  tav_apb_agent                     agent;
  tav_ctrl_cb                       cb;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    regmodel  = tav_chip_block::type_id::create("regmodel");
    regmodel.build();
    adapter   = tav_apb_adapter::type_id::create("adapter");
    predictor = uvm_reg_predictor#(tav_apb_item)::type_id::create("predictor", this);
    agent     = tav_apb_agent::type_id::create("agent", this);
  endfunction
  function void connect_phase(uvm_phase phase);
    regmodel.default_map.set_sequencer(agent.sqr, adapter);   // model accesses go to this sequencer
    regmodel.dbg_map.set_sequencer(agent.sqr, adapter);       // the debug map uses the same APB agent here
    regmodel.default_map.set_auto_predict(0);                 // the predictor keeps the mirror
    regmodel.dbg_map.set_auto_predict(0);
    predictor.map     = regmodel.default_map;
    predictor.adapter = adapter;
    agent.mon.ap.connect(predictor.bus_in);                   // every APB transfer, from anyone
    cb = tav_ctrl_cb::type_id::create("cb");
    uvm_reg_cb::add(regmodel.ip.ctrl, cb);                        // hook the callback onto CTRL
  endfunction
endclass

class tav_ral_test extends uvm_test;
  `uvm_component_utils(tav_ral_test)
  tav_env            env;
  tav_err_catcher    catcher;
  virtual tav_apb_if vif;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    env = tav_env::type_id::create("env", this);
    catcher = new("catcher");
    uvm_report_cb::add(null, catcher);
    if (!uvm_config_db#(virtual tav_apb_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "no virtual interface")
  endfunction
  task run_phase(uvm_phase phase);
    tav_tour_seq         s0 = tav_tour_seq::type_id::create("s0");
    uvm_reg_hw_reset_seq s1 = uvm_reg_hw_reset_seq::type_id::create("s1");
    uvm_reg_bit_bash_seq s2 = uvm_reg_bit_bash_seq::type_id::create("s2");
    uvm_reg_mem_hdl_paths_seq s3a = uvm_reg_mem_hdl_paths_seq::type_id::create("s3a");
    uvm_reg_access_seq        s3b = uvm_reg_access_seq::type_id::create("s3b");
    uvm_mem_walk_seq          s3c = uvm_mem_walk_seq::type_id::create("s3c");
    uvm_reg_mem_shared_access_seq s3d = uvm_reg_mem_shared_access_seq::type_id::create("s3d");
    tav_w1c_seq          s4 = tav_w1c_seq::type_id::create("s4");
    tav_alias_seq        s5 = tav_alias_seq::type_id::create("s5");
    phase.raise_objection(this);
    wait (vif.presetn === 1'b1);
    repeat (2) @(posedge vif.pclk);
    s0.rm = env.regmodel.ip; s0.chip = env.regmodel; s0.vif = vif; s0.sqr = env.agent.sqr;
    s1.model = env.regmodel;
    s2.model = env.regmodel;
    s3a.model = env.regmodel; s3b.model = env.regmodel; s3c.model = env.regmodel; s3d.model = env.regmodel;
    s4.rm = env.regmodel.ip; s4.vif = vif;
    s5.rm = env.regmodel.ip; s5.vif = vif;
    tav_phase = 0; s0.start(null);
    tav_phase = 1; s1.start(null);
    tav_phase = 2; s2.start(null);
    tav_phase = 3; s3a.start(null); s3b.start(null); s3c.start(null); s3d.start(null);
    tav_phase = 4; s4.start(null);
    tav_phase = 5; s5.start(null);
    repeat (2) @(posedge vif.pclk);
    tav_print_results();
    phase.drop_objection(this);
  endtask
  function void tav_print_results();
    string nm[6] = '{"tour of the methods      ", "hw_reset (built-in)      ",
                     "bit_bash (built-in)      ", "paths/access/walk/shared ",
                     "W1C (targeted)           ", "alias (targeted)         "};
    for (int p = 0; p <= 5; p++)
      `uvm_info("RESULT", $sformatf("Phase %0d %s: APB reads=%0d writes=%0d errors=%0d -> %s",
                p, nm[p], tav_n_rd[p], tav_n_wr[p], catcher.n_err[p],
                catcher.n_err[p] == 0 ? "PASS" : "FAIL"), UVM_NONE)
  endfunction
endclass

// ---------------------------------------------------------------------------
// Top
// ---------------------------------------------------------------------------
module tav_top;
  logic pclk = 0;
  int   BUG = 0;
  always #5 pclk = ~pclk;

  tav_apb_if vif (pclk);
  tav_apb_regs dut (.pclk(pclk), .presetn(vif.presetn), .psel(vif.psel), .penable(vif.penable),
                    .pwrite(vif.pwrite), .paddr(vif.paddr), .pwdata(vif.pwdata),
                    .prdata(vif.prdata), .pready(vif.pready), .pslverr(vif.pslverr),
                    .ev(vif.ev), .bug(BUG));

  initial begin
    vif.presetn = 0; vif.ev = 0;
    void'($value$plusargs("BUG=%d", BUG));
    `uvm_info("TOP", $sformatf("Running with BUG=%0d", BUG), UVM_NONE)
    uvm_config_db#(virtual tav_apb_if)::set(null, "uvm_test_top*", "vif", vif);
    repeat (3) @(negedge pclk);
    vif.presetn = 1;
  end

  initial run_test("tav_ral_test");
endmodule
