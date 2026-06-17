// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

module dma_cov_bind;
  bind dma dma_cov_if u_dma_cov_if (
    .clk             (clk_i),
    .rst_n           (rst_ni),
    .reg2hw          (reg2hw),
    .ctrl_state_q    (ctrl_state_q),
    .transfer_byte_q (transfer_byte_q),
    .transfer_width_q(transfer_width_q)
  );
endmodule
