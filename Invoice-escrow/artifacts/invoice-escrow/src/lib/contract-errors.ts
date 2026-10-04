const contractErrorCopy: Record<string, string> = {
  TooEarly: 'This action is not available yet. Wait until the displayed deadline.',
  TooLate: 'The action window has closed. Check the invoice timeline for the next available step.',
  NotFunded: 'The buyer must fund this invoice before this action is available.',
  SellerLimitExceeded: 'The seller credit limit is reached. Settle an existing advance or request less.',
  UtilizationCapExceeded: 'The pool utilization cap is reached. Try a smaller advance or wait for repayments.',
  ConcentrationCapExceeded: 'The pool concentration limit is reached. Try again after pool exposure changes.',
  RiskTooHigh: 'The requested advance exceeds the current risk limit. Review the quote or try a smaller amount.',
  TenantTooLong: 'Too tenored. Shorten the time to maturity before requesting an advance.',
  OpenDispute: 'This invoice has an open dispute. Resolve it before continuing.',
  AlreadyFinanced: 'This receivable has already been financed by the pool.',
  NotReceivableOwner: 'Only the current receivable owner can perform this action.',
  NothingToClaim: 'There is no claimable balance for this address right now.',
};

export function getContractErrorMessage(error: unknown): string {
  const text = collectErrorText(error);
  const name = Object.keys(contractErrorCopy).find((candidate) =>
    new RegExp(`\\b${candidate}\\b`, 'i').test(text),
  );
  if (name) return contractErrorCopy[name];
  return text || 'The transaction could not be completed. Check your wallet and try again.';
}

function collectErrorText(error: unknown): string {
  if (typeof error === 'string') return error;
  if (!error || typeof error !== 'object') return '';

  const item = error as {
    message?: unknown;
    shortMessage?: unknown;
    cause?: unknown;
    data?: unknown;
  };
  return [
    typeof item.shortMessage === 'string' ? item.shortMessage : '',
    typeof item.message === 'string' ? item.message : '',
    typeof item.data === 'string' ? item.data : '',
    collectErrorText(item.cause),
  ]
    .filter(Boolean)
    .join(' ');
}