// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

module dma_cov_bind;
  bind dma dma_cov_if u_dma_cov_if (
    .clk               (clk_i),
    .rst_n             (rst_ni),
    .reg2hw            (reg2hw),
    .ctrl_state_q      (ctrl_state_q),
    .read_issue        (read_issue),
    .write_issue       (write_issue),
    .cross_port        (cross_port),
    .rd_done_q         (rd_done_q),
    .sha2_consumed_q   (sha2_consumed_q),
    .use_inline_hashing(use_inline_hashing),
    .do_read           (do_read),
    .do_write          (do_write),
    .digest_sel        (digest_sel),
    .set_error_code    (set_error_code),
    .next_error        (next_error)
  );
endmodule
