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
  input [31:0]           transfer_byte_q,
  input [2:0]            transfer_width_q
);
  `include "dv_fcov_macros.svh"

  bit en_full_cov = 1'b1;

  // Bytes still to transfer once the current beat is accounted for. In DmaShaWait the byte
  // counters have already advanced for the in-flight beat, so this is what the next beat will see;
  // that next beat is the partial final beat when this is non-zero but below the transfer width.
  logic [31:0] bytes_after_curr;
  logic        next_beat_partial;
  assign bytes_after_curr  = reg2hw.total_data_size.q - transfer_byte_q;
  assign next_beat_partial = (bytes_after_curr != 0) &&
                             (bytes_after_curr < {29'b0, transfer_width_q});

  covergroup dma_fsm_cg @(posedge clk);
    option.per_instance = 1;
    option.name = "dma_fsm_cg";

    // Visit every control-FSM state, including the inline-hashing wait state.
    cp_ctrl_state: coverpoint ctrl_state_q iff (rst_n) {
      bins idle       = {DmaIdle};
      bins clr_intr   = {DmaClearIntrSrc};
      bins wait_intr  = {DmaWaitIntrSrcResponse};
      bins addr_setup = {DmaAddrSetup};
      bins send_read  = {DmaSendRead};
      bins wait_read  = {DmaWaitReadResponse};
      bins send_write = {DmaSendWrite};
      bins wait_write = {DmaWaitWriteResponse};
      bins sha_wait   = {DmaShaWait};
      bins sha_final  = {DmaShaFinalize};
      bins error      = {DmaError};
    }

    // FSM edges the within-chunk fast path introduced / depends upon.
    cp_fsm_transition: coverpoint ctrl_state_q iff (rst_n) {
      // Direct within-chunk next beat: skips DmaAddrSetup (the optimization).
      bins fast_next_beat    = (DmaWaitWriteResponse => DmaSendRead);
      // First beat of a chunk still passes through DmaAddrSetup.
      bins setup_first_beat  = (DmaAddrSetup => DmaSendRead);
      // Deferred-hash path keeps the DmaAddrSetup round-trip.
      bins sha_wait_to_setup = (DmaShaWait => DmaAddrSetup);
    }

    // The corner that exposed the deferred-hash byte-enable bug: waiting in DmaShaWait for the
    // SHA engine while the next beat will be the partial final beat.
    cp_sha_wait_next_partial: coverpoint next_beat_partial
        iff (rst_n && (ctrl_state_q == DmaShaWait)) {
      bins next_full    = {1'b0};
      bins next_partial = {1'b1};
    }
  endgroup

  `DV_FCOV_INSTANTIATE_CG(dma_fsm_cg, en_full_cov)

endinterface
