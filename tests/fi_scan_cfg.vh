// SPDX-License-Identifier: Apache-2.0
// Copyright 2025-2026 the FIawase authors
// Values for elaborating the wrapper in CI. A real build includes the
// fi_scan_cfg.vh that synthesis writes next to its netlist.
`ifndef FI_SCAN_CFG_VH
`define FI_SCAN_CFG_VH
`define FI_N_FF        8192
`define FI_SCAN_LEN    64
`define FI_SCRUB_LEN   8
`endif
