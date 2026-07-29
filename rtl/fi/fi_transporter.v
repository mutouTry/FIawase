// SPDX-License-Identifier: Apache-2.0
// Copyright 2025-2026 the FIawase authors

`ifndef FI_JTAG_FI_DEF_VH
`define FI_JTAG_FI_DEF_VH

// ============================================================
// FI-private wrapper-visible JTAG / DMI definitions
// ============================================================

// Fixed wrapper JTAG IR contract
`define FI_JTAG_IR_BITS         5
`define FI_JTAG_IR_IDCODE       5'b00001
`define FI_JTAG_IR_DTMCS        5'b10000
`define FI_JTAG_IR_DMI          5'b10001
`define FI_JTAG_IR_BYPASS       5'b11111

// DMI ops
`define FI_DMI_OP_NOP           2'b00
`define FI_DMI_OP_READ          2'b01
`define FI_DMI_OP_WRITE         2'b10

// DMI response status
`define FI_DMI_RESP_OK          2'b00
`define FI_DMI_RESP_FAIL        2'b10
`define FI_DMI_RESP_BUSY        2'b11

// FI private address window
`define FI_DMI_BASE_ADDR        7'h60

// Register map. The "FI Configuration" of paper Fig. 5 -- the blue
// block the FI Resolver must NOT reset -- is CFG0 .. CFG_TBL_LEN.
`define FI_DMI_ADDR_FI_MODE      (`FI_DMI_BASE_ADDR + 7'h00)
`define FI_DMI_ADDR_FI_STATUS    (`FI_DMI_BASE_ADDR + 7'h01)
`define FI_DMI_ADDR_CFG0         (`FI_DMI_BASE_ADDR + 7'h02)
`define FI_DMI_ADDR_CFG_SCAN_LEN (`FI_DMI_BASE_ADDR + 7'h03)  // Scan_Len
`define FI_DMI_ADDR_CFG_FI_INDEX (`FI_DMI_BASE_ADDR + 7'h04)  // FI_Index, static mode
`define FI_DMI_ADDR_CFG_FI_CYCLE (`FI_DMI_BASE_ADDR + 7'h05)  // FI_Cycle base
`define FI_DMI_ADDR_CFG_TO_THR   (`FI_DMI_BASE_ADDR + 7'h06)  // TO_Thr
`define FI_DMI_ADDR_FI_CMD       (`FI_DMI_BASE_ADDR + 7'h07)
`define FI_DMI_ADDR_CFG_TBL_LEN  (`FI_DMI_BASE_ADDR + 7'h08)  // FI_Entry count
`define FI_DMI_ADDR_FI_CYCLE     (`FI_DMI_BASE_ADDR + 7'h09)  // running FI_Cycle, RO
`define FI_DMI_ADDR_FI_VERSION   (`FI_DMI_BASE_ADDR + 7'h0F)

// FI Table window
`define FI_DMI_ADDR_TBL_CTRL    (`FI_DMI_BASE_ADDR + 7'h10)
`define FI_DMI_ADDR_TBL_ADDR    (`FI_DMI_BASE_ADDR + 7'h11)
`define FI_DMI_ADDR_TBL_WDATA   (`FI_DMI_BASE_ADDR + 7'h12)
`define FI_DMI_ADDR_TBL_RCMD    (`FI_DMI_BASE_ADDR + 7'h13)
`define FI_DMI_ADDR_TBL_RDATA   (`FI_DMI_BASE_ADDR + 7'h14)
`define FI_DMI_ADDR_TBL_STATUS  (`FI_DMI_BASE_ADDR + 7'h15)

// CFG0 bits
`define FI_CFG0_AUTO_BIT        0
`define FI_CFG0_END_BIT         1

// FI_CMD bits
`define FI_CMD_START_BIT        0

// TBL_CTRL bits
`define FI_TBL_CTRL_AUTOINC_BIT 0

// TBL_STATUS bits
`define FI_TBL_STATUS_PENDING_BIT 0
`define FI_TBL_STATUS_VALID_BIT   1

// FI_STATUS bits
`define FI_STATUS_ENABLE_BIT    0
`define FI_STATUS_TBL_DONE_BIT  1
`define FI_STATUS_ERR_ORDER_BIT 2
`define FI_STATUS_ERR_MALF_BIT  3
`define FI_STATUS_CYC_OVF_BIT   4

// FI_VERSION value. Bumped whenever the FI_Entry encoding changes, so
// a host can tell which table format the wrapper expects.
//   0x0001_0000 : {N[31:24], FI_Index[23:0]}, one scan pass per flipped bit
//   0x0002_0000 : {EOP, Cycle_Offset, FI_Index}, one scan pass per pattern
`define FI_VERSION_VALUE        32'h0002_0000

`endif




// `include "fi_jtag_fi_def.vh"

// ============================================================
// FI Transporter                                  (paper Fig. 4)
// ------------------------------------------------------------
// Owns the always-on (AON) JTAG connection to the host, terminates host
// control outside the DUT, and exposes the FI-private configuration and
// status window. Passive snoop + active cutover:
//
// fi_mode_active = 0 (paper: "Transparent"):
//   - DUT gets raw JTAG
//   - host sees raw DUT TDO
//   - transporter snoops only for the FI_MODE write trigger
//
// fi_mode_active = 1 (paper: "Parked"):
//   - DUT JTAG is cut off / parked
//   - transporter owns TAP/DTM/DMI and the FI registers
//
// Important:
// This module solves the JTAG-side ownership problem.
// If the FI Executor / FI Table host port are in a different clock
// domain than aon_clk_i, a second CDC wrapper is still required.
// ============================================================
module fi_transporter #(
    parameter integer DMI_ADDR_BITS = 7,
    parameter integer DMI_DATA_BITS = 32,
    parameter integer DMI_OP_BITS   = 2,
    parameter integer DW            = 32,
    parameter integer TBL_WORDS     = 256,
    parameter [31:0]  IDCODE_VALUE  = 32'hF17E_0006
) (
    input  wire                         aon_clk_i,
    input  wire                         aon_rst_ni,

    input  wire                         jtag_tck_i,
    input  wire                         jtag_tms_i,
    input  wire                         jtag_tdi_i,
    input  wire                         jtag_trst_ni,
    output wire                         jtag_tdo_o,

    // Downstream DUT JTAG
    output wire                         dut_jtag_tck_o,
    output wire                         dut_jtag_tms_o,
    output wire                         dut_jtag_tdi_o,
    input  wire                         dut_jtag_tdo_i,

    // Transporter -> FI executor config/control
    output wire                         fi_mode_o,
    output wire                         cfg_auto_o,
    output wire                         cfg_start_o,
    output wire [31:0]                  cfg_scan_len_o,
    output wire [31:0]                  cfg_fi_index_o,
    output wire                         cfg_end_o,
    output wire [31:0]                  cfg_fi_cycle_o,
    output wire                         cfg_fi_cycle_wr_o,   // 1-cycle strobe on a CFG_FI_CYCLE write
    output wire [31:0]                  cfg_to_thr_o,
    output wire [31:0]                  cfg_tbl_len_o,     // FI_Entry count in this batch

    // FI Transporter -> FI Table host port
    output wire                         tbl_host_wr_en_o,
    output wire                         tbl_host_rd_en_o,
    output wire [$clog2(TBL_WORDS)-1:0] tbl_host_addr_o,
    output wire [DW-1:0]                tbl_host_wdata_o,
    output wire [DW/8-1:0]              tbl_host_wmask_o,
    input  wire [DW-1:0]                tbl_host_rdata_i,

    // Status from executor
    input  wire                         cfg_en_able_i,
    input  wire [31:0]                  fi_cycle_i,
    input  wire                         table_exhausted_i,
    input  wire                         err_order_i,
    input  wire                         err_malformed_i,
    input  wire                         fi_cycle_ovf_i
);

    localparam integer TAP_REQ_BITS  = DMI_ADDR_BITS + DMI_DATA_BITS + DMI_OP_BITS;
    localparam integer DTM_REQ_BITS  = TAP_REQ_BITS;
    localparam integer DTM_RESP_BITS = TAP_REQ_BITS;
    localparam integer DMI_RESP_BITS = TAP_REQ_BITS;

    // TAP <-> DTM
    wire                     tap_req_w;
    wire [TAP_REQ_BITS-1:0]  tap_data_w;
    wire                     tap_dmireset_w;
    wire [DTM_RESP_BITS-1:0] tap_resp_data_w;
    wire [31:0]              tap_idcode_w;
    wire [31:0]              tap_dtmcs_w;
    wire                     tap_safe_switch_w;
    wire                     fi_jtag_tdo_w;
    wire                     tap_ir_is_dmi_w;

    // DTM <-> CDC
    wire [DTM_REQ_BITS-1:0]  dtm_req_data_w;
    wire                     dtm_req_valid_w;
    wire                     dtm_req_ready_w;

    wire [DMI_RESP_BITS-1:0] dmi_resp_data_w;
    wire                     dmi_resp_valid_w;
    wire                     dmi_resp_ready_w;
    wire                     dtm_idle_w;

    // CDC <-> regs
    wire [DTM_REQ_BITS-1:0]  core_req_data_w;
    wire                     core_req_valid_w;
    wire                     core_req_ready_w;

    wire [DMI_RESP_BITS-1:0] core_resp_data_w;
    wire                     core_resp_valid_w;
    wire                     core_resp_ready_w;

    // Requested mode from AON-side FI regs
    wire fi_mode_req_w;

    // Active routing mode in JTAG domain
    reg fi_mode_active_q;
    reg fi_mode_req_sync1_q;
    reg fi_mode_req_sync2_q;

    // ------------------------------------------------------------------
    // Shared reset for both CDC bridges
    // ------------------------------------------------------------------
    // fi_cdc_2phase_v6 is a 2-phase toggle handshake: the source and the
    // destination each hold half of a matched toggle pair. Resetting only
    // one half desynchronises them:
    //   - the source sees dst_toggle move and clears src_busy_q even though
    //     nothing was delivered (a request is lost, src_ready_o lies), and
    //   - the destination re-synchronises a src_toggle that no longer
    //     matches its own, fabricating a dst_valid_o pulse carrying stale
    //     src_data_hold_q (a phantom transaction).
    // Both halves must therefore see the same reset event. In the current
    // testbench jtag_trst_ni and aon_rst_ni are both tied to the global
    // rst_ni, so the hazard is masked; on FPGA/silicon with a real TRST pin
    // it is live.
    //
    // Scope note: this combination is applied to the CDC bridges ONLY.
    // It must not reach fi_dmi_regs_v6 - that bank holds the FI campaign
    // configuration and the FI table pointer, which have to survive a TRST.
    // Aborting the in-flight DMI transaction on TRST is the correct
    // semantic; losing the campaign configuration is not.
    //
    // FPGA note: this makes assertion consistent. If TRST and the AON reset
    // ever become genuinely independent, each domain still needs an
    // async-assert / sync-deassert reset synchroniser so that the release
    // edge is not asynchronous to the receiving clock.
    wire cdc_rst_ni = aon_rst_ni & jtag_trst_ni;

    // Synchronize requested mode into JTAG domain and only commit
    // on a safe JTAG boundary.
    always @(posedge jtag_tck_i or negedge jtag_trst_ni) begin
        if (!jtag_trst_ni) begin
            fi_mode_req_sync1_q <= 1'b0;
            fi_mode_req_sync2_q <= 1'b0;
            fi_mode_active_q    <= 1'b0;
        end else begin
            fi_mode_req_sync1_q <= fi_mode_req_w;
            fi_mode_req_sync2_q <= fi_mode_req_sync1_q;

            if (tap_safe_switch_w && dtm_idle_w) begin
                fi_mode_active_q <= fi_mode_req_sync2_q;
            end
        end
    end

    assign fi_mode_o = fi_mode_active_q;

    fi_jtag_tap #(
        .DMI_ADDR_BITS (DMI_ADDR_BITS),
        .DMI_DATA_BITS (DMI_DATA_BITS),
        .DMI_OP_BITS   (DMI_OP_BITS)
    ) u_tap (
        .jtag_tck_i        (jtag_tck_i),
        .jtag_tdi_i        (jtag_tdi_i),
        .jtag_tms_i        (jtag_tms_i),
        .jtag_trst_ni      (jtag_trst_ni),
        .jtag_tdo_o        (fi_jtag_tdo_w),

        .tap_req_o         (tap_req_w),
        .tap_data_o        (tap_data_w),
        .dmireset_o        (tap_dmireset_w),
        .tap_safe_switch_o (tap_safe_switch_w),
        .tap_ir_is_dmi_o   (tap_ir_is_dmi_w),

        .dtm_data_i        (tap_resp_data_w),
        .idcode_i          (tap_idcode_w),
        .dtmcs_i           (tap_dtmcs_w)
    );

    fi_jtag_dtm_v6 #(
        .DMI_ADDR_BITS (DMI_ADDR_BITS),
        .DMI_DATA_BITS (DMI_DATA_BITS),
        .DMI_OP_BITS   (DMI_OP_BITS),
        .IDCODE_VALUE  (IDCODE_VALUE)
    ) u_dtm (
        .jtag_tck_i        (jtag_tck_i),
        .jtag_trst_ni      (jtag_trst_ni),

        .fi_mode_active_i  (fi_mode_active_q),

        .tap_req_i         (tap_req_w),
        .tap_data_i        (tap_data_w),
        .dmireset_i        (tap_dmireset_w),
        .tap_ir_is_dmi_i   (tap_ir_is_dmi_w),

        .dtm_req_data_o    (dtm_req_data_w),
        .dtm_req_valid_o   (dtm_req_valid_w),
        .dtm_req_ready_i   (dtm_req_ready_w),

        .dmi_resp_data_i   (dmi_resp_data_w),
        .dmi_resp_valid_i  (dmi_resp_valid_w),
        .dmi_resp_ready_o  (dmi_resp_ready_w),

        .dtm_idle_o        (dtm_idle_w),

        .data_o            (tap_resp_data_w),
        .idcode_o          (tap_idcode_w),
        .dtmcs_o           (tap_dtmcs_w)
    );

    fi_cdc_2phase_v6 #(
        .DATA_WIDTH (DTM_REQ_BITS)
    ) u_cdc_req (
        .src_rst_ni  (cdc_rst_ni),
        .src_clk_i   (jtag_tck_i),
        .src_data_i  (dtm_req_data_w),
        .src_valid_i (dtm_req_valid_w),
        .src_ready_o (dtm_req_ready_w),

        .dst_rst_ni  (cdc_rst_ni),
        .dst_clk_i   (aon_clk_i),
        .dst_data_o  (core_req_data_w),
        .dst_valid_o (core_req_valid_w),
        .dst_ready_i (core_req_ready_w)
    );

    fi_cdc_2phase_v6 #(
        .DATA_WIDTH (DMI_RESP_BITS)
    ) u_cdc_resp (
        .src_rst_ni  (cdc_rst_ni),
        .src_clk_i   (aon_clk_i),
        .src_data_i  (core_resp_data_w),
        .src_valid_i (core_resp_valid_w),
        .src_ready_o (core_resp_ready_w),

        .dst_rst_ni  (cdc_rst_ni),
        .dst_clk_i   (jtag_tck_i),
        .dst_data_o  (dmi_resp_data_w),
        .dst_valid_o (dmi_resp_valid_w),
        .dst_ready_i (dmi_resp_ready_w)
    );

    fi_dmi_regs_v6 #(
        .DMI_ADDR_BITS (DMI_ADDR_BITS),
        .DMI_DATA_BITS (DMI_DATA_BITS),
        .DMI_OP_BITS   (DMI_OP_BITS),
        .DW            (DW),
        .TBL_WORDS     (TBL_WORDS)
    ) u_regs (
        .clk_i            (aon_clk_i),
        .rst_ni           (aon_rst_ni),

        .dmi_req_data_i   (core_req_data_w),
        .dmi_req_valid_i  (core_req_valid_w),
        .dmi_req_ready_o  (core_req_ready_w),

        .dmi_resp_data_o  (core_resp_data_w),
        .dmi_resp_valid_o (core_resp_valid_w),
        .dmi_resp_ready_i (core_resp_ready_w),

        .fi_mode_req_o    (fi_mode_req_w),
        .fi_mode_active_i (fi_mode_active_q),

        .cfg_auto_o       (cfg_auto_o),
        .cfg_start_o      (cfg_start_o),
        .cfg_scan_len_o        (cfg_scan_len_o),
        .cfg_fi_index_o      (cfg_fi_index_o),
        .cfg_end_o        (cfg_end_o),
        .cfg_fi_cycle_o     (cfg_fi_cycle_o),
        .cfg_fi_cycle_wr_o  (cfg_fi_cycle_wr_o),
        .cfg_to_thr_o     (cfg_to_thr_o),
        .cfg_tbl_len_o    (cfg_tbl_len_o),

        .tbl_host_wr_en_o (tbl_host_wr_en_o),
        .tbl_host_rd_en_o (tbl_host_rd_en_o),
        .tbl_host_addr_o  (tbl_host_addr_o),
        .tbl_host_wdata_o (tbl_host_wdata_o),
        .tbl_host_wmask_o (tbl_host_wmask_o),
        .tbl_host_rdata_i (tbl_host_rdata_i),

        .cfg_en_able_i     (cfg_en_able_i),
        .fi_cycle_i        (fi_cycle_i),
        .table_exhausted_i (table_exhausted_i),
        .err_order_i       (err_order_i),
        .err_malformed_i   (err_malformed_i),
        .fi_cycle_ovf_i    (fi_cycle_ovf_i)
    );

    // Transparent pass-through when FI mode is inactive.
    assign dut_jtag_tck_o = fi_mode_active_q ? 1'b0       : jtag_tck_i;
    assign dut_jtag_tms_o = fi_mode_active_q ? 1'b1       : jtag_tms_i;
    assign dut_jtag_tdi_o = fi_mode_active_q ? 1'b0       : jtag_tdi_i;

    assign jtag_tdo_o     = fi_mode_active_q ? fi_jtag_tdo_w : dut_jtag_tdo_i;

endmodule


// ============================================================
// JTAG TAP front-end
// ============================================================
module fi_jtag_tap #(
    parameter integer DMI_ADDR_BITS = 7,
    parameter integer DMI_DATA_BITS = 32,
    parameter integer DMI_OP_BITS   = 2
) (
    input  wire jtag_tck_i,
    input  wire jtag_tdi_i,
    input  wire jtag_tms_i,
    input  wire jtag_trst_ni,
    output wire jtag_tdo_o,

    output wire [DMI_ADDR_BITS + DMI_DATA_BITS + DMI_OP_BITS - 1:0] tap_data_o,
    output wire tap_req_o,
    output wire dmireset_o,
    output wire tap_safe_switch_o,
    output wire tap_ir_is_dmi_o,

    input  wire [DMI_ADDR_BITS + DMI_DATA_BITS + DMI_OP_BITS - 1:0] dtm_data_i,
    input  wire [31:0] idcode_i,
    input  wire [31:0] dtmcs_i
);
    localparam integer IR_BITS        = `FI_JTAG_IR_BITS;
    localparam integer SHIFT_REG_BITS = DMI_ADDR_BITS + DMI_DATA_BITS + DMI_OP_BITS;

    localparam [15:0] TEST_LOGIC_RESET = 16'h0001;
    localparam [15:0] RUN_TEST_IDLE    = 16'h0002;
    localparam [15:0] SELECT_DR        = 16'h0004;
    localparam [15:0] CAPTURE_DR       = 16'h0008;
    localparam [15:0] SHIFT_DR         = 16'h0010;
    localparam [15:0] EXIT1_DR         = 16'h0020;
    localparam [15:0] PAUSE_DR         = 16'h0040;
    localparam [15:0] EXIT2_DR         = 16'h0080;
    localparam [15:0] UPDATE_DR        = 16'h0100;
    localparam [15:0] SELECT_IR        = 16'h0200;
    localparam [15:0] CAPTURE_IR       = 16'h0400;
    localparam [15:0] SHIFT_IR         = 16'h0800;
    localparam [15:0] EXIT1_IR         = 16'h1000;
    localparam [15:0] PAUSE_IR         = 16'h2000;
    localparam [15:0] EXIT2_IR         = 16'h4000;
    localparam [15:0] UPDATE_IR        = 16'h8000;

    reg [15:0] tap_state_q, tap_state_d;
    reg [`FI_JTAG_IR_BITS-1:0] ir_reg_q;
    reg [SHIFT_REG_BITS-1:0] shift_reg_q;
    reg tap_req_q;
    reg [SHIFT_REG_BITS-1:0] tap_data_q;
    reg dmireset_q;
    reg jtag_tdo_q;

    always @(*) begin
        case (tap_state_q)
            TEST_LOGIC_RESET: tap_state_d = jtag_tms_i ? TEST_LOGIC_RESET : RUN_TEST_IDLE;
            RUN_TEST_IDLE   : tap_state_d = jtag_tms_i ? SELECT_DR        : RUN_TEST_IDLE;
            SELECT_DR       : tap_state_d = jtag_tms_i ? SELECT_IR        : CAPTURE_DR;
            CAPTURE_DR      : tap_state_d = jtag_tms_i ? EXIT1_DR         : SHIFT_DR;
            SHIFT_DR        : tap_state_d = jtag_tms_i ? EXIT1_DR         : SHIFT_DR;
            EXIT1_DR        : tap_state_d = jtag_tms_i ? UPDATE_DR        : PAUSE_DR;
            PAUSE_DR        : tap_state_d = jtag_tms_i ? EXIT2_DR         : PAUSE_DR;
            EXIT2_DR        : tap_state_d = jtag_tms_i ? UPDATE_DR        : SHIFT_DR;
            UPDATE_DR       : tap_state_d = jtag_tms_i ? SELECT_DR        : RUN_TEST_IDLE;
            SELECT_IR       : tap_state_d = jtag_tms_i ? TEST_LOGIC_RESET : CAPTURE_IR;
            CAPTURE_IR      : tap_state_d = jtag_tms_i ? EXIT1_IR         : SHIFT_IR;
            SHIFT_IR        : tap_state_d = jtag_tms_i ? EXIT1_IR         : SHIFT_IR;
            EXIT1_IR        : tap_state_d = jtag_tms_i ? UPDATE_IR        : PAUSE_IR;
            PAUSE_IR        : tap_state_d = jtag_tms_i ? EXIT2_IR         : PAUSE_IR;
            EXIT2_IR        : tap_state_d = jtag_tms_i ? UPDATE_IR        : SHIFT_IR;
            UPDATE_IR       : tap_state_d = jtag_tms_i ? SELECT_DR        : RUN_TEST_IDLE;
            default         : tap_state_d = TEST_LOGIC_RESET;
        endcase
    end

    always @(posedge jtag_tck_i or negedge jtag_trst_ni) begin
        if (!jtag_trst_ni)
            tap_state_q <= TEST_LOGIC_RESET;
        else
            tap_state_q <= tap_state_d;
    end

    always @(posedge jtag_tck_i or negedge jtag_trst_ni) begin
        if (!jtag_trst_ni) begin
            shift_reg_q <= {SHIFT_REG_BITS{1'b0}};
        end else begin
            case (tap_state_q)
                CAPTURE_IR: begin
                    shift_reg_q <= {{(SHIFT_REG_BITS-2){1'b0}}, 2'b01};
                end

                SHIFT_IR: begin
                    shift_reg_q <= {
                        {(SHIFT_REG_BITS-IR_BITS){1'b0}},
                        jtag_tdi_i,
                        shift_reg_q[IR_BITS-1:1]
                    };
                end

                CAPTURE_DR: begin
                    case (ir_reg_q)
                        `FI_JTAG_IR_BYPASS: shift_reg_q <= {SHIFT_REG_BITS{1'b0}};
                        `FI_JTAG_IR_IDCODE: shift_reg_q <= {{(SHIFT_REG_BITS-32){1'b0}}, idcode_i};
                        `FI_JTAG_IR_DTMCS : shift_reg_q <= {{(SHIFT_REG_BITS-32){1'b0}}, dtmcs_i};
                        `FI_JTAG_IR_DMI   : shift_reg_q <= dtm_data_i;
                        default           : shift_reg_q <= {SHIFT_REG_BITS{1'b0}};
                    endcase
                end

                SHIFT_DR: begin
                    case (ir_reg_q)
                        `FI_JTAG_IR_BYPASS: shift_reg_q <= {{(SHIFT_REG_BITS-1){1'b0}}, jtag_tdi_i};
                        `FI_JTAG_IR_IDCODE: shift_reg_q <= {{(SHIFT_REG_BITS-32){1'b0}}, jtag_tdi_i, shift_reg_q[31:1]};
                        `FI_JTAG_IR_DTMCS : shift_reg_q <= {{(SHIFT_REG_BITS-32){1'b0}}, jtag_tdi_i, shift_reg_q[31:1]};
                        `FI_JTAG_IR_DMI   : shift_reg_q <= {jtag_tdi_i, shift_reg_q[SHIFT_REG_BITS-1:1]};
                        default           : shift_reg_q <= {{(SHIFT_REG_BITS-1){1'b0}}, jtag_tdi_i};
                    endcase
                end

                default: begin
                end
            endcase
        end
    end

    always @(posedge jtag_tck_i or negedge jtag_trst_ni) begin
        if (!jtag_trst_ni) begin
            tap_req_q  <= 1'b0;
            tap_data_q <= {SHIFT_REG_BITS{1'b0}};
            dmireset_q <= 1'b0;
        end else begin
            tap_req_q  <= ((tap_state_q == UPDATE_DR) && (ir_reg_q == `FI_JTAG_IR_DMI));
            tap_data_q <= shift_reg_q;
            dmireset_q <= ((tap_state_q == UPDATE_DR) &&
                           (ir_reg_q == `FI_JTAG_IR_DTMCS) &&
                           shift_reg_q[16]);
        end
    end

    always @(negedge jtag_tck_i or negedge jtag_trst_ni) begin
        if (!jtag_trst_ni) begin
            ir_reg_q   <= `FI_JTAG_IR_IDCODE;
            jtag_tdo_q <= 1'b0;
        end else begin
            if (tap_state_q == TEST_LOGIC_RESET)
                ir_reg_q <= `FI_JTAG_IR_IDCODE;
            else if (tap_state_q == UPDATE_IR)
                ir_reg_q <= shift_reg_q[IR_BITS-1:0];

            if ((tap_state_q == SHIFT_IR) || (tap_state_q == SHIFT_DR))
                jtag_tdo_q <= shift_reg_q[0];
            else
                jtag_tdo_q <= 1'b0;
        end
    end

    assign tap_req_o         = tap_req_q;
    assign tap_data_o        = tap_data_q;
    assign dmireset_o        = dmireset_q;
    assign jtag_tdo_o        = jtag_tdo_q;
    assign tap_safe_switch_o = (tap_state_q == RUN_TEST_IDLE) ||
                               (tap_state_q == TEST_LOGIC_RESET);
    assign tap_ir_is_dmi_o   = (ir_reg_q == `FI_JTAG_IR_DMI);

endmodule


// ============================================================
// JTAG-side DTM FSM
// ------------------------------------------------------------
// Passive mode (fi_mode_active_i=0):
//   - do NOT run full busy/response semantics
//   - only snoop for one trigger:
//       IR=DMI, UPDATE_DR packet, op=WRITE, addr=FI_MODE, data[0]=1
//   - issue one request pulse for that trigger only
//
// Active mode (fi_mode_active_i=1):
//   - normal FI-side DTM/response behavior
// ============================================================
module fi_jtag_dtm_v6 #(
    parameter integer DMI_ADDR_BITS = 7,
    parameter integer DMI_DATA_BITS = 32,
    parameter integer DMI_OP_BITS   = 2,
    parameter [31:0]  IDCODE_VALUE  = 32'hF17E_0006
) (
    input  wire jtag_tck_i,
    input  wire jtag_trst_ni,

    input  wire fi_mode_active_i,

    input  wire [DMI_ADDR_BITS + DMI_DATA_BITS + DMI_OP_BITS - 1:0] tap_data_i,
    input  wire tap_req_i,
    input  wire dmireset_i,
    input  wire tap_ir_is_dmi_i,

    output wire [DMI_ADDR_BITS + DMI_DATA_BITS + DMI_OP_BITS - 1:0] dtm_req_data_o,
    output wire dtm_req_valid_o,
    input  wire dtm_req_ready_i,

    input  wire [DMI_ADDR_BITS + DMI_DATA_BITS + DMI_OP_BITS - 1:0] dmi_resp_data_i,
    input  wire dmi_resp_valid_i,
    output wire dmi_resp_ready_o,
    output wire dtm_idle_o,

    output wire [DMI_ADDR_BITS + DMI_DATA_BITS + DMI_OP_BITS - 1:0] data_o,
    output wire [31:0] idcode_o,
    output wire [31:0] dtmcs_o
);
    localparam integer DTM_BITS = DMI_ADDR_BITS + DMI_DATA_BITS + DMI_OP_BITS;
    localparam [5:0] DMI_ABITS  = DMI_ADDR_BITS[5:0];

    localparam [1:0] S_IDLE      = 2'd0;
    localparam [1:0] S_SEND      = 2'd1;
    localparam [1:0] S_WAIT_RESP = 2'd2;

    reg [1:0]          state_q;
    reg [DTM_BITS-1:0] dtm_data_q;
    reg                stick_busy_q;
    reg                req_pulse_q;
    reg                resp_ready_q;

    wire [DMI_OP_BITS-1:0]   req_op_w;
    wire [DMI_DATA_BITS-1:0] req_data_w;
    wire [DMI_ADDR_BITS-1:0] req_addr_w;
    wire req_is_active_w;
    wire busy_now_w;
    wire [DTM_BITS-1:0] busy_response_w;
    wire [1:0] dmistat_w;

    wire passive_entry_trigger_w;

    assign req_op_w        = tap_data_i[DMI_OP_BITS-1:0];
    assign req_data_w      = tap_data_i[DMI_OP_BITS +: DMI_DATA_BITS];
    assign req_addr_w      = tap_data_i[DTM_BITS-1 -: DMI_ADDR_BITS];
    assign req_is_active_w = (req_op_w == `FI_DMI_OP_READ) ||
                             (req_op_w == `FI_DMI_OP_WRITE);
    assign busy_now_w      = (state_q != S_IDLE);

    assign passive_entry_trigger_w =
        (!fi_mode_active_i) &&
        tap_req_i &&
        tap_ir_is_dmi_i &&
        (req_op_w   == `FI_DMI_OP_WRITE) &&
        (req_addr_w == `FI_DMI_ADDR_FI_MODE) &&
        (req_data_w[0] == 1'b1);

    assign busy_response_w = {{(DMI_ADDR_BITS + DMI_DATA_BITS){1'b0}}, `FI_DMI_RESP_BUSY};
    assign dmistat_w       = (fi_mode_active_i && (stick_busy_q || busy_now_w)) ? 2'b11 : 2'b00;

    assign idcode_o = IDCODE_VALUE;
    assign dtmcs_o  = {
        14'b0,
        1'b0,       // dmihardreset
        1'b0,       // dmireset reads 0
        1'b0,       // reserved
        3'h1,       // idle hint
        dmistat_w,
        DMI_ABITS,
        4'h1
    };

    always @(posedge jtag_tck_i or negedge jtag_trst_ni) begin
        if (!jtag_trst_ni) begin
            state_q      <= S_IDLE;
            dtm_data_q   <= {DTM_BITS{1'b0}};
            stick_busy_q <= 1'b0;
            req_pulse_q  <= 1'b0;
            resp_ready_q <= 1'b0;
        end else begin
            req_pulse_q  <= 1'b0;
            resp_ready_q <= 1'b0;

            // In passive mode, keep local DTM quiescent except for one entry trigger.
            if (!fi_mode_active_i) begin
                state_q      <= S_IDLE;
                dtm_data_q   <= {DTM_BITS{1'b0}};
                stick_busy_q <= 1'b0;

                if (passive_entry_trigger_w && dtm_req_ready_i) begin
                    dtm_data_q  <= tap_data_i;
                    req_pulse_q <= 1'b1;
                end
            end else begin
                if (dmireset_i)
                    stick_busy_q <= 1'b0;

                case (state_q)
                    S_IDLE: begin
                        if (tap_req_i && req_is_active_w) begin
                            dtm_data_q <= tap_data_i;
                            state_q    <= S_SEND;
                        end
                    end

                    S_SEND: begin
                        if (dtm_req_ready_i) begin
                            req_pulse_q <= 1'b1;
                            state_q     <= S_WAIT_RESP;
                        end
                    end

                    S_WAIT_RESP: begin
                        resp_ready_q <= 1'b1;

                        if (tap_req_i)
                            stick_busy_q <= 1'b1;

                        if (dmi_resp_valid_i) begin
                            dtm_data_q <= dmi_resp_data_i;
                            state_q    <= S_IDLE;
                        end
                    end

                    default: begin
                        state_q <= S_IDLE;
                    end
                endcase

                if ((state_q == S_SEND || state_q == S_WAIT_RESP) && tap_req_i)
                    stick_busy_q <= 1'b1;
            end
        end
    end

    assign dtm_req_data_o   = dtm_data_q;
    assign dtm_req_valid_o  = req_pulse_q;

    // ------------------------------------------------------------------
    // Response drain rule
    // ------------------------------------------------------------------
    // Every request this DTM issues produces exactly one response, and the
    // DTM is the only consumer of the response CDC. If a response is not
    // taken, u_cdc_resp keeps dst_valid_o asserted, its source half stays
    // busy, fi_dmi_regs_v6 never clears dmi_resp_valid_o and therefore
    // holds dmi_req_ready_o low - the whole DMI path stalls behind it.
    //
    // Two cases have to be covered:
    //   S_WAIT_RESP : the response for the outstanding request (resp_ready_q)
    //   S_IDLE      : any response arriving here is an orphan. The DTM never
    //                 has more than one request in flight (u_cdc_req allows
    //                 only one), so a response seen while idle belongs to a
    //                 transaction whose response was already consumed, or to
    //                 the passive-mode FI_MODE entry trigger. It must be
    //                 dropped, not left in the bridge.
    //
    // Passive mode holds state_q at S_IDLE, so the FI_MODE trigger response
    // is drained there as well. The previous form
    //     fi_mode_active_i ? resp_ready_q : 1'b0
    // never drained it, which left every post-cutover transaction reading
    // back the PREVIOUS transaction's response. Gating on fi_mode_active_i
    // is not enough either: the cutover commits through 2 sync stages while
    // the response returns through 3, so the mode flips before the response
    // arrives and it would be stranded anyway.
    assign dmi_resp_ready_o = resp_ready_q | (state_q == S_IDLE);

    assign dtm_idle_o       = (state_q == S_IDLE);

    // In passive mode, TDO is not selected, so returned DMI payload is irrelevant.
    // Still keep it stable and benign.
    assign data_o = fi_mode_active_i
                  ? ((stick_busy_q || busy_now_w) ? busy_response_w : dtm_data_q)
                  : {DTM_BITS{1'b0}};

endmodule


// ============================================================
// 2-phase CDC bridge
// ============================================================
module fi_cdc_2phase_v6 #(
    parameter integer DATA_WIDTH = 41
) (
    input  wire                  src_rst_ni,
    input  wire                  src_clk_i,
    input  wire [DATA_WIDTH-1:0] src_data_i,
    input  wire                  src_valid_i,
    output wire                  src_ready_o,

    input  wire                  dst_rst_ni,
    input  wire                  dst_clk_i,
    output reg  [DATA_WIDTH-1:0] dst_data_o,
    output reg                   dst_valid_o,
    input  wire                  dst_ready_i
);
    reg [DATA_WIDTH-1:0] src_data_hold_q;
    reg                  src_toggle_q;
    reg                  src_busy_q;
    reg                  dst_toggle_q;

    reg dst_toggle_src1_q, dst_toggle_src2_q, dst_toggle_src3_q;
    reg src_toggle_dst1_q, src_toggle_dst2_q, src_toggle_dst3_q;

    assign src_ready_o = ~src_busy_q;

    always @(posedge src_clk_i or negedge src_rst_ni) begin
        if (!src_rst_ni) begin
            src_data_hold_q   <= {DATA_WIDTH{1'b0}};
            src_toggle_q      <= 1'b0;
            src_busy_q        <= 1'b0;
            dst_toggle_src1_q <= 1'b0;
            dst_toggle_src2_q <= 1'b0;
            dst_toggle_src3_q <= 1'b0;
        end else begin
            dst_toggle_src1_q <= dst_toggle_q;
            dst_toggle_src2_q <= dst_toggle_src1_q;
            dst_toggle_src3_q <= dst_toggle_src2_q;

            if (src_busy_q && (dst_toggle_src2_q ^ dst_toggle_src3_q))
                src_busy_q <= 1'b0;

            if (src_valid_i && !src_busy_q) begin
                src_data_hold_q <= src_data_i;
                src_toggle_q    <= ~src_toggle_q;
                src_busy_q      <= 1'b1;
            end
        end
    end

    always @(posedge dst_clk_i or negedge dst_rst_ni) begin
        if (!dst_rst_ni) begin
            src_toggle_dst1_q <= 1'b0;
            src_toggle_dst2_q <= 1'b0;
            src_toggle_dst3_q <= 1'b0;
            dst_data_o        <= {DATA_WIDTH{1'b0}};
            dst_valid_o       <= 1'b0;
            dst_toggle_q      <= 1'b0;
        end else begin
            src_toggle_dst1_q <= src_toggle_q;
            src_toggle_dst2_q <= src_toggle_dst1_q;
            src_toggle_dst3_q <= src_toggle_dst2_q;

            if (!dst_valid_o && (src_toggle_dst2_q ^ src_toggle_dst3_q)) begin
                dst_data_o  <= src_data_hold_q;
                dst_valid_o <= 1'b1;
            end else if (dst_valid_o && dst_ready_i) begin
                dst_valid_o <= 1'b0;
                dst_toggle_q <= src_toggle_dst2_q;
            end
        end
    end

endmodule


// ============================================================
// AON-side FI-private DMI register bank
// ============================================================
module fi_dmi_regs_v6 #(
    parameter integer DMI_ADDR_BITS = 7,
    parameter integer DMI_DATA_BITS = 32,
    parameter integer DMI_OP_BITS   = 2,
    parameter integer DW            = 32,
    parameter integer TBL_WORDS     = 256
) (
    input  wire clk_i,
    input  wire rst_ni,

    input  wire [DMI_ADDR_BITS + DMI_DATA_BITS + DMI_OP_BITS - 1:0] dmi_req_data_i,
    input  wire dmi_req_valid_i,
    output wire dmi_req_ready_o,

    output reg  [DMI_ADDR_BITS + DMI_DATA_BITS + DMI_OP_BITS - 1:0] dmi_resp_data_o,
    output reg  dmi_resp_valid_o,
    input  wire dmi_resp_ready_i,

    output reg  fi_mode_req_o,
    input  wire fi_mode_active_i,

    output reg  cfg_auto_o,
    output reg  cfg_start_o,
    output reg  [31:0] cfg_scan_len_o,
    output reg  [31:0] cfg_fi_index_o,
    output reg  cfg_end_o,
    output reg  [31:0] cfg_fi_cycle_o,
    output reg  cfg_fi_cycle_wr_o,
    output reg  [31:0] cfg_to_thr_o,
    output reg  [31:0] cfg_tbl_len_o,

    output reg  tbl_host_wr_en_o,
    output reg  tbl_host_rd_en_o,
    output reg  [$clog2(TBL_WORDS)-1:0] tbl_host_addr_o,
    output reg  [DW-1:0] tbl_host_wdata_o,
    output reg  [DW/8-1:0] tbl_host_wmask_o,
    input  wire [DW-1:0] tbl_host_rdata_i,

    input  wire cfg_en_able_i,
    input  wire [31:0] fi_cycle_i,
    input  wire table_exhausted_i,
    input  wire err_order_i,
    input  wire err_malformed_i,
    input  wire fi_cycle_ovf_i
);

    localparam integer REQ_BITS      = DMI_ADDR_BITS + DMI_DATA_BITS + DMI_OP_BITS;
    localparam integer TBL_ADDR_BITS = (TBL_WORDS <= 1) ? 1 : $clog2(TBL_WORDS);

    localparam [1:0] TBL_IDLE    = 2'd0;
    localparam [1:0] TBL_RD_ISS  = 2'd1;
    localparam [1:0] TBL_RD_WAIT = 2'd2;

    wire [DMI_OP_BITS-1:0]   req_op_w;
    wire [DMI_DATA_BITS-1:0] req_data_w;
    wire [DMI_ADDR_BITS-1:0] req_addr_w;

    reg [1:0]    tbl_state_q;
    reg [DW-1:0] tbl_rdata_shadow_q;
    reg          tbl_rd_pending_q;
    reg          tbl_rd_valid_q;
    reg          tbl_auto_inc_q;

    // Live software-visible pointer register.
    reg [TBL_ADDR_BITS-1:0] tbl_addr_ptr_q;

    assign req_op_w   = dmi_req_data_i[DMI_OP_BITS-1:0];
    assign req_data_w = dmi_req_data_i[DMI_OP_BITS +: DMI_DATA_BITS];
    assign req_addr_w = dmi_req_data_i[REQ_BITS-1 -: DMI_ADDR_BITS];

    assign dmi_req_ready_o = ~dmi_resp_valid_o;

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            fi_mode_req_o      <= 1'b0;
            cfg_auto_o         <= 1'b0;
            cfg_start_o        <= 1'b0;
            cfg_scan_len_o          <= 32'h0;
            cfg_fi_index_o        <= 32'h0;
            cfg_end_o          <= 1'b0;
            cfg_fi_cycle_o       <= 32'h0;
            cfg_fi_cycle_wr_o    <= 1'b0;
            cfg_to_thr_o       <= 32'h0;
            cfg_tbl_len_o      <= 32'h0;   // 0 = no table -> nothing is injected

            tbl_host_wr_en_o   <= 1'b0;
            tbl_host_rd_en_o   <= 1'b0;
            tbl_host_addr_o    <= {TBL_ADDR_BITS{1'b0}};
            tbl_host_wdata_o   <= {DW{1'b0}};
            tbl_host_wmask_o   <= {(DW/8){1'b1}}; // whole-word writes only

            dmi_resp_data_o    <= {{(REQ_BITS-DMI_OP_BITS){1'b0}}, `FI_DMI_RESP_OK};
            dmi_resp_valid_o   <= 1'b0;

            tbl_state_q        <= TBL_IDLE;
            tbl_rdata_shadow_q <= {DW{1'b0}};
            tbl_rd_pending_q   <= 1'b0;
            tbl_rd_valid_q     <= 1'b0;
            tbl_auto_inc_q     <= 1'b0;
            tbl_addr_ptr_q     <= {TBL_ADDR_BITS{1'b0}};
        end else begin
            cfg_start_o      <= 1'b0;
            cfg_fi_cycle_wr_o  <= 1'b0;
            tbl_host_wr_en_o <= 1'b0;
            tbl_host_rd_en_o <= 1'b0;

            if (dmi_resp_valid_o && dmi_resp_ready_i)
                dmi_resp_valid_o <= 1'b0;

            case (tbl_state_q)
                TBL_IDLE: begin
                    if (tbl_rd_pending_q) begin
                        // Present current pointer to the FI Table read port and pulse read enable.
                        tbl_host_addr_o  <= tbl_addr_ptr_q;
                        tbl_host_rd_en_o <= 1'b1;
                        tbl_state_q      <= TBL_RD_ISS;
                    end
                end

                TBL_RD_ISS: begin
                    tbl_state_q <= TBL_RD_WAIT;
                end

                TBL_RD_WAIT: begin
                    tbl_rdata_shadow_q <= tbl_host_rdata_i;
                    tbl_rd_valid_q     <= 1'b1;
                    tbl_rd_pending_q   <= 1'b0;
                    tbl_state_q        <= TBL_IDLE;
                end

                default: begin
                    tbl_state_q <= TBL_IDLE;
                end
            endcase

            if (dmi_req_valid_i && dmi_req_ready_o && !dmi_resp_valid_o) begin
                case (req_op_w)
                    `FI_DMI_OP_NOP: begin
                        dmi_resp_data_o  <= {req_addr_w, req_data_w, `FI_DMI_RESP_OK};
                        dmi_resp_valid_o <= 1'b1;
                    end

                    `FI_DMI_OP_READ: begin
                        case (req_addr_w)
                            `FI_DMI_ADDR_FI_MODE: begin
                                dmi_resp_data_o <= {
                                    req_addr_w,
                                    {31'b0, fi_mode_active_i},
                                    `FI_DMI_RESP_OK
                                };
                            end

                            `FI_DMI_ADDR_FI_STATUS: begin
                                dmi_resp_data_o <= {
                                    req_addr_w,
                                    {27'b0,
                                     fi_cycle_ovf_i,     // bit4
                                     err_malformed_i,    // bit3
                                     err_order_i,        // bit2
                                     table_exhausted_i,  // bit1
                                     cfg_en_able_i},     // bit0
                                    `FI_DMI_RESP_OK
                                };
                            end

                            `FI_DMI_ADDR_CFG0: begin
                                dmi_resp_data_o <= {
                                    req_addr_w,
                                    {30'b0, cfg_end_o, cfg_auto_o},
                                    `FI_DMI_RESP_OK
                                };
                            end

                            `FI_DMI_ADDR_CFG_SCAN_LEN: begin
                                dmi_resp_data_o <= {req_addr_w, cfg_scan_len_o, `FI_DMI_RESP_OK};
                            end

                            `FI_DMI_ADDR_CFG_FI_INDEX: begin
                                dmi_resp_data_o <= {req_addr_w, cfg_fi_index_o, `FI_DMI_RESP_OK};
                            end

                            `FI_DMI_ADDR_CFG_FI_CYCLE: begin
                                dmi_resp_data_o <= {req_addr_w, cfg_fi_cycle_o, `FI_DMI_RESP_OK};
                            end

                            `FI_DMI_ADDR_CFG_TO_THR: begin
                                dmi_resp_data_o <= {req_addr_w, cfg_to_thr_o, `FI_DMI_RESP_OK};
                            end

                            `FI_DMI_ADDR_CFG_TBL_LEN: begin
                                dmi_resp_data_o <= {req_addr_w, cfg_tbl_len_o, `FI_DMI_RESP_OK};
                            end

                            // Running FI_Cycle. Advances by the current
                            // pattern's Cycle_Offset every trial, so this is
                            // the read-back for a cycle sweep.
                            `FI_DMI_ADDR_FI_CYCLE: begin
                                dmi_resp_data_o <= {req_addr_w, fi_cycle_i, `FI_DMI_RESP_OK};
                            end

                            `FI_DMI_ADDR_FI_VERSION: begin
                                dmi_resp_data_o <= {req_addr_w, `FI_VERSION_VALUE, `FI_DMI_RESP_OK};
                            end

                            `FI_DMI_ADDR_TBL_CTRL: begin
                                dmi_resp_data_o <= {
                                    req_addr_w,
                                    {31'b0, tbl_auto_inc_q},
                                    `FI_DMI_RESP_OK
                                };
                            end

                            `FI_DMI_ADDR_TBL_ADDR: begin
                                dmi_resp_data_o <= {
                                    req_addr_w,
                                    {{(32-TBL_ADDR_BITS){1'b0}}, tbl_addr_ptr_q},
                                    `FI_DMI_RESP_OK
                                };
                            end

                            `FI_DMI_ADDR_TBL_WDATA: begin
                                dmi_resp_data_o <= {
                                    req_addr_w,
                                    tbl_host_wdata_o,
                                    `FI_DMI_RESP_OK
                                };
                            end

                            `FI_DMI_ADDR_TBL_RDATA: begin
                                dmi_resp_data_o <= {
                                    req_addr_w,
                                    tbl_rdata_shadow_q,
                                    tbl_rd_valid_q ? `FI_DMI_RESP_OK : `FI_DMI_RESP_BUSY
                                };
                            end

                            `FI_DMI_ADDR_TBL_STATUS: begin
                                dmi_resp_data_o <= {
                                    req_addr_w,
                                    {29'b0, tbl_rd_valid_q, tbl_rd_pending_q, tbl_auto_inc_q},
                                    `FI_DMI_RESP_OK
                                };
                            end

                            default: begin
                                dmi_resp_data_o <= {
                                    req_addr_w,
                                    32'hBADA_0001,
                                    `FI_DMI_RESP_FAIL
                                };
                            end
                        endcase

                        dmi_resp_valid_o <= 1'b1;
                    end

                    `FI_DMI_OP_WRITE: begin
                        case (req_addr_w)
                            `FI_DMI_ADDR_FI_MODE: begin
                                fi_mode_req_o <= req_data_w[0];
                                dmi_resp_data_o <= {
                                    req_addr_w,
                                    {31'b0, req_data_w[0]},
                                    `FI_DMI_RESP_OK
                                };
                            end

                            `FI_DMI_ADDR_CFG0: begin
                                cfg_auto_o <= req_data_w[`FI_CFG0_AUTO_BIT];
                                cfg_end_o  <= req_data_w[`FI_CFG0_END_BIT];
                                dmi_resp_data_o <= {
                                    req_addr_w,
                                    {30'b0,
                                     req_data_w[`FI_CFG0_END_BIT],
                                     req_data_w[`FI_CFG0_AUTO_BIT]},
                                    `FI_DMI_RESP_OK
                                };
                            end

                            `FI_DMI_ADDR_CFG_SCAN_LEN: begin
                                cfg_scan_len_o <= req_data_w;
                                dmi_resp_data_o <= {
                                    req_addr_w,
                                    req_data_w,
                                    `FI_DMI_RESP_OK
                                };
                            end

                            `FI_DMI_ADDR_CFG_FI_INDEX: begin
                                cfg_fi_index_o <= req_data_w;
                                dmi_resp_data_o <= {
                                    req_addr_w,
                                    req_data_w,
                                    `FI_DMI_RESP_OK
                                };
                            end

                            // Writing the base target cycle also re-arms the
                            // executor's FI_Cycle accumulator. The strobe is
                            // what does it -- rewriting the SAME value must
                            // still reset a sweep that has already advanced.
                            `FI_DMI_ADDR_CFG_FI_CYCLE: begin
                                cfg_fi_cycle_o    <= req_data_w;
                                cfg_fi_cycle_wr_o <= 1'b1;
                                dmi_resp_data_o <= {
                                    req_addr_w,
                                    req_data_w,
                                    `FI_DMI_RESP_OK
                                };
                            end

                            `FI_DMI_ADDR_CFG_TO_THR: begin
                                cfg_to_thr_o <= req_data_w;
                                dmi_resp_data_o <= {
                                    req_addr_w,
                                    req_data_w,
                                    `FI_DMI_RESP_OK
                                };
                            end

                            `FI_DMI_ADDR_CFG_TBL_LEN: begin
                                cfg_tbl_len_o <= req_data_w;
                                dmi_resp_data_o <= {
                                    req_addr_w,
                                    req_data_w,
                                    `FI_DMI_RESP_OK
                                };
                            end

                            `FI_DMI_ADDR_FI_CMD: begin
                                cfg_start_o <= req_data_w[`FI_CMD_START_BIT];
                                dmi_resp_data_o <= {
                                    req_addr_w,
                                    req_data_w,
                                    `FI_DMI_RESP_OK
                                };
                            end

                            `FI_DMI_ADDR_TBL_CTRL: begin
                                tbl_auto_inc_q <= req_data_w[`FI_TBL_CTRL_AUTOINC_BIT];
                                dmi_resp_data_o <= {
                                    req_addr_w,
                                    {31'b0, req_data_w[`FI_TBL_CTRL_AUTOINC_BIT]},
                                    `FI_DMI_RESP_OK
                                };
                            end

                            `FI_DMI_ADDR_TBL_ADDR: begin
                                tbl_addr_ptr_q <= req_data_w[TBL_ADDR_BITS-1:0];
                                dmi_resp_data_o <= {
                                    req_addr_w,
                                    {{(32-TBL_ADDR_BITS){1'b0}}, req_data_w[TBL_ADDR_BITS-1:0]},
                                    `FI_DMI_RESP_OK
                                };
                            end

                            `FI_DMI_ADDR_TBL_WDATA: begin
                                // Snapshot current pointer to the FI Table host address bus.
                                // The table consumes it on the next clk edge when wr_en is seen.
                                tbl_host_addr_o  <= tbl_addr_ptr_q;
                                tbl_host_wdata_o <= req_data_w[DW-1:0];
                                tbl_host_wr_en_o <= 1'b1;

                                if (tbl_auto_inc_q)
                                    tbl_addr_ptr_q <= tbl_addr_ptr_q + {{(TBL_ADDR_BITS-1){1'b0}}, 1'b1};

                                dmi_resp_data_o <= {
                                    req_addr_w,
                                    req_data_w,
                                    `FI_DMI_RESP_OK
                                };
                            end

                            `FI_DMI_ADDR_TBL_RCMD: begin
                                tbl_rd_pending_q <= 1'b1;
                                tbl_rd_valid_q   <= 1'b0;
                                dmi_resp_data_o  <= {
                                    req_addr_w,
                                    req_data_w,
                                    `FI_DMI_RESP_OK
                                };
                            end

                            default: begin
                                dmi_resp_data_o <= {
                                    req_addr_w,
                                    32'hBADA_0002,
                                    `FI_DMI_RESP_FAIL
                                };
                            end
                        endcase

                        dmi_resp_valid_o <= 1'b1;
                    end

                    default: begin
                        dmi_resp_data_o  <= {
                            req_addr_w,
                            32'hBADA_0003,
                            `FI_DMI_RESP_FAIL
                        };
                        dmi_resp_valid_o <= 1'b1;
                    end
                endcase
            end
        end
    end

endmodule