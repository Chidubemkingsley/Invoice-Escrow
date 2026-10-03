/**
 * Contract wiring for the verified testnet deployments.
 *
 * ABIs in `src/abis/` are the verified artifacts: `USDG` came from the
 * explorer API for the verified USDG implementation, `InvoiceEscrow.json` and
 * `AdvancePool.json` from the Foundry build of the sources verified on both
 * explorers. `deployments/<chainId>.json` supplies token/escrow/pool per chain.
 */
import {
  createPublicClient,
  createWalletClient,
  http,
  type Abi,
  type Address,
  type PublicClient,
  type Chain,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { escrowAbi, poolAbi, tokenAbi } from './abis/index';
import { walletConfig, type SupportedChainId } from './lib/chains';
import { resolveDeployment, type DeploymentFile } from './lib/deployments';

/** True once the verified ABI artifacts and a per-chain deployment file are present. */
export const contractArtifactsAvailable = true;

export const abis = {
  token: tokenAbi,
  escrow: escrowAbi,
  pool: poolAbi,
};

export type ContractBundle = {
  deployment: DeploymentFile;
  /** Owner recorded in the deployment file, when present. */
  poolOwner?: `0x${string}`;
  chain: Chain;
  publicClient: PublicClient;
  addresses: { token: Address; escrow: Address; pool: Address };
};

/** Resolve the deployed contracts for a chain, or null when the chain is unsupported/unconfigured. */
export function getContracts(chainId: number): ContractBundle | null {
  const resolved = resolveDeployment(chainId);
  if (resolved.status !== 'ready') return null;

  const chain = walletConfig.chains.find((c) => c.id === chainId);
  if (!chain) return null;

  return {
    deployment: resolved.deployment,
    poolOwner: (resolved.deployment as { owner?: `0x${string}` }).owner,
    chain: chain as Chain,
    publicClient: createPublicClient({ chain: chain as Chain, transport: http() }),
    addresses: {
      token: resolved.deployment.token,
      escrow: resolved.deployment.escrow,
      pool: resolved.deployment.pool,
    },
  };
}

export function isSupportedChain(chainId: number | undefined): chainId is SupportedChainId {
  return chainId != null && walletConfig.chains.some((c) => c.id === chainId);
}

/** Read helpers used by the invoice, market and pool pages. */
export const reads = {
  async usdgBalance(bundle: ContractBundle, account: Address) {
    return bundle.publicClient.readContract({
      address: bundle.addresses.token,
      abi: abis.token,
      functionName: 'balanceOf',
      args: [account],
    });
  },

  async tokenDecimals(bundle: ContractBundle) {
    return bundle.publicClient.readContract({
      address: bundle.addresses.token,
      abi: abis.token,
      functionName: 'decimals',
    });
  },

  async nextInvoiceId(bundle: ContractBundle) {
    return bundle.publicClient.readContract({
      address: bundle.addresses.escrow,
      abi: abis.escrow,
      functionName: 'nextInvoiceId',
    });
  },

  async invoice(bundle: ContractBundle, id: bigint) {
    return bundle.publicClient.readContract({
      address: bundle.addresses.escrow,
      abi: abis.escrow,
      functionName: 'getInvoice',
      args: [id],
    });
  },

  async milestones(bundle: ContractBundle, id: bigint) {
    return bundle.publicClient.readContract({
      address: bundle.addresses.escrow,
      abi: abis.escrow,
      functionName: 'getMilestones',
      args: [id],
    });
  },

  async reputation(bundle: ContractBundle, account: Address) {
    return bundle.publicClient.readContract({
      address: bundle.addresses.escrow,
      abi: abis.escrow,
      functionName: 'reputation',
      args: [account],
    }) as Promise<readonly [number, number, number]>;
  },

  async quote(bundle: ContractBundle, id: bigint): Promise<readonly [bigint, bigint, bigint]> {
    return bundle.publicClient.readContract({
      address: bundle.addresses.pool,
      abi: abis.pool,
      functionName: 'quote',
      args: [id],
    }) as Promise<readonly [bigint, bigint, bigint]>;
  },

  async poolState(bundle: ContractBundle): Promise<{
    totalAssets: bigint;
    totalSupply: bigint;
    deployed: bigint;
    outstandingFace: bigint;
  }> {
    const [totalAssets, totalSupply, deployed, outstandingFace] = await Promise.all([
      bundle.publicClient.readContract({
        address: bundle.addresses.pool,
        abi: abis.pool,
        functionName: 'totalAssets',
      }) as Promise<bigint>,
      bundle.publicClient.readContract({
        address: bundle.addresses.pool,
        abi: abis.pool,
        functionName: 'totalSupply',
      }) as Promise<bigint>,
      bundle.publicClient.readContract({
        address: bundle.addresses.pool,
        abi: abis.pool,
        functionName: 'deployed',
      }) as Promise<bigint>,
      bundle.publicClient.readContract({
        address: bundle.addresses.pool,
        abi: abis.pool,
        functionName: 'outstandingFace',
      }) as Promise<bigint>,
    ]);
    return { totalAssets, totalSupply, deployed, outstandingFace };
  },

  async sharePrice(bundle: ContractBundle): Promise<bigint> {
    return bundle.publicClient.readContract({
      address: bundle.addresses.pool,
      abi: abis.pool,
      functionName: 'convertToAssets',
      args: [10n ** 18n],
    }) as Promise<bigint>;
  },

  async sellerCredit(bundle: ContractBundle, seller: Address) {
    const [limit, exposure] = await Promise.all([
      bundle.publicClient.readContract({
        address: bundle.addresses.pool,
        abi: abis.pool,
        functionName: 'sellerCreditLimit',
        args: [seller],
      }),
      bundle.publicClient.readContract({
        address: bundle.addresses.pool,
        abi: abis.pool,
        functionName: 'sellerExposure',
        args: [seller],
      }),
    ]);
    return { limit, exposure };
  },
};

/**
 * Write requests. A public client cannot sign, so each helper returns a request object
 * that a component hands to wagmi's `useWriteContract` (or to a wallet client in a script).
 */
export type WriteRequest = {
  address: Address;
  abi: Abi;
  functionName: string;
  args: readonly unknown[];
};

export const writes = {
  approveToken: (bundle: ContractBundle, spender: Address, amount: bigint): WriteRequest => ({
    address: bundle.addresses.token,
    abi: abis.token,
    functionName: 'approve',
    args: [spender, amount],
  }),

  createInvoice: (
    bundle: ContractBundle,
    args: {
      buyer: Address;
      arbiter: Address;
      amounts: readonly bigint[];
      deadlines: readonly number[];
      docHash: `0x${string}`;
    },
  ): WriteRequest => ({
    address: bundle.addresses.escrow,
    abi: abis.escrow,
    functionName: 'createInvoice',
    args: [args.buyer, args.arbiter, args.amounts, args.deadlines, args.docHash],
  }),

  cancelInvoice: (bundle: ContractBundle, id: bigint): WriteRequest => ({
    address: bundle.addresses.escrow,
    abi: abis.escrow,
    functionName: 'cancelInvoice',
    args: [id],
  }),

  fund: (bundle: ContractBundle, id: bigint): WriteRequest => ({
    address: bundle.addresses.escrow,
    abi: abis.escrow,
    functionName: 'fund',
    args: [id],
  }),

  submitMilestone: (bundle: ContractBundle, id: bigint, index: bigint): WriteRequest => ({
    address: bundle.addresses.escrow,
    abi: abis.escrow,
    functionName: 'submitMilestone',
    args: [id, index],
  }),

  approveMilestone: (bundle: ContractBundle, id: bigint, index: bigint): WriteRequest => ({
    address: bundle.addresses.escrow,
    abi: abis.escrow,
    functionName: 'approveMilestone',
    args: [id, index],
  }),

  disputeMilestone: (bundle: ContractBundle, id: bigint, index: bigint): WriteRequest => ({
    address: bundle.addresses.escrow,
    abi: abis.escrow,
    functionName: 'disputeMilestone',
    args: [id, index],
  }),

  reclaimUnsubmitted: (bundle: ContractBundle, id: bigint, index: bigint): WriteRequest => ({
    address: bundle.addresses.escrow,
    abi: abis.escrow,
    functionName: 'reclaimUnsubmitted',
    args: [id, index],
  }),

  autoRelease: (bundle: ContractBundle, id: bigint, index: bigint): WriteRequest => ({
    address: bundle.addresses.escrow,
    abi: abis.escrow,
    functionName: 'autoRelease',
    args: [id, index],
  }),

  resolveDispute: (
    bundle: ContractBundle,
    id: bigint,
    index: bigint,
    sellerAmount: bigint,
  ): WriteRequest => ({
    address: bundle.addresses.escrow,
    abi: abis.escrow,
    functionName: 'resolveDispute',
    args: [id, index, sellerAmount],
  }),

  resolveExpiredDispute: (bundle: ContractBundle, id: bigint, index: bigint): WriteRequest => ({
    address: bundle.addresses.escrow,
    abi: abis.escrow,
    functionName: 'resolveExpiredDispute',
    args: [id, index],
  }),

  claimDeferred: (bundle: ContractBundle, to: Address): WriteRequest => ({
    address: bundle.addresses.escrow,
    abi: abis.escrow,
    functionName: 'claim',
    args: [to],
  }),

  approveReceivable: (bundle: ContractBundle, id: bigint): WriteRequest => ({
    address: bundle.addresses.escrow,
    abi: abis.escrow,
    functionName: 'approve',
    args: [bundle.addresses.pool, id],
  }),

  advance: (bundle: ContractBundle, id: bigint, minAdvance: bigint): WriteRequest => ({
    address: bundle.addresses.pool,
    abi: abis.pool,
    functionName: 'advance',
    args: [id, minAdvance],
  }),

  deposit: (bundle: ContractBundle, receiver: Address, assets: bigint): WriteRequest => ({
    address: bundle.addresses.pool,
    abi: abis.pool,
    functionName: 'deposit',
    args: [assets, receiver],
  }),

  withdraw: (bundle: ContractBundle, owner: Address, assets: bigint): WriteRequest => ({
    address: bundle.addresses.pool,
    abi: abis.pool,
    functionName: 'withdraw',
    args: [assets, owner, owner],
  }),

  pauseEscrow: (bundle: ContractBundle): WriteRequest => ({
    address: bundle.addresses.escrow,
    abi: abis.escrow,
    functionName: 'pause',
    args: [],
  }),

  unpauseEscrow: (bundle: ContractBundle): WriteRequest => ({
    address: bundle.addresses.escrow,
    abi: abis.escrow,
    functionName: 'unpause',
    args: [],
  }),

  pausePool: (bundle: ContractBundle): WriteRequest => ({
    address: bundle.addresses.pool,
    abi: abis.pool,
    functionName: 'pause',
    args: [],
  }),

  unpausePool: (bundle: ContractBundle): WriteRequest => ({
    address: bundle.addresses.pool,
    abi: abis.pool,
    functionName: 'unpause',
    args: [],
  }),

  setFee: (bundle: ContractBundle, feeBps: number, recipient: Address): WriteRequest => ({
    address: bundle.addresses.escrow,
    abi: abis.escrow,
    functionName: 'setFee',
    args: [feeBps, recipient],
  }),

  setParams: (
    bundle: ContractBundle,
    params: {
      baseAprBps: number;
      minDiscountBps: number;
      maxDiscountBps: number;
      newcomerPremiumBps: number;
      riskSlopeBps: number;
      utilizationCapBps: number;
      concentrationCapBps: number;
      minHistory: number;
      maxTenor: number;
    },
  ): WriteRequest => ({
    address: bundle.addresses.pool,
    abi: abis.pool,
    functionName: 'setParams',
    args: [params],
  }),

  sweepDeferred: (bundle: ContractBundle, to: Address): WriteRequest => ({
    address: bundle.addresses.pool,
    abi: abis.pool,
    functionName: 'sweepDeferred',
    args: [to],
  }),
};

/** Event topics for the activity feed: filter logs by topic0 over a block range, no indexer needed. */
export const events = {
  invoiceCreated: abis.escrow.find(
    (e) => e.type === 'event' && e.name === 'InvoiceCreated',
  ) as Abi[number],
  invoiceFunded: abis.escrow.find((e) => e.type === 'event' && e.name === 'InvoiceFunded') as Abi[number],
  milestoneSubmitted: abis.escrow.find(
    (e) => e.type === 'event' && e.name === 'MilestoneSubmitted',
  ) as Abi[number],
  milestoneDisputed: abis.escrow.find(
    (e) => e.type === 'event' && e.name === 'MilestoneDisputed',
  ) as Abi[number],
  milestoneSettled: abis.escrow.find(
    (e) => e.type === 'event' && e.name === 'MilestoneSettled',
  ) as Abi[number],
  payoutDeferred: abis.escrow.find((e) => e.type === 'event' && e.name === 'PayoutDeferred') as Abi[number],
  claimed: abis.escrow.find((e) => e.type === 'event' && e.name === 'Claimed') as Abi[number],
  advanced: abis.pool.find((e) => e.type === 'event' && e.name === 'Advanced') as Abi[number],
  advanceSettled: abis.pool.find(
    (e) => e.type === 'event' && e.name === 'AdvanceSettled',
  ) as Abi[number],
};

/** Local-only signing client, for the anvil rehearsal in `pnpm dev` demos. Never used with a real key. */
export function createLocalSigner(bundle: ContractBundle, privateKey: `0x${string}`) {
  const account = privateKeyToAccount(privateKey);
  const wallet = createWalletClient({ account, chain: bundle.chain, transport: http() });
  return { account, wallet };
}