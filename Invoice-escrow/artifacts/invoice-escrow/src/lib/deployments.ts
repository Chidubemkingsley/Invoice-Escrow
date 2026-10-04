import { isAddress, type Address } from 'viem';
import { getSupportedChain } from './chains';

export type DeploymentFile = {
  chainId: number;
  token: Address;
  escrow: Address;
  pool: Address;
  faucetUrls?: {
    token?: string;
    gas?: string;
  };
};

type DeploymentResult =
  | { status: 'ready'; deployment: DeploymentFile }
  | { status: 'unsupported-chain'; chainId: number }
  | { status: 'missing'; chainId: number; fileName: string }
  | { status: 'invalid'; chainId: number; fileName: string; reason: string };

const deploymentModules = import.meta.glob<DeploymentFile>(
  '../../deployments/*.json',
  { eager: true, import: 'default' },
);

const deploymentFiles = new Map<string, unknown>(
  Object.entries(deploymentModules).map(([path, config]) => [
    path.split('/').at(-1) ?? '',
    config,
  ]),
);

export function resolveDeployment(chainId: number): DeploymentResult {
  const chain = getSupportedChain(chainId);
  if (!chain) return { status: 'unsupported-chain', chainId };

  const fileName = `${chainId}.json`;
  const raw = deploymentFiles.get(fileName);
  if (!raw) return { status: 'missing', chainId, fileName };

  if (!raw || typeof raw !== 'object') {
    return {
      status: 'invalid',
      chainId,
      fileName,
      reason: 'The deployment file must contain a JSON object.',
    };
  }

  const candidate = raw as Partial<DeploymentFile>;
  if (candidate.chainId !== chainId) {
    return {
      status: 'invalid',
      chainId,
      fileName,
      reason: `Expected chainId ${chainId} in ${fileName}.`,
    };
  }

  const addressEntries = [
    ['token', candidate.token],
    ['escrow', candidate.escrow],
    ['pool', candidate.pool],
  ] as const;
  const invalidEntry = addressEntries.find(
    ([, address]) => typeof address !== 'string' || !isAddress(address),
  );
  if (invalidEntry) {
    return {
      status: 'invalid',
      chainId,
      fileName,
      reason: `The ${invalidEntry[0]} address is missing or invalid.`,
    };
  }

  return {
    status: 'ready',
    deployment: candidate as DeploymentFile,
  };
}