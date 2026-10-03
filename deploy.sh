#!/usr/bin/env bash
# Usage:
#   ./deploy.sh deploy <network> [--verify]    deploy contracts, writes deployments/<chainid>.json
#   ./deploy.sh demo   <network>               run the full invoice -> advance -> settle flow
# Networks: arbitrum_sepolia | robinhood_testnet | arbitrum_one | robinhood_mainnet | <any rpc url / anvil>
set -euo pipefail
cd "$(dirname "$0")"

CMD="${1:-}"; NET="${2:-}"; EXTRA="${3:-}"
[[ -z "$CMD" || -z "$NET" ]] && { sed -n '2,6p' "$0"; exit 1; }
[[ -f .env ]] && { set -a; source .env; set +a; }
: "${PRIVATE_KEY:?PRIVATE_KEY is not set (copy .env.example to .env)}"
command -v forge >/dev/null || { echo "forge not found: install Foundry (https://getfoundry.sh)"; exit 1; }
[[ -d lib/openzeppelin-contracts ]] || forge install OpenZeppelin/openzeppelin-contracts@v5.1.0 foundry-rs/forge-std

case "$NET" in
  arbitrum_one|robinhood_mainnet)
    read -r -p "!! MAINNET ($NET). Real funds. Type 'mainnet' to continue: " ok
    [[ "$ok" == "mainnet" ]] || { echo aborted; exit 1; } ;;
esac

# Arbitrum-stack chains charge an L1 data fee that forge's local simulation can under-estimate;
# a gas multiplier avoids "intrinsic gas too low". --slow sends txs one by one (the demo is order-dependent).
FLAGS=(--rpc-url "$NET" --broadcast --slow --gas-estimate-multiplier "${GAS_MULT:-200}")

case "$CMD" in
  deploy)
    if [[ "$EXTRA" == "--verify" ]]; then
      case "$NET" in
        robinhood_testnet) FLAGS+=(--verify --verifier blockscout --verifier-url https://explorer.testnet.chain.robinhood.com/api/) ;;
        robinhood_mainnet) FLAGS+=(--verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/) ;;
        *) : "${ETHERSCAN_API_KEY:?set ETHERSCAN_API_KEY to verify on Arbiscan}"; FLAGS+=(--verify) ;;
      esac
    fi
    forge script script/Deploy.s.sol "${FLAGS[@]}" ;;
  demo)
    : "${SELLER_KEY:?}"; : "${BUYER_KEY:?}"
    forge script script/Demo.s.sol "${FLAGS[@]}" ;;
  *) echo "unknown command: $CMD"; exit 1 ;;
esac
