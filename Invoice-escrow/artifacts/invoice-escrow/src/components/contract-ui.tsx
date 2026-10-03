import type { ReactNode } from 'react';
import { useEffect, useState } from 'react';
import { useAccount, useWaitForTransactionReceipt, useWriteContract } from 'wagmi';
import { getContractErrorMessage } from '../lib/contract-errors';
import type { ContractBundle, WriteRequest } from '../contract-adapter';

const U = 1_000_000n;

export function usd(value: bigint | undefined, digits = 2): string {
  if (value === undefined) return '—';
  const whole = value / U;
  const frac = (value % U).toString().padStart(6, '0').slice(0, digits);
  return `${whole.toLocaleString('en-US')}.${frac}`;
}

export function pct(bps: number | bigint, digits = 2): string {
  const value = Number(bps) / 100;
  return `${value.toFixed(digits)}%`;
}

export function short(address: string | undefined): string {
  if (!address) return '—';
  return `${address.slice(0, 6)}…${address.slice(-4)}`;
}

export function toUnits(value: string, decimals = 6): bigint {
  if (!value.trim()) return 0n;
  const [whole, frac = ''] = value.trim().split('.');
  return BigInt(whole || '0') * 10n ** BigInt(decimals) + BigInt((frac + '0'.repeat(decimals)).slice(0, decimals) || '0');
}

export function fromUnits(value: bigint | undefined, decimals = 6): string {
  if (value === undefined) return '';
  const whole = value / 10n ** BigInt(decimals);
  const frac = (value % 10n ** BigInt(decimals)).toString().padStart(decimals, '0').replace(/0+$/, '');
  return frac ? `${whole}.${frac}` : `${whole}`;
}

export function useNow(intervalMs = 15_000): number {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), intervalMs);
    return () => clearInterval(id);
  }, [intervalMs]);
  return now;
}

/** Submit a write request through the connected wallet, with decoded revert messages. */
export function useContractWrite() {
  const { writeContractAsync, data: hash } = useWriteContract();
  const { isLoading: isPending, isSuccess } = useWaitForTransactionReceipt({ hash });
  const [error, setError] = useState<string | null>(null);

  async function submit(request: WriteRequest | undefined) {
    if (!request) return;
    setError(null);
    try {
      await writeContractAsync({
        address: request.address,
        abi: request.abi,
        functionName: request.functionName,
        args: request.args as never,
      });
    } catch (err) {
      setError(getContractErrorMessage(err));
    }
  }

  return { submit, hash, isPending: isPending || (!!hash && !isSuccess), error, clearError: () => setError(null) };
}

export function WriteButton({
  bundle,
  request,
  children,
  testId,
  variant = 'primary',
  disabled,
}: {
  bundle: ContractBundle | null;
  request: WriteRequest | undefined;
  children: ReactNode;
  testId: string;
  variant?: 'primary' | 'secondary';
  disabled?: boolean;
}) {
  const { address } = useAccount();
  const { submit, isPending, error } = useContractWrite();
  const className = variant === 'primary' ? 'button-primary' : 'button-secondary';
  const noWallet = !address;
  const noDeployment = !bundle;

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
      <button
        className={className}
        data-testid={testId}
        disabled={disabled || noWallet || noDeployment || isPending}
        title={noWallet ? 'Connect a wallet first' : noDeployment ? 'Unsupported network' : undefined}
        onClick={() => submit(request)}
      >
        {isPending ? 'Confirming…' : children}
      </button>
      {error && (
        <span className="form-footnote" style={{ color: '#b45309' }} data-testid={`${testId}-error`}>
          {error}
        </span>
      )}
    </div>
  );
}

export function TxLink({ txHash }: { txHash: `0x${string}` | undefined }) {
  if (!txHash) return <span>—</span>;
  return (
    <a href={`https://sepolia-rollup.arbitrum.io/tx/${txHash}`} target="_blank" rel="noreferrer">
      {txHash.slice(0, 10)}…
    </a>
  );
}

export function Metric({ label, value, hint }: { label: string; value: ReactNode; hint?: string }) {
  return (
    <div data-testid={`metric-${label.toLowerCase().replaceAll(' ', '-')}`}>
      <label>{label}</label>
      <strong>{value}</strong>
      {hint && <small style={{ display: 'block', opacity: 0.6 }}>{hint}</small>}
    </div>
  );
}

export function Loading({ label = 'Reading the contracts…' }: { label?: string }) {
  return (
    <section className="panel empty-state" data-testid="state-loading">
      <p>{label}</p>
    </section>
  );
}

export function ErrorNote({ error }: { error: unknown }) {
  if (!error) return null;
  return (
    <div className="notice-bar" data-testid="notice-read-error">
      {error instanceof Error ? error.message : String(error)}
    </div>
  );
}