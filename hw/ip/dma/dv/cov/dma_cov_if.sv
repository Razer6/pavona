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
  input                  use_inline_hashing
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
  endgroup

  `DV_FCOV_INSTANTIATE_CG(dma_fsm_cg, en_full_cov)

endinterface
