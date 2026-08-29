# ghost-escrow-contracts

Immutable, no-admin escrow contracts for [Ghost Escrow](https://escrow.kyc.rip)
(kyc.rip) — deals between strangers, funds locked by code, disputes settled by
staked, slashable arbitrators. No owner keys, no upgrades, no admin backdoor:
once a deal exists, nobody — including us — can change its rules.

> **Status: testnet.** These contracts run on Sepolia today. An independent
> security review is scheduled before any mainnet deployment.

## Current version — Arbitrator Model v2 + clone factory 

Live on **Sepolia** (v4 triad, security batch of 2026-08-29, all sources
[verified on Sourcify](https://sourcify.dev)):

| Contract | Address |
|---|---|
| `ArbitratorRegistry` | `0xE39dDD8b10Fb5b054688E6b14CCA2D01388DBA08` |
| `EscrowCloneFactory` | `0x40D9Daed6A705e2001F52E73266e45c1a71A35fd` |
| `AppealCourt` | `0x0f9C57234Cf133eA4B715Eb280B2F3Cac75c8a36` |
| `GhostEscrowV2CImpl` | `0x74fFF29f57d943A6784Dc28EDb4Be748588C4443` |
| `GhostEscrowV2OpenCImpl` | `0x05a2538F73e704Cb9dB0E5E8011327333e5AB5Bd` |

Deploy record: `deployments-v3.json`. Every deal is an EIP-1167 clone of a
template implementation; templates are append-only (`addTemplate`, 48h timelock
on mainnet) and **existing deals never migrate** — each runs to completion on
the code it was created with.

Reproduce + verify:

```bash
forge build && forge test          # 290 tests
cast codehash <address> --rpc-url <rpc>   # compare against your own build
```

The v1.1 reference notes below describe the original single-template design and
remain accurate for the frozen legacy contracts (`GhostEscrow`, `EscrowFactory`,
`GhostEscrowV2`, `GhostEscrowV2Open`).

## Contracts

- **`src/GhostEscrow.sol`** — one immutable contract per deal. State advances only
  through deposits, signed mutual actions (EIP-712, nonce + deadline), an arbitrator
  ruling, or permissionless timeouts. No owner, no admin, no upgrade path.
- **`src/EscrowFactory.sol`** — CREATE2 deployer (`predictAddress` + `createEscrow`),
  event-only registry, holds no funds.

## Key semantics (v1.1)

- Mutual actions (`release` / `refund` / `mutualSplit` / `replaceArbitrator` /
  `rescueToken`) require **both** parties' EIP-712 signatures, bound to the current
  nonce **and** a deadline — stale or replayed signatures never work.
- Mutual settlement is allowed from `Disputed`; the pre-paid arbitrator fee pot
  returns to the dispute opener when no ruling was rendered.
- Deposits are credited by balance delta (fee-on-transfer safe) and tracked per
  depositor; expiry refunds go to whoever actually paid (`claimExpired`).
- `syncDeposit()` credits tokens transferred directly to the deal address (e.g. a
  Monero→USDC swap into the CREATE2-predicted address) to the buyer.
- `autoReleaseDelay` is a per-deal parameter (1–90 days); silence = acceptance pays
  the seller — a surfaced product choice.
- `rescueToken()` can recover deal-token dust only once the deal is fully settled;
  live deal funds can never be siphoned.
- On-record decisions (see REVIEW #9–14): no on-chain ruling SLA; ties favor the
  dispute opener; mutual refunds pay the platform fee; expiry is fee-free.

## Tooling

- Foundry (`forge`). Solc pinned `0.8.28`; OZ contracts `5.3.0` (npm).
- `npm run test` / `forge test` — 117 tests: state machine, mutual actions,
  disputes, timeouts, rescue matrix, factory/CREATE2, cross-deal signature
  isolation, fuzz + conservation invariants.
- `npm run export:abi` → `abi/*.json` consumed by the app + indexer.
- `npm run deploy:testnet` — see `script/Deploy.s.sol` (env: `RPC_URL`,
  `PRIVATE_KEY`, `FEE_RECIPIENT`, `PLATFORM_FEE_BPS`).

## Layout

```
src/        contracts (v1.1 reference)
test/       unit + fuzz suites
script/     deploy scripts
abi/        exported ABIs (npm run export:abi)
```

## Releases & versioning

- New template versions ship through the factory's append-only `addTemplate`,
  behind an on-chain activation timelock (48h on mainnet) — the codehash is
  public and diffable before any deal can use a new template.
- Existing deals never migrate: every deal runs to completion on the exact code
  it was created with, and superseded versions stay listed here as
  frozen-but-valid.
- Each release publishes addresses + codehashes in `deployments-*.json` and is
  source-verified (Sourcify, Etherscan) before it is announced.
