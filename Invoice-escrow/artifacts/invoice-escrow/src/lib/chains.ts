import { createConfig, http, injected } from 'wagmi';
import { defineChain } from 'viem';
import { arbitrumSepolia } from 'viem/chains';

export const robinhoodTestnet = defineChain({
  id: 46630,
  name: 'Robinhood Chain Testnet',
  nativeCurrency: {
    name: 'Ether',
    symbol: 'ETH',
    decimals: 18,
  },
  rpcUrls: {
    default: {
      http: ['https://rpc.testnet.chain.robinhood.com'],
    },
  },
  blockExplorers: {
    default: {
      name: 'Robinhood Testnet Explorer',
      url: 'https://explorer.testnet.chain.robinhood.com',
    },
  },
  testnet: true,
});

export const supportedChains = [arbitrumSepolia, robinhoodTestnet] as const;

const chains = supportedChains;

export const walletConfig = createConfig({
  chains,
  connectors: [injected()],
  transports: {
    [arbitrumSepolia.id]: http(),
    [robinhoodTestnet.id]: http(),
  },
});

export function getSupportedChain(chainId: number) {
  return supportedChains.find((chain) => chain.id === chainId);
}
export type SupportedChainId = (typeof supportedChains)[number]['id'];
