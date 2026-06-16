// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`include "prim_assert.sv"

module dma
  import tlul_pkg::*;
  import dma_pkg::*;
  import dma_reg_pkg::*;
#(
  parameter logic [NumAlerts-1:0]           AlertAsyncOn              = {NumAlerts{1'b1}},
  // Number of cycles of differential skew to be tolerated on the alert signal
  parameter int unsigned                    AlertSkewCycles           = 1,
  parameter bit                             EnableDataIntgGen         = 1'b1,
  parameter bit                             EnableRspDataIntgCheck    = 1'b1,
  parameter bit                             EnableRacl                = 1'b0,
  parameter bit                             RaclErrorRsp              = EnableRacl,
  parameter top_racl_pkg::racl_policy_sel_t RaclPolicySelVec[NumRegs] = '{NumRegs{0}},
  // Generic host port descriptor. `NumPorts` and the `PortDesc` array default to the
  // `dma_pkg` values and can be overridden together at the top level.
  parameter int unsigned                    NumPorts                  = dma_pkg::NumPortsDefault,
  parameter dma_pkg::dma_port_desc_t        PortDesc [NumPorts]       = dma_pkg::DmaPortDesc,
  // Per-class host port counts; size the boundary port vectors and let topgen size the
  // matching top-level nets. On override they are supplied in lock-step (checked below).
  parameter int unsigned                    NumTlul32                 = dma_pkg::NumTlul32Default,
  parameter int unsigned                    NumTlul64                 = dma_pkg::NumTlul64Default
) (
  input logic                                       clk_i,
  input logic                                       rst_ni,
  input prim_mubi_pkg::mubi4_t                      scanmode_i,
  // DMA interrupts and incoming LSIO triggers
  output  logic                                     intr_dma_done_o,
  output  logic                                     intr_dma_chunk_done_o,
  output  logic                                     intr_dma_error_o,
  input   lsio_trigger_t                            lsio_trigger_i,
  // Alerts
  input  prim_alert_pkg::alert_rx_t [NumAlerts-1:0] alert_rx_i,
  output prim_alert_pkg::alert_tx_t [NumAlerts-1:0] alert_tx_o,
  // RACL interface
  input  top_racl_pkg::racl_policy_vec_t            racl_policies_i,
  output top_racl_pkg::racl_error_log_t             racl_error_o,
  // Device port
  input   tlul_pkg::tl_h2d_t                        tl_d_i,
  output  tlul_pkg::tl_d2h_t                        tl_d_o,
  // 32-bit TLUL host ports; xbar-vs-p2p routing is resolved at the top level. Width is
  // clamped to >= 1 so a zero count yields a single tied-off placeholder port.
  output  tlul_pkg::tl_h2d_t         [dma_pkg::dma_max1(NumTlul32)-1:0] host32_tl_h_o,
  input   tlul_pkg::tl_d2h_t         [dma_pkg::dma_max1(NumTlul32)-1:0] host32_tl_h_i,
  // 64-bit TLUL host ports (off-bus, point-to-point)
  output  dma_tlul_pkg::dma_tl_h2d_t [dma_pkg::dma_max1(NumTlul64)-1:0] host64_h2d_o,
  input   tlul_pkg::tl_d2h_t         [dma_pkg::dma_max1(NumTlul64)-1:0] host64_d2h_i
);
  import prim_mubi_pkg::*;
  import prim_sha2_pkg::*;

  dma_reg2hw_t reg2hw;
  dma_hw2reg_t hw2reg;

  localparam int unsigned TRANSFER_BYTES_WIDTH    = $bits(reg2hw.total_data_size.q);
  localparam int unsigned INTR_CLEAR_SOURCES_WIDTH = $clog2(NumIntClearSources);
  localparam int unsigned NR_SHA_DIGEST_ELEMENTS  = 16;

  // Port-index width derived from the (possibly-overridden) module `NumPorts`, rather than
  // dma_pkg::DmaPortIdxW which is fixed to the package-default port count.
  localparam int unsigned PortIdxW = prim_util_pkg::vbits(NumPorts);

  // Module-local descriptor helpers indexing the module parameter `PortDesc` directly so
  // they constant-fold in generate/`ASSERT_INIT` contexts (the `dma_pkg` versions take an
  // open array and serve block-level DV on the package-default descriptor).
  function automatic int unsigned dma_count_class_local(dma_pkg::dma_port_class_e cls);
    dma_count_class_local = 0;
    for (int unsigned i = 0; i < NumPorts; i++) begin
      if (PortDesc[i].cls == cls) dma_count_class_local = dma_count_class_local + 1;
    end
  endfunction

  function automatic int unsigned dma_class_subidx_local(int unsigned p);
    dma_class_subidx_local = 0;
    for (int unsigned i = 0; i < p; i++) begin
      if (PortDesc[i].cls == PortDesc[p].cls) dma_class_subidx_local = dma_class_subidx_local + 1;
    end
  endfunction

  // Count how many ports in `PortDesc` carry a given ASID. Used by elaboration-time
  // assertions guarding the interrupt-clear port lookup, which requires both the
  // OT-internal and SoC-control ASIDs to be present in `PortDesc`.
  function automatic int unsigned dma_count_asid_local(dma_pkg::asid_encoding_e asid);
    dma_count_asid_local = 0;
    for (int unsigned i = 0; i < NumPorts; i++) begin
      if (PortDesc[i].asid == asid) dma_count_asid_local = dma_count_asid_local + 1;
    end
  endfunction

  // Unified per-port signals feeding the class-agnostic FSM. The generate loop below
  // routes each port to its boundary array (32-bit or 64-bit) by its descriptor class.
  logic [NumPorts-1:0]                      port_req, port_we, port_gnt;
  logic [NumPorts-1:0]                      port_rvalid, port_err, port_intg_err;
  logic [NumPorts-1:0][DMA_ADDR_WIDTH-1:0]  port_addr;
  logic [NumPorts-1:0][top_pkg::TL_DW-1:0]  port_wdata, port_rdata;
  logic [NumPorts-1:0][top_pkg::TL_DBW-1:0] port_be;

  // Aggregated TL-UL response integrity error (OR-reduced over all host ports).
  logic dma_tlul_rsp_intg_err;

  // Unified interrupt-clear trigger (resolved index selects the target port).
  logic                       dma_clear_intr;

  logic                       capture_return_data;
  logic [top_pkg::TL_DW-1:0]  read_return_data_q, read_return_data_d, dma_rsp_data;
  logic [DMA_ADDR_WIDTH-1:0]  new_src_addr, new_dst_addr;

  logic dma_state_error;
  // SEC_CM: FSM.SPARSE
  dma_ctrl_state_e ctrl_state_q, ctrl_state_d;
  logic set_error_code, clear_go, clear_status, clear_sha_status, chunk_done;

  logic [INTR_CLEAR_SOURCES_WIDTH-1:0] clear_index_d, clear_index_q;
  logic                                clear_index_en, intr_clear_tlul_rsp_valid;
  logic                                intr_clear_tlul_gnt, intr_clear_tlul_rsp_error;

  logic [DmaErrLast-1:0] next_error;

  // Read request grant
  logic read_gnt;
  // Read response
  logic read_rsp_valid;
  // Read error occurred
  //   (Note: in use `read_rsp_error` must be qualified with `read_rsp_valid`)
  logic read_rsp_error;

  // Write request grant
  logic write_gnt;
  // Write response
  logic write_rsp_valid;
  // Write error occurred
  //   (Note: in use `write_rsp_error` must be qualified with `write_rsp_valid`)
  logic write_rsp_error;

  logic cfg_abort_en;
  assign cfg_abort_en = reg2hw.control.abort.q;

  logic cfg_handshake_en;

  // Decode scan mode enable MuBi signal.
  logic scanmode;
  assign scanmode = mubi4_test_true_strict(scanmode_i);

  logic sw_reg_wr, sw_reg_wr1, sw_reg_wr2;
  assign sw_reg_wr = reg2hw.control.go.qe;
  prim_flop #(
    .Width(1)
  ) aff_reg_wr1 (
    .clk_i ( clk_i      ),
    .rst_ni( rst_ni     ),
    .d_i   ( sw_reg_wr  ),
    .q_o   ( sw_reg_wr1 )
  );
  prim_flop #(
    .Width(1)
  ) aff_reg_wr2 (
    .clk_i ( clk_i      ),
    .rst_ni( rst_ni     ),
    .d_i   ( sw_reg_wr1 ),
    .q_o   ( sw_reg_wr2 )
  );

  // Stretch out CR writes to make sure new value can propagate through logic
  logic sw_reg_wr_extended;
  assign sw_reg_wr_extended = sw_reg_wr || sw_reg_wr1 || sw_reg_wr2;

  logic gated_clk_en, gated_clk;
  assign gated_clk_en = reg2hw.control.go.q       ||
                        (ctrl_state_q != DmaIdle) ||
                        sw_reg_wr_extended;

  prim_clock_gating #(
    .FpgaBufGlobal(1'b0) // Instantiate a local instead of a global clock buffer on FPGAs
  ) dma_clk_gate (
    .clk_i    ( clk_i        ),
    .en_i     ( gated_clk_en ),
    .test_en_i( scanmode     ),     ///< Test On to turn off the clock gating during test
    .clk_o    ( gated_clk    )
  );

  logic reg_intg_error;
  // SEC_CM: BUS.INTEGRITY
  // SEC_CM: RANGE.CONFIG.REGWEN_MUBI
  dma_reg_top #(
    .EnableRacl       ( EnableRacl       ),
    .RaclErrorRsp     ( RaclErrorRsp     ),
    .RaclPolicySelVec ( RaclPolicySelVec )
  ) u_dma_reg (
    .clk_i     ( clk_i          ),
    .rst_ni    ( rst_ni         ),
    .tl_i      ( tl_d_i         ),
    .tl_o      ( tl_d_o         ),
    .reg2hw,
    .hw2reg,
    .racl_policies_i,
    .racl_error_o,
    .intg_err_o( reg_intg_error )
  );

  // Alerts
  logic [NumAlerts-1:0] alert_test, alerts;
  assign alert_test = {reg2hw.alert_test.q & reg2hw.alert_test.qe};
  assign alerts[0]  = reg_intg_error          ||
                      dma_tlul_rsp_intg_err   ||
                      dma_state_error;

  for (genvar i = 0; i < NumAlerts; i++) begin : gen_alert_tx
    prim_alert_sender #(
      .AsyncOn(AlertAsyncOn[i]),
      .SkewCycles(AlertSkewCycles),
      .IsFatal(1'b1)
    ) u_prim_alert_sender (
      .clk_i,
      .rst_ni,
      .alert_test_i (alert_test[i]),
      .alert_req_i  (alerts[i]),
      .alert_ack_o  (),
      .alert_state_o(),
      .alert_rx_i   (alert_rx_i[i]),
      .alert_tx_o   (alert_tx_o[i])
    );
  end

  // Generic host-port datapath: instantiate the host adapter for each port's class,
  // routing it to the 32-bit or 64-bit boundary vector.
  for (genvar p = 0; p < NumPorts; p++) begin : gen_host_port
    if (PortDesc[p].cls == PortTlul32) begin : g_tlul32
      // Standard 32-bit TLUL host adapter.
      tlul_adapter_host #(
        .MAX_REQS(NUM_MAX_OUTSTANDING_REQS),
        .EnableDataIntgGen(EnableDataIntgGen),
        .EnableRspDataIntgCheck(EnableRspDataIntgCheck)
      ) u_host (
        .clk_i          ( gated_clk                         ),
        .rst_ni         ( rst_ni                            ),
        // do not make a request unless there is room for the response
        .req_i          ( port_req[p]                       ),
        .gnt_o          ( port_gnt[p]                       ),
        .addr_i         ( port_addr[p][top_pkg::TL_AW-1:0]  ),
        .we_i           ( port_we[p]                        ),
        .wdata_i        ( port_wdata[p]                     ),
        .wdata_intg_i   ( TL_A_USER_DEFAULT.data_intg       ),
        .be_i           ( port_be[p]                        ),
        .instr_type_i   ( MuBi4False                        ),
        .user_rsvd_i    ( PortDesc[p].user_rsvd              ),
        .valid_o        ( port_rvalid[p]                    ),
        .rdata_o        ( port_rdata[p]                     ),
        .rdata_intg_o   (                                   ),
        .err_o          ( port_err[p]                       ),
        .intg_err_o     ( port_intg_err[p]                  ),
        .tl_o           ( host32_tl_h_o[dma_class_subidx_local(p)]  ),
        .tl_i           ( host32_tl_h_i[dma_class_subidx_local(p)]  )
      );
    end else begin : g_tlul64
      // Wide 64-bit TLUL host adapter (off-bus, point-to-point).
      dma_tlul_adapter_host #(
        .MAX_REQS(NUM_MAX_OUTSTANDING_REQS),
        .EnableDataIntgGen(EnableDataIntgGen),
        .EnableRspDataIntgCheck(EnableRspDataIntgCheck)
      ) u_host (
        .clk_i          ( gated_clk                           ),
        .rst_ni         ( rst_ni                              ),
        // do not make a request unless there is room for the response
        .req_i          ( port_req[p]                         ),
        .gnt_o          ( port_gnt[p]                         ),
        .addr_i         ( port_addr[p]                        ),
        .we_i           ( port_we[p]                          ),
        .wdata_i        ( port_wdata[p]                       ),
        .wdata_intg_i   ( TL_A_USER_DEFAULT.data_intg         ),
        .be_i           ( port_be[p]                          ),
        .instr_type_i   ( MuBi4False                          ),
        // Wide a_user reserved field is DmaRsvdWidth (not stock RsvdWidth) bits.
        .user_rsvd_i    ( dma_tlul_pkg::DmaRsvdWidth'(PortDesc[p].user_rsvd) ),
        .valid_o        ( port_rvalid[p]                      ),
        .rdata_o        ( port_rdata[p]                       ),
        .rdata_intg_o   (                                     ),
        .err_o          ( port_err[p]                         ),
        .intg_err_o     ( port_intg_err[p]                    ),
        .tl_o           ( host64_h2d_o[dma_class_subidx_local(p)] ),
        .tl_i           ( host64_d2h_i[dma_class_subidx_local(p)] )
      );
    end
  end

  // Zero-count handling: tie off the placeholder boundary vector (default the output,
  // absorb the input) when a class has no ports.
  if (NumTlul32 == 0) begin : gen_no_tl32
    assign host32_tl_h_o = '{default: tlul_pkg::TL_H2D_DEFAULT};
    logic unused_host32_tl_h_i;
    assign unused_host32_tl_h_i = ^{host32_tl_h_i};
  end
  if (NumTlul64 == 0) begin : gen_no_tl64
    assign host64_h2d_o = '{default: dma_tlul_pkg::DMA_TL_H2D_DEFAULT};
    logic unused_host64_d2h_i;
    assign unused_host64_d2h_i = ^{host64_d2h_i};
  end

  // Aggregate the per-port response-integrity errors into the single alert path.
  assign dma_tlul_rsp_intg_err = |port_intg_err;

  // Masking incoming handshake triggers with their enables
  lsio_trigger_t lsio_trigger;
  always_comb begin
    lsio_trigger = '0;

    for (int i = 0; i < NumIntClearSources; i++) begin
      lsio_trigger[i] = lsio_trigger_i[i] && reg2hw.handshake_intr_enable.q[i];
    end
  end

  // During the active DMA operation, most of the DMA registers are locked with a hardware-
  // controlled REGWEN. However, this mechanism is not possible for all registers. For example,
  // some registers already have a different REGWEN attached (range locking) or the CONTROL
  // register, which needs to be partly writable. To lock those registers, we capture their value
  // during the start of the operation and, later on, only use the captured value in the state
  // machine. The captured state is stored in control_q.
  control_state_t control_d, control_q;
  logic           capture_state;

  // Fiddle out control bits into captured state
  always_comb begin
    control_d.opcode                     = opcode_e'(reg2hw.control.opcode.q);
    control_d.cfg_handshake_en           = reg2hw.control.hardware_handshake_enable.q;
    control_d.cfg_digest_swap            = reg2hw.control.digest_swap.q;
    control_d.range_valid                = reg2hw.range_valid.q;
    control_d.enabled_memory_range_base  = reg2hw.enabled_memory_range_base.q;
    control_d.enabled_memory_range_limit = reg2hw.enabled_memory_range_limit.q;
  end

  prim_flop_en #(
    .Width($bits(control_state_t))
  ) u_opcode (
    .clk_i  ( gated_clk     ),
    .rst_ni ( rst_ni        ),
    .en_i   ( capture_state ),
    .d_i    ( control_d     ),
    .q_o    ( control_q     )
  );

  `PRIM_FLOP_SPARSE_FSM(aff_ctrl_state_q, ctrl_state_d, ctrl_state_q, dma_ctrl_state_e, DmaIdle,
                        gated_clk, rst_ni)

  logic [TRANSFER_BYTES_WIDTH-1:0] transfer_byte_q, transfer_byte_d;
  logic [TRANSFER_BYTES_WIDTH-1:0] transfer_remaining_bytes;
  logic [TRANSFER_BYTES_WIDTH-1:0] chunk_remaining_bytes;
  logic [TRANSFER_BYTES_WIDTH-1:0] remaining_bytes;
  logic                            capture_transfer_byte;
  prim_flop_en #(
    .Width(TRANSFER_BYTES_WIDTH)
  ) aff_transfer_byte (
    .clk_i  ( gated_clk             ),
    .rst_ni ( rst_ni                ),
    .en_i   ( capture_transfer_byte ),
    .d_i    ( transfer_byte_d       ),
    .q_o    ( transfer_byte_q       )
  );

  logic [TRANSFER_BYTES_WIDTH-1:0] chunk_byte_q, chunk_byte_d;
  logic                            capture_chunk_byte;
  prim_flop_en #(
    .Width(TRANSFER_BYTES_WIDTH)
  ) aff_chunk_byte (
    .clk_i  ( gated_clk          ),
    .rst_ni ( rst_ni             ),
    .en_i   ( capture_chunk_byte ),
    .d_i    ( chunk_byte_d       ),
    .q_o    ( chunk_byte_q       )
  );

  logic       capture_transfer_width;
  logic [2:0] transfer_width_q, transfer_width_d;
  prim_flop_en #(
    .Width(3)
  ) aff_transfer_width (
    .clk_i ( gated_clk              ),
    .rst_ni( rst_ni                 ),
    .en_i  ( capture_transfer_width ),
    .d_i   ( transfer_width_d       ),
    .q_o   ( transfer_width_q       )
  );

  logic                      capture_addr;
  logic [DMA_ADDR_WIDTH-1:0] src_addr_q, src_addr_d;
  logic [DMA_ADDR_WIDTH-1:0] dst_addr_q, dst_addr_d;
  prim_flop_en #(
    .Width(DMA_ADDR_WIDTH)
  ) aff_src_addr (
    .clk_i ( gated_clk    ),
    .rst_ni( rst_ni       ),
    .en_i  ( capture_addr ),
    .d_i   ( src_addr_d   ),
    .q_o   ( src_addr_q   )
  );

  prim_flop_en #(
    .Width(DMA_ADDR_WIDTH)
  ) aff_dst_addr (
    .clk_i ( gated_clk    ),
    .rst_ni( rst_ni       ),
    .en_i  ( capture_addr ),
    .d_i   ( dst_addr_d   ),
    .q_o   ( dst_addr_q   )
  );

  logic                       capture_be;
  logic [top_pkg::TL_DBW-1:0] req_src_be_q, req_src_be_d;
  logic [top_pkg::TL_DBW-1:0] req_dst_be_q, req_dst_be_d;
  prim_flop_en #(
    .Width(top_pkg::TL_DBW)
  ) aff_req_src_be (
    .clk_i ( gated_clk    ),
    .rst_ni( rst_ni       ),
    .en_i  ( capture_be   ),
    .d_i   ( req_src_be_d ),
    .q_o   ( req_src_be_q )
  );

  prim_flop_en #(
    .Width(top_pkg::TL_DBW)
  ) aff_req_dst_be (
    .clk_i ( gated_clk    ),
    .rst_ni( rst_ni       ),
    .en_i  ( capture_be   ),
    .d_i   ( req_dst_be_d ),
    .q_o   ( req_dst_be_q )
  );

  prim_flop_en #(
    .Width(INTR_CLEAR_SOURCES_WIDTH)
  ) u_clear_index (
    .clk_i ( gated_clk      ),
    .rst_ni( rst_ni         ),
    .en_i  ( clear_index_en ),
    .d_i   ( clear_index_d  ),
    .q_o   ( clear_index_q  )
  );

  logic use_inline_hashing;
  logic sha2_hash_start, sha2_hash_process;
  logic sha2_valid, sha2_ready, sha2_digest_set;
  sha_fifo32_t sha2_data;
  digest_mode_e sha2_mode;
  sha_word64_t [7:0] sha2_digest;

  assign use_inline_hashing = control_q.opcode inside {OpcSha256,  OpcSha384, OpcSha512};
  // When reaching DmaShaFinalize, we are consuming data and start computing the digest value
  assign sha2_hash_process = (ctrl_state_q == DmaShaFinalize);

  logic sha2_consumed_d, sha2_consumed_q;
  prim_flop #(
    .Width(1)
  ) u_sha2_consumed (
    .clk_i ( gated_clk       ),
    .rst_ni( rst_ni          ),
    .d_i   ( sha2_consumed_d ),
    .q_o   ( sha2_consumed_q )
  );

  logic sha2_hash_done;
  logic sha2_hash_done_d, sha2_hash_done_q;
  prim_flop #(
    .Width(1)
  ) u_sha2_hash_done (
    .clk_i ( gated_clk        ),
    .rst_ni( rst_ni           ),
    .d_i   ( sha2_hash_done_d ),
    .q_o   ( sha2_hash_done_q )
  );

  // The SHA engine requires the message length in bits
  logic [63:0] sha2_message_len_bits;
  assign sha2_message_len_bits = reg2hw.total_data_size.q << 3;

  // Translate the DMA opcode to the SHA2 digest mode
  always_comb begin
    unique case (control_q.opcode)
      OpcSha256: sha2_mode = SHA2_256;
      OpcSha384: sha2_mode = SHA2_384;
      OpcSha512: sha2_mode = SHA2_512;
      default:   sha2_mode = SHA2_None;
    endcase
  end

  // SHA2 engine for inline hashing operations
  prim_sha2_32 #(.MultimodeEn(1)) u_sha2 (
    .clk_i              ( clk_i                 ),
    .rst_ni             ( rst_ni                ),
    .wipe_secret_i      ( 1'b0                  ),
    .wipe_v_i           ( 32'b0                 ),
    .fifo_rvalid_i      ( sha2_valid            ),
    .fifo_rdata_i       ( sha2_data             ),
    .fifo_rready_o      ( sha2_ready            ),
    .sha_en_i           ( 1'b1                  ),
    .hash_start_i       ( sha2_hash_start       ),
    .hash_stop_i        ( 1'b0                  ),
    .hash_continue_i    ( 1'b0                  ),
    .digest_mode_i      ( sha2_mode             ),
    .hash_process_i     ( sha2_hash_process     ),
    .hash_done_o        ( sha2_hash_done        ),
    .message_length_i   ( sha2_message_len_bits ),
    .digest_i           ( '0                    ),
    .digest_we_i        ( '0                    ),
    .digest_o           ( sha2_digest           ),
    .digest_on_blk_o    (                       ),
    .hash_running_o     (                       ),
    .idle_o             (                       )
  );

  // Fiddle ASIDs out for better readability during the rest of the code
  logic [ASID_WIDTH-1:0] src_asid, dst_asid;
  assign src_asid = reg2hw.addr_space_id.src_asid.q;
  assign dst_asid = reg2hw.addr_space_id.dst_asid.q;

  // Per-port "is 32-bit?" vector (constant), indexed by the upper-bits-zero checks below.
  logic [NumPorts-1:0] PortIs32;
  for (genvar p = 0; p < NumPorts; p++) begin : gen_port_is32
    assign PortIs32[p] = (PortDesc[p].cls != PortTlul64);
  end

  // ASID -> port-index reverse lookup; a miss drives the ASID validity error below.
  logic [PortIdxW-1:0] src_port_idx, dst_port_idx;
  logic                   src_asid_valid, dst_asid_valid;
  always_comb begin
    src_port_idx   = '0;
    dst_port_idx   = '0;
    src_asid_valid = 1'b0;
    dst_asid_valid = 1'b0;
    for (int unsigned i = 0; i < NumPorts; i++) begin
      if (PortDesc[i].asid == asid_encoding_e'(src_asid)) begin
        src_port_idx   = PortIdxW'(i);
        src_asid_valid = 1'b1;
      end
      if (PortDesc[i].asid == asid_encoding_e'(dst_asid)) begin
        dst_port_idx   = PortIdxW'(i);
        dst_asid_valid = 1'b1;
      end
    end
  end

  // Interrupt-clear targeting: clear_intr_bus selects 1 -> OT-internal, 0 -> SoC-control;
  // resolve those ASIDs to port indices via the descriptor lookup.
  logic [PortIdxW-1:0] ot_internal_port_idx, soc_control_port_idx;
  always_comb begin
    ot_internal_port_idx = '0;
    soc_control_port_idx = '0;
    for (int unsigned i = 0; i < NumPorts; i++) begin
      if (PortDesc[i].asid == OtInternalAddr) ot_internal_port_idx = PortIdxW'(i);
      if (PortDesc[i].asid == SocControlAddr) soc_control_port_idx = PortIdxW'(i);
    end
  end

  logic [PortIdxW-1:0] clr_port_idx;
  assign clr_port_idx = reg2hw.clear_intr_bus.q[clear_index_q] ? ot_internal_port_idx
                                                              : soc_control_port_idx;

  // Bus signals are asserted only when configured and active, so address/data are not
  // leaked to other buses: only the resolved port is driven, everything else is '0.
  always_comb begin
    port_req   = '0;
    port_we    = '0;
    port_addr  = '0;
    port_wdata = '0;
    port_be    = '0;

    if (ctrl_state_q == DmaSendRead) begin
      port_req [src_port_idx] = 1'b1;
      port_addr[src_port_idx] = src_addr_q;
      port_be  [src_port_idx] = req_src_be_q;
    end
    if (ctrl_state_q == DmaSendWrite) begin
      port_req  [dst_port_idx] = 1'b1;
      port_we   [dst_port_idx] = 1'b1;
      port_addr [dst_port_idx] = dst_addr_q;
      port_wdata[dst_port_idx] = read_return_data_q;
      port_be   [dst_port_idx] = req_dst_be_q;
    end
    if (dma_clear_intr) begin
      port_req  [clr_port_idx] = 1'b1;
      port_we   [clr_port_idx] = 1'b1;
      port_addr [clr_port_idx] = DMA_ADDR_WIDTH'(reg2hw.intr_src_addr[clear_index_q].q);
      port_wdata[clr_port_idx] = reg2hw.intr_src_wr_val[clear_index_q].q;
      port_be   [clr_port_idx] = {top_pkg::TL_DBW{1'b1}};
    end
  end

  // Response / read-data muxing: index the per-port arrays by the resolved indices.
  assign read_gnt       = port_gnt   [src_port_idx];
  assign read_rsp_valid = port_rvalid[src_port_idx];
  assign read_rsp_error = port_err   [src_port_idx];

  assign write_gnt       = port_gnt   [dst_port_idx];
  assign write_rsp_valid = port_rvalid[dst_port_idx];
  assign write_rsp_error = port_err   [dst_port_idx];

  // Interrupt-clear response muxing: index by the resolved clear-target port.
  assign intr_clear_tlul_gnt       = port_gnt   [clr_port_idx];
  assign intr_clear_tlul_rsp_valid = port_rvalid[clr_port_idx];
  assign intr_clear_tlul_rsp_error = port_err   [clr_port_idx];

  // Collect read data from the appropriate port.
  assign dma_rsp_data = port_rdata[src_port_idx];

  always_comb begin
    ctrl_state_d = ctrl_state_q;

    capture_transfer_byte  = 1'b0;
    transfer_byte_d        = transfer_byte_q;
    capture_chunk_byte     = 1'b0;
    chunk_byte_d           = chunk_byte_q;
    capture_transfer_width = 1'b0;
    transfer_width_d       = '0;
    capture_return_data    = 1'b0;
    capture_state          = 1'b0;

    next_error   = '0;
    capture_addr = 1'b0;
    src_addr_d   = '0;
    dst_addr_d   = '0;

    capture_be   = '0;
    req_src_be_d = '0;
    req_dst_be_d = '0;

    dma_clear_intr = 1'b0;
    clear_index_d  = '0;
    clear_index_en = '0;

    clear_go       = 1'b0;
    chunk_done     = 1'b0;

    dma_state_error = 1'b0;

    sha2_hash_start      = 1'b0;
    sha2_valid           = 1'b0;
    sha2_digest_set      = 1'b0;
    sha2_consumed_d      = sha2_consumed_q;

    // Make `SHA2 Done` sticky to not miss a single-cycle done event during any outstanding writes
    if (ctrl_state_q == DmaIdle) begin
      sha2_hash_done_d = 1'b0;
    end else begin
      sha2_hash_done_d = sha2_hash_done_q | sha2_hash_done;
    end

    // Default assignments for the muxed config signals for the idle state
    cfg_handshake_en = control_q.cfg_handshake_en;

    // Abort has the highest priority in the state machine. In all cases, if the abort is raised,
    // the DMA is reset to the idle state. This includes the error state and the default state,
    // which should never be reached during normal operation. The abort condition has precedence
    // over any outstanding TL-UL transaction.
    if (cfg_abort_en) begin
      ctrl_state_d = DmaIdle;
      clear_go     = 1'b1;
    end else begin
      unique case (ctrl_state_q)
        DmaIdle: begin
          chunk_byte_d       = '0;
          capture_chunk_byte = 1'b1;

          // In DmaIdle we need to determine if we are really idling or we are doing a roundtrip
          // via idle. If we are really idling, we need to take the config from the register
          // interface; otherwise we need to take the captured data.
          if (!reg2hw.status.busy.q) begin
            // We are idling
            cfg_handshake_en = reg2hw.control.hardware_handshake_enable.q;
          end
          // else, we are doing a roundtrip, and signaling is covered by the default assignment

          // Wait for `go` bit to be set to proceed with data movement
          if (reg2hw.control.go.q || reg2hw.status.busy.q) begin
            // Clear the transferred bytes only on the very first iteration
            if (reg2hw.control.initial_transfer.q && !reg2hw.status.busy.q) begin
              transfer_byte_d       = '0;
              capture_transfer_byte = 1'b1;
              // Capture unlocked state when starting the transfer.
              capture_state = 1'b1;
            end
            // if not handshake start transfer
            if (!cfg_handshake_en) begin
              ctrl_state_d = DmaAddrSetup;
            end else if (cfg_handshake_en && |lsio_trigger) begin
              // if handshake wait for interrupt
              if (|reg2hw.clear_intr_src.q) begin
                clear_index_en = 1'b1;
                clear_index_d  = '0;
                ctrl_state_d   = DmaClearIntrSrc;
              end else begin
                ctrl_state_d = DmaAddrSetup;
              end
            end
          end
        end

        DmaClearIntrSrc: begin
          // Clear the interrupt by writing
          if (reg2hw.clear_intr_src.q[clear_index_q]) begin
            // Send 'clear interrupt' write to the bus selected by clr_port_idx
            dma_clear_intr = 1'b1;

            if (intr_clear_tlul_gnt) begin
              ctrl_state_d = DmaWaitIntrSrcResponse;
            end

            // Writes also get a resp valid, but no data.
            // Need to wait for this to not overrun TL-UL adapter
            // The response might come immediately
            if (intr_clear_tlul_rsp_valid) begin
              if (intr_clear_tlul_rsp_error) begin
                next_error[DmaBusErr] = 1'b1;
                ctrl_state_d = DmaError;
              end else if (32'(clear_index_q) >= (NumIntClearSources - 1)) begin
                ctrl_state_d = DmaAddrSetup;  // Proceed now we've handled all
              end else begin
                clear_index_en = 1'b1;
                clear_index_d  = clear_index_q + INTR_CLEAR_SOURCES_WIDTH'(1'b1);
                ctrl_state_d   = DmaClearIntrSrc;  // Override the _gnt response above.
              end
            end
          end else begin
            // Do nothing if no clearing requested
            clear_index_en = 1'b1;
            clear_index_d  = clear_index_q + INTR_CLEAR_SOURCES_WIDTH'(1'b1);

            if (32'(clear_index_q) >= (NumIntClearSources - 1)) begin
              ctrl_state_d = DmaAddrSetup;
            end
          end
        end

        DmaWaitIntrSrcResponse: begin
          // Writes also get a resp valid, but no data.
          // Need to wait for this to not overrun TL-UL adapter
          if (intr_clear_tlul_rsp_valid) begin
            if (intr_clear_tlul_rsp_error) begin
              next_error[DmaBusErr] = 1'b1;
              ctrl_state_d = DmaError;
            end else if (32'(clear_index_q) < (NumIntClearSources - 1)) begin
              clear_index_en = 1'b1;
              clear_index_d  = clear_index_q + INTR_CLEAR_SOURCES_WIDTH'(1'b1);
              ctrl_state_d   = DmaClearIntrSrc;
            end else begin
              ctrl_state_d = DmaAddrSetup;
            end
          end
        end

        DmaAddrSetup: begin
          capture_transfer_width = 1'b1;
          capture_addr           = 1'b1;
          capture_be             = 1'b1;
          sha2_consumed_d        = 1'b0;

          // Convert the `transfer_width` encoding to bytes per transaction
          unique case (reg2hw.transfer_width.q)
            DmaXfer1BperTxn: transfer_width_d = 3'b001; // 1 byte
            DmaXfer2BperTxn: transfer_width_d = 3'b010; // 2 bytes
            DmaXfer4BperTxn: transfer_width_d = 3'b100; // 4 bytes
            // Value 3 is an invalid configuration value that leads to an error
            default: next_error[DmaSizeErr] = 1'b1;  // Invalid transfer_width
          endcase

          // Use start address on first byte of transaction
          if ((transfer_byte_q == '0) ||
              // or when in the fixed address mode
              reg2hw.src_config.increment.q == AddrNoIncrement ||
              // or when transferring the first byte of a chunk and in wrapped increment mode
              (chunk_byte_q == '0 && reg2hw.src_config.wrap.q == AddrWrapChunk)) begin
            src_addr_d = {reg2hw.src_addr_hi.q, reg2hw.src_addr_lo.q};
          end else begin
            // Advance from the previous transaction within this chunk
            src_addr_d = src_addr_q + DMA_ADDR_WIDTH'(transfer_width_d);
          end

          // Use start address on first byte of transaction
          if ((transfer_byte_q == '0) ||
              // or when in the fixed address mode
              reg2hw.dst_config.increment.q == AddrNoIncrement ||
              // or when transferring the first byte of a chunk and in wrapped increment mode
              (chunk_byte_q == '0 && reg2hw.dst_config.wrap.q == AddrWrapChunk)) begin
            dst_addr_d = {reg2hw.dst_addr_hi.q, reg2hw.dst_addr_lo.q};
          end else begin
            // Advance from the previous transaction within this chunk
            dst_addr_d = dst_addr_q + DMA_ADDR_WIDTH'(transfer_width_d);
          end

          unique case (transfer_width_d)
            3'b001: begin
              req_dst_be_d = top_pkg::TL_DBW'('b0001) << dst_addr_d[1:0];
              req_src_be_d = top_pkg::TL_DBW'('b0001) << src_addr_d[1:0];
            end
            3'b010: begin
              if (remaining_bytes >= TRANSFER_BYTES_WIDTH'(transfer_width_d)) begin
                req_dst_be_d = top_pkg::TL_DBW'('b0011) << dst_addr_d[1:0];
                req_src_be_d = top_pkg::TL_DBW'('b0011) << src_addr_d[1:0];
              end else begin
                req_dst_be_d = top_pkg::TL_DBW'('b0001) << dst_addr_d[1:0];
                req_src_be_d = top_pkg::TL_DBW'('b0001) << src_addr_d[1:0];
              end
            end
            3'b100: begin
              if (remaining_bytes >= TRANSFER_BYTES_WIDTH'(transfer_width_d)) begin
                req_dst_be_d = {top_pkg::TL_DBW{1'b1}};
              end else begin
                unique case (remaining_bytes)
                  TRANSFER_BYTES_WIDTH'('h1): req_dst_be_d = top_pkg::TL_DBW'('b0001);
                  TRANSFER_BYTES_WIDTH'('h2): req_dst_be_d = top_pkg::TL_DBW'('b0011);
                  TRANSFER_BYTES_WIDTH'('h3): req_dst_be_d = top_pkg::TL_DBW'('b0111);
                  default:                    req_dst_be_d = top_pkg::TL_DBW'('b1111);
                endcase
              end

              req_src_be_d = req_dst_be_d;  // in the case of 4B src should always = dst
            end
            default: begin
              req_dst_be_d = top_pkg::TL_DBW'('b0000);
              req_src_be_d = top_pkg::TL_DBW'('b0000);
            end
          endcase

          // Error checking. An invalid configuration triggers one or more errors
          // and does not start the DMA transfer
          if ((reg2hw.chunk_data_size.q == '0) ||         // No empty transactions
              (reg2hw.total_data_size.q == '0)) begin     // No empty transactions
            next_error[DmaSizeErr] = 1'b1;
          end

          if (!(control_q.opcode inside {OpcCopy, OpcSha256, OpcSha384, OpcSha512})) begin
            next_error[DmaOpcodeErr] = 1'b1;
          end

          // Inline hashing is only allowed for 32-bit transfer width
          if (use_inline_hashing) begin
            if (reg2hw.transfer_width.q != DmaXfer4BperTxn) begin
              next_error[DmaSizeErr] = 1'b1;
            end
          end

          // Ensure that ASIDs have valid values, i.e., resolve to a configured port.
          // SEC_CM: ASID.INTERSIG.MUBI
          if (!src_asid_valid) begin
            next_error[DmaAsidErr] = 1'b1;
          end
          if (!dst_asid_valid) begin
            next_error[DmaAsidErr] = 1'b1;
          end

          // Check the validity of the restricted DMA-enabled memory range
          // Note: both the base and the limit addresses are inclusive
          if (control_q.enabled_memory_range_limit < control_q.enabled_memory_range_base) begin
            next_error[DmaBaseLimitErr] = 1'b1;
          end

          // In 4-byte transfers, source and destination address must be 4-byte aligned
          if (reg2hw.transfer_width.q == DmaXfer4BperTxn && |reg2hw.src_addr_lo.q[1:0]) begin
            next_error[DmaSrcAddrErr] = 1'b1;
          end
          if (reg2hw.transfer_width.q == DmaXfer4BperTxn && |reg2hw.dst_addr_lo.q[1:0]) begin
            next_error[DmaDstAddrErr] = 1'b1;
          end

          // In 2-byte transfers, source and destination address must be 2-byte aligned
          if (reg2hw.transfer_width.q == DmaXfer2BperTxn && reg2hw.src_addr_lo.q[0]) begin
            next_error[DmaSrcAddrErr] = 1'b1;
          end
          if (reg2hw.transfer_width.q == DmaXfer2BperTxn &&
              reg2hw.dst_addr_lo.q[0]) begin
            next_error[DmaDstAddrErr] = 1'b1;
          end

          // Descriptor-driven memory-range protection: when exactly one endpoint is
          // range-checked, its address range must fall within the DMA enabled memory region.
          //
          // The descriptor-indexed checks below resolve `PortDesc`/`PortIs32` via
          // src/dst_port_idx, which default to port 0 on an invalid ASID. Gate them on
          // both ASIDs being valid so an invalid ASID raises only DmaAsidErr (above) and
          // not a spurious DmaSrc/DstAddrErr from the bogus default index.
          if (src_asid_valid && dst_asid_valid) begin
            // Destination is the range-checked endpoint (e.g. SoC -> OT copy).
            if (PortDesc[dst_port_idx].range_check && !PortDesc[src_port_idx].range_check &&
                // Out-of-bound check
                ((reg2hw.dst_addr_lo.q > control_q.enabled_memory_range_limit) ||
                  (reg2hw.dst_addr_lo.q < control_q.enabled_memory_range_base) ||
                  ((DMA_ADDR_WIDTH'(reg2hw.dst_addr_lo.q) +
                    DMA_ADDR_WIDTH'(reg2hw.chunk_data_size.q)) >
                    DMA_ADDR_WIDTH'(control_q.enabled_memory_range_limit)))) begin
              next_error[DmaDstAddrErr] = 1'b1;
            end

            // Source is the range-checked endpoint (e.g. OT -> SoC copy).
            if (PortDesc[src_port_idx].range_check && !PortDesc[dst_port_idx].range_check &&
                  // Out-of-bound check
                  ((reg2hw.src_addr_lo.q > control_q.enabled_memory_range_limit) ||
                  (reg2hw.src_addr_lo.q < control_q.enabled_memory_range_base)   ||
                  ((DMA_ADDR_WIDTH'(reg2hw.src_addr_lo.q) +
                    DMA_ADDR_WIDTH'(reg2hw.chunk_data_size.q)) >
                    DMA_ADDR_WIDTH'(control_q.enabled_memory_range_limit)))) begin
              next_error[DmaSrcAddrErr] = 1'b1;
            end

            // 32-bit source port: upper address bits must be zero (32-bit address space).
            if (PortIs32[src_port_idx] && (|reg2hw.src_addr_hi.q)) begin
              next_error[DmaSrcAddrErr] = 1'b1;
            end

            // 32-bit destination port: upper address bits must be zero (32-bit address space).
            if (PortIs32[dst_port_idx] && (|reg2hw.dst_addr_hi.q)) begin
              next_error[DmaDstAddrErr] = 1'b1;
            end
          end

          if (!control_q.range_valid) begin
            next_error[DmaRangeValidErr] = 1'b1;
          end

          // If one or more errors occurred, transition to the error state.
          if (|next_error) begin
            ctrl_state_d = DmaError;
          end else begin
            // Start the inline hashing if we are in the very first transfer. This is indicated
            // when transfer_byte_q is still 0
            if (transfer_byte_q == '0) begin
              if (use_inline_hashing) begin
                sha2_hash_start = 1'b1;
              end
            end
            ctrl_state_d = DmaSendRead;
          end
        end

        DmaSendRead,
        DmaWaitReadResponse: begin
          if (read_rsp_valid) begin
            if (read_rsp_error) begin
              next_error[DmaBusErr] = 1'b1;
              ctrl_state_d          = DmaError;
            end else begin
              capture_return_data = 1'b1;
              // We received data, feed it into the SHA2 engine
              if (use_inline_hashing) begin
                sha2_valid      = 1'b1;
                sha2_consumed_d = sha2_ready;
              end
              ctrl_state_d = DmaSendWrite;
            end
          end else if (read_gnt) begin
            // Only Request handled
            ctrl_state_d = DmaWaitReadResponse;
          end
        end

        DmaSendWrite,
        DmaWaitWriteResponse: begin
          // If using inline hashing and data is not yet consumed, apply it
          if (use_inline_hashing && !sha2_consumed_q) begin
            sha2_valid = 1'b1;
            sha2_consumed_d = sha2_ready;
          end

          if (write_rsp_valid) begin
            if (write_rsp_error) begin
              next_error[DmaBusErr] = 1'b1;
              ctrl_state_d          = DmaError;
            end else begin
              // Advance by the number of bytes just transferred
              transfer_byte_d       = transfer_byte_q + TRANSFER_BYTES_WIDTH'(transfer_width_q);
              chunk_byte_d          = chunk_byte_q + TRANSFER_BYTES_WIDTH'(transfer_width_q);
              capture_transfer_byte = 1'b1;
              capture_chunk_byte    = 1'b1;

              // If we are doing inline hashing and the data was not consumed yet, wait until it is
              // consumed by the SHA engine and then continue.
              if (use_inline_hashing && !(sha2_ready || sha2_consumed_q)) begin
                ctrl_state_d = DmaShaWait;
              end else begin
                // Will there still be more to do _after_ this advance?
                if (transfer_byte_d >= reg2hw.total_data_size.q) begin
                  if (use_inline_hashing) begin
                    ctrl_state_d = DmaShaFinalize;
                  end else begin
                    clear_go     = 1'b1;
                    ctrl_state_d = DmaIdle;
                  end
                end else if (chunk_byte_d >= reg2hw.chunk_data_size.q) begin
                  // Conditionally clear the `go` bit when not being used in hardware handshake
                  // mode.
                  // In non-hardware handshake mode, finishing one chunk should raise the
                  // `chunk_done` IRQ and status bit, reset the `go` bit and await the next
                  // FW-controlled chunk.
                  clear_go     = !control_q.cfg_handshake_en;
                  chunk_done   = !control_q.cfg_handshake_en;
                  ctrl_state_d = DmaIdle;
                end else begin
                  ctrl_state_d = DmaAddrSetup;
                end
              end
            end
          end else if (write_gnt) begin
            // Only Request handled
            ctrl_state_d = DmaWaitWriteResponse;
          end
        end

        DmaShaWait: begin
          // Still waiting for the SHA engine to consume the data
          sha2_valid = 1'b1;

          if (sha2_ready) begin
            // Byte count has already been updated for this transfer
            if (transfer_byte_q >= reg2hw.total_data_size.q) begin
              ctrl_state_d = DmaShaFinalize;
            end else if (chunk_byte_q >= reg2hw.chunk_data_size.q) begin
              // Conditionally clear the `go` bit when not being in hardware handshake mode.
              // In non-hardware handshake mode, finishing one chunk should raise the done IRQ
              // and done bit, and release the `go` bit for the next FW-controlled chunk.
              clear_go     = !control_q.cfg_handshake_en;
              chunk_done   = !control_q.cfg_handshake_en;
              ctrl_state_d = DmaIdle;
            end else begin
              ctrl_state_d = DmaAddrSetup;
            end
          end
        end

        DmaShaFinalize: begin
          if (sha2_hash_done_q) begin
            // Digest is ready, capture it to the CSRs
            sha2_digest_set = 1'b1;
            ctrl_state_d   = DmaIdle;
            clear_go       = 1'b1;
          end
        end

        // Wait here until the error is cleared
        DmaError: begin
          if (!reg2hw.status.error.q) begin
            ctrl_state_d = DmaIdle;
            clear_go     = 1'b1;
          end
        end

        default: begin
          // Should not be reachable
          dma_state_error = 1'b1;
        end
      endcase
    end
  end

  // Sub-word selection and replication across the bus width, such that it is available to the
  // destination for any address alignment.
  always_comb begin
    unique case (transfer_width_q)
      // 1B/txn - steer the selected byte to all byte lanes
      3'b001:
        unique casez (req_src_be_q)
          4'b1???: read_return_data_d = {4{dma_rsp_data[31:24]}};
          4'b01??: read_return_data_d = {4{dma_rsp_data[23:16]}};
          4'b001?: read_return_data_d = {4{dma_rsp_data[15:8]}};
          default: read_return_data_d = {4{dma_rsp_data[7:0]}};
        endcase
      // 2B/txn - select and duplicate the appropriate half-word
      // Note that for the final transaction of a transfer, there may be only a single strobe set.
      3'b010:  read_return_data_d = {2{|req_src_be_q[1:0] ? dma_rsp_data[15:0]
                                                          : dma_rsp_data[31:16]}};
      default: read_return_data_d = dma_rsp_data;
    endcase
  end


  prim_flop_en #(
    .Width(top_pkg::TL_DW)
  ) aff_read_return_data (
    .clk_i ( gated_clk             ),
    .rst_ni( rst_ni                ),
    .en_i  ( capture_return_data   ),
    .d_i   ( read_return_data_d    ),
    .q_o   ( read_return_data_q    )
  );

  // Mux the data for the SHA2 engine. When capturing the data we
  // can use the data from the bus, otherwise the captured data from the flop
  //
  // Note: the SHA2 logic expects the `data` and `mask` fields to be populated from the MSBs down.
  assign sha2_data.data = {<<8{capture_return_data ? read_return_data_d :
                                                     read_return_data_q}};
  assign sha2_data.mask = {<<1{req_dst_be_q}};

  // Interrupt logic
  prim_intr_hw #(
    .IntrT ( "Status" )
  ) u_intr_dma_done (
    .clk_i                  ( clk_i                         ),
    .rst_ni                 ( rst_ni                        ),
    .event_intr_i           ( reg2hw.status.done.q          ),
    .reg2hw_intr_enable_q_i ( reg2hw.intr_enable.dma_done.q ),
    .reg2hw_intr_test_q_i   ( reg2hw.intr_test.dma_done.q   ),
    .reg2hw_intr_test_qe_i  ( reg2hw.intr_test.dma_done.qe  ),
    .reg2hw_intr_state_q_i  ( reg2hw.intr_state.dma_done.q  ),
    .hw2reg_intr_state_de_o ( hw2reg.intr_state.dma_done.de ),
    .hw2reg_intr_state_d_o  ( hw2reg.intr_state.dma_done.d  ),
    .intr_o                 ( intr_dma_done_o               )
  );

  prim_intr_hw #(
    .IntrT ( "Status" )
  ) u_intr_chunk_dma_done (
    .clk_i                  ( clk_i                               ),
    .rst_ni                 ( rst_ni                              ),
    .event_intr_i           ( reg2hw.status.chunk_done.q          ),
    .reg2hw_intr_enable_q_i ( reg2hw.intr_enable.dma_chunk_done.q ),
    .reg2hw_intr_test_q_i   ( reg2hw.intr_test.dma_chunk_done.q   ),
    .reg2hw_intr_test_qe_i  ( reg2hw.intr_test.dma_chunk_done.qe  ),
    .reg2hw_intr_state_q_i  ( reg2hw.intr_state.dma_chunk_done.q  ),
    .hw2reg_intr_state_de_o ( hw2reg.intr_state.dma_chunk_done.de ),
    .hw2reg_intr_state_d_o  ( hw2reg.intr_state.dma_chunk_done.d  ),
    .intr_o                 ( intr_dma_chunk_done_o               )
  );

  prim_intr_hw #(
    .IntrT ( "Status" )
  ) u_intr_error (
    .clk_i                  ( clk_i                          ),
    .rst_ni                 ( rst_ni                         ),
    .event_intr_i           ( reg2hw.status.error.q          ),
    .reg2hw_intr_enable_q_i ( reg2hw.intr_enable.dma_error.q ),
    .reg2hw_intr_test_q_i   ( reg2hw.intr_test.dma_error.q   ),
    .reg2hw_intr_test_qe_i  ( reg2hw.intr_test.dma_error.qe  ),
    .reg2hw_intr_state_q_i  ( reg2hw.intr_state.dma_error.q  ),
    .hw2reg_intr_state_de_o ( hw2reg.intr_state.dma_error.de ),
    .hw2reg_intr_state_d_o  ( hw2reg.intr_state.dma_error.d  ),
    .intr_o                 ( intr_dma_error_o               )
  );

  logic data_move_state;
  logic update_dst_addr_reg, update_src_addr_reg;

  assign data_move_state = (ctrl_state_q == DmaSendWrite)         ||
                           (ctrl_state_q == DmaWaitWriteResponse) ||
                           (ctrl_state_q == DmaShaWait)           ||
                           (ctrl_state_q == DmaShaFinalize);



  // Calculate the number of bytes remaining until the end of the current chunk.
  // Note that the total transfer size may be a non-integral multiple of the programmed chunk size,
  // so we must consider the `total_data_size` here too; this is important in determining the
  // correct write strobes for the final word of the transfer.
  assign transfer_remaining_bytes = reg2hw.total_data_size.q - transfer_byte_q;
  assign chunk_remaining_bytes = reg2hw.chunk_data_size.q - chunk_byte_q;
  assign remaining_bytes = (transfer_remaining_bytes < chunk_remaining_bytes) ?
                            transfer_remaining_bytes : chunk_remaining_bytes;

  always_comb begin
    // Because of using the primitives for interrupt handling, the hw2reg registers cannot be
    // collectively assigned a default value since that would create a second driver to the
    // interrupt registers.
    // Thus we must ensure that all registers are initialized manually to avoid creating latches.

    // Clear the `go` bit if we are in a single transfer and finished the DMA operation,
    // hardware handshake mode when we finished all transfers, or when aborting the transfer.
    hw2reg.control.go.de = clear_go || cfg_abort_en;
    hw2reg.control.go.d  = 1'b0;

    // Unlock the register set when not busy. IDLE is not the right indicator,
    // since multi-chunked transfers roundtrip via IDLE.
    hw2reg.cfg_regwen.d = prim_mubi_pkg::mubi4_bool_to_mubi(~reg2hw.status.busy.q);

    // When we would update the register, we would update it with the current transferred number of
    // bytes of the current chunk
    new_dst_addr = {reg2hw.dst_addr_hi.q, reg2hw.dst_addr_lo.q} +
                    DMA_ADDR_WIDTH'(reg2hw.chunk_data_size.q);
    new_src_addr = {reg2hw.src_addr_hi.q, reg2hw.src_addr_lo.q} +
                    DMA_ADDR_WIDTH'(reg2hw.chunk_data_size.q);

    // If we are in multi-chunk mode, we need to update the register addresses since they are needed
    // for the next chunk. Do this only when going back to Idle and when we are incrementing the
    // address but not doing wrap-around.
    update_dst_addr_reg = 1'b0;
    update_src_addr_reg = 1'b0;
    if (data_move_state && (ctrl_state_d == DmaIdle)) begin
      if (reg2hw.src_config.increment.q == AddrNoIncrement &&
          reg2hw.src_config.wrap.q == AddrNoWrapChunk) begin
        update_src_addr_reg = 1'b1;
      end
      if (reg2hw.dst_config.increment.q == AddrNoIncrement &&
          reg2hw.dst_config.wrap.q == AddrNoWrapChunk) begin
        update_dst_addr_reg = 1'b1;
      end
    end

    hw2reg.dst_addr_hi.de = update_dst_addr_reg;
    hw2reg.dst_addr_hi.d  = new_dst_addr[63:32];

    hw2reg.dst_addr_lo.de = update_dst_addr_reg;
    hw2reg.dst_addr_lo.d  = new_dst_addr[31:0];

    hw2reg.src_addr_hi.de = update_src_addr_reg;
    hw2reg.src_addr_hi.d  = new_src_addr[63:32];

    hw2reg.src_addr_lo.de = update_src_addr_reg;
    hw2reg.src_addr_lo.d  = new_src_addr[31:0];

    hw2reg.control.initial_transfer.de = 1'b0;
    hw2reg.control.initial_transfer.d  = 1'b0;
    // Clear the `initial transfer` flag when leaving the DmaIdle state the first time.
    if ((ctrl_state_q == DmaIdle) && (ctrl_state_d != DmaIdle) &&
        reg2hw.control.initial_transfer.q) begin
      hw2reg.control.initial_transfer.de = 1'b1;
    end

    // Assert busy write enable on
    // - transitions from IDLE out
    // - clearing the `go` bit (going back to idle)
    // - abort                 (going back to idle)
    hw2reg.status.busy.de = ((ctrl_state_q == DmaIdle) && (ctrl_state_d != DmaIdle)) ||
                            clear_go                                                 ||
                            cfg_abort_en;
    // If transitioning from IDLE, set busy, otherwise clear it
    hw2reg.status.busy.d  = ((ctrl_state_q == DmaIdle) && (ctrl_state_d != DmaIdle)) ? 1'b1 : 1'b0;

    // Status is cleared when leaving the IDLE state the first time, i.e., when busy is not yet set
    clear_status = (ctrl_state_q == DmaIdle) && (ctrl_state_d != DmaIdle) && !reg2hw.status.busy.q;
    // The SHA digest valid and the digest itself needs to incorporate the initial transfer flag as
    // busy is deasserted for every chunk in the middle of a multi-chunk memory-to-memory transfer
    clear_sha_status = (ctrl_state_q == DmaIdle) && (ctrl_state_d != DmaIdle) &&
                       reg2hw.control.initial_transfer.q;

    // Set the done bit only when finishing all chunks. Automatically clear the done bit when
    // starting a new transfer
    hw2reg.status.done.de = ((!cfg_abort_en) && data_move_state && clear_go && ~chunk_done) |
                            clear_status;
    hw2reg.status.done.d  = clear_status? 1'b0 : 1'b1;

    hw2reg.status.error.de = (ctrl_state_d == DmaError) | clear_status;
    hw2reg.status.error.d  = clear_status? 1'b0 : 1'b1;

    hw2reg.status.aborted.de = cfg_abort_en | clear_status;
    hw2reg.status.aborted.d  = clear_status? 1'b0 : 1'b1;

    hw2reg.status.sha2_digest_valid.de = sha2_digest_set | clear_sha_status;
    hw2reg.status.sha2_digest_valid.d  = sha2_digest_set;

    hw2reg.status.chunk_done.de = ((!cfg_abort_en) && chunk_done) | clear_status;
    hw2reg.status.chunk_done.d  = clear_status? 1'b0 : 1'b1;

    // Write digest to CSRs when needed. The digest is an 8-element 64-bit datatype. Depending on
    // the selected hashing algorithm, the digest is stored differently in the digest datatype:
    // SHA2-256: digest[0-7][31:0] store the 256-bit digest. The upper 32-bits of all digest
    //           elements are zero
    // SHA2-384: digest[0-5][63:0] store the 384-bit digest.
    // SHA2-512: digest[0-7][63:0] store the 512-bit digest.
    for (int i = 0; i < NR_SHA_DIGEST_ELEMENTS; i++) begin
      hw2reg.sha2_digest[i].de = sha2_digest_set | clear_sha_status;
      hw2reg.sha2_digest[i].d  = '0;
    end

    // Only mux the digest data when sha2_digest_set is set. Setting the digest happens during the
    // DmaFinalze state, where we need to use the stored and locked `control_q.opcode` value.
    // In case of clear_sha_status being asserted, the default value from hw2reg = '0; clears
    // the digest
    if (sha2_digest_set) begin
      for (int unsigned i = 0; i < NR_SHA_DIGEST_ELEMENTS / 2; i++) begin
        unique case (control_q.opcode)
          OpcSha256: begin
            hw2reg.sha2_digest[i].d = conv_endian32(sha2_digest[i][0 +: 32],
                                                    control_q.cfg_digest_swap);
          end
          OpcSha384: begin
            if (i < 6) begin
              hw2reg.sha2_digest[i*2].d     = conv_endian32(sha2_digest[i][32 +: 32],
                                                            control_q.cfg_digest_swap);
              hw2reg.sha2_digest[(i*2)+1].d = conv_endian32(sha2_digest[i][0  +: 32],
                                                            control_q.cfg_digest_swap);
            end
          end
          default: begin // SHA2-512
            hw2reg.sha2_digest[i*2].d     = conv_endian32(sha2_digest[i][32 +: 32],
                                                          control_q.cfg_digest_swap);
            hw2reg.sha2_digest[(i*2)+1].d = conv_endian32(sha2_digest[i][0  +: 32],
                                                          control_q.cfg_digest_swap);
          end
        endcase
      end
    end

    // Set the error code only when entering the error state
    set_error_code = (ctrl_state_q != DmaError) && (ctrl_state_d == DmaError);

    // Fiddle out error signals
    hw2reg.error_code.src_addr_error.de    = set_error_code | clear_status;
    hw2reg.error_code.dst_addr_error.de    = set_error_code | clear_status;
    hw2reg.error_code.opcode_error.de      = set_error_code | clear_status;
    hw2reg.error_code.size_error.de        = set_error_code | clear_status;
    hw2reg.error_code.bus_error.de         = set_error_code | clear_status;
    hw2reg.error_code.base_limit_error.de  = set_error_code | clear_status;
    hw2reg.error_code.range_valid_error.de = set_error_code | clear_status;
    hw2reg.error_code.asid_error.de        = set_error_code | clear_status;

    hw2reg.error_code.src_addr_error.d     = clear_status? '0 : next_error[DmaSrcAddrErr];
    hw2reg.error_code.dst_addr_error.d     = clear_status? '0 : next_error[DmaDstAddrErr];
    hw2reg.error_code.opcode_error.d       = clear_status? '0 : next_error[DmaOpcodeErr];
    hw2reg.error_code.size_error.d         = clear_status? '0 : next_error[DmaSizeErr];
    hw2reg.error_code.bus_error.d          = clear_status? '0 : next_error[DmaBusErr];
    hw2reg.error_code.base_limit_error.d   = clear_status? '0 : next_error[DmaBaseLimitErr];
    hw2reg.error_code.range_valid_error.d  = clear_status? '0 : next_error[DmaRangeValidErr];
    hw2reg.error_code.asid_error.d         = clear_status? '0 : next_error[DmaAsidErr];

    // Clear the `control.abort` bit once we have handled the abort request
    hw2reg.control.abort.de = hw2reg.status.aborted.de;
    hw2reg.control.abort.d  = 1'b0;

    // Clear the SHA2 digests if the SHA2 valid flag is cleared (RW1C)
    if (reg2hw.status.sha2_digest_valid.qe & reg2hw.status.sha2_digest_valid.q) begin
      for (int i = 0; i < NR_SHA_DIGEST_ELEMENTS; i++) begin
        hw2reg.sha2_digest[i].de = 1'b0;
        hw2reg.sha2_digest[i].d  = '0;
      end
    end

    // Clear the error code if the error flag is cleared (RW1C)
    if (reg2hw.status.error.qe & reg2hw.status.error.q) begin
      // Clear all errors
      hw2reg.error_code.src_addr_error.de = 1'b1;
      hw2reg.error_code.dst_addr_error.de = 1'b1;
      hw2reg.error_code.opcode_error.de      = 1'b1;
      hw2reg.error_code.size_error.de        = 1'b1;
      hw2reg.error_code.bus_error.de         = 1'b1;
      hw2reg.error_code.base_limit_error.de  = 1'b1;
      hw2reg.error_code.range_valid_error.de = 1'b1;
      hw2reg.error_code.asid_error.de        = 1'b1;

      hw2reg.error_code.src_addr_error.d  = 1'b0;
      hw2reg.error_code.dst_addr_error.d  = 1'b0;
      hw2reg.error_code.opcode_error.d       = 1'b0;
      hw2reg.error_code.size_error.d         = 1'b0;
      hw2reg.error_code.bus_error.d          = 1'b0;
      hw2reg.error_code.base_limit_error.d   = 1'b0;
      hw2reg.error_code.range_valid_error.d  = 1'b0;
      hw2reg.error_code.asid_error.d         = 1'b0;
    end
  end

  //////////////////////////////////////////////////////////////////////////////
  // Unused signals
  //////////////////////////////////////////////////////////////////////////////
  logic unused_signals;
  assign unused_signals = ^{reg2hw.enabled_memory_range_base.qe,
                            reg2hw.enabled_memory_range_limit.qe,
                            reg2hw.range_regwen.q};

  //////////////////////////////////////////////////////////////////////////////
  // Assertions
  //////////////////////////////////////////////////////////////////////////////

  // All outputs should be known values after reset
  `ASSERT_KNOWN(AlertsKnown_A, alert_tx_o)
  `ASSERT_KNOWN_IF(RaclErrorOKnown_A, racl_error_o, racl_error_o.valid)
  `ASSERT_KNOWN(IntrDmaDoneKnown_A, intr_dma_done_o)
  `ASSERT_KNOWN(IntrDmaChunkDoneKnown_A, intr_dma_chunk_done_o)
  `ASSERT_KNOWN(IntrDmaErrorKnown_A, intr_dma_error_o)

  `ASSERT_KNOWN(TlDValidKnownO_A, tl_d_o.d_valid)
  `ASSERT_KNOWN(TlAReadyKnownO_A, tl_d_o.a_ready)

  // 32-bit host ports
  for (genvar i = 0; i < NumTlul32; i++) begin : gen_host_tl_known_a
    `ASSERT_KNOWN(HostTlAValidKnownO_A, host32_tl_h_o[i].a_valid)
    `ASSERT_KNOWN(HostTlDReadyKnownO_A, host32_tl_h_o[i].d_ready)
  end
  // 64-bit host ports
  for (genvar i = 0; i < NumTlul64; i++) begin : gen_host_wide_known_a
    `ASSERT_KNOWN(HostTlWideAValidKnownO_A, host64_h2d_o[i].a_valid)
    `ASSERT_KNOWN(HostTlWideDReadyKnownO_A, host64_h2d_o[i].d_ready)
  end

  // At most one host port may be requested at a time.
  `ASSERT(OnePortReq_A, $onehot0(port_req), gated_clk, !rst_ni)

  // A request must only target a port whose ASID resolved to a valid index.
  `ASSERT(ReadReqValidIdx_A, (ctrl_state_q == DmaSendRead) |-> src_asid_valid,
          gated_clk, !rst_ni)
  `ASSERT(WriteReqValidIdx_A, (ctrl_state_q == DmaSendWrite) |-> dst_asid_valid,
          gated_clk, !rst_ni)

  // Alert assertions for reg_we onehot check
  `ASSERT_PRIM_REG_WE_ONEHOT_ERROR_TRIGGER_ALERT(RegWeOnehotCheck_A, u_dma_reg, alert_tx_o[0])

  // Handshake interrupt enable register must be expanded if there are more than 32 handshake
  // trigger wires
  `ASSERT_NEVER(LimitHandshakeTriggerWires_A, NumIntClearSources > 32)

  // The RTL code assumes the BE signal is 4-bit wide
  `ASSERT_NEVER(BeLengthMustBe4_A, top_pkg::TL_DBW != 4)

  // The DMA enabled memory should not be changed after lock
  `ASSERT_NEVER(NoDmaEnabledMemoryChangeAfterLock_A,
                prim_mubi_pkg::mubi4_test_false_loose(
                  prim_mubi_pkg::mubi4_t'(reg2hw.range_regwen.q)) &&
                  (reg2hw.enabled_memory_range_base.qe ||
                   reg2hw.enabled_memory_range_limit.qe))

  // Alert assertion for sparse FSM.
  `ASSERT_PRIM_FSM_ERROR_TRIGGER_ALERT(CtrlStateFsmCheck_A, aff_ctrl_state_q, alert_tx_o[0])

  // Boundary-class count parameters must stay consistent with the `PortDesc` array.
  `ASSERT_INIT(NumTlul32Consistent_A, NumTlul32 == dma_count_class_local(dma_pkg::PortTlul32))
  `ASSERT_INIT(NumTlul64Consistent_A, NumTlul64 == dma_count_class_local(dma_pkg::PortTlul64))
  // A DMA with zero data ports is degenerate (PortDesc[NumPorts] requires NumPorts >= 1).
  `ASSERT_INIT(NumPortsNonZero_A, NumPorts >= 1)

  // The interrupt-clear path resolves the OT-internal and SoC-control ASIDs to port
  // indices via `PortDesc` (clr_port_idx). A miss would silently default to port 0, so
  // require both clear-target ASIDs to be present in `PortDesc`.
  `ASSERT_INIT(OtInternalPortPresent_A, dma_count_asid_local(dma_pkg::OtInternalAddr) >= 1)
  `ASSERT_INIT(SocControlPortPresent_A, dma_count_asid_local(dma_pkg::SocControlAddr) >= 1)

  // The wide a_user must occupy exactly TL_AUW bits, like the stock tl_a_user_t.
  `ASSERT_INIT(DmaAUserWidth_A, $bits(dma_tlul_pkg::dma_tl_a_user_t) == top_pkg::TL_AUW)
endmodule
