// SPDX-License-Identifier: Apache-2.0
// Copyright 2025-2026 the FIawase authors
// Portions derived from the tinyriscv SoC testbench, see NOTICE.
// ============================================================
// Gate-level FI testbench.
//
// Simulator select: `vcs enables $fsdbDump*, `iverilog enables $dump*.
// Define exactly one FROM THE COMMAND LINE -- FIawase's sim/fi_sim.mk does it:
//   vcs      +define+vcs
//   iverilog -Diverilog
// Do NOT `define it here.
// ============================================================
`include "defines.svh"
`include "jtag_def.svh"

module chaos_soc_tb;

    wire halted;

    reg  clk_i;
    reg  rst_ni;

    always #10  clk_i = ~clk_i;     // 50MHz


    time start_time;

    initial begin
        start_time = $time;
        $display("[%t] Simulation started.", start_time);
    end

    wire sim_end = u_tinyriscv_soc_top.gpio_data_out_module[0];


    initial begin
        clk_i = 0;
        rst_ni = 0;
        #150;
        rst_ni = 1;
    end


    `define RomNum 16384
    // read mem data
    reg[7:0] rom [0 : `RomNum*4-1];

    integer i;
    string  fw_path;
    initial begin
        
        for (i=0;i<(`RomNum*4);i=i+1) begin
            rom[i] = 'd0;
        end
    
        // Firmware image, one 8-bit hex byte per line (little endian words).
        //   simv +firmware=path/to/app.verilog
        if (!$value$plusargs("firmware=%s", fw_path))
            fw_path = "firmware.verilog";
        $display("[TB] loading firmware %0s", fw_path);
        $readmemh(fw_path, rom);


        #10
        // Backdoor-load the ROM. There is no bus path for this, so the
        // target is a hierarchical reference into whatever rom.sv
        // instantiated -- which depends on T22NM (see rtl/perips/rom.sv):
        //
        //   T22NM defined    vendor SRAM macro. This is the production
        //                    path; the macro's behavioural model must hold
        //                    the array in a 32-bit-wide reg called `ram`.
        //   T22NM undefined  gen_ram behavioural model, no macro needed.
        //                    Convenient for a first look, but NOT the path
        //                    the FI campaign is validated on, and 16k x 32
        //                    of inferred flops makes synthesis impractical.
        //
        // If your macro is named differently, override FI_ROM_MEM from the
        // command line rather than editing this file, e.g.
        //   +define+FI_ROM_MEM=u_tinyriscv_soc_top.u_rom.uMYMACRO.mem
        `ifndef FI_ROM_MEM
          `ifdef T22NM
            `define FI_ROM_MEM u_tinyriscv_soc_top.u_rom.usram_sp_16384x32.ram
          `else
            `define FI_ROM_MEM u_tinyriscv_soc_top.u_rom.u_gen_ram.ram
          `endif
        `endif

        for (i=0;i<(`RomNum);i=i+1) begin
            `FI_ROM_MEM[i] = {
                                     rom[i*4+3],
                                     rom[i*4+2],
                                     rom[i*4+1],
                                     rom[i*4+0]};
        end


    end


    integer dumpwave;
        // generate wave file, used by verdi
    initial begin
        // FI_FSDB is defined by sim/fi_sim.mk only when the Verdi novas PLI was
        // actually linked in. Keying on it rather than on `vcs` is what makes
        // `make wave` work either way: $fsdbDump* without the PLI is a silent
        // no-op.
        if($value$plusargs("DUMPWAVE=%d",dumpwave)) begin
        if(dumpwave != 0) begin
        `ifdef FI_FSDB
                $display("[WAVE] fsdb -> chaos_soc_tb.fsdb");
                $fsdbDumpfile("chaos_soc_tb.fsdb");
                $fsdbDumpvars(0, chaos_soc_tb, "+mda");
        `else
                $display("[WAVE] vcd -> chaos_soc_tb.vcd (no Verdi PLI)");
                $dumpfile("chaos_soc_tb.vcd");
                $dumpvars(0, chaos_soc_tb);
        `endif
        end
        end
    end


    integer ifu_valid_cnt = 0;
    integer idu_valid_cnt = 0;
    integer total_cycles = 0;

    integer log_fd;

    initial begin
        log_fd = $fopen("inst_valid_log.txt", "w");
        if (log_fd == 0) begin
            $display("Failed to open log file.");
            $finish;
        end
    end

    always @(posedge clk_i) begin
        if ((sim_end != 1) && (rst_ni == 1)) begin
            total_cycles = total_cycles + 1;

            if (chaos_soc_tb.u_tinyriscv_soc_top.u_tinyriscv_core.u_ifu_idu.inst_valid_o)
                ifu_valid_cnt = ifu_valid_cnt + 1;

            if (chaos_soc_tb.u_tinyriscv_soc_top.u_tinyriscv_core.u_idu_exu.inst_valid_o)
                idu_valid_cnt = idu_valid_cnt + 1;

        end
    end


    final begin
        $fwrite(log_fd, "\n=== Summary ===\n");
        $fwrite(log_fd, "Total cycles: %0d\n", total_cycles);
        $fwrite(log_fd, "IFU inst_valid_o = 1 count: %0d\n", ifu_valid_cnt);
        $fwrite(log_fd, "IDU inst_valid_o = 1 count: %0d\n", idu_valid_cnt);

        $fclose(log_fd);
    end


    wire           sim_jtag_tck;
    wire           sim_jtag_tms;
    wire           sim_jtag_tdi;
    wire           sim_jtag_trstn;
    wire           sim_jtag_tdo;
    wire           sim_jtag_exit;


    wire[16-1:0] io_pins;

    wire sc_scanin;
    wire sc_scanen;
    wire sc_testmode;
    wire tb_io_scanout;
    wire clk_gate_o;
    wire fi_rst;

    fi_wrapper_top #(
        .DMI_ADDR_BITS (7),
        .DMI_DATA_BITS (32),
        .DMI_OP_BITS   (2),
        .DW            (32),
        .TBL_WORDS     (256),
        .IDCODE_VALUE  (32'hF17E_0007)
        // N_FF / LOOKAHEAD deliberately left at their defaults: N_FF comes
        // from fi_scan_cfg.vh, which is the single source of truth for the
        // FI_Entry field boundaries.
        ) u_fi_wrapper_top (
        .aon_hfclk_i   (clk_i),
        .aon_lfclk_i   (1'b0),      // if tinyriscv has no lf clock, tie off or use clk_i if required
        .aon_rst_ni    (rst_ni),

        // Host JTAG from TB
        .jtag_tck_i    (sim_jtag_tck),
        .jtag_tms_i    (sim_jtag_tms),
        .jtag_tdi_i    (sim_jtag_tdi),
        .jtag_trst_ni  (rst_ni),
        .jtag_tdo_o    (sim_jtag_tdo),

        // To DUT JTAG
        .dut_jtag_tck_o(dut_jtag_tck),
        .dut_jtag_tms_o(dut_jtag_tms),
        .dut_jtag_tdi_o(dut_jtag_tdi),
        .dut_jtag_tdo_i(dut_jtag_tdo),

        // Scan/test interface
        .scan_out_i    (tb_io_scanout),
        .scan_in_o     (sc_scanin),    
        .scan_en_o     (sc_scanen),    
        .testmode_o    (sc_testmode),  

        .clk_gate_o    (clk_gate_o), // Clk_Gate -> the DUT's scan_gate port
        .fi_rst        (fi_rst),

        // Memory restore (fi_time_ctrl). This testbench keeps the plain SRAM
        // models, so the step is answered at once and does nothing. To restore the
        // memories, build their models with FIawase's rtl/fi_sram_restore.vh and wire them here.
        .fi_mem_req_o  (),
        .fi_mem_done_i (1'b1),
        .fi_mem_abort_i(1'b0),
        .fi_mem_bad_i  (1'b0)
    );


    tinyriscv_soc_top u_tinyriscv_soc_top (
        .clk_50m_i      (clk_i),
        .rst_ext_ni     (fi_rst),        // use wrapper-generated reset if intended

        .halted_ind_pin (halted),

        .jtag_TCK_pin   (dut_jtag_tck),
        .jtag_TMS_pin   (dut_jtag_tms),
        .jtag_TDI_pin   (dut_jtag_tdi),
        .jtag_TDO_pin   (dut_jtag_tdo),

        .io_data_out    (io_pins),

        // Inputs the netlist has and this testbench does not drive, tied to idle levels
        // (left open they read as Z/X):
        //   io_data_in      all 1: the idle level of the GPIO/UART-RX pads (an idle UART line is high)
        //   flash_spi_dq_in all 1: the idle level of the flash data lines; the program runs from the ROM
        //   data_source     0: created by DFT insertion (fi_report lists it), used only in test mode,
        //                   where it drives the reset muxes; 0 keeps the functional reset inactive
        //                   during every pass
        .io_data_in     (16'hFFFF),
        .flash_spi_dq_in(4'hF),
        .data_source    (1'b0),

        .io_testmode   (sc_testmode),
        .io_scanin     (sc_scanin),
        .io_scanen     (sc_scanen),
        .io_scanout    (tb_io_scanout),

        .scan_gate     (clk_gate_o)   // DUT-side name; FIawase calls it Clk_Gate
    );

    // ---- optional SDF back-annotation ----
    // Off by default: the FI campaign normally runs zero-delay, which is
    // both much faster and sufficient, since an injection is defined at a
    // cycle boundary. Turn it on with make SDF=<file>, which supplies
    // all three defines below and moves the timescale precision to 1ps --
    // SDF delays are in ps, so at 10ps every sub-ns path rounds to zero.
`ifdef SDF_SIM
    initial begin
        $sdf_annotate(`FI_SDF_FILE, `FI_SDF_INSTANCE, , "annotate.log",
                      `FI_SDF_CORNER, "1.0:1.0:1.0", `FI_SDF_SCALE);
    end
`endif


    // ================================================================
    // UART observation -- three taps, one simulation
    // ----------------------------------------------------------------
    //   A  pad  + rst_ni   stdout          baseline
    //   B  tx_o + rst_ni   uart_txo.log    same reset, tap BEFORE the pinmux
    //   C  pad  + fi_rst   uart_pad_fi.log same tap, monitor resets with DUT
    //
    // Score a campaign on uart_txo.log (tap B): tx_o is the DUT's UART output.
    // The example's pad 0 is shared between GPIO0 and UART0_TX, and the
    // firmware drives GPIO0 before it switches the pin mux, so the pad (A, C)
    // carries extra bytes ahead of the payload: uart_rx_print does not check
    // the stop bit and turns every 1->0 there into a byte. The observer's own
    // filter hides them (n_byte is cleared at the first TXDATA write). C's
    // receiver is reset with the DUT, so its bit timing starts clean in every
    // trial; until a campaign is armed fi_rst is rst_ni and C equals A.
    // ================================================================
    wire uart_rxd = io_pins[0];

    // A -- the pad. Keep the instance name: the tb's obs_uart_byte
    // probe below reaches into u_uart_rx_print.uart_done_d1/d2.
    uart_rx_print #
    (
        .CLK_FREQ(50000000)
    ) u_uart_rx_print
    (
    .sys_clk(clk_i),
    .sys_rst_n(rst_ni),
    .uart_rxd(uart_rxd),
    .uart_done(),
    .uart_data()
    );

    // B -- uart0's own tx_o, before the pinmux selects the pad.
    wire uart_txo_raw = u_tinyriscv_soc_top.uart_tx[0];
    uart_rx_print #
    (
        .CLK_FREQ(50000000),
        .USE_FILE(1),
        .LOGFILE("uart_txo.log")
    ) u_uart_rx_print_txo
    (
    .sys_clk(clk_i),
    .sys_rst_n(rst_ni),
    .uart_rxd(uart_txo_raw),
    .uart_done(),
    .uart_data()
    );

    // C -- same pad as A, but the monitor is reset by the FI reset.
    uart_rx_print #
    (
        .CLK_FREQ(50000000),
        .USE_FILE(1),
        .LOGFILE("uart_pad_fi.log")
    ) u_uart_rx_print_fi
    (
    .sys_clk(clk_i),
    .sys_rst_n(fi_rst),
    .uart_rxd(uart_rxd),
    .uart_done(),
    .uart_data()
    );

  
  jtagdpi jtagdpi(
  .clk_i(clk_i),
  .rst_ni(rst_ni),

  .jtag_tck(sim_jtag_tck),
  .jtag_tms(sim_jtag_tms),
  .jtag_tdi(sim_jtag_tdi),
  .jtag_tdo(sim_jtag_tdo),
  .jtag_trst_n(sim_jtag_trstn),
  .jtag_srst_n(sim_jtag_exit)
  );


    // ==================================================================
    // FI EXECUTION WINDOW OBSERVER
    // ------------------------------------------------------------------
    // Reports three cycle numbers, ONCE, for the first run of the program.
    // Later rounds of the internal FI reset loop repeat the same program and
    // are not reported again.
    //
    //   exec start : first write to the GPIO block   -> program reached main
    //   exec end   : first write to UART TXDATA      -> compute done
    //   uart done  : last byte fully received        -> printing finished
    //
    // [exec start, exec end) is the range to draw cfg_fi_cycle_i from.
    // uart done is the earliest cfg_to_thr_i that lets a round finish
    // printing before the FI loop resets the DUT.
    //
    // The two execution markers come from the core data bus, so no program
    // symbols are involved: swapping the workload needs no change here. The
    // address map is a SoC property (rtl/core/defines.svh,
    // rtl/pkg/uart_reg_pkg.sv), not a program property.
    //
    // Read-only except for the terminator at the bottom, which owns $finish.
    //
    // ASCII only: non-ASCII in Verilog source upsets some tools in the
    // VCS/Verdi/DC chain.
    // ==================================================================

    localparam [31:0] OBS_PERIP_MASK  = 32'hFFFF_0000;
    localparam [31:0] OBS_GPIO_BASE   = 32'h0300_0000;  // GPIO_ADDR_BASE
    localparam [31:0] OBS_UART_TXDATA = 32'h0500_0008;  // UART0 + TXDATA offset

    // Quiet time after the last UART byte before the numbers are considered
    // final. Must outlast one character frame (86.8 us at 115200 baud).
    localparam integer OBS_DRAIN_NS = 2_000_000;
    localparam integer OBS_POLL_NS  =   100_000;

    // Idle gap on the UART that means "this run has finished printing".
    // Must exceed one character frame (86.8 us at 115200 baud) with margin,
    // but stay well inside one FI round so the report lands before the reset.
    localparam integer OBS_QUIET_NS =   500_000;

    // ---- probes ----------------------------------------------------------
    wire fi_en      = u_fi_wrapper_top.cfg_en_able_w;   // FI campaign active
    wire fi_resolver_rst = u_fi_wrapper_top.resolver_rst_w;      // FI reset -> new round

    wire        obs_dwr   = u_tinyriscv_soc_top.u_tinyriscv_core.data_req_o &
                            u_tinyriscv_soc_top.u_tinyriscv_core.data_we_o  &
                            u_tinyriscv_soc_top.u_tinyriscv_core.data_gnt_i;
    wire [31:0] obs_daddr = u_tinyriscv_soc_top.u_tinyriscv_core.data_addr_o;

    wire obs_uart_byte = u_uart_rx_print.uart_done_d1 &
                        ~u_uart_rx_print.uart_done_d2;

    // Monotonic cycle count from reset release. Equal to the wrapper's
    // clock_counter (the one cfg_fi_cycle_i is compared against) for the whole
    // first round; unlike it, this one never stops or resets, so the UART
    // tail after the program's done flag is still measured correctly.
    // It is cleared again when resolver_rst falls, which is the same event that
    // clears clock_counter (reset-window phase 2), so the two stay aligned
    // round after round and the numbers remain valid cfg_fi_cycle_i values.
    integer obs_cyc;
    reg     obs_srst_d;
    always @(posedge clk_i or negedge rst_ni)
        if (!rst_ni) begin
            obs_cyc    <= 0;
            obs_srst_d <= 1'b0;
        end else begin
            obs_srst_d <= fi_resolver_rst;
            if (obs_srst_d && (fi_resolver_rst !== 1'b1)) obs_cyc <= 0;
            else                                     obs_cyc <= obs_cyc + 1;
        end

    // ---- captured numbers -------------------------------------------------
    integer c_start, c_end, c_uart_done, n_byte;
    time    t_last_byte;
    reg     reported;

    // ---- terminator state -------------------------------------------------
    reg     fi_seen, fi_done;
    time    t_fi_done, t_round_end;
    integer n_round_end;
    integer obs_fd;

    initial begin
        c_start = -1; c_end = -1; c_uart_done = -1; n_byte = 0;
        t_last_byte = 0; reported = 1'b0;
        fi_seen = 0; fi_done = 0; t_fi_done = 0;
        t_round_end = 0; n_round_end = 0;
        obs_fd = $fopen("fi_exec_window.txt", "w");
    end

    // ---- capture, first occurrence only ------------------------------------
    always @(posedge clk_i) begin
        if ((rst_ni === 1'b1) && !reported) begin
            if (obs_dwr === 1'b1) begin
                if ((c_start < 0) && ((obs_daddr & OBS_PERIP_MASK) == OBS_GPIO_BASE))
                    c_start = obs_cyc;
                if ((c_end < 0) && (obs_daddr == OBS_UART_TXDATA)) begin
                    c_end = obs_cyc;
                    // Printing cannot have produced a received byte before the
                    // first TXDATA write. Anything decoded earlier is line
                    // noise, typically the TX pin glitching while the DUT is
                    // held in reset, so drop it.
                    n_byte = 0; c_uart_done = -1; t_last_byte = 0;
                end
            end
            if (obs_uart_byte === 1'b1) begin
                n_byte      = n_byte + 1;
                c_uart_done = obs_cyc;      // keeps moving until printing stops
                t_last_byte = $time;
            end
        end
    end

    // ---- pad-path forensics -------------------------------------------------
    // A falling edge on the pad BEFORE the program's first TXDATA write cannot
    // be a UART start bit, so every line this prints is one fabricated byte in
    // uart_pad_fi.log / stdout. It reports the one thing static reading cannot
    // settle -- WHEN the edges happen and what the pad was following:
    //
    //   tx_o = 1 at that instant -> the pad is NOT on uart0. io0_mux is still
    //          at its RESVAL of 00 and you are watching the firmware drive
    //          GPIO0 on a shared pad. Fix is the pinmux/firmware, not the tb.
    //   tx_o = 0 -> uart0 really did pull tx_o low, and tap B would have logged
    //          the same byte. It did not, so this outcome would be new
    //          information: look at uart0, not the pinmux.
    //
    // On the example it shows tx_o = 1: the pad is on GPIO0. Off by default,
    // with the rest of the forensics.
`ifdef FI_DEBUG
    always @(negedge uart_rxd) begin
        if ((rst_ni === 1'b1) && (c_end < 0))
            $display("[PAD-EDGE] t=%0t cyc=%0d  pad 1->0  tx_o=%b fi_rst=%b",
                     $time, obs_cyc, uart_txo_raw, fi_rst);
    end
`endif

    // ---- end-of-program flag: only feeds the terminator ---------------------
    always @(posedge sim_end) begin
        if (rst_ni === 1'b1) begin
            n_round_end = n_round_end + 1;
            t_round_end = $time;
        end
    end

    // ---- per-trial outcome, one line each -----------------------------------
    // A campaign of N trials produces up to N payloads, and a MISSING payload is
    // ambiguous three ways: the injected fault hung the program, the hardware
    // timeout (CFG_TO_THR) cut the trial short, or $finish truncated the last
    // one. From the payload stream alone those are indistinguishable, which
    // makes a campaign unscoreable. One line per trial separates them.
    //
    // The trial boundary is resolver_rst rising -- the FI reset window that ends
    // one trial and starts the next -- so this counts what the HARDWARE did,
    // independently of whether the program produced output.
    // scan=N on each line is the length of that trial's scan window. It is the
    // one number that says an injection physically happened, so it stays on
    // always: scan=0 means the chain never rotated and the trial's result says
    // nothing about the fault, whatever the payload looks like.
    integer trial_n, trial_bytes, scan_win, scan_win_c0;
    reg     trial_txd, trial_rst_d, scanen_prev;

    initial begin
        trial_n = 0; trial_bytes = 0; trial_txd = 1'b0; trial_rst_d = 1'b0;
        scan_win = 0; scan_win_c0 = 0; scanen_prev = 1'b0;
    end

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            trial_bytes <= 0;
            trial_txd   <= 1'b0;
            trial_rst_d <= 1'b0;
            scan_win    <= 0;
            scanen_prev <= 1'b0;
        end else begin
            trial_rst_d <= fi_resolver_rst;
            scanen_prev <= sc_scanen;
            if (obs_uart_byte === 1'b1) trial_bytes <= trial_bytes + 1;
            if ((obs_dwr === 1'b1) && (obs_daddr == OBS_UART_TXDATA))
                trial_txd <= 1'b1;

            if      ((sc_scanen === 1'b1) && (scanen_prev !== 1'b1)) scan_win_c0 <= obs_cyc;
            else if ((sc_scanen !== 1'b1) && (scanen_prev === 1'b1)) scan_win    <= obs_cyc - scan_win_c0;

            if ((fi_resolver_rst === 1'b1) && (trial_rst_d !== 1'b1)) begin
                // trial_txd says the program got as far as printing; trial_bytes
                // says the bytes actually made it out. TIMEOUT means CFG_TO_THR
                // fired with the program still short of its first TXDATA write,
                // i.e. it hung or the threshold is too tight for this workload.
                $display("[FI-TRIAL %0d] cyc=%0d scan=%0d bytes=%0d  %s",
                         trial_n + 1, obs_cyc, scan_win, trial_bytes,
                         (trial_txd !== 1'b1)  ? "TIMEOUT (never reached first TXDATA write)" :
                         (trial_bytes == 0)    ? "compute finished, no UART captured"         :
                                                 "payload printed");
                trial_n     <= trial_n + 1;
                trial_bytes <= 0;
                trial_txd   <= 1'b0;
                scan_win    <= 0;
            end
        end
    end

    // ---- injection-path probe, +define+FI_DEBUG only -------------------------
    // scan=N on the FI-TRIAL line already answers "did an injection happen".
    // These answer "where did it stop" when it did not:
    //
    //   scan_start      the time comparator fired, with the table handshake
    //   scan_ctrl_start the scan controller was actually triggered
    //   entry_pop       which FI_Index was consumed, in shift order
    //   scan_out        toggle count -- the DUT obeying, not just scan_en high
    //   target_*        the targeted flop before/after: the only measurement
    //                   that depends on nothing else. FI_TGT_WORD is DUT- AND
    //                   netlist-specific, which is the other reason this whole
    //                   block is off by default.
    //
    //   make DEFINES='+define+T22NM +define+FI_DEBUG'
`ifdef FI_DEBUG
`define FI_CORE u_fi_wrapper_top.u_fi_executor.u_fi_executor_core
`define FI_TIME `FI_CORE.u_fi_time_ctrl

    // The register to watch: look the target's FI_Index up in fi_scanmap.txt;
    // injecting it must show up here as a difference of exactly one bit.
    // Retarget with +define+FI_TGT_WORD=<hierarchical net> for another flop.
`ifndef FI_TGT_WORD
  `define FI_TGT_WORD u_tinyriscv_soc_top.u_tinyriscv_core.u_gpr_reg.gpr_rw_2__not_x0_rf_dff.qout
`endif

    integer dbg_c0, scan_out_tog;
    reg     scan_out_prev, dbg_sen_d;
    reg [31:0] tgt_before;
    initial begin dbg_c0 = 0; scan_out_tog = 0; tgt_before = 32'd0; dbg_sen_d = 1'b0; end

    always @(posedge clk_i) begin
        if (rst_ni === 1'b1) begin
            dbg_sen_d     <= sc_scanen;
            scan_out_prev <= tb_io_scanout;
            if ((sc_scanen === 1'b1) && (dbg_sen_d !== 1'b1)) begin
                dbg_c0       <= obs_cyc;
                scan_out_tog <= 0;
                tgt_before   <= `FI_TGT_WORD;
                $display("[FI-PROBE] scan_en RISE t=%0t cyc=%0d  testmode=%b clk_gate=%b  target_before=%08h",
                         $time, obs_cyc, sc_testmode, clk_gate_o, `FI_TGT_WORD);
            end else if ((sc_scanen !== 1'b1) && (dbg_sen_d === 1'b1)) begin
                $display("[FI-PROBE] scan_en FALL t=%0t cyc=%0d  held %0d cycles (CFG_SCAN_LEN=%0d)  scan_out toggled %0d times",
                         $time, obs_cyc, obs_cyc - dbg_c0,
                         u_fi_wrapper_top.u_fi_executor.cfg_scan_len_i, scan_out_tog);
                $display("[FI-PROBE] target_after=%08h  XOR=%08h  %s",
                         `FI_TGT_WORD, tgt_before ^ `FI_TGT_WORD,
                         (tgt_before === `FI_TGT_WORD) ? "UNCHANGED -- nothing was injected into this flop"
                                                       : "CHANGED");
            end else if (sc_scanen === 1'b1) begin
                if (tb_io_scanout !== scan_out_prev)
                    scan_out_tog <= scan_out_tog + 1;
            end
        end
    end

    always @(posedge clk_i) begin
        if ((rst_ni === 1'b1) && `FI_CORE.scan_start === 1'b1)
            $display("[FI-PROBE] scan_start  t=%0t cnt=%0d target=%0d fired=%b | en_able=%b tbl_valid=%b tbl_ready=%b arm_ok=%b",
                     $time, `FI_TIME.clock_counter, `FI_TIME.fi_cycle_q,
                     `FI_TIME.fi_fired_q, `FI_CORE.cfg_en_able_r,
                     `FI_CORE.tbl_valid, `FI_CORE.tbl_ready, `FI_CORE.arm_ok);
        if (`FI_CORE.scan_ctrl_cfg_start === 1'b1)
            $display("[FI-PROBE] scan_ctrl_start t=%0t (2 cycles after scan_start)", $time);
        if (`FI_CORE.entry_pop === 1'b1)
            $display("[FI-PROBE] entry_pop   t=%0t index=%0d", $time, `FI_CORE.entry_index_sel);
    end
`endif

    // The drain after the last injection has to cover a whole program run: the
    // final trial still has to execute and print. c_uart_done is that length,
    // measured on the first run, so this follows the workload instead of a
    // constant that silently truncates a slower one.
    //
    // OBS_DRAIN_NS is a FLOOR, not just the fallback. c_uart_done is captured
    // on the first run, and that run is not guaranteed to be a good one -- if
    // it crashes early it yields a small number, and deriving the drain from it
    // alone makes the window SHORTER than OBS_DRAIN_NS. The last
    // trial then gets truncated because an earlier one failed, which reads as
    // "the final injection produced nothing" and is not true.
    function automatic integer obs_drain_ns;
        integer derived;
        derived      = (c_uart_done > 0) ? (c_uart_done * 20 + 1_000_000) : 0;
        obs_drain_ns = (derived > OBS_DRAIN_NS) ? derived : OBS_DRAIN_NS;
    endfunction

    // ---- campaign state for the terminator ----------------------------------
    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            fi_seen <= 1'b0; fi_done <= 1'b0; t_fi_done <= 0;
        end else begin
            if (fi_en === 1'b1) fi_seen <= 1'b1;
            if (fi_seen && (fi_en !== 1'b1) && !fi_done) begin
                fi_done   <= 1'b1;
                t_fi_done <= $time;
            end
        end
    end

    // ---- report, emitted exactly once ---------------------------------------
    function automatic void obs_report(input integer fd);
        begin
            $fwrite(fd, "\n======== FI EXECUTION WINDOW (first run) ========\n");
            $fwrite(fd, "cycles from reset release, 50 MHz / 20 ns\n");
            $fwrite(fd, "  exec start (first GPIO write)     : %0d\n", c_start);
            $fwrite(fd, "  exec end   (first UART TXDATA wr) : %0d\n", c_end);
            $fwrite(fd, "  uart done  (last byte received)   : %0d\t(%0d bytes)\n",
                    c_uart_done, n_byte);
            if ((c_start >= 0) && (c_end >= 0))
                $fwrite(fd, "cfg_fi_cycle_i range : [%0d, %0d)\n", c_start, c_end);
            if (c_uart_done >= 0)
                $fwrite(fd, "cfg_to_thr_i       : > %0d\n", c_uart_done);
            $fwrite(fd, "=================================================\n");
        end
    endfunction

    function automatic void obs_emit;
        begin
            if (!reported) begin
                reported = 1'b1;
                obs_report(obs_fd);          // -> fi_exec_window.txt
                obs_report(32'h8000_0001);   // -> stdout
                $fclose(obs_fd);
            end
        end
    endfunction

    // A resolver_rst restarts the program, so it invalidates a partial capture:
    // throw it away and measure the next run instead. Note the FIRST resolver_rst
    // is normally the campaign kickoff: once armed, the run in progress ends
    // when its cycle counter reaches CFG_TO_THR (at once if it is already
    // past), which can land in the middle of the first run - freezing there
    // would report exec end = -1.
    reg fi_scanrst_d;
    initial fi_scanrst_d = 1'b0;

    always @(posedge clk_i) begin
        if (rst_ni === 1'b1) begin
            if ((fi_resolver_rst === 1'b1) && (fi_scanrst_d !== 1'b1) && !reported) begin
                c_start = -1; c_end = -1; c_uart_done = -1; n_byte = 0;
            end
            fi_scanrst_d = fi_resolver_rst;
        end
    end

    // ------------------------------------------------------------------
    // TERMINATOR
    //   FI campaign : run until the FI table is exhausted (cfg_en_able_w
    //                 falls), then drain and finish.
    //   No campaign : finish OBS_DRAIN_NS after the first sim_end.
    //   Backstop    : +vcs+finish+<time> on the simv command line. The final
    //                 block still runs, so a hung injection still reports.
    // A hung round produces no sim_end, so sim_end is deliberately not the
    // campaign termination condition.
    //
    // The same poll also emits the report once printing has been quiet for
    // OBS_DRAIN_NS, so the numbers appear early instead of at $finish.
    // ------------------------------------------------------------------
    initial begin
        forever begin
            #(OBS_POLL_NS);
            // A run is complete once all three numbers are in and the UART
            // has been idle long enough that printing must have stopped.
            if ((n_byte > 0) && (c_start >= 0) && (c_end >= 0) &&
                (($time - t_last_byte) >= OBS_QUIET_NS))
                obs_emit;
            if (fi_done && (($time - t_fi_done) >= obs_drain_ns())) begin
                $display("[FI-OBS] FI table exhausted after %0d trials -> finish",
                         trial_n);
                $finish;
            end
            if (!fi_seen && (n_round_end > 0) &&
                (($time - t_round_end) >= OBS_DRAIN_NS)) begin
                $display("[FI-OBS] single pass done -> finish");
                $finish;
            end
        end
    end

    final begin
        obs_emit;   // in case the program never printed or never finished
        // The trial still running when the simulation ended never reached its
        // resolver_rst boundary, so it would otherwise vanish silently -- which
        // is exactly the ambiguity this block exists to remove.
        if (fi_seen)
            $display("[FI-TRIAL %0d] cyc=%0d bytes=%0d  TRUNCATED by $finish",
                     trial_n + 1, obs_cyc, trial_bytes);
    end

endmodule
