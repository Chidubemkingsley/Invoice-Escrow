# Testnet deployment files

The app intentionally refuses to show contract-backed pages until a verified
deployment file exists for the connected chain. Do not put placeholder or
sample addresses here.

Add one JSON file per supported chain, named `<chainId>.json`:

```json
{
  "chainId": 421614,
  "token": "0x...",
  "escrow": "0x...",
  "pool": "0x...",
  "faucetUrls": {
    "token": "https://...",
    "gas": "https://..."
  }
}
```

The contract ABIs and exact function/event signatures were not included with
the frontend specification. Supply the verified ABI artifacts before enabling
reads, writes, event indexing, or transaction actions.