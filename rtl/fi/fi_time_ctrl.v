// SPDX-License-Identifier: Apache-2.0
// Copyright 2025-2026 the FIawase authors
// ============================================================
// FI Time Controller + FI Resolver        (paper Fig. 5, FI Executor)
// ------------------------------------------------------------
// Paper name -> code name
//   FI_Cycle      fi_cycle_q / fi_cycle_o     TO_Thr  cfg_to_thr_i
//   scan start    scan_start_o
//   Cycle_Offset  cycle_offset_i  (from the FI Table Controller)
//
// The paper draws the FI Resolver as a separate block. In RTL it is the
// reset window in the second half of this module: on timeout,
// resolver_rst_o resets the DUT and every counter in the FI logic while
// the FI configuration registers -- which live in the FI Transporter --
// are left untouched. That is the "reset all states except FI
// Configuration" arrow of Fig. 5. Impact Classify is host side and has
// no RTL here.
// ============================================================
module fi_time_ctrl #(
  // ============================================================
  // Reset-window pacing
  // ------------------------------------------------------------
  // RTC_ALIGN_EN = 1 : the DUT has an independent slow (RTC / lf) clock
  //                    domain. The reset window is advanced by rising
  //                    edges of aon_rtcToggle_a, so the phase at which
  //                    reset is released is deterministic with respect
  //                    to that domain. Without it the program would
  //                    restart at a different hf/lf phase every
  //                    iteration and the cycle counter / PC would drift.
  //
  // RTC_ALIGN_EN = 0 : single-clock DUT. There is no slow domain to
  //                    align to, so aon_rtcToggle_a takes no part in the
  //                    reset logic at all and may be tied off. The
  //                    window is paced by a fixed hf cycle count, which
  //                    is deterministic by construction.
  //
  // RST_CYC : length of each of the two reset-window phases, in hf
  //           cycles. Only used when RTC_ALIGN_EN = 0. resolver_rst is held
  //           for the second phase, so this is also the reset pulse
  //           width. The DUT reset synchroniser (rst_gen) asserts
  //           asynchronously and releases 5 cycles later, so a few tens
  //           of cycles is plenty.
  // ============================================================
  parameter integer RTC_ALIGN_EN = 0,
  parameter integer RST_CYC      = 32
)(
  input  wire         clk,
  input  wire         rst_n,

  // Only used when RTC_ALIGN_EN = 1; tie off otherwise.
  input  wire         aon_rtcToggle_a,

  input  wire         cfg_end_i,
  input  wire [31:0]  cfg_fi_cycle_i,     // FI_Cycle base from the host
  input  wire         cfg_fi_cycle_wr_i,  // 1-cycle strobe: host wrote CFG_FI_CYCLE
  input  wire [31:0]  cfg_to_thr_i,       // TO_Thr, timeout threshold

  // Per-pattern Cycle_Offset, from the FI Table Controller. Latched
  // there from the EOP entry and held across resolver_rst.
  input  wire [31:0]  cycle_offset_i,

  output wire         scan_start_o,       // "scan start" -> FI Scan Controller
  output wire         resolver_rst_o,     // FI Resolver reset -> DUT + FI counters
  output wire         testmode_rst_o,

  output wire [31:0]  fi_cycle_o,       // current FI_Cycle, for host read-back
  output wire         fi_cycle_ovf_o    // FI_Cycle walked past the timeout
);

  // ============================================================
  // Internal State
  // ============================================================
  reg [31:0] clock_counter;
  reg        stopped;

  // ============================================================
  // FI_Cycle: a running register, not a read-only config constant.
  // ------------------------------------------------------------
  // Base value comes from the host (CFG_FI_CYCLE, DMI 0x65) and is
  // (re)loaded on every write to it -- a write strobe, not a
  // compare-against-shadow, so that rewriting the SAME base value
  // still re-arms a fresh batch.
  //
  // It is then advanced by the current pattern's Cycle_Offset at the
  // END of the reset window, atomically with clearing clock_counter.
  // That instant is the only safe one: adding at done_o instead would
  // raise the target while clock_counter is still climbing inside the
  // same trial, and the == compare would fire a second, spurious
  // injection.
  //
  // Note this register lives outside the FI Resolver reset by
  // construction -- fi_time_ctrl generates resolver_rst, it never
  // consumes it -- which is exactly what the config-preserving
  // reset contract requires.
  // ============================================================
  reg [31:0] fi_cycle_q;
  reg        fi_fired_q;   // one-shot per trial, cleared with clock_counter

  reg        scan_start_pulse;
  reg        resolver_rst_r;
  reg        testmode_rst_r;

  // Track progress of the RTC-aligned reset sequence
  //   0: idle
  //   1: stop seen, waiting for first rtc rise  -> assert resolver_rst
  //   2: resolver_rst active, waiting for second rtc rise -> deassert/reset done
  reg [1:0]  rtc_phase;

  // ============================================================
  // Enables
  // ============================================================
  wire fi_hit_en = (fi_cycle_q != 32'd0);
  wire to_hit_en = (cfg_to_thr_i != 32'd0);

  // The cycle sweep has walked past the end of the trial window: no
  // injection can ever hit again, every further trial would just burn a
  // full timeout for nothing.
  assign fi_cycle_ovf_o = to_hit_en && (fi_cycle_q >= cfg_to_thr_i);
  assign fi_cycle_o     = fi_cycle_q;

  // ============================================================
  // Sync & edge-detect cfg_end_i into clk domain
  // ============================================================
  reg [1:0] end_sync;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      end_sync <= 2'b00;
    else
      end_sync <= {end_sync[0], cfg_end_i};
  end

  wire end_rise_pulse = end_sync[0] & ~end_sync[1];

  // ============================================================
  // Sync & edge-detect aon_rtcToggle_a into clk domain
  // ============================================================
  reg [1:0] rtc_sync;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      rtc_sync <= 2'b00;
    else
      rtc_sync <= {rtc_sync[0], aon_rtcToggle_a};
  end

  wire rtc_rise_pulse = rtc_sync[0] & ~rtc_sync[1];

  // ============================================================
  // Reset-window pacing source
  // ------------------------------------------------------------
  // rst_advance is the single event that steps the reset window
  // forward. With RTC_ALIGN_EN=1 it is an RTC rising edge (original
  // behaviour, bit for bit). With RTC_ALIGN_EN=0 it is a fixed hf
  // cycle count, so a DUT without any slow clock never stalls here.
  // ============================================================
  reg [31:0] rst_cnt;
  wire rst_cnt_hit = (rst_cnt >= (RST_CYC - 1));

  wire rst_advance = (RTC_ALIGN_EN != 0) ? rtc_rise_pulse : rst_cnt_hit;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      rst_cnt <= 32'd0;
    else if (!stopped)
      rst_cnt <= 32'd0;             // counter only runs inside the window
    else if (rst_advance)
      rst_cnt <= 32'd0;             // restart between phase 1 and phase 2
    else
      rst_cnt <= rst_cnt + 32'd1;
  end

  // ============================================================
  // Stop conditions
  // ============================================================
  wire stop_by_end = end_rise_pulse;
  wire stop_by_to  = to_hit_en && (clock_counter >= cfg_to_thr_i);
  wire stop_event  = stop_by_end | stop_by_to;

  // ============================================================
  // Main sequencing
  // ============================================================
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      clock_counter      <= 32'd0;
      stopped            <= 1'b0;
      rtc_phase          <= 2'd0;

      scan_start_pulse <= 1'b0;
      resolver_rst_r         <= 1'b0;
      testmode_rst_r     <= 1'b0;

      fi_cycle_q         <= 32'd0;
      fi_fired_q         <= 1'b0;

    end else begin
      // default
      scan_start_pulse <= 1'b0;

      // --------------------------------------------------------
      // Free-running phase
      // --------------------------------------------------------
      if (!stopped) begin
        clock_counter <= clock_counter + 32'd1;

        if (fi_hit_en && !fi_fired_q && (clock_counter == fi_cycle_q)) begin
          scan_start_pulse <= 1'b1;
          fi_fired_q         <= 1'b1;   // at most one injection per trial
        end

        if (stop_event) begin
          // Enter reset-prep immediately
          stopped        <= 1'b1;
          rtc_phase      <= 2'd1;   // wait first RTC rising edge
          testmode_rst_r <= 1'b1;   // immediately force top-level testmode_o = 0
          resolver_rst_r     <= 1'b0;   // reset window not started yet
        end
      end

      // --------------------------------------------------------
      // Stopped / RTC-aligned reset window sequencing
      // --------------------------------------------------------
      else begin
        case (rtc_phase)
          // Phase 1: wait one pacing event, then start the reset window
          2'd1: begin
            if (rst_advance) begin
              resolver_rst_r <= 1'b1;
              rtc_phase  <= 2'd2;
            end
          end

          // Phase 2: wait the next pacing event, then end the reset window
          // and release the testmode reset
          2'd2: begin
            if (rst_advance) begin
              resolver_rst_r     <= 1'b0;
              testmode_rst_r <= 1'b0;

              // Return to idle / restart counting
              stopped        <= 1'b0;
              rtc_phase      <= 2'd0;
              clock_counter  <= 32'd0;

              // Advance the injection target for the next trial,
              // atomically with clearing the counter it is compared
              // against. cycle_offset_i still carries the offset of the
              // pattern that just ran: the Table Controller only re-arms
              // its fill on this same edge, so it cannot have been
              // overwritten yet.
              fi_cycle_q     <= fi_cycle_q + cycle_offset_i;
              fi_fired_q     <= 1'b0;
            end
          end

          default: begin
            // Defensive recovery
            rtc_phase <= 2'd0;
          end
        endcase
      end

      // Host (re)loads the base target. Deliberately last, so an
      // explicit write always wins over the accumulate above.
      if (cfg_fi_cycle_wr_i) begin
        fi_cycle_q <= cfg_fi_cycle_i;
        fi_fired_q <= 1'b0;
      end
    end
  end

  assign scan_start_o = scan_start_pulse;
  assign resolver_rst_o     = resolver_rst_r;
  assign testmode_rst_o = testmode_rst_r;

endmodule
