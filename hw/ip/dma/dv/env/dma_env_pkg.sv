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

  // DV-side operation selector. The RTL CONTROL register no longer carries an `opcode` field; it
  // exposes orthogonal `read_en`/`write_en`/`digest` controls. This enum is a convenience handle
  // used throughout the DV (sequences, scoreboard, coverage) that decodes to those three fields via
  // the helpers below. Values are arbitrary DV labels and do not correspond to any CSR encoding.
  typedef enum {
    OpcCopy,         // read_en=1, write_en=1, digest=NONE
    OpcSha256,       // read_en=1, write_en=1, digest=SHA256  (copy + hash)
    OpcSha384,       // read_en=1, write_en=1, digest=SHA384
    OpcSha512,       // read_en=1, write_en=1, digest=SHA512
    OpcMemset,       // read_en=0, write_en=1, digest=NONE    (fill from SRC_ADDR_LO pattern)
    OpcVerifySha256, // read_en=1, write_en=0, digest=SHA256  (read + hash, no write)
    OpcVerifySha384, // read_en=1, write_en=0, digest=SHA384
    OpcVerifySha512  // read_en=1, write_en=0, digest=SHA512
  } opcode_e;

  // Decode an operation to the captured CONTROL fields.
  function automatic bit opcode_read_en(opcode_e op);
    return !(op == OpcMemset);  // every op reads except memset
  endfunction
  function automatic bit opcode_write_en(opcode_e op);
    return !(op inside {OpcVerifySha256, OpcVerifySha384, OpcVerifySha512});  // verify does not write
  endfunction
  // CONTROL.digest field value (2-bit, matches dma_pkg::dma_digest_e encoding).
  function automatic bit [1:0] opcode_digest(opcode_e op);
    case (op)
      OpcSha256, OpcVerifySha256: return 2'd1;  // DigestSha256
      OpcSha384, OpcVerifySha384: return 2'd2;  // DigestSha384
      OpcSha512, OpcVerifySha512: return 2'd3;  // DigestSha512
      default:                    return 2'd0;  // DigestNone (copy, memset)
    endcase
  endfunction
  // True if the operation computes an inline digest (copy+hash or verify).
  function automatic bit opcode_has_digest(opcode_e op);
    return (opcode_digest(op) != 2'd0);
  endfunction

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
