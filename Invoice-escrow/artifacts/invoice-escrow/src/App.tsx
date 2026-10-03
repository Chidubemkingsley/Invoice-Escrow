import { useMemo, useState, type ReactNode } from 'react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { ErrorBoundary } from '@/components/error-boundary';
import { Toaster } from '@/components/ui/toaster';
import { TooltipProvider } from '@/components/ui/tooltip';
import { ConnectButton, RainbowKitProvider } from '@rainbow-me/rainbowkit';
import { useAccount, useChainId, WagmiProvider } from 'wagmi';
import {
  Activity,
  ArrowDownToLine,
  ArrowLeftRight,
  ArrowUpRight,
  BadgeCheck,
  Blocks,
  BriefcaseBusiness,
  ChevronRight,
  CircleDollarSign,
  Clock3,
  FileCheck2,
  FilePlus2,
  Gavel,
  Landmark,
  LockKeyhole,
  Menu,
  ShieldCheck,
  TrendingUp,
  Wallet,
} from 'lucide-react';
import NotFound from '@/pages/not-found';
import { LandingPage } from './pages/landing';
import {
  ActivityPage,
  AdminPage,
  ArbiterPage,
  CreatePage,
  DashboardPage,
  InvoicePage,
  MarketPage,
  OverviewPage,
  PoolPage,
  ReputationPage,
} from './pages/live-pages';
import { Link, Route, Switch, useLocation, Router as WouterRouter } from 'wouter';
import { contractArtifactsAvailable } from './contract-adapter';
import { getSupportedChain, walletConfig } from './lib/chains';
import { resolveDeployment } from './lib/deployments';
import '@rainbow-me/rainbowkit/styles.css';
import './escrow.css';

const queryClient = new QueryClient();

const navGroups = [
  { label: 'Workspace', links: [
    { href: '/', title: 'Home', icon: Blocks },
    { href: '/dashboard', title: 'My dashboard', icon: BriefcaseBusiness },
    { href: '/create', title: 'New invoice', icon: FilePlus2 },
    { href: '/market', title: 'Receivables market', icon: ArrowLeftRight },
  ]},
  { label: 'Capital & trust', links: [
    { href: '/pool', title: 'Liquidity pool', icon: Landmark },
    { href: '/arbiter', title: 'Disputes', icon: Gavel },
    { href: '/reputation', title: 'Reputation', icon: BadgeCheck },
  ]},
  { label: 'Protocol', links: [
    { href: '/activity', title: 'Activity', icon: Activity },
    { href: '/admin', title: 'Administration', icon: LockKeyhole },
  ]},
];

function useWallet() {
  const { address, chain, status } = useAccount();
  const chainId = useChainId();
  return {
    chainId: chainId ?? null,
    chainName: chain?.name ?? (chainId ? getSupportedChain(chainId)?.name : undefined),
    account: address ?? '',
    connecting: status === 'connecting',
  };
}

function WalletControl({ wallet }: { wallet: ReturnType<typeof useWallet> }) {
  return <ConnectButton.Custom>
    {({ account, chain, mounted, openAccountModal, openChainModal, openConnectModal }) => {
      const ready = mounted;
      const connected = ready && account && chain;
      if (!ready) {
        return <button className="wallet-button" disabled data-testid="button-connect-wallet"><Wallet size={13} style={{ verticalAlign: 'middle', marginRight: 6 }} />Connect wallet</button>;
      }
      if (!connected) {
        return <button className="wallet-button" onClick={openConnectModal} data-testid="button-connect-wallet"><Wallet size={13} style={{ verticalAlign: 'middle', marginRight: 6 }} />Connect wallet</button>;
      }
      if (chain.unsupported) {
        return <button className="wallet-button" onClick={openChainModal} data-testid="button-switch-network">Switch network</button>;
      }
      return <button className="wallet-button" onClick={openAccountModal} data-testid="button-connect-wallet">{wallet.connecting ? 'Connecting…' : account.displayName}</button>;
    }}
  </ConnectButton.Custom>;
}

function Shell({ children, route, wallet }: { children: ReactNode; route: string; wallet: ReturnType<typeof useWallet> }) {
  const [menuOpen, setMenuOpen] = useState(false);
  const page = [...navGroups.flatMap((g) => g.links)].find((item) => item.href === route)?.title ?? (route.startsWith('/invoice/') ? 'Invoice detail' : 'Overview');
  const deploymentState = wallet.chainId === null ? null : resolveDeployment(wallet.chainId);
  const walletReady = !!wallet.account && deploymentState?.status === 'ready' && contractArtifactsAvailable;
  const chain = wallet.chainId === null ? undefined : getSupportedChain(wallet.chainId);
  return (
    <div className="app-shell">
      {menuOpen && <button className="mobile-backdrop" aria-label="Close menu" data-testid="button-close-menu" onClick={() => setMenuOpen(false)} />}
      <aside className={`sidebar ${menuOpen ? 'sidebar-open' : ''}`} data-testid="navigation-sidebar">
        <Link href="/" className="brand" data-testid="link-brand"><span className="brand-mark">e</span><span><span className="brand-name">Invoice-escrow</span><span className="brand-caption">Trade with confidence</span></span></Link>
        {navGroups.map((group) => <div key={group.label}>
          <div className="nav-kicker">{group.label}</div>
          {group.links.map((item) => {
            const Icon = item.icon;
            const active = route === item.href || (item.href === '/dashboard' && route === '/invoice');
            return <Link key={item.href} href={item.href} className={`nav-link ${active ? 'active' : ''}`} data-testid={`link-nav-${item.href.slice(1) || 'overview'}`} onClick={() => setMenuOpen(false)}><span className="nav-icon"><Icon size={15} strokeWidth={1.7} /></span>{item.title}</Link>;
          })}
        </div>)}
        <div className="sidebar-foot"><div className="network-line"><i className="network-dot" />{chain?.name ?? 'Unsupported network'}</div><div className="sidebar-small">Testnet · read only</div></div>
      </aside>
      <div className="main-shell">
        <header className="topbar">
          <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
            <button className="mobile-menu" aria-label="Open navigation" data-testid="button-open-menu" onClick={() => setMenuOpen(true)}><Menu size={18} /></button>
            <div className="crumb"><span>Workspace</span><ChevronRight size={13} /><strong data-testid="text-current-page">{page}</strong></div>
          </div>
          <div className="top-actions">
            <div className={`network-pill ${chain ? 'network-supported' : 'network-warning'}`} data-testid="status-wallet-network"><span />{chain?.name ?? `Unsupported · ${wallet.chainId ?? '—'}`}</div>
            <WalletControl wallet={wallet} />
          </div>
        </header>
        <main>{children}</main>
        <nav className="mobile-nav" aria-label="Mobile navigation">{navGroups[0].links.slice(0, 4).map((item) => { const Icon = item.icon; return <Link key={item.href} href={item.href} className={route === item.href ? 'active' : ''} data-testid={`mobile-link-${item.href.slice(1) || 'overview'}`}><Icon size={17} />{item.title.split(' ')[0]}</Link>; })}</nav>
      </div>
      {walletReady && <span className="sr-only" data-testid="status-wallet-ready">Wallet connected to configured chain</span>}
    </div>
  );
}

function DeploymentGate({ wallet }: { wallet: ReturnType<typeof useWallet> }) {
  const state = wallet.chainId === null ? null : resolveDeployment(wallet.chainId);
  const deployment = state?.status === 'ready' ? state.deployment : undefined;
  const chain = wallet.chainId === null ? undefined : getSupportedChain(wallet.chainId);
  const chainLabel = chain ? `${chain.name} · ${wallet.chainId}` : `Unsupported · ${wallet.chainId ?? 'no active chain'}`;
  const entries = [
    ['Network', chainLabel, !!chain],
    ['Settlement token', deployment?.token ?? 'Not configured', !!deployment],
    ['Invoice escrow', deployment?.escrow ?? 'Not configured', !!deployment],
    ['Receivables pool', deployment?.pool ?? 'Not configured', !!deployment],
  ];
  const incomplete = state?.status !== 'ready';
  const heading = state?.status === 'unsupported-chain'
    ? 'Unsupported network'
    : state?.status === 'invalid'
      ? 'Deployment file is invalid'
      : incomplete
        ? 'Deployment not configured'
        : !contractArtifactsAvailable
          ? 'Contract interfaces are not available'
          : 'Connect to a supported network';
  const detail = state?.status === 'invalid'
    ? state.reason
    : state?.status === 'unsupported-chain'
      ? 'This app supports Arbitrum Sepolia and Robinhood Chain Testnet. Switch to one of those networks to continue.'
      : incomplete
        ? `Add a verified deployments/${wallet.chainId ?? '<chainId>'}.json file with the token, escrow and pool addresses before using this network.`
        : 'The deployment addresses are configured, but verified contract ABIs and exact artifact layouts have not been supplied. Contract reads and actions remain disabled until those artifacts are added.';
  return <div className="workspace gate-workspace">
    <div className="eyebrow">Invoice escrow · testnet</div>
    <h1 className="page-title" data-testid="text-page-title">A clearer way to get paid.</h1>
    <p className="page-subtitle">Invoice-backed settlement for sellers, buyers and capital providers. Funds and actions stay gated until this deployment can be verified.</p>
    <section className="hero-panel" aria-label="Product introduction" data-testid="panel-product-introduction">
      <div><div className="hero-index">01 / VERIFIED SETTLEMENT</div><h2>Trade on terms.<br />Settle on milestones.</h2><p>One shared record from invoice to final release.</p></div>
      <div className="hero-metric"><strong>TESTNET ACCESS</strong><span>Live contract data appears here only after deployment verification.</span></div>
    </section>
    <section className="blocking-card" data-testid="state-deployment-blocked">
      <div className="block-accent" />
      <div className="block-content">
        <div className="block-symbol"><LockKeyhole size={19} /></div>
        <div className="eyebrow">Action gate · protocol configuration</div>
        <h2>{heading}</h2>
        <p>{detail}</p>
        <div className="deploy-grid" aria-label="Deployment verification" data-testid="list-deployment-settings">{entries.map(([label, value, ok]) => <div className="deploy-cell" key={label as string} data-testid={`deployment-${String(label).toLowerCase().replaceAll(' ', '-')}`}><div className="deploy-label">{label}</div><div className={`deploy-value ${ok ? '' : 'missing'}`}>{value}</div></div>)}</div>
        <div className="block-note"><ShieldCheck size={16} /><span><b>No sample financial data.</b> Balances, invoices, quotes, pool metrics and history are not shown until they can be read from a verified deployment. Contract functions and tuple layouts will only be integrated from supplied ABI artifacts.</span></div>
      </div>
    </section>
    <footer className="footer-line"><span>Invoice escrow · secure testnet workspace</span><span>Contract actions locked pending verification</span></footer>
  </div>;
}

function RoutedApp() {
  const [location] = useLocation();
  const wallet = useWallet();
  const matchedInvoice = location.match(/^\/invoice\/([^/]+)$/);
  const route = matchedInvoice ? '/invoice' : location;
  const page = useMemo(() => {
    if (matchedInvoice) return <InvoicePage id={decodeURIComponent(matchedInvoice[1])} />;
    switch (location) {
      case '/': return <LandingPage />;
      case '/dashboard': return <DashboardPage />;
      case '/create': return <CreatePage />;
      case '/market': return <MarketPage />;
      case '/pool': return <PoolPage />;
      case '/arbiter': return <ArbiterPage />;
      case '/reputation': return <ReputationPage />;
      case '/admin': return <AdminPage />;
      case '/activity': return <ActivityPage />;
      default: return <NotFound />;
    }
  }, [location, matchedInvoice?.[1]]);
  const deploymentState = wallet.chainId === null ? null : resolveDeployment(wallet.chainId);
  const readyForReads = deploymentState?.status === 'ready' && contractArtifactsAvailable;
  return <Shell route={route} wallet={wallet}><RoutedErrorBoundary resetKey={location}><Switch>
    <Route path="/" component={() => page} />
    <Route path="/dashboard" component={() => readyForReads ? page : <DeploymentGate wallet={wallet} />} />
    <Route path="/create" component={() => readyForReads ? page : <DeploymentGate wallet={wallet} />} />
    <Route path="/market" component={() => readyForReads ? page : <DeploymentGate wallet={wallet} />} />
    <Route path="/pool" component={() => readyForReads ? page : <DeploymentGate wallet={wallet} />} />
    <Route path="/arbiter" component={() => readyForReads ? page : <DeploymentGate wallet={wallet} />} />
    <Route path="/reputation" component={() => readyForReads ? page : <DeploymentGate wallet={wallet} />} />
    <Route path="/admin" component={() => readyForReads ? page : <DeploymentGate wallet={wallet} />} />
    <Route path="/activity" component={() => readyForReads ? page : <DeploymentGate wallet={wallet} />} />
    <Route path="/invoice/:id" component={() => readyForReads ? page : <DeploymentGate wallet={wallet} />} />
    <Route component={NotFound} />
  </Switch></RoutedErrorBoundary></Shell>;
}

function RoutedErrorBoundary({ children, resetKey }: { children: ReactNode; resetKey: string }) {
  return <ErrorBoundary resetKey={resetKey}>{children}</ErrorBoundary>;
}

function App() {
  return <WagmiProvider config={walletConfig}><QueryClientProvider client={queryClient}><RainbowKitProvider><TooltipProvider><WouterRouter base={import.meta.env.BASE_URL.replace(/\/$/, '')}><RoutedApp /></WouterRouter><Toaster /></TooltipProvider></RainbowKitProvider></QueryClientProvider></WagmiProvider>;
}

export default App;