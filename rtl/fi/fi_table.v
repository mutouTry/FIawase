// SPDX-License-Identifier: Apache-2.0
// Copyright 2025-2026 the FIawase authors
// ============================================================
// FI Table                                (paper Fig. 5, FI Executor)
// ------------------------------------------------------------
// Wrapper-local replay storage: TBL_WORDS x DW words of FI_Entry.
// Two ports:
//   host side  written over DMI by the FI Transporter (the batch load)
//   exec side  combinational read by the FI Table Controller, so
//              advancing the word pointer IS the whole memory access
//
// Flops here; block RAM after FPGA inference. Deliberately not an SRAM
// macro -- the table must stay readable while the DUT is frozen and
// must survive the FI Resolver reset.
// ============================================================
module fi_table #(
  parameter integer DW        = 32,
  parameter integer TBL_WORDS = 64
)(
  input  wire                          clk,
  input  wire                          rst_n,

  // Host-side access from the FI Transporter
  input  wire                          host_wr_en_i,
  input  wire                          host_rd_en_i,
  input  wire [$clog2(TBL_WORDS)-1:0]  host_addr_i,
  input  wire [DW-1:0]                 host_wdata_i,
  input  wire [DW/8-1:0]               host_wmask_i,   // kept only for interface compatibility
  output reg  [DW-1:0]                 host_rdata_o,

  // FI Table Controller side, bypass read
  // input  wire                          exec_en_i,      // not used for data gating
  input  wire [31:0]                   exec_rd_addr_i,
  output wire [DW-1:0]                 exec_rdata_o
);

  reg [DW-1:0] mem [0:TBL_WORDS-1];

  integer i;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      host_rdata_o <= {DW{1'b0}};
      for (i = 0; i < TBL_WORDS; i = i + 1)
        mem[i] <= {DW{1'b0}};
    end else begin
      if (host_wr_en_i)
        mem[host_addr_i] <= host_wdata_i;   // whole-word write, host_wmask_i ignored

      if (host_rd_en_i)
        host_rdata_o <= mem[host_addr_i];
    end
  end

  wire [$clog2(TBL_WORDS)-1:0] exec_word_addr;
  assign exec_word_addr = exec_rd_addr_i[$clog2(TBL_WORDS)+1:2];

  // bypass read is always visible from storage, no enable
  assign exec_rdata_o = mem[exec_word_addr];

endmodule