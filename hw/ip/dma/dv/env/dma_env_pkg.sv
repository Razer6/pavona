// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

package dma_env_pkg;
  // dep packages
  import uvm_pkg::*;
  import top_pkg::*;
  import dv_utils_pkg::*;
  import dv_base_agent_pkg::*;
  import dv_lib_pkg::*;
  import mem_model_pkg::*;
  import tl_agent_pkg::*;
  import cip_base_pkg::*;
  import dv_base_reg_pkg::*;
  import csr_utils_pkg::*;
  import dma_ral_pkg::*;
  import prim_mubi_pkg::*;
  import dma_pkg::*;
  import dma_tlul_pkg::*;
  import tlul_pkg::*;

  // macro includes
  `include "uvm_macros.svh"
  `include "dv_macros.svh"

  // parameters
  parameter uint NUM_ALERTS = 1;
  parameter string LIST_OF_ALERTS[NUM_ALERTS] = {"fatal_fault"};

  parameter uint CTN_ADDR_WIDTH = 32;
  parameter uint CTN_DATA_WIDTH = 32;
  parameter uint HOST_ADDR_WIDTH = 32;
  parameter uint HOST_DATA_WIDTH = 32;
  // The SoC System bus carries a 64-bit address (`dma_pkg::DMA_ADDR_WIDTH`) but a
  // standard 32-bit TL data path; its memory/FIFO models use a 64-bit address with
  // the standard `HOST_DATA_WIDTH` (32-bit) data width.

  // Index of interrupt in intf_vif and bits within `intr_` registers.
  typedef enum {
    IntrDmaDone = 0,
    IntrDmaChunkDone,
    IntrDmaError,
    // Count of the number of used interrupts.
    NumDmaInterrupts
  } dma_intr_e;

  // Completion status bits (DV-internal)
  typedef enum {
    StatusDone,
    StatusChunkDone,
    StatusError,
    StatusAborted
  } status_e;
  // Bitmask of completion reason(s)
  typedef uint status_t;

  // types
  typedef virtual dma_if dma_vif;
  typedef class dma_scoreboard;

  typedef struct {
    asid_encoding_e src_id;
    asid_encoding_e dst_id;
  } addr_space_id_t;

  // package sources
  `include "dma_seq_item.sv"
  `include "dma_handshake_mode_fifo.sv"
  // Wide (64-bit) TileLink transactor for the host64 SoC System port (must precede
  // the env cfg / scoreboard / env / vseqs that reference these types).
  `include "dma_tl_seq_item.sv"
  `include "dma_tl_agent_cfg.sv"
  `include "dma_tl_monitor.sv"
  `include "dma_tl_device_driver.sv"
  `include "dma_tl_sequencer.sv"
  `include "dma_tl_agent.sv"
  `include "dma_tl_device_seq.sv"
  `include "dma_env_cfg.sv"
  `include "dma_env_cov.sv"
  `include "dma_virtual_sequencer.sv"
  `include "dma_scoreboard.sv"
  `include "dma_env.sv"
  `include "dma_pull_seq.sv"
  `include "dma_vseq_list.sv"

endpackage
