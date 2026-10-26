// SPDX-License-Identifier: Apache-2.0
// Copyright 2025-2026 the FIawase authors
// FPGA versions of the example SoC's two SRAM macro models, with the FI memory restore in block-RAM
// form (fpga/rtl/fi_sram_fpga.v). The pins and their behaviour are those of the macros' simulation
// models: gwen = 1 loads the read address, gwen = 0 writes the
// bytes whose wen bit 0/8/16/24 (active low) is 0, cen and the margin pins are unused.
// After the clock-gate conversion clk is the free-running clock and fi_ce_i marks the edges
// the macro's own (frozen) clock has.
//   u_rom (16384 x 32, program image): UNDO, 64-entry log, content from FI_ROM_INIT
//   u_ram ( 8192 x 32, data):          FILL with 0, 8 banks of 1024 words

module sram_sp_16384x32 (
    input  wire        clk,
    input  wire [13:0] a,
    input  wire [31:0] d,
    input  wire [31:0] wen,
    input  wire        gwen,
    input  wire        cen,
    output wire [31:0] q,
    input  wire        stov,
    input  wire [2:0]  ema,
    input  wire [1:0]  emaw,
    input  wire        emas,
    input  wire        ret1n,
    input  wire        fi_ce_i,
    input  wire        fi_restore_i,
    output wire        fi_done_o,
    output wire        fi_abort_o,
    output wire        fi_bad_o
);
    fi_sram_fpga #(
        .AW(14), .DW(32), .KIND(0), .LOG_DEPTH(64), .BANKS(1),
`ifdef FI_ROM_INIT
        .INIT_FILE(`FI_ROM_INIT)
`else
        .INIT_FILE("none")
`endif
    ) u_core (
        .clk(clk), .ce(fi_ce_i), .a(a), .d(d),
        .wenb({4{!gwen}} & {!wen[24], !wen[16], !wen[8], !wen[0]}), .ren(gwen), .q(q),
        .restore_i(fi_restore_i), .done_o(fi_done_o), .abort_o(fi_abort_o), .bad_o(fi_bad_o)
    );
endmodule

module sram_sp_8192x32 (
    input  wire        clk,
    input  wire [12:0] a,
    input  wire [31:0] d,
    input  wire [31:0] wen,
    input  wire        gwen,
    input  wire        cen,
    output wire [31:0] q,
    input  wire        stov,
    input  wire [2:0]  ema,
    input  wire [1:0]  emaw,
    input  wire        emas,
    input  wire        ret1n,
    input  wire        fi_ce_i,
    input  wire        fi_restore_i,
    output wire        fi_done_o,
    output wire        fi_abort_o,
    output wire        fi_bad_o
);
    fi_sram_fpga #(
        .AW(13), .DW(32), .KIND(1), .LOG_DEPTH(1), .BANKS(8)
    ) u_core (
        .clk(clk), .ce(fi_ce_i), .a(a), .d(d),
        .wenb({4{!gwen}} & {!wen[24], !wen[16], !wen[8], !wen[0]}), .ren(gwen), .q(q),
        .restore_i(fi_restore_i), .done_o(fi_done_o), .abort_o(fi_abort_o), .bad_o(fi_bad_o)
    );
endmodule
