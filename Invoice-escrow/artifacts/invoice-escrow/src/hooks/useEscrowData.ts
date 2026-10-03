import { useEffect, useMemo } from 'react';
import { useAccount, useChainId } from 'wagmi';
import { useQuery } from '@tanstack/react-query';
import type { Address } from 'viem';
import { getContracts, reads, type ContractBundle } from '../contract-adapter';
import { escrowAbi, poolAbi } from '../abis/index';

export function usePageTitle(title: string) {
  useEffect(() => {
    document.title = `${title} · Invoice escrow`;
  }, [title]);
}

export function useContracts(): { bundle: ContractBundle | null; ready: boolean } {
  const chainId = useChainId();
  const bundle = useMemo(() => getContracts(chainId), [chainId]);
  return { bundle, ready: !!bundle };
}

export function useAccountAddress(): Address | undefined {
  const { address } = useAccount();
  return address;
}

const query = {
  enabled: (bundle: ContractBundle | null) => !!bundle,
} as const;

export function useNextInvoiceId(bundle: ContractBundle | null) {
  return useQuery({
    queryKey: ['escrow', 'nextInvoiceId', bundle?.chain.id],
    queryFn: () => reads.nextInvoiceId(bundle as ContractBundle),
    ...query,
    enabled: !!bundle,
  });
}

export type InvoiceRow = {
  id: bigint;
  seller: Address;
  buyer: Address;
  arbiter: Address;
  status: number;
  total: bigint;
  remaining: bigint;
  openMilestones: number;
  openDisputes: number;
  feeBps: number;
  owner: Address | undefined;
  milestones: { amount: bigint; deadline: number; status: number }[];
  docHash?: string;
};

const STATUS = ['None', 'Created', 'Funded', 'Closed', 'Cancelled'] as const;
const MILESTONE = ['Pending', 'Submitted', 'Disputed', 'Settled'] as const;

export function useInvoice(bundle: ContractBundle | null, id: bigint | undefined) {
  return useQuery({
    queryKey: ['escrow', 'invoice', bundle?.chain.id, id?.toString()],
    enabled: !!bundle && id !== undefined,
    refetchInterval: 15_000,
    queryFn: async (): Promise<InvoiceRow | null> => {
      const b = bundle as ContractBundle;
      const invoice = (await reads.invoice(b, id as bigint)) as Record<string, unknown>;
      if (Number(invoice.status) === 0) return null;
      const milestones = (await reads.milestones(b, id as bigint)) as readonly {
        amount: bigint;
        deadline: number;
        status: number;
      }[];
      let owner: Address | undefined;
      try {
        owner = (await b.publicClient.readContract({
          address: b.addresses.escrow,
          abi: escrowAbi,
          functionName: 'ownerOf',
          args: [id as bigint],
        })) as Address;
      } catch {
        owner = undefined;
      }
      return {
        id: id as bigint,
        seller: invoice.seller as Address,
        buyer: invoice.buyer as Address,
        arbiter: invoice.arbiter as Address,
        status: Number(invoice.status),
        total: BigInt(invoice.total as bigint),
        remaining: BigInt(invoice.remaining as bigint),
        openMilestones: Number(invoice.openMilestones),
        openDisputes: Number(invoice.openDisputes),
        feeBps: Number(invoice.feeBps),
        owner,
        milestones: milestones.map((m) => ({ amount: m.amount, deadline: Number(m.deadline), status: Number(m.status) })),
        docHash: invoice.docHash as string | undefined,
      };
    },
  });
}

/** Enumerate invoices up to the current id and keep the ones this wallet can see or act on. */
export function useInvoices(bundle: ContractBundle | null, limit = 40) {
  const account = useAccountAddress();
  const nextId = useNextInvoiceId(bundle);

  return useQuery({
    queryKey: ['escrow', 'invoices', bundle?.chain.id, account, nextId.data?.toString()],
    enabled: !!bundle,
    queryFn: async (): Promise<InvoiceRow[]> => {
      const b = bundle as ContractBundle;
      const top = Number(nextId.data ?? 1n);
      const start = Math.max(1, top - limit);
      const ids = Array.from({ length: top - start }, (_, i) => BigInt(start + i)).reverse();
      const rows = await Promise.all(
        ids.map(async (id) => {
          try {
            const invoice = (await b.publicClient.readContract({
              address: b.addresses.escrow,
              abi: escrowAbi,
              functionName: 'getInvoice',
              args: [id],
            })) as Record<string, unknown>;
            if (Number(invoice.status) === 0) return null;
            const milestones = (await b.publicClient.readContract({
              address: b.addresses.escrow,
              abi: escrowAbi,
              functionName: 'getMilestones',
              args: [id],
            })) as readonly { amount: bigint; deadline: number; status: number }[];
            return {
              id,
              seller: invoice.seller as Address,
              buyer: invoice.buyer as Address,
              arbiter: invoice.arbiter as Address,
              status: Number(invoice.status),
              total: BigInt(invoice.total as bigint),
              remaining: BigInt(invoice.remaining as bigint),
              openMilestones: Number(invoice.openMilestones),
              openDisputes: Number(invoice.openDisputes),
              feeBps: Number(invoice.feeBps),
              owner: undefined,
              milestones: milestones.map((m) => ({
                amount: m.amount,
                deadline: Number(m.deadline),
                status: Number(m.status),
              })),
            } as InvoiceRow;
          } catch {
            return null;
          }
        }),
      );
      return rows.filter((r): r is InvoiceRow => r !== null);
    },
  });
}

export function useReputation(bundle: ContractBundle | null, address: Address | undefined) {
  return useQuery({
    queryKey: ['escrow', 'reputation', bundle?.chain.id, address],
    enabled: !!bundle && !!address,
    queryFn: async () => {
      const [clean, disputed, defaulted] = await reads.reputation(bundle as ContractBundle, address as Address);
      return { clean: Number(clean), disputed: Number(disputed), defaulted: Number(defaulted) };
    },
  });
}

export function usePoolState(bundle: ContractBundle | null) {
  const account = useAccountAddress();
  return useQuery({
    queryKey: ['pool', 'state', bundle?.chain.id, account],
    enabled: !!bundle,
    refetchInterval: 15_000,
    queryFn: async () => {
      const b = bundle as ContractBundle;
      const [state, sharePrice, params, maxWithdraw, idleCap, paused, escrowPaused, owner, balance] = await Promise.all([
        reads.poolState(b),
        reads.sharePrice(b),
        b.publicClient.readContract({ address: b.addresses.pool, abi: poolAbi, functionName: 'params' }) as Promise<PoolParams>,
        account
          ? (b.publicClient.readContract({ address: b.addresses.pool, abi: poolAbi, functionName: 'maxWithdraw', args: [account] }) as Promise<bigint>)
          : Promise.resolve(0n),
        b.publicClient.readContract({ address: b.addresses.pool, abi: poolAbi, functionName: '_idleCap' }) as Promise<bigint>,
        b.publicClient.readContract({ address: b.addresses.pool, abi: poolAbi, functionName: 'paused' }) as Promise<boolean>,
        b.publicClient.readContract({ address: b.addresses.escrow, abi: escrowAbi, functionName: 'paused' }) as Promise<boolean>,
        b.publicClient.readContract({ address: b.addresses.pool, abi: poolAbi, functionName: 'owner' }) as Promise<Address>,
        account
          ? (b.publicClient.readContract({ address: b.addresses.pool, abi: poolAbi, functionName: 'balanceOf', args: [account] }) as Promise<bigint>)
          : Promise.resolve(0n),
      ]);
      const p = params;
      const idle = state.totalAssets - state.deployed;
      return {
        ...state,
        sharePrice,
        idle,
        maxWithdraw,
        idleCap,
        paused,
        escrowPaused,
        owner,
        lpShares: balance,
        lpValue: (balance * sharePrice) / 10n ** 18n,
        utilizationBps: state.totalAssets === 0n ? 0 : Number((state.deployed * 10000n) / state.totalAssets),
        faceUtilizationBps: state.totalAssets === 0n ? 0 : Number((state.outstandingFace * 10000n) / state.totalAssets),
        params: {
          baseAprBps: p.baseAprBps,
          minDiscountBps: p.minDiscountBps,
          maxDiscountBps: p.maxDiscountBps,
          newcomerPremiumBps: p.newcomerPremiumBps,
          riskSlopeBps: p.riskSlopeBps,
          utilizationCapBps: p.utilizationCapBps,
          concentrationCapBps: p.concentrationCapBps,
          minHistory: p.minHistory,
          maxTenor: p.maxTenor,
        },
      };
    },
  });
}

export function useQuote(bundle: ContractBundle | null, id: bigint | undefined) {
  return useQuery({
    queryKey: ['pool', 'quote', bundle?.chain.id, id?.toString()],
    enabled: !!bundle && id !== undefined && id > 0n,
    queryFn: async () => {
      const q = (await reads.quote(bundle as ContractBundle, id as bigint)) as readonly bigint[];
      return { face: q[0], discountBps: q[1], advance: q[2] };
    },
    retry: false,
  });
}

type PoolParams = {
  baseAprBps: number;
  minDiscountBps: number;
  maxDiscountBps: number;
  newcomerPremiumBps: number;
  riskSlopeBps: number;
  utilizationCapBps: number;
  concentrationCapBps: number;
  minHistory: number;
  maxTenor: number;
};

export type ActivityEvent = {
  name: string;
  args: Record<string, unknown>;
  txHash: `0x${string}` | undefined;
  blockNumber: bigint | undefined;
  logIndex: number | undefined;
};

const EVENT_ABI = [
  {
    type: 'event',
    name: 'InvoiceCreated',
    inputs: [
      { indexed: true, name: 'id', type: 'uint256' },
      { indexed: true, name: 'seller', type: 'address' },
      { indexed: true, name: 'buyer', type: 'address' },
      { indexed: true, name: 'arbiter', type: 'address' },
      { indexed: false, name: 'total', type: 'uint256' },
      { indexed: false, name: 'docHash', type: 'bytes32' },
    ],
  },
  {
    type: 'event',
    name: 'InvoiceFunded',
    inputs: [
      { indexed: true, name: 'id', type: 'uint256' },
      { indexed: false, name: 'total', type: 'uint256' },
    ],
  },
  {
    type: 'event',
    name: 'MilestoneSubmitted',
    inputs: [
      { indexed: true, name: 'id', type: 'uint256' },
      { indexed: true, name: 'index', type: 'uint256' },
    ],
  },
  {
    type: 'event',
    name: 'MilestoneDisputed',
    inputs: [
      { indexed: true, name: 'id', type: 'uint256' },
      { indexed: true, name: 'index', type: 'uint256' },
    ],
  },
  {
    type: 'event',
    name: 'MilestoneSettled',
    inputs: [
      { indexed: true, name: 'id', type: 'uint256' },
      { indexed: true, name: 'index', type: 'uint256' },
      { indexed: false, name: 'outcome', type: 'uint8' },
      { indexed: false, name: 'payee', type: 'address' },
      { indexed: false, name: 'toPayee', type: 'uint256' },
      { indexed: false, name: 'fee', type: 'uint256' },
      { indexed: false, name: 'toBuyer', type: 'uint256' },
    ],
  },
  {
    type: 'event',
    name: 'PayoutDeferred',
    inputs: [
      { indexed: true, name: 'to', type: 'address' },
      { indexed: false, name: 'amount', type: 'uint256' },
    ],
  },
  {
    type: 'event',
    name: 'Claimed',
    inputs: [
      { indexed: true, name: 'account', type: 'address' },
      { indexed: true, name: 'to', type: 'address' },
      { indexed: false, name: 'amount', type: 'uint256' },
    ],
  },
  {
    type: 'event',
    name: 'Advanced',
    inputs: [
      { indexed: true, name: 'invoiceId', type: 'uint256' },
      { indexed: true, name: 'seller', type: 'address' },
      { indexed: true, name: 'recipient', type: 'address' },
      { indexed: false, name: 'face', type: 'uint256' },
      { indexed: false, name: 'advance', type: 'uint256' },
      { indexed: false, name: 'discountBps', type: 'uint256' },
    ],
  },
  {
    type: 'event',
    name: 'AdvanceSettled',
    inputs: [
      { indexed: true, name: 'invoiceId', type: 'uint256' },
      { indexed: false, name: 'face', type: 'uint256' },
      { indexed: false, name: 'costRetired', type: 'uint256' },
      { indexed: false, name: 'received', type: 'uint256' },
    ],
  },
] as const;

export function useActivity(bundle: ContractBundle | null, lookback = 30_000n) {
  return useQuery({
    queryKey: ['activity', bundle?.chain.id, bundle?.addresses.escrow, lookback.toString()],
    enabled: !!bundle,
    refetchInterval: 20_000,
    queryFn: async (): Promise<ActivityEvent[]> => {
      const b = bundle as ContractBundle;
      const latest = await b.publicClient.getBlockNumber();
      const from = latest > lookback ? latest - lookback : 0n;
      const [escrowLogs, poolLogs] = await Promise.all([
        b.publicClient.getContractEvents({
          address: b.addresses.escrow,
          abi: EVENT_ABI,
          fromBlock: from,
          toBlock: latest,
        }) as Promise<readonly { eventName?: string; args?: Record<string, unknown>; transactionHash?: `0x${string}`; blockNumber?: bigint; logIndex?: number }[]>,
        b.publicClient.getContractEvents({
          address: b.addresses.pool,
          abi: EVENT_ABI,
          fromBlock: from,
          toBlock: latest,
        }) as Promise<readonly { eventName?: string; args?: Record<string, unknown>; transactionHash?: `0x${string}`; blockNumber?: bigint; logIndex?: number }[]>,
      ]);
      return [...escrowLogs, ...poolLogs]
        .map((log) => ({
          name: log.eventName ?? 'Unknown',
          args: (log.args ?? {}) as Record<string, unknown>,
          txHash: log.transactionHash,
          blockNumber: log.blockNumber,
          logIndex: log.logIndex,
        }))
        .sort((a, b) =>
          a.blockNumber === b.blockNumber
            ? (b.logIndex ?? 0) - (a.logIndex ?? 0)
            : Number((b.blockNumber ?? 0n) - (a.blockNumber ?? 0n)),
        );
    },
    retry: false,
  });
}

export { STATUS, MILESTONE };