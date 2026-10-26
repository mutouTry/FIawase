// SPDX-License-Identifier: Apache-2.0
// Copyright 2025-2026 the FIawase authors
// ============================================================
// FI Time Controller + FI Resolver        (docs/DESIGN.md 1.2)
// ------------------------------------------------------------
// Figure name -> code name
//   FI_Cycle      fi_cycle_q / fi_cycle_o     TO_Thr  cfg_to_thr_i
//   scan start    scan_start_o
//   Cycle_Offset  cycle_offset_i  (from the FI Table Controller)
//
// The figure draws the FI Resolver as a separate block. In RTL it is the
// reset window in the second half of this module: on timeout,
// resolver_rst_o resets the DUT and every counter in the FI logic while
// the FI configuration registers -- which live in the FI Transporter --
// are left untouched. That is the "reset all states except FI
// Configuration" arrow of the figure. Impact Classify is host side and has
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
  //           for the second phase, or for both with SCRUB = 1, so the
  //           reset pulse is RST_CYC or 2 x RST_CYC wide. A DUT reset synchroniser asserts asynchronously and
  //           releases a few cycles later, so a few tens of cycles is
  //           plenty.
  // ============================================================
  parameter integer RTC_ALIGN_EN = 0,
  parameter integer RST_CYC      = 32,
  // ============================================================
  // SCRUB = 1 : when a trial ends, ask the Scan Controller for a scrub pass
  //             (zeros shifted into the chain: its first SCRUB_LEN cells,
  //             the ones without a reset, see fi_scan_ctrl) with the DUT still
  //             out of reset and frozen by Clk_Gate as in any pass, and
  //             assert resolver_rst on its last shift edge, so that no
  //             functional edge comes in between. Every scan flop then
  //             starts the next trial as at power-on: 0 before the reset,
  //             its reset value if it has one, and 0 if it has none (e.g. a
  //             register file). Shifted with the DUT in reset instead, a
  //             flop held by an asynchronous set would feed 1s to the flops
  //             without a reset that follow it on the chain. Without a scrub
  //             such flops carry over whatever the previous trial left in
  //             them. Costs SCRUB_LEN cycles per trial. A memory restore
  //             longer than the scrub goes on in the reset pulse, and the
  //             reset is released only once it is done (phase 2).
  // ============================================================
  parameter integer SCRUB        = 1,
  // ============================================================
  // MEM_RESTORE = 1 : ask the FI memory models (fi_sram_restore.vh) to put
  //             every DUT memory back to its power-on content (mem_req_o /
  //             mem_done_i). With SCRUB = 1 the restore runs alongside the
  //             scrub, from its first shift on: the freeze then holds every
  //             memory's clock, so the DUT cannot reach them, and the models
  //             restore on the free-running clock. mem_req_o stays up until
  //             the reset is released, so a DUT write during the reset pulse
  //             still shows as mem_bad_i. With SCRUB = 0 it runs inside the
  //             reset window, as the only step. Memories are
  //             neither reset nor on the chain, so without it a stray store
  //             in one trial (e.g. into the program memory) is still there
  //             in every later trial. A memory whose undo log is full asks
  //             to end the running trial (mem_abort_i): it ends like a
  //             timeout and mem_abort_last_o (FI_STATUS bit 6) tells the host
  //             to count it as DUE. A memory that cannot vouch for its restore
  //             (mem_bad_i) stops the campaign with the DUT held in reset:
  //             mem_halt_o, FI_STATUS bit 5.
  // ============================================================
  parameter integer MEM_RESTORE  = 1
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
  output wire         fi_cycle_ovf_o,   // FI_Cycle walked past the timeout

  // Scrub handshake with the FI Scan Controller (SCRUB = 1)
  output wire         scrub_req_o,
  input  wire         scrub_done_i,
  input  wire         scrub_run_i,        // the scrub is shifting (the freeze is on)
  input  wire         scrub_last_i,       // this cycle's edge is its last shift

  // Memory restore handshake with the FI memory models (MEM_RESTORE = 1)
  output wire         mem_req_o,          // level, held until mem_done_i
  input  wire         mem_done_i,         // every memory is back at power-on content
  input  wire         mem_abort_i,        // some memory asks to end the trial (undo log full)
  input  wire         mem_bad_i,          // some memory could not be restored
  output wire         mem_halt_o,         // sticky: campaign stopped, DUT held in reset
  output wire         mem_abort_last_o,   // the last trial was ended by mem_abort_i
  output wire         stopped_o           // 1 from a trial's stop to the end of its reset window
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
  reg        scrub_req_r;
  reg        mem_req_r;
  reg        mem_halt_r;
  reg        mem_abort_last_r;

  // Track progress of the reset window
  //   0: idle
  //   SCRUB = 1:
  //   3: stop seen, scrub pass running, DUT frozen, memories restoring
  //      -> assert resolver_rst on the last shift edge -> phase 6
  //   6: resolver_rst active, waiting for the first pacing event -> phase 2
  //   SCRUB = 0:
  //   1: stop seen, waiting for the first pacing event -> assert resolver_rst
  //   4: resolver_rst active, memories restoring (MEM_RESTORE = 1) -> phase 2 / 5
  //   both:
  //   2: resolver_rst active, waiting for the next pacing event (and, after a
  //      scrub, for the memories) -> deassert / reset done, or phase 5
  //   5: halted: a memory could not be restored; resolver_rst stays active
  reg [2:0]  rtc_phase;

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
  // forward. With RTC_ALIGN_EN=1 it is an RTC rising edge. With
  // RTC_ALIGN_EN=0 it is a fixed hf
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
    else if (rst_advance || (rtc_phase == 3'd3) || (rtc_phase == 3'd4) || (rtc_phase == 3'd5))
      rst_cnt <= 32'd0;             // restart between phases; held during scrub / restore / halt
    else
      rst_cnt <= rst_cnt + 32'd1;
  end

  // ============================================================
  // Stop conditions
  // ============================================================
  wire stop_by_end = end_rise_pulse;
  wire stop_by_to  = to_hit_en && (clock_counter >= cfg_to_thr_i);
  // A memory cannot record any more writes: end the trial now (only in a
  // campaign, i.e. with a timeout configured, like stop_by_to).
  wire stop_by_mem = to_hit_en && (MEM_RESTORE != 0) && mem_abort_i;
  wire stop_event  = stop_by_end | stop_by_to | stop_by_mem;

  // ============================================================
  // Main sequencing
  // ============================================================
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      clock_counter      <= 32'd0;
      stopped            <= 1'b0;
      rtc_phase          <= 3'd0;

      scan_start_pulse <= 1'b0;
      resolver_rst_r         <= 1'b0;
      testmode_rst_r     <= 1'b0;
      scrub_req_r        <= 1'b0;
      mem_req_r          <= 1'b0;
      mem_halt_r         <= 1'b0;
      mem_abort_last_r   <= 1'b0;

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
          mem_abort_last_r <= stop_by_mem;
          resolver_rst_r     <= 1'b0;   // reset window not started yet
          if (SCRUB != 0) begin
            // Scrub now, before the reset; testmode is let through for it
            // (the Scan Controller raises and drops it).
            rtc_phase      <= 3'd3;
            scrub_req_r    <= 1'b1;
            testmode_rst_r <= 1'b0;
          end else begin
            rtc_phase      <= 3'd1;   // wait for the first pacing event
            testmode_rst_r <= 1'b1;   // immediately force top-level testmode_o = 0
          end
        end
      end

      // --------------------------------------------------------
      // Stopped: reset window sequencing
      // --------------------------------------------------------
      else begin
        case (rtc_phase)
          // Phase 1 (SCRUB = 0): wait one pacing event, then start the reset
          // window
          3'd1: begin
            if (rst_advance) begin
              resolver_rst_r <= 1'b1;
              if (MEM_RESTORE != 0) begin
                rtc_phase  <= 3'd4;
                mem_req_r  <= 1'b1;
              end else begin
                rtc_phase  <= 3'd2;
              end
            end
          end

          // Phase 3 (SCRUB = 1): the scrub pass runs with the DUT frozen; the
          // memories restore alongside it from its first shift, when the
          // freeze holds their clocks. The DUT reset goes up on the last
          // shift edge, so the flops without a reset keep the scrub's zeros.
          // scrub_done_i without a run: no chain configured (Scan_Len 0).
          3'd3: begin
            if ((MEM_RESTORE != 0) && scrub_run_i)
              mem_req_r <= 1'b1;
            if (scrub_last_i || scrub_done_i) begin
              resolver_rst_r <= 1'b1;
              scrub_req_r    <= 1'b0;
              testmode_rst_r <= 1'b1;
              if (MEM_RESTORE != 0)
                mem_req_r <= 1'b1;
              rtc_phase      <= 3'd6;
            end
          end

          // Phase 6 (SCRUB = 1): the reset pulse, first half
          3'd6: begin
            if (rst_advance)
              rtc_phase <= 3'd2;
          end

          // Phase 4 (SCRUB = 0): every FI memory model restores itself (DUT in reset)
          3'd4: begin
            if (mem_done_i) begin
              mem_req_r <= 1'b0;
              if (mem_bad_i) begin
                // Some memory is not back at its power-on content: the next
                // trial would not start clean. Stop here with the DUT held in
                // reset; the host reloads the memories and starts the
                // remaining trials as a new campaign.
                mem_halt_r <= 1'b1;
                rtc_phase  <= 3'd5;
              end else begin
                rtc_phase  <= 3'd2;
              end
            end
          end

          // Phase 5: halted (left only through rst_n)
          3'd5: begin
          end

          // Phase 2: wait the next pacing event, then end the reset window
          // and release the testmode reset. After a scrub the memories may
          // still be restoring (then wait for a later pacing event), and a
          // memory that could not be restored halts the campaign here.
          3'd2: begin
            if (rst_advance && mem_req_r && mem_done_i && mem_bad_i) begin
              mem_req_r  <= 1'b0;
              mem_halt_r <= 1'b1;
              rtc_phase  <= 3'd5;
            end else if (rst_advance && (!mem_req_r || mem_done_i)) begin
              resolver_rst_r     <= 1'b0;
              testmode_rst_r <= 1'b0;
              mem_req_r      <= 1'b0;

              // Return to idle / restart counting
              stopped        <= 1'b0;
              rtc_phase      <= 3'd0;
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
            rtc_phase <= 3'd0;
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
  assign scrub_req_o    = scrub_req_r;
  assign mem_req_o      = mem_req_r;
  assign mem_halt_o     = mem_halt_r;
  assign mem_abort_last_o = mem_abort_last_r;
  assign stopped_o      = stopped;

endmodule
