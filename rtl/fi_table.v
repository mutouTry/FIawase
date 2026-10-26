// SPDX-License-Identifier: Apache-2.0
// Copyright 2025-2026 the FIawase authors
// ============================================================
// FI Table                                (docs/DESIGN.md 1.2)
// ------------------------------------------------------------
// Wrapper-local replay storage: TBL_WORDS x DW words of FI_Entry.
// Two ports:
//   host side  written over DMI by the FI Transporter (the batch load)
//   exec side  combinational read by the FI Table Controller, so
//              advancing the word pointer IS the whole memory access
//
// Deliberately not an SRAM macro -- the table must stay readable while
// the DUT is frozen and must survive the FI Resolver reset.
//
// No reset on the content: it powers up as 0 and then holds whatever the
// host wrote. That is what lets FPGA synthesis map it to distributed RAM,
// the host port as its read/write port and the exec port as its
// asynchronous read port; a reset that clears it forces one flop per bit.
// The end of a batch is counted against CFG_TBL_LEN, so a word past it is
// never read.
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
  input  wire [31:0]                   exec_rd_addr_i,
  output wire [DW-1:0]                 exec_rdata_o
);

  reg [DW-1:0] mem [0:TBL_WORDS-1];

  integer i;
  initial
    for (i = 0; i < TBL_WORDS; i = i + 1)
      mem[i] = {DW{1'b0}};

  always @(posedge clk)
    if (host_wr_en_i)
      mem[host_addr_i] <= host_wdata_i;   // whole-word write, host_wmask_i ignored

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      host_rdata_o <= {DW{1'b0}};
    else if (host_rd_en_i)
      host_rdata_o <= mem[host_addr_i];
  end

  wire [$clog2(TBL_WORDS)-1:0] exec_word_addr;
  assign exec_word_addr = exec_rd_addr_i[$clog2(TBL_WORDS)+1:2];

  // bypass read is always visible from storage, no enable
  assign exec_rdata_o = mem[exec_word_addr];

endmodule
