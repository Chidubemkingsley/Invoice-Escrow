import type { Abi } from 'viem';
import { usdgAbi } from './USDG';
import { invoiceescrowAbi } from './InvoiceEscrow';
import { advancepoolAbi } from './AdvancePool';

/**
 * Verified ABI artifacts.
 * - usdgAbi: pulled from the verified USDG implementation source on the block explorer.
 * - invoiceEscrowAbi / advancePoolAbi: generated from the Foundry build of the exact
 *   sources verified on both explorers (Arbitrum Sepolia and Robinhood Chain Testnet).
 */
export const tokenAbi = usdgAbi as Abi;
export const escrowAbi = invoiceescrowAbi as Abi;
export const poolAbi = advancepoolAbi as Abi;
export type { Abi };
