import { Link } from 'wouter';
import {
  ArrowLeftRight,
  ArrowUpRight,
  BadgeCheck,
  Blocks,
  Clock3,
  FileCheck2,
  Landmark,
  LockKeyhole,
  ShieldCheck,
  Wallet,
} from 'lucide-react';
import { useActivity, useContracts, useInvoices, usePoolState } from '../hooks/useEscrowData';
import { ErrorNote, fromUnits, Metric, pct, short, usd } from '../components/contract-ui';
import { getSupportedChain } from '../lib/chains';

const STEPS = [
  {
    n: '01',
    title: 'Create the invoice',
    body: 'The seller registers a receivable with an arbiter and a milestone schedule. The invoice is minted as an ERC-721, so the right to be paid becomes transferable.',
    icon: FileCheck2,
  },
  {
    n: '02',
    title: 'Buyer locks the funds',
    body: 'The buyer deposits the full amount in USDG into escrow. Nothing is released until a milestone is delivered and the review window passes.',
    icon: LockKeyhole,
  },
  {
    n: '03',
    title: 'Get paid today',
    body: 'The seller sells the receivable to the pool at a discount and is paid immediately. When escrow settles, the pool receives the face value and LPs earn the spread.',
    icon: ArrowLeftRight,
  },
];

const ROLES = [
  {
    icon: FileCheck2,
    title: 'Seller',
    body: 'Invoice a buyer, deliver on milestones, and sell the receivable whenever you want cash before the final release.',
    cta: { href: '/create', label: 'Create an invoice' },
  },
  {
    icon: ShieldCheck,
    title: 'Buyer',
    body: 'Lock funds against clear milestones. Approve delivery, dispute it in the review window, or reclaim anything undelivered after the grace period.',
    cta: { href: '/dashboard', label: 'Open my dashboard' },
  },
  {
    icon: Landmark,
    title: 'Liquidity provider',
    body: 'Deposit USDG into the pool and fund advances at a discount. Earn the spread as milestones settle, with caps and per-seller credit limits in place.',
    cta: { href: '/pool', label: 'View the pool' },
  },
];

const GUARANTEES = [
  { title: 'Nobody can be locked out', body: 'A silent buyer triggers auto-release after 7 days. A silent arbiter forces a 50/50 split after 14. A seller who never delivers lets the buyer reclaim the funds.' },
  { title: 'Reputation is a by-product', body: 'Every settled outcome updates an on-chain track record, and the pool prices risk from it. Good counterparties get cheaper advances automatically.' },
  { title: 'Bad debt cannot be recycled', body: 'Losses are recognised when they occur, the credit limit stays consumed, and withdrawals reserve the buffer that keeps the pool lending.' },
  { title: 'Regulated-stainable payouts', body: 'USDG is a supervised stablecoin that can freeze addresses. Failed payouts are parked and claimable to a clean address instead of locking an escrow.' },
];

export function LandingPage() {
  const { bundle } = useContracts();
  const pool = usePoolState(bundle);
  const invoices = useInvoices(bundle);
  const activity = useActivity(bundle, 5_000n);
  const account = bundle?.poolOwner;

  const stats = {
    escrowed: (invoices.data ?? []).reduce((sum, r) => sum + (r.status === 2 ? r.remaining : 0n), 0n),
    invoices: (invoices.data ?? []).length,
    poolAssets: pool.data?.totalAssets,
    sharePrice: pool.data ? fromUnits(pool.data.sharePrice, 18) : undefined,
    util: pool.data?.utilizationBps,
  };

  return (
    <div className="workspace" data-testid="page-landing">
      {/* ------------------------------------------------------------------ hero */}
      <section className="hero-panel" aria-label="Introduction" data-testid="panel-hero">
        <div>
          <div className="hero-index">INVOICE ESCROW · USDG · {bundle?.chain.name ?? 'SUPPORTED NETWORKS'}</div>
          <h1 style={{ fontSize: 38, lineHeight: 1.1, margin: '10px 0 8px' }} data-testid="text-hero-title">
            Get paid today.
            <br />
            Not in 90 days.
          </h1>
          <p style={{ maxWidth: 520 }}>
            A Southeast Asian exporter or agency invoices an overseas buyer and waits months to be paid. Buyers do not
            want to pay upfront with no recourse; sellers cannot wait. This settles on milestones and finances the
            receivable in between.
          </p>
          <div style={{ display: 'flex', gap: 10, marginTop: 18, flexWrap: 'wrap' }}>
            <Link href="/create" className="button-primary" data-testid="cta-create-invoice">
              Create an invoice <ArrowUpRight size={14} />
            </Link>
            <Link href="/market" className="button-secondary" data-testid="cta-explore-market">
              Get an instant advance
            </Link>
          </div>
        </div>
        <div className="hero-metric">
          <strong>LIVE FROM THE CONTRACTS</strong>
          <span>
            Escrowed {usd(stats.escrowed)} USDG across {stats.invoices} invoices
            <br />
            Pool {usd(stats.poolAssets)} USDG · share price {stats.sharePrice ?? '—'} · utilisation{' '}
            {stats.util !== undefined ? pct(stats.util) : '—'}
          </span>
        </div>
      </section>

      <ErrorNote error={pool.error ?? invoices.error} />

      {/* -------------------------------------------------------------- how it works */}
      <div className="section-heading">
        <h2>How settlement works</h2>
        <span>THREE MOVES</span>
      </div>
      <div className="split-layout" style={{ gridTemplateColumns: 'repeat(3, minmax(0, 1fr))' }}>
        {STEPS.map((step) => {
          const Icon = step.icon;
          return (
            <section className="panel" key={step.n} data-testid={`panel-step-${step.n}`}>
              <div className="hero-index">{step.n}</div>
              <div style={{ display: 'flex', alignItems: 'center', gap: 8, margin: '8px 0 6px' }}>
                <Icon size={16} />
                <h3 style={{ margin: 0, fontSize: 15 }}>{step.title}</h3>
              </div>
              <p style={{ margin: 0, opacity: 0.78, fontSize: 13, lineHeight: 1.55 }}>{step.body}</p>
            </section>
          );
        })}
      </div>

      {/* ------------------------------------------------------------- live numbers */}
      <div className="section-heading">
        <h2>Protocol state</h2>
        <span>READ ON-CHAIN</span>
      </div>
      <div className="stat-strip" data-testid="strip-live-stats">
        <Metric label="Escrowed" value={`${usd(stats.escrowed)} USDG`} hint="unsettled milestone value" />
        <Metric label="Invoices" value={stats.invoices} hint="on this deployment" />
        <Metric label="Pool assets" value={`${usd(stats.poolAssets)} USDG`} hint="idle + carrying value" />
        <Metric label="Share price" value={stats.sharePrice ?? '—'} hint="USDG per pool share" />
      </div>

      {/* ------------------------------------------------------------------- roles */}
      <div className="section-heading">
        <h2>Three ways in</h2>
        <span>SELLER · BUYER · LP</span>
      </div>
      <div className="split-layout" style={{ gridTemplateColumns: 'repeat(3, minmax(0, 1fr))' }}>
        {ROLES.map((role) => {
          const Icon = role.icon;
          return (
            <section className="panel" key={role.title} data-testid={`panel-role-${role.title.toLowerCase().replace(' ', '-')}`}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                <Icon size={16} />
                <h3 style={{ margin: 0, fontSize: 15 }}>{role.title}</h3>
              </div>
              <p style={{ margin: '8px 0 14px', opacity: 0.78, fontSize: 13, lineHeight: 1.55 }}>{role.body}</p>
              <Link href={role.cta.href} className="button-secondary" data-testid={`cta-role-${role.title.toLowerCase().replace(' ', '-')}`}>
                {role.cta.label}
              </Link>
            </section>
          );
        })}
      </div>

      {/* ---------------------------------------------------------------- timeline */}
      <div className="section-heading">
        <h2>Milestone lifecycle</h2>
        <span>NO PARTY CAN BLOCK ANOTHER FOREVER</span>
      </div>
      <section className="panel" data-testid="panel-lifecycle">
        <div className="table-row header">
          <span>STAGE</span>
          <span>WHO ACTS</span>
          <span>DEADLINE</span>
          <span>OUTCOME</span>
        </div>
        <div className="table-row">
          <span>Pending</span>
          <span>Seller submits</span>
          <span>delivery deadline</span>
          <span>+ 3d grace, then the buyer can reclaim</span>
        </div>
        <div className="table-row">
          <span>Submitted</span>
          <span>Buyer approves or disputes</span>
          <span>7-day review window</span>
          <span>approved pays the payee; silence auto-releases</span>
        </div>
        <div className="table-row">
          <span>Disputed</span>
          <span>Arbiter splits the amount</span>
          <span>14-day response window</span>
          <span>silence forces an even 50/50 split</span>
        </div>
        <div className="table-row">
          <span>Settled</span>
          <span>Escrow pays the current NFT owner</span>
          <span>—</span>
          <span>fee withheld, reputation recorded</span>
        </div>
      </section>

      {/* -------------------------------------------------------------- guarantees */}
      <div className="section-heading">
        <h2>Why it holds together</h2>
        <span>DESIGN GUARANTEES</span>
      </div>
      <div className="split-layout">
        <section className="panel" style={{ display: 'grid', gap: 12 }}>
          {GUARANTEES.slice(0, 2).map((g) => (
            <div key={g.title}>
              <h3 style={{ margin: '0 0 4px', fontSize: 14 }}>{g.title}</h3>
              <p style={{ margin: 0, opacity: 0.78, fontSize: 13, lineHeight: 1.55 }}>{g.body}</p>
            </div>
          ))}
        </section>
        <section className="panel" style={{ display: 'grid', gap: 12 }}>
          {GUARANTEES.slice(2).map((g) => (
            <div key={g.title}>
              <h3 style={{ margin: '0 0 4px', fontSize: 14 }}>{g.title}</h3>
              <p style={{ margin: 0, opacity: 0.78, fontSize: 13, lineHeight: 1.55 }}>{g.body}</p>
            </div>
          ))}
        </section>
      </div>

      {/* ------------------------------------------------------------------ proofs */}
      <div className="section-heading">
        <h2>Recent on-chain events</h2>
        <span>LAST 5,000 BLOCKS</span>
      </div>
      <div className="table-row header">
        <span>EVENT</span>
        <span>DETAIL</span>
        <span>BLOCK</span>
        <span>CONTRACT</span>
      </div>
      {(activity.data ?? []).slice(0, 6).map((e, i) => (
        <div className="table-row" key={`${e.txHash}-${i}`} data-testid={`landing-event-${e.name}`}>
          <span>{e.name}</span>
          <span>
            {e.args.id !== undefined ? `invoice #${String(e.args.id)}` : ''}
            {e.args.advance !== undefined ? ` advance ${usd(e.args.advance as bigint)} USDG` : ''}
            {e.args.amount !== undefined ? ` ${usd(e.args.amount as bigint)} USDG` : ''}
          </span>
          <span>{e.blockNumber?.toString() ?? '—'}</span>
          <span>{short(bundle?.addresses.escrow)}</span>
        </div>
      ))}
      {(activity.data ?? []).length === 0 && (
        <section className="panel empty-state">
          <div className="empty-icon">
            <Blocks size={17} />
          </div>
          <h3>No events yet on this deployment</h3>
          <p>Create the first invoice to see the protocol come alive.</p>
        </section>
      )}

      {/* ---------------------------------------------------------------- networks */}
      <div className="section-heading">
        <h2>Deployments</h2>
        <span>VERIFIED SOURCES</span>
      </div>
      <section className="panel" data-testid="panel-networks">
        {bundle ? (
          <div className="status-line">
            <i />
            Active: {bundle.chain.name} · escrow {short(bundle.addresses.escrow)} · pool {short(bundle.addresses.pool)} · token{' '}
            {short(bundle.addresses.token)} · operator {short(account)}
          </div>
        ) : (
          <div className="status-line">
            <i />
            Connect a wallet on {[421614, 46630].map((id) => getSupportedChain(id)?.name).join(' or ')} to read the contracts.
          </div>
        )}
        <div style={{ display: 'flex', gap: 10, marginTop: 12, flexWrap: 'wrap' }}>
          <Link href="/activity" className="button-secondary" data-testid="cta-activity">
            <Clock3 size={14} /> Event log
          </Link>
          <Link href="/reputation" className="button-secondary" data-testid="cta-reputation">
            <BadgeCheck size={14} /> Reputation
          </Link>
          <Link href="/admin" className="button-secondary" data-testid="cta-admin">
            <Wallet size={14} /> Operator controls
          </Link>
        </div>
      </section>

      <footer className="footer-line">
        <span>Invoice escrow · USDG on Arbitrum and Robinhood Chain</span>
        <span>Testnet · AI-audited, not externally audited</span>
      </footer>
    </div>
  );
}