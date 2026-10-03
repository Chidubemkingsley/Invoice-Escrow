import { useEffect, useMemo, useState } from 'react';
import { useAccount } from 'wagmi';
import {
  Activity as ActivityIcon,
  ArrowLeftRight,
  BadgeCheck,
  BriefcaseBusiness,
  CircleDollarSign,
  Clock3,
  FileCheck2,
  FilePlus2,
  Gavel,
  Landmark,
  LockKeyhole,
  TrendingUp,
} from 'lucide-react';
import { Link } from 'wouter';
import { poolAbi as advancePoolAbi } from '../abis/index';
import { reads, writes } from '../contract-adapter';
import {
  MILESTONE,
  STATUS,
  useAccountAddress,
  useActivity,
  useContracts,
  useInvoice,
  useInvoices,
  useNextInvoiceId,
  usePageTitle,
  usePoolState,
  useQuote,
  useReputation,
  type ActivityEvent,
  type InvoiceRow,
} from '../hooks/useEscrowData';
import {
  AddressLink,
  ErrorNote,
  explorerTxUrl,
  fromUnits,
  Loading,
  Metric,
  pct,
  short,
  toUnits,
  until,
  useNow,
  usd,
  WriteButton,
  TxLink,
} from '../components/contract-ui';

type PageShellProps = { children: React.ReactNode; route: string; action?: React.ReactNode };
export function PageShell({ children, route, action }: PageShellProps) {
  return (
    <div className="workspace">
      <PageHeading route={route} action={action} />
      {children}
    </div>
  );
}

const headings: Record<string, { eyebrow: string; title: string; subtitle: string }> = {
  '/': { eyebrow: 'Protocol overview', title: 'A clearer way to get paid.', subtitle: 'Live figures read from the verified testnet deployment.' },
  '/dashboard': { eyebrow: 'Your workspace', title: 'The work in front of you.', subtitle: 'Invoices where you are the seller, the buyer or the arbiter.' },
  '/create': { eyebrow: 'New receivable', title: 'Create an invoice.', subtitle: 'Set the parties, document hash and milestone schedule before funding.' },
  '/market': { eyebrow: 'Seller liquidity', title: 'Explore an early settlement.', subtitle: 'Live quotes against invoice face value, from the pool contract.' },
  '/pool': { eyebrow: 'Capital allocation', title: 'Liquidity, deployed with care.', subtitle: 'Idle capital, deployed advances, share price and withdrawal limits.' },
  '/arbiter': { eyebrow: 'Independent resolution', title: 'Resolve with evidence.', subtitle: 'Disputes assigned to the connected address, with the split under your control.' },
  '/reputation': { eyebrow: 'Counterparty history', title: 'Trust, earned over time.', subtitle: 'Counters read from the escrow contract, not from an off-chain score.' },
  '/admin': { eyebrow: 'Protocol operations', title: 'Deployment controls.', subtitle: 'Owner-only controls for the configured contracts.' },
  '/activity': { eyebrow: 'Protocol record', title: 'Recent activity.', subtitle: 'Events decoded from escrow and pool logs.' },
  '/invoice': { eyebrow: 'Invoice detail', title: 'Invoice.', subtitle: 'Milestones, payouts and the actions available to your role.' },
};

function PageHeading({ route, action }: { route: string; action?: React.ReactNode }) {
  const config = headings[route] ?? headings['/'];
  return (
    <div className="page-head">
      <div>
        <div className="eyebrow">{config.eyebrow}</div>
        <h1 className="page-title" data-testid="text-page-title">
          {config.title}
        </h1>
        <p className="page-subtitle">{config.subtitle}</p>
      </div>
      {action && <div className="page-head-actions">{action}</div>}
    </div>
  );
}

function statusChip(row: InvoiceRow) {
  if (row.status === 2) return row.openDisputes > 0 ? 'Disputed' : 'Funded';
  return STATUS[row.status] ?? 'Unknown';
}

function nextAction(row: InvoiceRow, account: string | undefined): string {
  if (row.status === 1) return 'Awaiting buyer funding';
  if (row.status !== 2) return '—';
  const pending = row.milestones.find((m) => m.status === 0);
  const submitted = row.milestones.find((m) => m.status === 1);
  const disputed = row.milestones.find((m) => m.status === 2);
  if (disputed) return 'Arbiter ruling required';
  if (submitted) return row.buyer === account ? 'Approve or dispute' : 'Auto-release available';
  if (pending) return row.seller === account ? 'Submit milestone' : 'Delivery pending';
  return '—';
}

/* ------------------------------------------------------------------ overview */

export function OverviewPage() {
  usePageTitle('Overview');
  const { bundle } = useContracts();
  const pool = usePoolState(bundle);
  const invoices = useInvoices(bundle);
  const activity = useActivity(bundle);

  const totals = useMemo(() => {
    const rows = invoices.data ?? [];
    return {
      count: rows.length,
      escrowed: rows.reduce((sum, r) => sum + (r.status === 2 ? r.remaining : 0n), 0n),
      funded: rows.filter((r) => r.status === 2).length,
      disputed: rows.filter((r) => r.openDisputes > 0).length,
    };
  }, [invoices.data]);

  return (
    <PageShell route="/">
      <section className="hero-panel" data-testid="panel-overview">
        <div>
          <div className="hero-index">INVOICE ESCROW / {bundle?.chain.name ?? 'unsupported network'}</div>
          <h2>
            Commercial trust,
            <br />
            made programmable.
          </h2>
          <p>Milestone settlement, receivables finance and a shared record.</p>
        </div>
        <div className="hero-metric">
          <strong>POOL SHARE PRICE</strong>
          <span>{pool.data ? `${fromUnits(pool.data.sharePrice, 18)} USDG` : '—'}</span>
        </div>
      </section>
      <div className="stat-strip">
        <Metric label="Escrowed" value={usd(totals.escrowed)} hint={`${totals.funded} funded invoices`} />
        <Metric label="Invoices" value={totals.count} hint={`${totals.disputed} in dispute`} />
        <Metric label="Pool assets" value={usd(pool.data?.totalAssets)} hint={`idle ${usd(pool.data?.idle)}`} />
        <Metric label="Utilization" value={pool.data ? pct(pool.data.utilizationBps) : '—'} hint={pool.data ? `face ${pct(pool.data.faceUtilizationBps)}` : undefined} />
      </div>
      <ErrorNote error={invoices.error ?? pool.error} />
      <div className="section-heading">
        <h2>Protocol activity</h2>
        <span>LIVE EVENTS</span>
      </div>
      <EventTable events={activity.data ?? []} loading={activity.isLoading} bundle={bundle} />
    </PageShell>
  );
}

/* ----------------------------------------------------------------- dashboard */

export function DashboardPage() {
  usePageTitle('My dashboard');
  const { bundle } = useContracts();
  const account = useAccountAddress();
  const invoices = useInvoices(bundle);

  const rows = useMemo(() => {
    const all = invoices.data ?? [];
    if (!account) return [];
    return all.filter((r) => r.seller === account || r.buyer === account || r.arbiter === account);
  }, [invoices.data, account]);

  const role = useMemo(() => {
    if (!account) return 'Connect a wallet';
    const all = invoices.data ?? [];
    if (all.some((r) => r.seller === account)) return 'Seller';
    if (all.some((r) => r.buyer === account)) return 'Buyer';
    if (all.some((r) => r.arbiter === account)) return 'Arbiter';
    return 'No role yet';
  }, [invoices.data, account]);

  return (
    <PageShell
      route="/dashboard"
      action={
        <Link href="/create" className="button-primary" data-testid="button-dashboard-create">
          <FilePlus2 size={14} /> New invoice
        </Link>
      }
    >
      {!account && <div className="notice-bar" data-testid="notice-dashboard-connect">Connect a wallet to see the invoices where you are the seller, buyer or arbiter.</div>}
      <div className="stat-strip">
        <Metric label="Your invoices" value={rows.length} hint={`role: ${role}`} />
        <Metric label="Needs your action" value={rows.filter((r) => nextAction(r, account) !== '—' && r.openMilestones > 0).length} />
        <Metric label="Funded value" value={usd(rows.reduce((s, r) => s + r.remaining, 0n))} />
        <Metric label="In dispute" value={rows.filter((r) => r.openDisputes > 0).length} />
      </div>
      {invoices.isLoading && <Loading />}
      <div className="section-heading">
        <h2>My invoices & actions</h2>
        <span>BY WALLET ROLE</span>
      </div>
      <div className="table-row header">
        <span>INVOICE</span>
        <span>COUNTERPARTY</span>
        <span>NEXT ACTION</span>
        <span>STATUS</span>
      </div>
      {rows.length === 0 && !invoices.isLoading && (
        <section className="panel empty-state" data-testid="state-empty-records">
          <div className="empty-icon">
            <BriefcaseBusiness size={17} />
          </div>
          <h3>Nothing for this wallet yet</h3>
          <p>Create an invoice, or fund one where you are the buyer.</p>
        </section>
      )}
      {rows.map((row) => (
        <Link key={row.id.toString()} href={`/invoice/${row.id}`} className="table-row" data-testid={`row-invoice-${row.id}`}>
          <span>
            #{row.id.toString()} · {usd(row.total)} USDG
          </span>
          <span>{short(row.seller === account ? row.buyer : row.seller)}</span>
          <span>{nextAction(row, account)}</span>
          <span>{statusChip(row)}</span>
        </Link>
      ))}
    </PageShell>
  );
}

/* -------------------------------------------------------------------- create */

export function CreatePage() {
  usePageTitle('New invoice');
  const { bundle } = useContracts();
  const account = useAccountAddress();
  const [buyer, setBuyer] = useState('');
  const [arbiter, setArbiter] = useState('');
  const [docHash, setDocHash] = useState('');
  const [rows, setRows] = useState([{ amount: '', deadline: '' }, { amount: '', deadline: '' }]);

  const valid =
    !!bundle &&
    !!account &&
    /^0x[a-fA-F0-9]{40}$/.test(buyer) &&
    /^0x[a-fA-F0-9]{40}$/.test(arbiter) &&
    buyer.toLowerCase() !== account.toLowerCase() &&
    arbiter.toLowerCase() !== buyer.toLowerCase() &&
    /^0x[a-fA-F0-9]{64}$/.test(docHash) &&
    rows.length > 0 &&
    rows.length <= 12 &&
    rows.every((r) => Number(r.amount) > 0 && r.deadline !== '');

  const total = rows.reduce((sum, r) => sum + toUnits(r.amount || '0'), 0n);

  const request =
    valid && bundle
      ? writes.createInvoice(bundle, {
          buyer: buyer as `0x${string}`,
          arbiter: arbiter as `0x${string}`,
          amounts: rows.map((r) => toUnits(r.amount)),
          deadlines: rows.map((r) => Math.floor(new Date(r.deadline).getTime() / 1000)),
          docHash: docHash as `0x${string}`,
        })
      : undefined;

  return (
    <PageShell
      route="/create"
      action={
        <WriteButton bundle={bundle} request={request} testId="button-submit-invoice">
          <FileCheck2 size={14} /> Create invoice
        </WriteButton>
      }
    >
      <div className="split-layout">
        <section className="form-panel">
          <div className="section-heading" style={{ marginTop: 0 }}>
            <h2>Invoice terms</h2>
            <span>ALL FIELDS REQUIRED</span>
          </div>
          <div className="field-grid">
            <div className="form-field">
              <label htmlFor="create-buyer">Buyer address</label>
              <input id="create-buyer" value={buyer} onChange={(e) => setBuyer(e.target.value)} placeholder="0x…" data-testid="input-buyer-address" />
            </div>
            <div className="form-field">
              <label htmlFor="create-arbiter">Arbiter address</label>
              <input id="create-arbiter" value={arbiter} onChange={(e) => setArbiter(e.target.value)} placeholder="0x…" data-testid="input-arbiter-address" />
            </div>
            <div className="form-field wide">
              <label htmlFor="create-doc">Invoice document hash (keccak/bytes32)</label>
              <input id="create-doc" value={docHash} onChange={(e) => setDocHash(e.target.value)} placeholder="0x…" data-testid="input-invoice-document-hash" />
            </div>
          </div>
          <div className="section-heading">
            <h2>Milestones</h2>
            <span>UP TO 12 · SEQUENTIAL</span>
          </div>
          {rows.map((row, i) => (
            <div className="field-grid" key={i}>
              <div className="form-field">
                <label htmlFor={`amount-${i}`}>Amount {i + 1} (USDG)</label>
                <input id={`amount-${i}`} value={row.amount} onChange={(e) => setRows((r) => r.map((x, j) => (j === i ? { ...x, amount: e.target.value } : x)))} placeholder="3000" data-testid={`input-milestone-amount-${i}`} />
              </div>
              <div className="form-field">
                <label htmlFor={`deadline-${i}`}>Deadline {i + 1}</label>
                <input id={`deadline-${i}`} type="datetime-local" value={row.deadline} onChange={(e) => setRows((r) => r.map((x, j) => (j === i ? { ...x, deadline: e.target.value } : x)))} data-testid={`input-milestone-deadline-${i}`} />
              </div>
            </div>
          ))}
          <div style={{ display: 'flex', gap: 8 }}>
            <button className="button-secondary" onClick={() => setRows((r) => (r.length < 12 ? [...r, { amount: '', deadline: '' }] : r))} data-testid="button-add-milestone">
              Add milestone
            </button>
            <button className="button-secondary" onClick={() => setRows((r) => (r.length > 1 ? r.slice(0, -1) : r))} data-testid="button-remove-milestone">
              Remove last
            </button>
          </div>
          <p className="form-footnote">
            Milestones settle in order. A submission after its deadline plus the 3-day grace is rejected on-chain, and the buyer can reclaim an
            undelivered milestone after the same window.
          </p>
        </section>
        <section className="form-panel">
          <div className="section-heading" style={{ marginTop: 0 }}>
            <h2>Settlement preview</h2>
            <span>FROM THE ESCROW</span>
          </div>
          <div className="stat-strip">
            <Metric label="Total" value={`${usd(total)} USDG`} />
            <Metric label="Milestones" value={rows.length} />
            <Metric label="Review window" value="7 days" hint="auto-release after" />
            <Metric label="Delivery grace" value="3 days" hint="refund after" />
          </div>
          <p className="form-footnote">
            The buyer funds the full total on-chain. Whoever holds the invoice ERC-721 receives settlement, so selling the NFT sells the right to be
            paid.
          </p>
          <div style={{ marginTop: 24 }}>
            <WriteButton bundle={bundle} request={request} testId="button-submit-invoice-secondary">
              Create invoice
            </WriteButton>
          </div>
        </section>
      </div>
    </PageShell>
  );
}

/* -------------------------------------------------------------------- market */

export function MarketPage() {
  usePageTitle('Receivables market');
  const { bundle } = useContracts();
  const account = useAccountAddress();
  const invoices = useInvoices(bundle);
  const candidates = useMemo(
    () => (invoices.data ?? []).filter((r) => r.status === 2 && r.openDisputes === 0 && r.remaining > 0n),
    [invoices.data],
  );
  const [selected, setSelected] = useState<bigint | undefined>(undefined);
  const [onlyMine, setOnlyMine] = useState(false);
  const [slippageBps, setSlippageBps] = useState(50); // 0.50%
  const now = useNow();
  const quote = useQuote(bundle, selected);
  const shown = onlyMine && account ? candidates.filter((r) => r.seller === account) : candidates;
  const minAdvance =
    selected && bundle && quote.data ? (quote.data.advance * BigInt(10_000 - slippageBps)) / 10_000n : undefined;
  const approveRequest = selected && bundle ? writes.approveReceivable(bundle, selected) : undefined;
  const advanceRequest = selected && bundle && minAdvance !== undefined ? writes.advance(bundle, selected, minAdvance) : undefined;

  return (
    <PageShell route="/market">
      <div className="notice-bar" data-testid="notice-market-data">
        Quotes come from <code>AdvancePool.quote(id)</code>. Delinquent invoices and invoices above the risk ceiling are refused on-chain.
      </div>
      <div className="stat-strip">
        <Metric label="Eligible receivables" value={shown.length} hint={onlyMine ? 'your invoices only' : undefined} />
        <Metric label="Selected face" value={usd(quote.data?.face)} />
        <Metric label="Discount" value={quote.data ? pct(quote.data.discountBps) : '—'} />
        <Metric label="Advance" value={quote.data ? `${usd(quote.data.advance)} USDG` : '—'} />
      </div>
      {invoices.isLoading && <Loading label="Loading funded invoices…" />}
      <div className="section-heading">
        <h2>Receivables eligible for a quote</h2>
        <span>SELLER VIEW</span>
      </div>
      <div className="table-row header">
        <span>INVOICE</span>
        <span>FACE VALUE</span>
        <span>DISCOUNT</span>
        <span>ADVANCE</span>
      </div>
      <div style={{ display: 'flex', gap: 8, marginBottom: 10, flexWrap: 'wrap' }}>
        <button className={`button-secondary ${onlyMine ? 'active' : ''}`} onClick={() => setOnlyMine(!onlyMine)} data-testid="filter-market-mine">
          My receivables only
        </button>
      </div>
      {shown.length === 0 && !invoices.isLoading && (
        <section className="panel empty-state" data-testid="state-empty-records">
          <div className="empty-icon">
            <ArrowLeftRight size={17} />
          </div>
          <h3>No funded receivables</h3>
          <p>Fund an invoice first; the pool only buys funded, undisputed invoices.</p>
        </section>
      )}
      {shown.map((row) => (
        <button
          key={row.id.toString()}
          className={`table-row ${selected === row.id ? 'active' : ''}`}
          data-testid={`row-quote-${row.id}`}
          onClick={() => setSelected(row.id)}
          style={{ width: '100%', textAlign: 'left' }}
        >
          <span>
            #{row.id.toString()} · seller {short(row.seller)}
            {row.seller === account ? ' (you)' : ''}
          </span>
          <span>{usd(row.remaining)} USDG</span>
          <span>{selected === row.id && quote.data ? pct(quote.data.discountBps) : '—'}</span>
          <span>
            {selected === row.id && quote.data ? (
              `${usd(quote.data.advance)} USDG`
            ) : (
              <span style={{ opacity: 0.7 }}>due {until(row.milestones[0]?.deadline ?? 0, now)}</span>
            )}
          </span>
        </button>
      ))}
      {selected !== undefined && (
        <section className="panel" style={{ marginTop: 18 }} data-testid="panel-advance-actions">
          <div className="section-heading" style={{ marginTop: 0 }}>
            <h2>Sell invoice #{selected.toString()}</h2>
            <span>TWO TRANSACTIONS</span>
          </div>
          {quote.error ? (
            <p className="form-footnote" style={{ color: '#b45309' }}>
              The pool will not buy this receivable: {(quote.error as Error).message.split('\n')[0]}
            </p>
          ) : (
            <>
              <div className="stat-strip">
                <Metric label="Face" value={`${usd(quote.data?.face)} USDG`} />
                <Metric label="Discount" value={quote.data ? pct(quote.data.discountBps) : '—'} />
                <Metric label="You receive" value={quote.data ? `${usd(quote.data.advance)} USDG` : '—'} />
                <Metric label="Slippage guard" value={`${(slippageBps / 100).toFixed(2)}%`} hint={`min ${usd(minAdvance)} USDG`} />
              </div>
              <div className="field-grid" style={{ marginTop: 12 }}>
                <div className="form-field">
                  <label htmlFor="slippage-bps">Slippage tolerance (bps)</label>
                  <input
                    id="slippage-bps"
                    value={slippageBps}
                    onChange={(e) => setSlippageBps(Math.max(0, Math.min(2000, Number(e.target.value) || 0)))}
                    data-testid="input-slippage-bps"
                  />
                </div>
              </div>
              <div style={{ display: 'flex', gap: 10, marginTop: 12, flexWrap: 'wrap' }}>
                <WriteButton bundle={bundle} request={approveRequest} testId="button-approve-pool" variant="secondary">
                  1 · Approve pool
                </WriteButton>
                <WriteButton bundle={bundle} request={advanceRequest} testId="button-advance">
                  2 · Advance now
                </WriteButton>
              </div>
            </>
          )}
        </section>
      )}
    </PageShell>
  );
}

/* ---------------------------------------------------------------------- pool */

export function PoolPage() {
  usePageTitle('Liquidity pool');
  const { bundle } = useContracts();
  const account = useAccountAddress();
  const pool = usePoolState(bundle);
  const [amount, setAmount] = useState('');

  const depositRequest = bundle && Number(amount) > 0 ? writes.deposit(bundle, account as `0x${string}`, toUnits(amount)) : undefined;
  const withdrawRequest = bundle && Number(amount) > 0 ? writes.withdraw(bundle, account as `0x${string}`, toUnits(amount)) : undefined;

  return (
    <PageShell
      route="/pool"
      action={
        <>
          <Link href="/pool" className="button-secondary" data-testid="button-pool-refresh">
            Refresh
          </Link>
        </>
      }
    >
      {pool.isLoading && <Loading />}
      <div className="stat-strip">
        <Metric label="Total assets" value={`${usd(pool.data?.totalAssets)} USDG`} hint="cash + deferred + carrying value" />
        <Metric label="Idle assets" value={`${usd(pool.data?.idle)} USDG`} hint={`withdrawable ${usd(pool.data?.idleCap)}`} />
        <Metric label="Deployed" value={`${usd(pool.data?.deployed)} USDG`} hint={pool.data ? `cost basis ${pct(pool.data.utilizationBps)}` : undefined} />
        <Metric label="Face outstanding" value={`${usd(pool.data?.outstandingFace)} USDG`} hint={pool.data ? `${pct(pool.data.faceUtilizationBps)} of NAV` : undefined} />
      </div>
      <div className="split-layout">
        <section>
          <div className="section-heading" style={{ marginTop: 0 }}>
            <h2>Pool position</h2>
            <span>SHARE PRICE · {pool.data ? `${fromUnits(pool.data.sharePrice, 18)} USDG` : '—'}</span>
          </div>
          <div className="panel" style={{ display: 'grid', gap: 10 }}>
            <div className="status-line">
              <i /> Your shares: {pool.data ? pool.data.lpShares.toString() : '—'} · value {usd(pool.data?.lpValue)} USDG
            </div>
            <div className="status-line">
              <i /> Max withdraw: {usd(pool.data?.maxWithdraw)} USDG
            </div>
            {pool.data?.paused && <div className="notice-bar">Pool is paused: new deposits and advances are closed, withdrawals stay open.</div>}
            <div className="field-grid">
              <div className="form-field">
                <label htmlFor="pool-amount">Amount (USDG)</label>
                <input id="pool-amount" value={amount} onChange={(e) => setAmount(e.target.value)} placeholder="100" data-testid="input-pool-amount" />
              </div>
            </div>
            <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
              <button className="button-secondary" onClick={() => setAmount(fromUnits(pool.data?.maxWithdraw))} data-testid="button-max-withdraw">
                Max withdraw
              </button>
            </div>
            <div style={{ display: 'flex', gap: 10, flexWrap: 'wrap' }}>
              <WriteButton bundle={bundle} request={depositRequest} testId="button-deposit">
                Deposit
              </WriteButton>
              <WriteButton bundle={bundle} request={withdrawRequest} testId="button-withdraw" variant="secondary" disabled={!!pool.data && pool.data.maxWithdraw === 0n}>
                Withdraw
              </WriteButton>
            </div>
            <p className="form-footnote">
              Deposits and advances can be paused by the operator; withdrawals and settlement cannot. Parameters are read live from the contract.
            </p>
          </div>
          {pool.data && (
            <div className="stat-strip" style={{ marginTop: 14 }}>
              <Metric label="Base APR" value={pct(pool.data.params.baseAprBps)} />
              <Metric label="Discount band" value={`${pct(pool.data.params.minDiscountBps)} – ${pct(pool.data.params.maxDiscountBps)}`} />
              <Metric label="Utilisation cap" value={pct(pool.data.params.utilizationCapBps)} hint="of face" />
              <Metric label="Concentration cap" value={pct(pool.data.params.concentrationCapBps)} />
            </div>
          )}
        </section>
        <section>
          <div className="section-heading" style={{ marginTop: 0 }}>
            <h2>Risk parameters</h2>
            <span>SET BY THE POOL OPERATOR</span>
          </div>
          {pool.data ? (
            <div className="panel" style={{ display: 'grid', gap: 8 }}>
              <div className="status-line">
                <i /> Newcomer premium {pct(pool.data.params.newcomerPremiumBps)} until {pool.data.params.minHistory} settled events
              </div>
              <div className="status-line">
                <i /> Defaults weigh 3× disputes in the premium
              </div>
              <div className="status-line">
                <i /> Max tenor {Math.round(pool.data.params.maxTenor / 86400)} days
              </div>
              <div className="status-line">
                <i /> Pool owner {short(pool.data.owner)}
              </div>
            </div>
          ) : (
            <section className="panel empty-state">
              <div className="empty-icon">
                <Landmark size={17} />
              </div>
              <h3>Pool metrics unavailable</h3>
              <p>Connect to a configured network.</p>
            </section>
          )}
        </section>
      </div>
    </PageShell>
  );
}

/* ------------------------------------------------------------------- arbiter */

export function ArbiterPage() {
  usePageTitle('Disputes');
  const { bundle } = useContracts();
  const account = useAccountAddress();
  const invoices = useInvoices(bundle);
  const now = useNow();

  const cases = useMemo(() => {
    const rows = invoices.data ?? [];
    return rows.flatMap((row) =>
      row.milestones
        .map((m, index) => ({ row, m, index }))
        .filter(({ m }) => m.status === 2)
        .map(({ row, m, index }) => ({
          id: row.id,
          index,
          amount: m.amount,
          deadline: m.deadline,
          mine: row.arbiter === account,
          expired: now / 1000 > m.deadline + 14 * 86400,
          seller: row.seller,
          buyer: row.buyer,
        })),
    );
  }, [invoices.data, account, now]);

  const mine = cases.filter((c) => c.mine);

  return (
    <PageShell route="/arbiter">
      <div className="notice-bar">
        After 14 days without a ruling, anyone can force an even 50/50 split through <code>resolveExpiredDispute</code>.
      </div>
      <div className="stat-strip">
        <Metric label="Assigned disputes" value={mine.length} />
        <Metric label="All open disputes" value={cases.length} />
        <Metric label="Response window" value="14 days" />
        <Metric label="Forced split" value="50 / 50" />
      </div>
      <div className="section-heading">
        <h2>Assigned cases</h2>
        <span>ARBITER VIEW</span>
      </div>
      <div className="table-row header">
        <span>INVOICE</span>
        <span>AMOUNT</span>
        <span>PARTIES</span>
        <span>ACTION</span>
      </div>
      {cases.length === 0 && !invoices.isLoading && (
        <section className="panel empty-state" data-testid="state-empty-records">
          <div className="empty-icon">
            <Gavel size={17} />
          </div>
          <h3>No open disputes</h3>
          <p>Nothing is waiting on an arbiter on this deployment.</p>
        </section>
      )}
      {cases.map((c) => (
        <ArbiterCase key={`${c.id}-${c.index}`} bundle={bundle} dispute={c} />
      ))}
    </PageShell>
  );
}

function ArbiterCase({
  bundle,
  dispute,
}: {
  bundle: ReturnType<typeof useContracts>['bundle'];
  dispute: { id: bigint; index: number; amount: bigint; mine: boolean };
}) {
  const [sellerAmount, setSellerAmount] = useState('');
  const resolve =
    bundle && dispute.mine && sellerAmount !== ''
      ? writes.resolveDispute(bundle, dispute.id, BigInt(dispute.index), toUnits(sellerAmount))
      : undefined;
  const force = bundle ? writes.resolveExpiredDispute(bundle, dispute.id, BigInt(dispute.index)) : undefined;

  return (
    <div className="panel" style={{ display: 'grid', gap: 10 }} data-testid={`panel-dispute-${dispute.id}-${dispute.index}`}>
      <div className="table-row header">
        <span>INVOICE #{dispute.id.toString()}</span>
        <span>{usd(dispute.amount)} USDG</span>
        <span>milestone {dispute.index}</span>
        <span>{dispute.mine ? 'assigned to you' : 'other arbiter'}</span>
      </div>
      {dispute.mine ? (
        <>
          <div className="field-grid">
            <div className="form-field">
              <label htmlFor={`split-${dispute.id}-${dispute.index}`}>Amount to the payee (USDG)</label>
              <input
                id={`split-${dispute.id}-${dispute.index}`}
                value={sellerAmount}
                onChange={(e) => setSellerAmount(e.target.value)}
                placeholder={fromUnits(dispute.amount / 2n)}
                data-testid={`input-split-${dispute.id}-${dispute.index}`}
              />
            </div>
          </div>
          <WriteButton bundle={bundle} request={resolve} testId={`button-resolve-${dispute.id}-${dispute.index}`}>
            Resolve split
          </WriteButton>
        </>
      ) : (
        <p className="form-footnote">Only the arbiter named at invoice creation can rule.</p>
      )}
      <WriteButton bundle={bundle} request={force} testId={`button-force-split-${dispute.id}-${dispute.index}`} variant="secondary">
        Force 50/50 (after 14 days)
      </WriteButton>
    </div>
  );
}

/* --------------------------------------------------------------- reputation */

export function ReputationPage() {
  usePageTitle('Reputation');
  const { bundle } = useContracts();
  const [address, setAddress] = useState('');
  const valid = /^0x[a-fA-F0-9]{40}$/.test(address);
  const reputation = useReputation(bundle, valid ? (address as `0x${string}`) : undefined);

  return (
    <PageShell route="/reputation">
      <section className="form-panel">
        <div className="form-field">
          <label htmlFor="reputation-address">Wallet address</label>
          <div style={{ display: 'flex', gap: 9 }}>
            <input id="reputation-address" value={address} onChange={(e) => setAddress(e.target.value)} placeholder="0x…" data-testid="input-reputation-address" />
            <button className="button-secondary" disabled={!valid} data-testid="button-lookup-reputation">
              <BadgeCheck size={14} /> Look up
            </button>
          </div>
        </div>
      </section>
      <div className="stat-strip">
        <Metric label="Clean" value={reputation.data?.clean ?? '—'} />
        <Metric label="Disputed" value={reputation.data?.disputed ?? '—'} />
        <Metric label="Defaulted" value={reputation.data?.defaulted ?? '—'} />
        <Metric
          label="Pricing tier"
          value={
            !reputation.data
              ? '—'
              : reputation.data.clean + reputation.data.disputed + reputation.data.defaulted === 0
                ? 'Unrated'
                : reputation.data.disputed + reputation.data.defaulted === 0
                  ? 'Preferred'
                  : reputation.data.defaulted > 0
                    ? 'Priced out'
                    : 'Caution'
          }
        />
      </div>
      <div className="section-heading">
        <h2>On-chain track record</h2>
        <span>EVENT-DERIVED</span>
      </div>
      {reputation.isFetching && <Loading label="Reading reputation…" />}
      {valid && !reputation.isFetching && (
        <section className="panel" data-testid="panel-reputation-result">
          <p>
            <b>{address}</b> has {reputation.data?.clean ?? 0} clean, {reputation.data?.disputed ?? 0} disputed and{' '}
            {reputation.data?.defaulted ?? 0} defaulted settled milestones. Defaults weigh three times a dispute in the pool's premium, and a single
            default prices a seller above the risk ceiling.
          </p>
        </section>
      )}
      {!valid && (
        <section className="panel empty-state">
          <div className="empty-icon">
            <TrendingUp size={17} />
          </div>
          <h3>Search a wallet address</h3>
          <p>Counters come from the escrow contract, so they cannot be edited off-chain.</p>
        </section>
      )}
    </PageShell>
  );
}

/* -------------------------------------------------------------------- admin */

export function AdminPage() {
  usePageTitle('Administration');
  const { bundle } = useContracts();
  const account = useAccountAddress();
  const pool = usePoolState(bundle);
  const isOwner = !!pool.data?.owner && !!account && String(pool.data.owner).toLowerCase() === account.toLowerCase();
  const [arbiter, setArbiter] = useState('');
  const [seller, setSeller] = useState('');
  const [limit, setLimit] = useState('');
  const [feeBps, setFeeBps] = useState('0');
  const [feeRecipient, setFeeRecipient] = useState('');
  const [maxDiscount, setMaxDiscount] = useState('');
  const [cap, setCap] = useState('');
  const [minHistory, setMinHistory] = useState('');

  return (
    <PageShell route="/admin">
      <div className="notice-bar" data-testid="notice-admin-owner">
        {isOwner
          ? `Connected address is the owner of this deployment (${short(pool.data?.owner)}).`
          : 'Owner-only actions stay locked unless the connected account is the contract owner.'}
      </div>
      <div className="stat-strip">
        <Metric label="Escrow" value={pool.data ? (pool.data.escrowPaused ? 'paused' : 'active') : '—'} />
        <Metric label="Pool" value={pool.data ? (pool.data.paused ? 'paused' : 'active') : '—'} />
        <Metric label="Max discount" value={pool.data ? pct(pool.data.params.maxDiscountBps) : '—'} />
        <Metric label="Utilisation cap" value={pool.data ? pct(pool.data.params.utilizationCapBps) : '—'} hint="of face" />
      </div>

      <div className="section-heading">
        <h2>Pause controls</h2>
        <span>NEW WORK ONLY</span>
      </div>
      <section className="panel" style={{ display: 'grid', gap: 12 }}>
        <p className="form-footnote" style={{ margin: 0 }}>
          Pausing stops new invoices, funding, deposits and advances. Settlement, refunds and withdrawals stay open by design.
        </p>
        <div style={{ display: 'flex', gap: 10, flexWrap: 'wrap' }}>
          <WriteButton
            bundle={isOwner ? bundle : null}
            request={bundle && isOwner ? (pool.data?.escrowPaused ? writes.unpauseEscrow(bundle) : writes.pauseEscrow(bundle)) : undefined}
            testId="button-admin-pause-escrow"
            variant={pool.data?.escrowPaused ? 'primary' : 'secondary'}
          >
            {pool.data?.escrowPaused ? 'Unpause escrow' : 'Pause escrow'}
          </WriteButton>
          <WriteButton
            bundle={isOwner ? bundle : null}
            request={bundle && isOwner ? (pool.data?.paused ? writes.unpausePool(bundle) : writes.pausePool(bundle)) : undefined}
            testId="button-admin-pause-pool"
            variant={pool.data?.paused ? 'primary' : 'secondary'}
          >
            {pool.data?.paused ? 'Unpause pool' : 'Pause pool'}
          </WriteButton>
        </div>
      </section>

      <div className="section-heading">
        <h2>Credit & arbitration</h2>
        <span>OPERATOR DECISIONS</span>
      </div>
      <section className="panel" style={{ display: 'grid', gap: 12 }}>
        <div className="field-grid">
          <div className="form-field">
            <label htmlFor="admin-arbiter">Approve dispute arbiter</label>
            <input id="admin-arbiter" value={arbiter} onChange={(e) => setArbiter(e.target.value)} placeholder="0x…" data-testid="input-admin-arbiter" />
          </div>
          <div className="form-field">
            <label htmlFor="admin-seller">Seller credit limit</label>
            <div style={{ display: 'flex', gap: 8 }}>
              <input id="admin-seller" value={seller} onChange={(e) => setSeller(e.target.value)} placeholder="seller 0x…" data-testid="input-admin-seller" />
              <input value={limit} onChange={(e) => setLimit(e.target.value)} placeholder="500000 USDG" data-testid="input-admin-limit" />
            </div>
          </div>
        </div>
        <AdminWrites bundle={bundle} isOwner={isOwner} arbiter={arbiter} seller={seller} limit={limit} />
      </section>

      <div className="section-heading">
        <h2>Risk parameters</h2>
        <span>BOUNDED ON-CHAIN</span>
      </div>
      <section className="panel" style={{ display: 'grid', gap: 12 }}>
        <div className="field-grid">
          <div className="form-field">
            <label htmlFor="admin-max-discount">Max discount (bps, ≤ 5000)</label>
            <input id="admin-max-discount" value={maxDiscount} onChange={(e) => setMaxDiscount(e.target.value)} placeholder={pool.data ? String(pool.data.params.maxDiscountBps) : '2000'} data-testid="input-admin-max-discount" />
          </div>
          <div className="form-field">
            <label htmlFor="admin-cap">Utilisation cap (bps, ≤ 10000)</label>
            <input id="admin-cap" value={cap} onChange={(e) => setCap(e.target.value)} placeholder={pool.data ? String(pool.data.params.utilizationCapBps) : '8000'} data-testid="input-admin-cap" />
          </div>
          <div className="form-field">
            <label htmlFor="admin-min-history">Min history (≥ 1)</label>
            <input id="admin-min-history" value={minHistory} onChange={(e) => setMinHistory(e.target.value)} placeholder={pool.data ? String(pool.data.params.minHistory) : '3'} data-testid="input-admin-min-history" />
          </div>
        </div>
        <WriteButton
          bundle={isOwner ? bundle : null}
          request={
            bundle && isOwner && pool.data
              ? writes.setParams(bundle, {
                  ...pool.data.params,
                  maxDiscountBps: maxDiscount === '' ? pool.data.params.maxDiscountBps : Number(maxDiscount),
                  utilizationCapBps: cap === '' ? pool.data.params.utilizationCapBps : Number(cap),
                  minHistory: minHistory === '' ? pool.data.params.minHistory : Number(minHistory),
                })
              : undefined
          }
          testId="button-admin-params"
        >
          Save risk parameters
        </WriteButton>
        <p className="form-footnote" style={{ margin: 0 }}>
          Leave a field blank to keep its current value. The contract rejects max discount above 50%, a zero cap, and a zero minimum history.
        </p>
      </section>

      <div className="section-heading">
        <h2>Protocol fee</h2>
        <span>SNAPSHOTTED PER INVOICE</span>
      </div>
      <section className="panel" style={{ display: 'grid', gap: 12 }}>
        <div className="field-grid">
          <div className="form-field">
            <label htmlFor="admin-fee">Fee (bps, ≤ 100)</label>
            <input id="admin-fee" value={feeBps} onChange={(e) => setFeeBps(e.target.value)} placeholder="0" data-testid="input-admin-fee" />
          </div>
          <div className="form-field">
            <label htmlFor="admin-fee-to">Fee recipient</label>
            <input id="admin-fee-to" value={feeRecipient} onChange={(e) => setFeeRecipient(e.target.value)} placeholder="0x…" data-testid="input-admin-fee-recipient" />
          </div>
        </div>
        <WriteButton
          bundle={isOwner ? bundle : null}
          request={
            bundle && isOwner && feeRecipient && /^0x[a-fA-F0-9]{40}$/.test(feeRecipient) && Number(feeBps) >= 0 && Number(feeBps) <= 100
              ? writes.setFee(bundle, Number(feeBps), feeRecipient as `0x${string}`)
              : undefined
          }
          testId="button-admin-fee"
          variant="secondary"
        >
          Update fee
        </WriteButton>
        <p className="form-footnote" style={{ margin: 0 }}>
          The rate is frozen into each invoice when it is created, but the recipient must stay a real address: the escrow rejects the zero address.
        </p>
      </section>
    </PageShell>
  );
}

function useAbiLoader() {
  return advancePoolAbi;
}

function AdminWrites({
  bundle,
  isOwner,
  arbiter,
  seller,
  limit,
}: {
  bundle: ReturnType<typeof useContracts>['bundle'];
  isOwner: boolean;
  arbiter: string;
  seller: string;
  limit: string;
}) {
  const abi = useAbiLoader();
  const arbiterRequest =
    bundle && abi && isOwner && /^0x[a-fA-F0-9]{40}$/.test(arbiter)
      ? { address: bundle.addresses.pool, abi, functionName: 'setApprovedArbiter', args: [arbiter, true] }
      : undefined;
  const creditRequest =
    bundle && abi && isOwner && /^0x[a-fA-F0-9]{40}$/.test(seller) && Number(limit) > 0
      ? { address: bundle.addresses.pool, abi, functionName: 'setSellerCreditLimit', args: [seller, toUnits(limit)] }
      : undefined;

  return (
    <div style={{ display: 'flex', gap: 10, flexWrap: 'wrap' }}>
      <WriteButton bundle={bundle} request={arbiterRequest} testId="button-admin-approve-arbiter">
        Approve arbiter
      </WriteButton>
      <WriteButton bundle={bundle} request={creditRequest} testId="button-admin-credit-limit" variant="secondary">
        Set credit limit
      </WriteButton>
    </div>
  );
}

/* ------------------------------------------------------------------ activity */

export function ActivityPage() {
  usePageTitle('Activity');
  const { bundle } = useContracts();
  const [filter, setFilter] = useState<'all' | 'claims' | 'disputes' | 'advances'>('all');
  const [address, setAddress] = useState('');
  const [lookback, setLookback] = useState(30_000);
  const activity = useActivity(bundle, BigInt(lookback));

  const events = (activity.data ?? []).filter((e) => {
    if (filter === 'claims' && e.name !== 'Claimed' && e.name !== 'PayoutDeferred') return false;
    if (filter === 'disputes' && e.name !== 'MilestoneDisputed' && e.name !== 'MilestoneSettled') return false;
    if (filter === 'advances' && e.name !== 'Advanced' && e.name !== 'AdvanceSettled') return false;
    if (address && !JSON.stringify(e.args).toLowerCase().includes(address.toLowerCase())) return false;
    return true;
  });

  return (
    <PageShell route="/activity">
      <div className="page-head-actions" style={{ marginTop: -14, marginBottom: 22 }}>
        <button className={`button-secondary ${filter === 'all' ? 'active' : ''}`} onClick={() => setFilter('all')} data-testid="filter-activity-all">
          All events
        </button>
        <button className={`button-secondary ${filter === 'claims' ? 'active' : ''}`} onClick={() => setFilter('claims')} data-testid="filter-activity-claims">
          Claims
        </button>
        <button className={`button-secondary ${filter === 'disputes' ? 'active' : ''}`} onClick={() => setFilter('disputes')} data-testid="filter-activity-disputes">
          Disputes
        </button>
        <button className={`button-secondary ${filter === 'advances' ? 'active' : ''}`} onClick={() => setFilter('advances')} data-testid="filter-activity-advances">
          Advances
        </button>
      </div>
      <div style={{ display: 'flex', gap: 9, marginBottom: 14, flexWrap: 'wrap', alignItems: 'flex-end' }}>
        <div className="form-field" style={{ minWidth: 260 }}>
          <label htmlFor="activity-address">Filter by address</label>
          <input
            id="activity-address"
            value={address}
            onChange={(e) => setAddress(e.target.value)}
            placeholder="0x… (any party in the event)"
            data-testid="input-activity-address"
          />
        </div>
        <div className="form-field" style={{ minWidth: 180 }}>
          <label htmlFor="activity-lookback">Block range</label>
          <select id="activity-lookback" value={lookback} onChange={(e) => setLookback(Number(e.target.value))} data-testid="select-activity-lookback">
            <option value={5_000}>Last 5,000 blocks</option>
            <option value={30_000}>Last 30,000 blocks</option>
            <option value={200_000}>Last 200,000 blocks</option>
          </select>
        </div>
      </div>
      {activity.isLoading && <Loading label={`Decoding events from the last ${lookback.toLocaleString()} blocks…`} />}
      <ErrorNote error={activity.error} />
      <div className="table-row header">
        <span>EVENT</span>
        <span>DETAIL</span>
        <span>BLOCK</span>
        <span>TRANSACTION</span>
      </div>
      <EventTable events={events} loading={false} bundle={bundle} />
    </PageShell>
  );
}

function EventTable({
  events,
  loading,
  bundle,
}: {
  events: ActivityEvent[];
  loading: boolean;
  bundle?: ReturnType<typeof useContracts>['bundle'];
}) {
  if (!loading && events.length === 0) {
    return (
      <section className="panel empty-state" data-testid="state-empty-records">
        <div className="empty-icon">
          <Clock3 size={17} />
        </div>
        <h3>No events in range</h3>
        <p>Nothing was emitted by these contracts in the last 30,000 blocks.</p>
      </section>
    );
  }
  return (
    <>
      {(events ?? []).map((e, i) => (
        <div className="table-row" key={`${e.txHash}-${e.logIndex}-${i}`} data-testid={`row-event-${e.name}`}>
          <span>{e.name}</span>
          <span>{describeEvent(e.name, e.args)}</span>
          <span>{e.blockNumber?.toString() ?? '—'}</span>
          <span><TxLink txHash={e.txHash} bundle={bundle} /></span>
        </div>
      ))}
    </>
  );
}

function describeEvent(name: string, args: Record<string, unknown>): string {
  const parts: string[] = [];
  if (args.id !== undefined) parts.push(`invoice #${String(args.id)}`);
  if (args.index !== undefined) parts.push(`milestone ${String(args.index)}`);
  if (args.face !== undefined) parts.push(`face ${usd(args.face as bigint)}`);
  if (args.advance !== undefined) parts.push(`advance ${usd(args.advance as bigint)}`);
  if (args.amount !== undefined) parts.push(`${usd(args.amount as bigint)} USDG`);
  if (args.total !== undefined) parts.push(`total ${usd(args.total as bigint)}`);
  if (args.received !== undefined) parts.push(`received ${usd(args.received as bigint)}`);
  if (args.discountBps !== undefined) parts.push(`discount ${pct(args.discountBps as bigint)}`);
  if (args.to !== undefined) parts.push(`to ${short(args.to as string)}`);
  if (args.payee !== undefined) parts.push(`payee ${short(args.payee as string)}`);
  if (args.outcome !== undefined) parts.push(`outcome ${['Clean', 'Disputed', 'Defaulted', 'AutoReleased'][Number(args.outcome)] ?? String(args.outcome)}`);
  if (args.invoiceId !== undefined) parts.push(`invoice #${String(args.invoiceId)}`);
  return parts.join(' · ') || name;
}

/* ------------------------------------------------------------------- invoice */

export function InvoicePage({ id }: { id: string }) {
  usePageTitle(`Invoice #${id}`);
  const { bundle } = useContracts();
  const account = useAccountAddress();
  const numeric = /^\d+$/.test(id) ? BigInt(id) : undefined;
  const invoice = useInvoice(bundle, numeric);
  const now = useNow();
  const quote = useQuote(bundle, invoice.data?.owner === account ? numeric : undefined);
  const row = invoice.data;

  if (!numeric) {
    return (
      <PageShell route="/invoice">
        <div className="notice-bar">Invoice identifiers must be numeric.</div>
      </PageShell>
    );
  }
  if (invoice.isLoading) {
    return (
      <PageShell route="/invoice">
        <Loading label={`Reading invoice #${id}…`} />
      </PageShell>
    );
  }
  if (!row) {
    return (
      <PageShell route="/invoice">
        <div className="notice-bar" data-testid="notice-invoice-missing">
          Invoice #{id} does not exist on this deployment.
        </div>
      </PageShell>
    );
  }

  const isSeller = row.seller === account;
  const isBuyer = row.buyer === account;
  const isArbiter = row.arbiter === account;
  const isPayee = row.owner === account;

  return (
    <PageShell route="/invoice">
      <div className="stat-strip">
        <Metric label="Remaining" value={`${usd(row.remaining)} USDG`} hint={`of ${usd(row.total)}`} />
        <Metric label="Milestones" value={`${row.milestones.length - row.openMilestones}/${row.milestones.length} settled`} />
        <Metric label="Fee" value={pct(row.feeBps)} hint="snapshotted at creation" />
        <Metric label="Status" value={statusChip(row)} />
      </div>
      <div className="split-layout">
        <section>
          <div className="section-heading" style={{ marginTop: 0 }}>
            <h2>Milestone schedule</h2>
            <span>INVOICE #{row.id.toString()}</span>
          </div>
          {row.milestones.map((m, index) => (
            <div className="table-row" key={index} data-testid={`row-milestone-${index}`}>
              <span>
                #{index} · {usd(m.amount)} USDG
              </span>
              <span title={new Date(m.deadline * 1000).toISOString()}>
                due {new Date(m.deadline * 1000).toISOString().slice(0, 10)} · {until(m.deadline, now)}
              </span>
              <span>{MILESTONE[m.status]}</span>
              <span>{m.status === 0 ? 'pending' : m.status === 1 ? 'in review' : 'settled'}</span>
            </div>
          ))}
          <div className="status-line" style={{ marginTop: 12, gap: 14, flexWrap: 'wrap' }}>
            <span>
              <i /> Seller <AddressLink address={row.seller} bundle={bundle} />
            </span>
            <span>
              <i /> Buyer <AddressLink address={row.buyer} bundle={bundle} />
            </span>
            <span>
              <i /> Arbiter <AddressLink address={row.arbiter} bundle={bundle} />
            </span>
          </div>
          <div className="status-line">
            <i /> Right to payment held by <AddressLink address={row.owner} bundle={bundle} />
            {row.owner === bundle?.addresses.pool && ' (the pool has financed this receivable)'}
          </div>
          <div className="status-line">
            <i /> Document hash {row.docHash ? `${String(row.docHash).slice(0, 18)}…` : 'not recorded'}
          </div>
          <div style={{ display: 'flex', gap: 8, marginTop: 12 }}>
            {row.id > 1n && (
              <Link href={`/invoice/${row.id - 1n}`} className="button-secondary" data-testid="link-prev-invoice">
                ← Invoice #{row.id - 1n}
              </Link>
            )}
            <Link href={`/invoice/${row.id + 1n}`} className="button-secondary" data-testid="link-next-invoice">
              Invoice #{row.id + 1n} →
            </Link>
          </div>
        </section>
        <section>
          <div className="section-heading" style={{ marginTop: 0 }}>
            <h2>Available actions</h2>
            <span>ROLE-GATED</span>
          </div>
          <div className="panel" style={{ display: 'grid', gap: 9 }}>
            {row.status === 1 && isSeller && (
              <WriteButton bundle={bundle} request={bundle ? writes.cancelInvoice(bundle, row.id) : undefined} testId="button-cancel-invoice" variant="secondary">
                Cancel invoice
              </WriteButton>
            )}
            {row.status === 1 && isBuyer && (
              <>
                <WriteButton bundle={bundle} request={bundle ? writes.approveToken(bundle, bundle.addresses.escrow, row.total) : undefined} testId="button-approve-escrow" variant="secondary">
                  1 · Approve escrow
                </WriteButton>
                <WriteButton bundle={bundle} request={bundle ? writes.fund(bundle, row.id) : undefined} testId="button-fund-invoice">
                  2 · Fund {usd(row.total)} USDG
                </WriteButton>
              </>
            )}
            {row.milestones.map((m, index) => {
              const idx = BigInt(index);
              if (m.status === 0 && isSeller) {
                return (
                  <WriteButton key={index} bundle={bundle} request={bundle ? writes.submitMilestone(bundle, row.id, idx) : undefined} testId={`button-submit-milestone-${index}`}>
                    Submit milestone #{index}
                  </WriteButton>
                );
              }
              if (m.status === 1 && isBuyer) {
                return (
                  <div key={index} style={{ display: 'flex', gap: 8 }}>
                    <WriteButton bundle={bundle} request={bundle ? writes.approveMilestone(bundle, row.id, idx) : undefined} testId={`button-approve-milestone-${index}`}>
                      Approve #{index}
                    </WriteButton>
                    <WriteButton bundle={bundle} request={bundle ? writes.disputeMilestone(bundle, row.id, idx) : undefined} testId={`button-dispute-milestone-${index}`} variant="secondary">
                      Dispute #{index}
                    </WriteButton>
                  </div>
                );
              }
              if (m.status === 1) {
                return (
                  <WriteButton key={index} bundle={bundle} request={bundle ? writes.autoRelease(bundle, row.id, idx) : undefined} testId={`button-auto-release-${index}`} variant="secondary">
                    Auto-release #{index} (permissionless)
                  </WriteButton>
                );
              }
              if (m.status === 2 && isArbiter) {
                return (
                  <WriteButton key={index} bundle={bundle} request={bundle ? writes.resolveExpiredDispute(bundle, row.id, idx) : undefined} testId={`button-expire-dispute-${index}`} variant="secondary">
                    Force 50/50 on #{index}
                  </WriteButton>
                );
              }
              if (m.status === 0) {
                return (
                  <WriteButton key={index} bundle={bundle} request={bundle ? writes.reclaimUnsubmitted(bundle, row.id, idx) : undefined} testId={`button-reclaim-${index}`} variant="secondary" disabled={false}>
                    Reclaim #{index} (permissionless, refund to buyer)
                  </WriteButton>
                );
              }
              return null;
            })}
            {isPayee && quote.data && (
              <div className="status-line">
                <i /> You hold the receivable: an advance would pay {usd(quote.data.advance)} USDG ({pct(quote.data.discountBps)} discount)
              </div>
            )}
          </div>
        </section>
      </div>
    </PageShell>
  );
}

export { CircleDollarSign, FileCheck2 };