// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

package dma_pkg;
  // Create a type to be exposed for the inter_signal_list in the HJSON definition
  // This type is needed since regtool cannot evaluate parameters defined in the HJSON
  typedef logic [dma_reg_pkg::NumIntClearSources-1:0] lsio_trigger_t;

  // Possible error bits the DMA can raise
  typedef enum logic [4:0] {
    DmaSrcAddrErr,
    DmaDstAddrErr,
    DmaOpcodeErr,
    DmaSizeErr,
    DmaBusErr,
    DmaBaseLimitErr,
    DmaRangeValidErr,
    DmaAsidErr,
    DmaErrLast
  } dma_error_e;

  // DMAC Transfer width as encoded in `transfer_width` register
  typedef enum logic [1:0] {
    DmaXfer1BperTxn = 2'h0,
    DmaXfer2BperTxn = 2'h1,
    DmaXfer4BperTxn = 2'h2
  } dma_transfer_width_e;

  // ASID uses a 4-bit FI protected encoding with a minimum Hamming distance of 2-bit
  parameter int unsigned ASID_WIDTH = 4;

  typedef enum logic [ASID_WIDTH-1:0] {
    OtInternalAddr = 4'h7,
    SocControlAddr = 4'ha,
    SocSystemAddr  = 4'h9
  } asid_encoding_e;

  ////////////////////////////////
  // Generic host port descriptor //
  ////////////////////////////////

  typedef enum logic [0:0] {
    PortTlul32,
    PortTlul64
  } dma_port_class_e;

  typedef struct packed {
    asid_encoding_e                 asid;
    dma_port_class_e                cls;
    logic                           range_check;
    logic [tlul_pkg::RsvdWidth-1:0] user_rsvd;
  } dma_port_desc_t;

  parameter dma_port_desc_t DmaPortOtInternal =
      '{asid: OtInternalAddr, cls: PortTlul32, range_check: 1'b1, user_rsvd: '0};
  parameter dma_port_desc_t DmaPortSocControl =
      '{asid: SocControlAddr, cls: PortTlul32, range_check: 1'b0, user_rsvd: '0};
  parameter dma_port_desc_t DmaPortSocSystem  =
      '{asid: SocSystemAddr, cls: PortTlul64, range_check: 1'b0, user_rsvd: '0};

  parameter int unsigned NumPortsDefault = 3;
  parameter dma_port_desc_t DmaPortDesc [NumPortsDefault] = '{
    DmaPortOtInternal,
    DmaPortSocControl,
    DmaPortSocSystem
  };

  function automatic int unsigned dma_count_class(dma_port_class_e c);
    dma_count_class = 0;
    for (int unsigned i = 0; i < NumPortsDefault; i++) begin
      if (DmaPortDesc[i].cls == c) dma_count_class = dma_count_class + 1;
    end
  endfunction

  function automatic int unsigned dma_class_subidx(int unsigned p);
    dma_class_subidx = 0;
    for (int unsigned i = 0; i < p; i++) begin
      if (DmaPortDesc[i].cls == DmaPortDesc[p].cls) dma_class_subidx = dma_class_subidx + 1;
    end
  endfunction

  parameter int unsigned NumTlul32Default = dma_count_class(PortTlul32);
  parameter int unsigned NumTlul64Default = dma_count_class(PortTlul64);

  function automatic int unsigned dma_max1(int unsigned n);
    dma_max1 = (n > 0) ? n : 1;
  endfunction

  parameter int unsigned DmaPortIdxW = prim_util_pkg::vbits(NumPortsDefault);

  // Inline-hashing digest selector carried in the captured control state.
  typedef enum logic [1:0] {
    DigestNone   = 2'd0,
    DigestSha256 = 2'd1,
    DigestSha384 = 2'd2,
    DigestSha512 = 2'd3
  } dma_digest_e;

  // Named bit definitions for the SRC_ and DST_CTRL register for convenience
  parameter bit AddrIncrement   = 1'b1;
  parameter bit AddrNoIncrement = 1'b0;
  parameter bit AddrWrapChunk   = 1'b1;
  parameter bit AddrNoWrapChunk = 1'b0;

  // Control state captured during the operation
  typedef struct packed {
    // Control register
    logic        read_en;
    logic        write_en;
    dma_digest_e digest_sel;
    logic       cfg_handshake_en;
    logic       cfg_digest_swap;
    logic       range_valid;
    // Enabled memory base register
    logic [31:0] enabled_memory_range_base;
    // Enabled memory limit register
    logic [31:0] enabled_memory_range_limit;
  } control_state_t;


  // Encoding generated with:
  // $ ./util/design/sparse-fsm-encode.py -d 3 -m 15 -n 8 \
  //     -s 8273645 --language=sv
  //
  // Hamming distance histogram:
  //
  //  0: --
  //  1: --
  //  2: --
  //  3: |||||||||||||| (27.27%)
  //  4: |||||||||||||||||||| (37.88%)
  //  5: ||||||||||| (21.21%)
  //  6: |||| (9.09%)
  //  7: || (4.55%)
  //  8: --
  //
  // Minimum Hamming distance: 3
  // Maximum Hamming distance: 7
  // Minimum Hamming weight: 3
  // Maximum Hamming weight: 7

  typedef enum logic [7:0] {
    DmaIdle                 = 8'b11110111,
    DmaClearIntrSrc         = 8'b10101100,
    DmaWaitIntrSrcResponse  = 8'b00101011,
    DmaAddrSetup            = 8'b11110000,
    DmaSendRead             = 8'b01000011,
    DmaWaitReadResponse     = 8'b00011111,
    DmaSendWrite            = 8'b10010100,
    DmaWaitWriteResponse    = 8'b11011001,
    DmaError                = 8'b01010110,
    DmaShaFinalize          = 8'b00110001,
    DmaShaWait              = 8'b01111010,
    DmaCfgValidate          = 8'b01001101,
    DmaReadBurst            = 8'b10000001,
    DmaWriteBurst           = 8'b10001010,
    DmaRunPipe              = 8'b00011000
  } dma_ctrl_state_e;

  // Maximum number of outstanding TL-UL requests per host port. >1 enables the read-ahead
  // burst datapath (DmaReadBurst/DmaWriteBurst) to keep multiple read requests in flight and
  // hide memory/bus read latency.
  //
  // Response ordering requirement: the burst path matches read data to metadata in arrival
  // order and does not inspect d_source. With NUM_MAX_OUTSTANDING_REQS > 1, each connected
  // fabric must therefore return all read responses in the order their requests were accepted,
  // across all source IDs. The OpenTitan-internal fabric provides this ordering; external
  // integrations must guarantee it. Otherwise, set NUM_MAX_OUTSTANDING_REQS to 1 or add a
  // d_source-indexed reorder buffer. See the read-ahead ordering section in
  // doc/theory_of_operation.md.
  parameter int unsigned NUM_MAX_OUTSTANDING_REQS = 8;

  // Depth of the read-ahead data/metadata FIFOs (also the maximum read burst length).
  parameter int unsigned DMA_BURST_FIFO_DEPTH = 8;

  // Internal address-arithmetic width. The DMA holds and increments src/dst
  // addresses at this width; 32-bit ports truncate to top_pkg::TL_AW, 64-bit
  // (off-bus) ports use the full width.
  parameter int unsigned DMA_ADDR_WIDTH = 64;

endpackage
