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
  input [DmaErrLast-1:0] next_error
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

endinterface
