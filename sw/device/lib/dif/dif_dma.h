// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#ifndef OPENTITAN_SW_DEVICE_LIB_DIF_DIF_DMA_H_
#define OPENTITAN_SW_DEVICE_LIB_DIF_DIF_DMA_H_

/**
 * @file
 * @brief <a href="/book/hw/ip/dma/">DMA Controller</a> Device Interface
 * Functions
 */

#include <stdint.h>

#include "hw/top/dma_regs.h"  // Generated.
#include "sw/device/lib/dif/autogen/dif_dma_autogen.h"

#ifdef __cplusplus
extern "C" {
#endif  // __cplusplus

// Target Address space that the source address pointer refers to.
typedef enum dif_dma_address_space_id {
  /* OpenTitan 32 bit internal bus. */
  kDifDmaOpentitanInternalBus = DMA_ADDR_SPACE_ID_SRC_ASID_VALUE_OT_ADDR,

  /* SoC control register address bus using 32 bit (or 64 bits if configured by
     an SoC) CTN port .*/
  kDifDmaSoCControlRegisterBus = DMA_ADDR_SPACE_ID_SRC_ASID_VALUE_SOC_ADDR,

  /* SoC system address bus using 64 bit SYS port. */
  kDifDmaSoCSystemBus = DMA_ADDR_SPACE_ID_SRC_ASID_VALUE_SYS_ADDR,

  /* Generic IDs; usable only if assigned to a port in the integration. */
  kDifDmaAsid0 = DMA_ADDR_SPACE_ID_SRC_ASID_VALUE_OT_ADDR,
  kDifDmaAsid1 = DMA_ADDR_SPACE_ID_SRC_ASID_VALUE_SOC_ADDR,
  kDifDmaAsid2 = DMA_ADDR_SPACE_ID_SRC_ASID_VALUE_SYS_ADDR,
  kDifDmaAsid3 = DMA_ADDR_SPACE_ID_SRC_ASID_VALUE_ASID_3,
  kDifDmaAsid4 = DMA_ADDR_SPACE_ID_SRC_ASID_VALUE_ASID_4,
  kDifDmaAsid5 = DMA_ADDR_SPACE_ID_SRC_ASID_VALUE_ASID_5,
  kDifDmaAsid6 = DMA_ADDR_SPACE_ID_SRC_ASID_VALUE_ASID_6,
  kDifDmaAsid7 = DMA_ADDR_SPACE_ID_SRC_ASID_VALUE_ASID_7,
  kDifDmaAsid8 = DMA_ADDR_SPACE_ID_SRC_ASID_VALUE_ASID_8,
  kDifDmaAsid9 = DMA_ADDR_SPACE_ID_SRC_ASID_VALUE_ASID_9,
  kDifDmaAsid10 = DMA_ADDR_SPACE_ID_SRC_ASID_VALUE_ASID_10,
  kDifDmaAsid11 = DMA_ADDR_SPACE_ID_SRC_ASID_VALUE_ASID_11,
  kDifDmaAsid12 = DMA_ADDR_SPACE_ID_SRC_ASID_VALUE_ASID_12,
  kDifDmaAsid13 = DMA_ADDR_SPACE_ID_SRC_ASID_VALUE_ASID_13,
  kDifDmaAsid14 = DMA_ADDR_SPACE_ID_SRC_ASID_VALUE_ASID_14,
  kDifDmaAsid15 = DMA_ADDR_SPACE_ID_SRC_ASID_VALUE_ASID_15,
} dif_dma_address_space_id_t;

/* Supported transaction widths by the DMA */
typedef enum dif_dma_transaction_width {
  /* Transfer 1 byte at a time.*/
  kDifDmaTransWidth1Byte = 0x00,
  /* Transfer 2 byte at a time.*/
  kDifDmaTransWidth2Bytes = 0x01,
  /* Transfer 4 byte at a time.*/
  kDifDmaTransWidth4Bytes = 0x02,
} dif_dma_transaction_width_t;

/* Supported operations by the DMA.
 *
 * The DMA CONTROL register no longer carries a single `opcode` field. Instead it
 * exposes three orthogonal controls: `read_en` (read from source), `write_en`
 * (write to destination) and `digest` (inline hash selector). This enum is kept
 * as a convenience selector: each value is decoded by the DIF into the
 * corresponding (read_en, write_en, digest) tuple written to CONTROL.
 *
 * Operation -> (read_en, write_en, digest):
 *   kDifDmaCopyOpcode      -> (1, 1, none)    copy source to destination
 *   kDifDmaSha256Opcode    -> (1, 1, sha256)  copy + inline SHA2-256
 *   kDifDmaSha384Opcode    -> (1, 1, sha384)  copy + inline SHA2-384
 *   kDifDmaSha512Opcode    -> (1, 1, sha512)  copy + inline SHA2-512
 *   kDifDmaMemsetOpcode    -> (0, 1, none)    fill destination from SRC_ADDR_LO
 *   kDifDmaVerifySha256Opcode -> (1, 0, sha256) read-only, digest over source
 *   kDifDmaVerifySha384Opcode -> (1, 0, sha384)
 *   kDifDmaVerifySha512Opcode -> (1, 0, sha512)
 *
 * The numeric values of the legacy copy/hash entries match the previous
 * CONTROL `opcode` encoding (Copy=0, Sha256=1, Sha384=2, Sha512=3) so callers
 * that hardcoded those values keep mapping to the same operation.
 */
typedef enum dif_dma_transaction_opcode {
  /* Simple copy from source to destination (read_en=1, write_en=1). */
  kDifDmaCopyOpcode = 0x00,
  /* Copy with inline hashing using SHA2-256. */
  kDifDmaSha256Opcode = 0x01,
  /* Copy with inline hashing using SHA2-384. */
  kDifDmaSha384Opcode = 0x02,
  /* Copy with inline hashing using SHA2-512. */
  kDifDmaSha512Opcode = 0x03,
  /* Memset: write only (read_en=0, write_en=1). The write data is the fill
     pattern replicated from the low 32 bits of the source address
     (SRC_ADDR_LO), set via `transaction.source.address`. */
  kDifDmaMemsetOpcode = 0x04,
  /* Verify: read only with inline hashing (read_en=1, write_en=0). The digest
     is computed over the read data; nothing is written to the destination. */
  kDifDmaVerifySha256Opcode = 0x05,
  kDifDmaVerifySha384Opcode = 0x06,
  kDifDmaVerifySha512Opcode = 0x07,
} dif_dma_transaction_opcode_t;

/**
 * Define the transaction address space.
 */
typedef struct dif_dma_transaction_address {
  uint64_t address;
  dif_dma_address_space_id_t asid;
} dif_dma_transaction_address_t;

/**
 * Addressing configuration.
 */
typedef struct dif_dma_address_config {
  /* Address wraps after each chunk, so chunks overlap */
  bool wrap;
  /* Increment after each (partial-)word transfer */
  bool increment;
} dif_dma_address_config_t;

/**
 * Parameters for a DMA Controller transaction.
 */
typedef struct dif_dma_transaction {
  dif_dma_transaction_address_t source;
  dif_dma_transaction_address_t destination;
  dif_dma_address_config_t src_config;
  dif_dma_address_config_t dst_config;
  /* Chunk size (in bytes) of the data object to transferred.*/
  size_t chunk_size;
  /* Total size (in bytes) of the data object to transferred.*/
  size_t total_size;
  /* Iteration width.*/
  dif_dma_transaction_width_t width;
} dif_dma_transaction_t;

/**
 * Configures DMA Controller for a transaction.
 *
 * This function should be called every time before `dif_dma_start`.
 *
 * @param dma A DMA Controller handle.
 * @param config Transaction configuration parameters.
 * @return The result of the operation.
 */
OT_WARN_UNUSED_RESULT
dif_result_t dif_dma_configure(const dif_dma_t *dma,
                               dif_dma_transaction_t transaction);

/**
 * Configures DMA Controller hardware handshake mode.
 *
 * This function should be called before `dif_dma_start`.
 *
 * Hardware handshake mode is used to push / pop FIFOs to / from low speed IO
 * peripherals receiving data e.g. I3C receive buffer.
 *
 * @param dma A DMA Controller handle.
 * @return The result of the operation.
 */
OT_WARN_UNUSED_RESULT
dif_result_t dif_dma_handshake_enable(const dif_dma_t *dma);

/**
 * Disable DMA Controller hardware handshake mode.
 *
 * @param dma A DMA Controller handle.
 * @return The result of the operation.
 */
OT_WARN_UNUSED_RESULT
dif_result_t dif_dma_handshake_disable(const dif_dma_t *dma);

/**
 * Begins a DMA Controller transaction.
 *
 * Before this function the DMA transaction shall be configured by calling the
 * function `dif_dma_configure` and optionally `dif_dma_handshake_enable` can be
 * called.
 *
 * The `opcode` selects the operation, which the DIF decodes into the CONTROL
 * `read_en`/`write_en`/`digest` fields. For `kDifDmaMemsetOpcode` the fill
 * pattern is taken from the configured source address (SRC_ADDR_LO), so set
 * `transaction.source.address` to the desired fill value before calling
 * `dif_dma_configure`.
 *
 * @param dma A DMA Controller handle.
 * @param opcode Transaction operation selector.
 * @return The result of the operation.
 */
OT_WARN_UNUSED_RESULT
dif_result_t dif_dma_start(const dif_dma_t *dma,
                           dif_dma_transaction_opcode_t opcode);

/**
 * Abort the DMA Controller transaction in execution.
 *
 * @param dma A DMA Controller handle.
 * @return The result of the operation.
 */
OT_WARN_UNUSED_RESULT
dif_result_t dif_dma_abort(const dif_dma_t *dma);

/**
 * Set the DMA enabled memory range within the OT internal memory space.
 *
 * @param dma A DMA Controller handle.
 * @param address Base address.
 * @param size The range size.
 * @return The result of the operation.
 */
OT_WARN_UNUSED_RESULT
dif_result_t dif_dma_memory_range_set(const dif_dma_t *dma, uint32_t address,
                                      size_t size);

/**
 * Get the DMA enabled memory range within the OT internal memory space.
 *
 * @param dma A DMA Controller handle.
 * @param[out] address Out-param for the base address.
 * @param[out] size Out-param for the range size.
 * @return The result of the operation.
 */
OT_WARN_UNUSED_RESULT
dif_result_t dif_dma_memory_range_get(const dif_dma_t *dma, uint32_t *address,
                                      size_t *size);
/**
 * Locks out the DMA memory range register.
 *
 * This function is reentrant: calling it while functionality is locked will
 * have no effect and return `kDifOk`.
 *
 * @param dma A DMA Controller handle.
 * @return The result of the operation.
 */
OT_WARN_UNUSED_RESULT
dif_result_t dif_dma_memory_range_lock(const dif_dma_t *dma);

/**
 * Checks whether the DMA memory range is locked.
 *
 * @param dma A DMA Controller handle.
 * @param[out] is_locked Out-param for the locked state.
 * @return The result of the operation.
 */
OT_WARN_UNUSED_RESULT
dif_result_t dif_dma_is_memory_range_locked(const dif_dma_t *dma,
                                            bool *is_locked);

/**
 * Checks whether the DMA memory range is valid.
 *
 * @param dma A DMA Controller handle.
 * @param[out] is_valid Out-param for the valid state.
 * @return The result of the operation.
 */
OT_WARN_UNUSED_RESULT
dif_result_t dif_dma_is_memory_range_valid(const dif_dma_t *dma,
                                           bool *is_valid);

typedef enum dif_dma_status_code {
  // DMA operation is active.
  kDifDmaStatusBusy = 0x01 << DMA_STATUS_BUSY_BIT,
  // Configured DMA operation is complete.
  kDifDmaStatusDone = 0x01 << DMA_STATUS_DONE_BIT,
  // Set once aborted operation drains.
  kDifDmaStatusAborted = 0x01 << DMA_STATUS_ABORTED_BIT,
  // Error occurred during the operation.
  // Check the error_code for information about the source of the error.
  kDifDmaStatusError = 0x01 << DMA_STATUS_ERROR_BIT,
  // Set once the SHA2 digest is valid after finishing a transfer
  kDifDmaStatusSha2DigestValid = 0x01 << DMA_STATUS_SHA2_DIGEST_VALID_BIT,
  // Transfer of a single chunk is complete.
  kDifDmaStatusChunkDone = 0x01 << DMA_STATUS_CHUNK_DONE_BIT,
} dif_dma_status_code_t;

/**
 * Bitmask with the `dif_dma_status_code_t` values.
 */
typedef uint32_t dif_dma_status_t;

/**
 * Reads the DMA status.
 *
 * @param dma A DMA Controller handle.
 * @param[out] status Out-param for the status.
 * @return The result of the operation.
 */
OT_WARN_UNUSED_RESULT
dif_result_t dif_dma_status_get(const dif_dma_t *dma, dif_dma_status_t *status);

/**
 * Writes the DMA status register and clears the corrsponding status bits.
 *
 * @param dma A DMA Controller handle.
 * @param status Status bits to be cleared.
 * @return The result of the operation.
 */
OT_WARN_UNUSED_RESULT
dif_result_t dif_dma_status_write(const dif_dma_t *dma,
                                  dif_dma_status_t status);

/**
 * Clear all status bits of the status register.
 *
 * @param dma A DMA Controller handle.
 * @return The result of the operation.
 */
OT_WARN_UNUSED_RESULT
dif_result_t dif_dma_status_clear(const dif_dma_t *dma);

/**
 * Poll the DMA status util a given flag in the register is set.
 *
 * @param dma A DMA Controller handle.
 * @param flag The status that needs to bet set.
 * @return The result of the operation.
 */
OT_WARN_UNUSED_RESULT
dif_result_t dif_dma_status_poll(const dif_dma_t *dma,
                                 dif_dma_status_code_t flag);

typedef enum dif_dma_error_code {
  // Source address error.
  kDifDmaErrorNone = 0x00,
  // Source address error.
  kDifDmaErrorSourceAddress = 0x01 << 0,
  // Destination address error.
  kDifDmaErrorDestinationAddress = 0x01 << 1,
  // Opcode error.
  kDifDmaErrorOpcode = 0x01 << 2,
  // Size error.
  kDifDmaErrorSize = 0x01 << 3,
  // Bus transaction error.
  kDifDmaErrorBus = 0x01 << 4,
  // DMA enable memory config error.
  kDifDmaErrorEnableMemoryConfig = 0x01 << 5,
  // Register range valid error.
  kDifDmaErrorRangeValid = 0x01 << 6,
  // Invalid ASID error.
  kDifDmaErrorInvalidAsid = 0x01 << 7,
} dif_dma_error_code_t;

/**
 * Reads the DMA error code.
 *
 * @param dma A DMA Controller handle.
 * @param[out] error Out-param for the error code.
 * @return The result of the operation.
 */
OT_WARN_UNUSED_RESULT
dif_result_t dif_dma_error_code_get(const dif_dma_t *dma,
                                    dif_dma_error_code_t *error);

/**
 * Return the digest length given a DMA opcode.
 *
 * @param opcode A DMA opcode.
 * @param digest_len The digest length.
 * @return The result of the operation.
 */
dif_result_t dif_dma_get_digest_length(dif_dma_transaction_opcode_t opcode,
                                       uint32_t *digest_len);

/**
 * Read out the SHA2 digest
 *
 * @param dma A DMA Controller handle.
 * @param opcode The opcode to select the length of the read digest.
 * @param[out] digest Pointer to the digest, to store the read values.
 * @return The result of the operation.
 */
dif_result_t dif_dma_sha2_digest_get(const dif_dma_t *dma,
                                     dif_dma_transaction_opcode_t opcode,
                                     uint32_t digest[]);

/**
 * Enable DMA controller handshake interrupt.
 *
 * @param dma A DMA Controller handle.
 * @param enable_state Enable state. The bit position corresponds to the IRQ
 * index.
 * @return The result of the operation.
 */
OT_WARN_UNUSED_RESULT
dif_result_t dif_dma_handshake_irq_enable(const dif_dma_t *dma,
                                          uint32_t enable_state);

/**
 * Enable the corresponding DME handshake interrupt clearing mechanism.
 *
 * @param dma A DMA Controller handle.
 * @param clear_state Enable interrupt clearing mechanism. The bit position
 *                    corresponds to the IRQ index.
 * @return The result of the operation.
 */
OT_WARN_UNUSED_RESULT
dif_result_t dif_dma_handshake_clear_irq(const dif_dma_t *dma,
                                         uint32_t clear_state);

/**
 * Select the encoded target port for one interrupt-clearing source.
 * The integration must configure a port with this ASID; otherwise the hardware
 * reports an ASID error when the enabled source is cleared.
 *
 * @param dma A DMA Controller handle.
 * @param source Zero-based interrupt source number (not a byte offset).
 * @param asid Target port's encoded ASID.
 * @return The result of the operation.
 */
OT_WARN_UNUSED_RESULT
dif_result_t dif_dma_handshake_clear_irq_asid(const dif_dma_t *dma,
                                            uint32_t source,
                                            dif_dma_address_space_id_t asid);

/**
 * Address index for every interrupt. Used to configure the write address and
 * write value for the interrupt clearing mechanism.
 */
typedef enum dif_dma_intr_idx {
  kDifDmaIntrClearIdx0 = 0x0,
  kDifDmaIntrClearIdx1 = 0x4,
  kDifDmaIntrClearIdx2 = 0x8,
  kDifDmaIntrClearIdx3 = 0xC,
  kDifDmaIntrClearIdx4 = 0x10,
  kDifDmaIntrClearIdx5 = 0x14,
  kDifDmaIntrClearIdx6 = 0x18,
  kDifDmaIntrClearIdx7 = 0x1C,
  kDifDmaIntrClearIdx8 = 0x20,
  kDifDmaIntrClearIdx9 = 0x24,
  kDifDmaIntrClearIdx10 = 0x28,
} dif_dma_intr_idx_t;

/**
 * Set the write address for the interrupt clearing mechanism.
 *
 * @param dma A DMA Controller handle.
 * @param idx Index of the selected interrupt.
 * @param intr_src_addr Address to write the interrupt clearing value to.
 * @return The result of the operation.
 */
OT_WARN_UNUSED_RESULT
dif_result_t dif_dma_intr_src_addr(const dif_dma_t *dma, dif_dma_intr_idx_t idx,
                                   uint32_t intr_src_addr);

/**
 * Set the write value for the interrupt clearing mechanism.
 *
 * @param dma A DMA Controller handle.
 * @param idx Index of the selected interrupt.
 * @param intr_src_value Value to write the interrupt clearing value to.
 * @return The result of the operation.
 */
OT_WARN_UNUSED_RESULT
dif_result_t dif_dma_intr_write_value(const dif_dma_t *dma,
                                      dif_dma_intr_idx_t idx,
                                      uint32_t intr_src_value);

#ifdef __cplusplus
}  // extern "C"
#endif  // __cplusplus

#endif  // OPENTITAN_SW_DEVICE_LIB_DIF_DIF_DMA_H_
