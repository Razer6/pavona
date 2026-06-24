// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

interface dma_cov_if
  import dma_reg_pkg::*;
  import dma_pkg::*;
(
  input                  clk,
  input                  rst_n,
  input dma_reg2hw_t     reg2hw,
  input dma_ctrl_state_e ctrl_state_q,
  input                  read_issue,
  input                  write_issue,
  input                  cross_port,
  input                  rd_done_q,
  input                  sha2_consumed_q,
  input                  use_inline_hashing,
  // Captured CONTROL fields driving the operation (copy/hash/memset/verify).
  input                  do_read,
  input                  do_write,
  input dma_digest_e     digest_sel,
  // Combo-reject: a CONTROL field combination raising DmaOpcodeErr in DmaAddrSetup.
  input                  set_error_code,
  input [DmaErrLast-1:0] next_error,
  // Actual length of the chunk being set up = min(total remaining, chunk_data_size); shorter than
  // chunk_data_size for the final chunk of a transfer whose total is not a chunk multiple.
  input [31:0]           remaining_bytes
);
  `include "dv_fcov_macros.svh"

  bit en_full_cov = 1'b1;

  // Concurrent read+write activity: meaningful overlap is read and write both issuing the same
  // cycle, which only happens on a cross-port copy.
  logic concurrent_rw;
  assign concurrent_rw = read_issue && write_issue;

  // SHA back-pressure corner: a beat has been captured (`rd_done_q`) in the per-beat region but the
  // SHA engine has not yet consumed it, so the read side is stalled awaiting `sha2_consumed_q`.
  logic sha_wait;
  assign sha_wait = (ctrl_state_q inside {DmaReadPrime, DmaOverlap}) &&
                    use_inline_hashing && rd_done_q && !sha2_consumed_q;

  // A CONTROL field combination is being rejected as DmaOpcodeErr this cycle.
  logic combo_reject;
  assign combo_reject = set_error_code && next_error[DmaOpcodeErr];

  // ----------------------------------------------------------------------------------------------
  // Configuration coverage. These close the holes that hid three review bugs: the multi-chunk
  // SRC/DST address write-back inversion, the inclusive-limit off-by-one, and the 13-bit GCM
  // block-count truncation. They are sampled in DmaAddrSetup, where the programmed CONTROL /
  // address / size / range fields are evaluated for the (about-to-launch) transfer.
  // ----------------------------------------------------------------------------------------------
  logic cfg_sample;
  assign cfg_sample = (ctrl_state_q == DmaAddrSetup);

  // Inclusive-limit boundary relationship per endpoint: the last accessed byte is
  // `addr + chunk_size - 1`, in range iff `<= limit`. 33-bit math avoids wrap. The `at_limit`
  // value (==2'd1) is the exact boundary the off-by-one previously made unreachable.
  logic [32:0] range_lim_ext, src_last_byte, dst_last_byte;
  assign range_lim_ext = {1'b0, reg2hw.enabled_memory_range_limit.q};
  assign src_last_byte = {1'b0, reg2hw.src_addr_lo.q} + {1'b0, reg2hw.chunk_data_size.q} - 33'd1;
  assign dst_last_byte = {1'b0, reg2hw.dst_addr_lo.q} + {1'b0, reg2hw.chunk_data_size.q} - 33'd1;
  logic [1:0] src_end_rel, dst_end_rel;
  assign src_end_rel = (src_last_byte <  range_lim_ext) ? 2'd0 :
                       (src_last_byte == range_lim_ext) ? 2'd1 : 2'd2;
  assign dst_end_rel = (dst_last_byte <  range_lim_ext) ? 2'd0 :
                       (dst_last_byte == range_lim_ext) ? 2'd1 : 2'd2;

  // Final-partial-chunk boundary. The ACTUAL last byte of the chunk being set up is
  // `addr + remaining_bytes - 1`; for the final chunk of a non-multiple transfer remaining_bytes is
  // shorter than chunk_data_size, so this measures the inclusive-limit boundary for the genuine
  // partial final chunk - the case the per-chunk range check must accept by its actual length
  // (distinct from the full-chunk boundary in src/dst_end_vs_limit above).
  logic        partial_final_chunk;
  assign partial_final_chunk = (remaining_bytes < reg2hw.chunk_data_size.q);
  logic [32:0] src_actual_last_byte, dst_actual_last_byte;
  assign src_actual_last_byte = {1'b0, reg2hw.src_addr_lo.q} + {1'b0, remaining_bytes} - 33'd1;
  assign dst_actual_last_byte = {1'b0, reg2hw.dst_addr_lo.q} + {1'b0, remaining_bytes} - 33'd1;
  logic [1:0] src_actual_end_rel, dst_actual_end_rel;
  assign src_actual_end_rel = (src_actual_last_byte <  range_lim_ext) ? 2'd0 :
                              (src_actual_last_byte == range_lim_ext) ? 2'd1 : 2'd2;
  assign dst_actual_end_rel = (dst_actual_last_byte <  range_lim_ext) ? 2'd0 :
                              (dst_actual_last_byte == range_lim_ext) ? 2'd1 : 2'd2;

  covergroup dma_fsm_cg @(posedge clk);
    option.per_instance = 1;
    option.name = "dma_fsm_cg";

    // Visit every control-FSM state.
    cp_ctrl_state: coverpoint ctrl_state_q iff (rst_n) {
      bins idle        = {DmaIdle};
      bins clr_intr    = {DmaClearIntrSrc};
      bins wait_intr   = {DmaWaitIntrSrcResponse};
      bins addr_setup  = {DmaAddrSetup};
      bins read_prime  = {DmaReadPrime};
      bins overlap     = {DmaOverlap};
      bins last_write  = {DmaLastWrite};
      bins sha_final   = {DmaShaFinalize};
      bins error       = {DmaError};
      // Inline AES block-serial sub-FSM.
      bins aes_gather   = {DmaAesGather};
      bins aes_process  = {DmaAesProcess};
      bins aes_scatter  = {DmaAesScatter};
      bins aes_ghash_aad = {DmaAesGhashAad};
      bins aes_tag      = {DmaAesTag};
    }

    // FSM edges of the per-beat overlap region.
    cp_fsm_transition: coverpoint ctrl_state_q iff (rst_n) {
      // Chunk setup primes the first read.
      bins setup_to_prime    = (DmaAddrSetup  => DmaReadPrime);
      // Multi-beat chunk enters the overlap region; single-beat chunk skips straight to the write.
      bins prime_to_overlap  = (DmaReadPrime  => DmaOverlap);
      bins prime_to_last     = (DmaReadPrime  => DmaLastWrite);
      // Steady-state overlap, and its exit to the final write.
      bins overlap_to_overlap = (DmaOverlap   => DmaOverlap);
      bins overlap_to_last    = (DmaOverlap   => DmaLastWrite);
      // Transfer / chunk completion out of the final write.
      bins last_to_final     = (DmaLastWrite  => DmaShaFinalize);
      bins last_to_idle      = (DmaLastWrite  => DmaIdle);
      bins final_to_idle     = (DmaShaFinalize => DmaIdle);
      // Inline AES block-serial path: setup -> (AAD ->) gather -> process -> scatter -> {next
      // block | tag (GCM) | idle (CTR)}; the tag completes or errors on a mismatch.
      bins setup_to_gather    = (DmaAddrSetup   => DmaAesGather);
      bins setup_to_aad       = (DmaAddrSetup   => DmaAesGhashAad);
      bins aad_to_gather      = (DmaAesGhashAad => DmaAesGather);
      bins gather_to_process  = (DmaAesGather   => DmaAesProcess);
      bins process_to_scatter = (DmaAesProcess  => DmaAesScatter);
      bins scatter_to_gather  = (DmaAesScatter  => DmaAesGather);  // next block
      bins scatter_to_tag     = (DmaAesScatter  => DmaAesTag);     // GCM finalize
      bins scatter_to_idle    = (DmaAesScatter  => DmaIdle);       // CTR complete
      bins tag_to_idle        = (DmaAesTag      => DmaIdle);       // GCM complete
      bins tag_to_error       = (DmaAesTag      => DmaError);      // tag mismatch
    }

    // Concurrent read/write activity. Bit order is {read_issue, write_issue}: MSB=read, LSB=write.
    cp_overlap: coverpoint {read_issue, write_issue} iff (rst_n) {
      bins none       = {2'b00};
      bins read_only  = {2'b10};
      bins write_only = {2'b01};
      bins both       = {2'b11};  // the actual concurrent read+write overlap
    }

    // Concurrent read+write activity collapsed to a single bit, for crossing with cross_port.
    cp_concurrent_rw: coverpoint concurrent_rw iff (rst_n) {
      bins serial     = {1'b0};
      bins concurrent = {1'b1};
    }

    // Cross-port qualifier: overlap is only meaningful when src and dst use different ports.
    cp_cross_port: coverpoint cross_port iff (rst_n) {
      bins same_port  = {1'b0};
      bins cross_port = {1'b1};
    }

    // Concurrent read+write must coincide with a cross-port copy.
    cr_overlap_xport: cross cp_concurrent_rw, cp_cross_port iff (rst_n) {
      bins overlap_cross = binsof(cp_concurrent_rw) intersect {1'b1} &&
                           binsof(cp_cross_port) intersect {1'b1};
    }

    // SHA back-pressure corner now lives in DmaReadPrime/DmaOverlap: a captured beat awaiting SHA
    // consume stalls the read side.
    cp_sha_backpressure: coverpoint sha_wait iff (rst_n) {
      bins not_waiting = {1'b0};
      bins waiting     = {1'b1};
    }

    // Captured CONTROL fields of an accepted operation. Sampled while in DmaReadPrime so the fields
    // reflect a transfer the DUT has accepted (a launched copy/hash/memset/verify).
    cp_do_read: coverpoint do_read iff (rst_n && ctrl_state_q == DmaReadPrime) {
      bins no_read = {1'b0};   // memset
      bins read    = {1'b1};   // copy / hash / verify
    }
    cp_do_write: coverpoint do_write iff (rst_n && ctrl_state_q == DmaReadPrime) {
      bins no_write = {1'b0};  // verify
      bins write    = {1'b1};  // copy / hash / memset
    }
    cp_digest: coverpoint digest_sel iff (rst_n && ctrl_state_q == DmaReadPrime) {
      bins none   = {DigestNone};
      bins sha256 = {DigestSha256};
      bins sha384 = {DigestSha384};
      bins sha512 = {DigestSha512};
    }

    // Cross read_en x write_en x digest restricted to the legal operation set:
    //   copy   (read, write, none), hash (read, write, sha*),
    //   memset (no_read, write, none), verify (read, no_write, sha*).
    cr_control_legal: cross cp_do_read, cp_do_write, cp_digest iff (rst_n) {
      bins copy   = binsof(cp_do_read.read)    && binsof(cp_do_write.write)    &&
                    binsof(cp_digest.none);
      bins hash   = binsof(cp_do_read.read)    && binsof(cp_do_write.write)    &&
                    (binsof(cp_digest.sha256) || binsof(cp_digest.sha384) ||
                     binsof(cp_digest.sha512));
      bins memset = binsof(cp_do_read.no_read) && binsof(cp_do_write.write)    &&
                    binsof(cp_digest.none);
      bins verify = binsof(cp_do_read.read)    && binsof(cp_do_write.no_write) &&
                    (binsof(cp_digest.sha256) || binsof(cp_digest.sha384) ||
                     binsof(cp_digest.sha512));
      // The remaining combinations are illegal and are covered via cp_combo_reject below.
      ignore_bins illegal = binsof(cp_do_read.no_read) && binsof(cp_do_write.no_write);
    }

    // Rejected CONTROL combinations raising DmaOpcodeErr (no-op, hash-without-read,
    // read-and-discard, handshake-without-read/write).
    cp_combo_reject: coverpoint combo_reject iff (rst_n) {
      bins not_rejected = {1'b0};
      bins rejected     = {1'b1};
    }
  endgroup

  `DV_FCOV_INSTANTIATE_CG(dma_fsm_cg, en_full_cov)

  covergroup dma_cfg_cg @(posedge clk);
    option.per_instance = 1;
    option.name = "dma_cfg_cg";

    // ---- Inclusive-limit boundary (#2). `at_limit` is the end==limit case the off-by-one hid. ----
    // Gated per side: memset has no source read, verify has no destination write.
    cp_src_end_vs_limit: coverpoint src_end_rel iff (rst_n && cfg_sample && do_read) {
      bins below    = {2'd0};
      bins at_limit = {2'd1};
      bins above    = {2'd2};
    }
    cp_dst_end_vs_limit: coverpoint dst_end_rel iff (rst_n && cfg_sample && do_write) {
      bins below    = {2'd0};
      bins at_limit = {2'd1};
      bins above    = {2'd2};
    }

    // ---- Final-partial-chunk boundary. Sampled only when the chunk being set up is the shorter
    //      final chunk (remaining_bytes < chunk_data_size). The `at_limit` bin is the key case the
    //      per-chunk range check must accept by its actual length: a partial final chunk ending
    //      exactly on the inclusive limit (a full-chunk computation would overshoot). `above` is the
    //      rejected (out-of-range) partial chunk. ----
    cp_src_partial_end: coverpoint src_actual_end_rel
        iff (rst_n && cfg_sample && do_read && partial_final_chunk) {
      bins below    = {2'd0};
      bins at_limit = {2'd1};
      bins above    = {2'd2};
    }
    cp_dst_partial_end: coverpoint dst_actual_end_rel
        iff (rst_n && cfg_sample && do_write && partial_final_chunk) {
      bins below    = {2'd0};
      bins at_limit = {2'd1};
      bins above    = {2'd2};
    }
  endgroup

  `DV_FCOV_INSTANTIATE_CG(dma_cfg_cg, en_full_cov)

endinterface
