# Ghost Escrow v2 — vanity CREATE3 deploy runbook

Operationalizes `script/DeployV.s.sol` with the **final** ground salts in
`vanity-salts.json` (grinder complete 2026-09-02; derivation re-verified).
This runbook is the *how*; the *whether/when* gates live in
`plans/ghost-escrow-mainnet-launch-checklist.md` and key custody in
`plans/ghost-escrow-ops-manual.md §D`. Do not deploy mainnet until the checklist
gates (chain, economics constants, 3 fresh keys, ≥4 arbitrators) are all met.

## The addresses you are buying

Each is `Create3Factory.predict(opsDeployer, salt)` and is identical on every
chain **iff** the three invariants below hold. Suffixes are asserted on-chain by
`DeployV`, so a wrong key/salt/factory fails loudly instead of deploying a
non-vanity address.

| Contract | Suffix | Address |
|---|---|---|
| registry (`ArbitratorRegistry`) | `5afe` | `0x000000aeee00daeaaa9e776db4bf451a5ece5afe` |
| factory (`EscrowCloneFactory`) | `fac7` | `0x000000d0c13fe25337697704a8a92fd854e8fac7` |
| court (`AppealCourt`) | `5ea1` | `0x0000009193e7460be143a4d86e18cce5803f5ea1` |
| stdImpl (`GhostEscrowV2CImpl`) | `dea1` | `0x0000006fa0db6f1706d236b2a18a594decb7dea1` |
| openImpl (`GhostEscrowV2OpenCImpl`) | `dea1` | `0x0000004e500a57fe572e914e4bb4a88cc4f4dea1` |

> **Two templates, both `dea1`.** `DeployV` deploys the standard *and* open
> escrow implementations (why `dea1` was ground with `wanted=2`). If a single
> template is ever desired, that is a `DeployV` change — trim `openImpl` +
> `SALT_OPEN` and drop `addTemplate(openImpl)`.

## The three invariants (else every address silently diverges)

1. **Factory placement.** `Create3Factory` MUST sit at
   `0xC0d740C874aD65Bb9d108769C9B9A9Ff7453033e` — i.e. the **bootstrap EOA**
   (`vanity-keys.key`, ops manual §D) at **nonce 0**. That EOA signs exactly one
   tx per chain, ever.
2. **Ops deployer.** `DeployV` MUST broadcast from
   `0x4d0E5F0f2B6Fbd35E0850dBC7747306AF9Ba7D5B` (the **ops EOA**) — `msg.sender`
   is the salt namespace.
3. **Proxy hash.** `Create3Factory.PROXY_INITCODE_HASH()` MUST equal
   `0x21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f`. Frozen
   proxy bytecode; `DeployV` refuses a factory whose codehash ≠ this repo's build.

## Step 0 — bootstrap the factory (once per chain)

```bash
forge script script/DeployV.s.sol:DeployC3Factory \
  --rpc-url <chain> --private-key $BOOTSTRAP_KEY --broadcast
```
Assert the logged `create3 factory:` == `0xC0d740…3033e` and `proxy initcode
hash:` == `0x21c35dbe…497c1f`. If either differs, **stop** — the bootstrap key
or its nonce is wrong and the vanity addresses will not reproduce.

## Step 1 — deploy the triad + templates (ops key)

Env is lifted straight from `vanity-salts.json` plus the economics constants
signed off in launch-checklist §3.

```bash
export CREATE3_FACTORY=0xC0d740C874aD65Bb9d108769C9B9A9Ff7453033e
export OPS=0x4d0E5F0f2B6Fbd35E0850dBC7747306AF9Ba7D5B   # asserts key == namespace
export EXPECTED_CHAIN_ID=<chain-id>
export ACTIVATION_DELAY=172800                           # 48h template timelock

# --- economics (launch-checklist §3; example values — confirm before mainnet) ---
export STAKING_TOKEN=0x…        # chain's canonical USDC
export FEE_RECIPIENT=0x…        # fresh, hardware-backed, never KYC-linked
export CURATOR=0x…              # fresh offline key (mainnet); ops manual §D
export PLATFORM_FEE_BPS=150
export MIN_STAKE=50000000                 # 50 USDC (6dp)
export HIGH_VALUE_THRESHOLD=25000000000   # 25,000 USDC

# --- salts (verbatim from vanity-salts.json) ---
export SALT_REGISTRY=0x023100000000000000000000000000000000000000000000b3b7588212000000
export SALT_FACTORY=0x069800000000000000000000000000000000000000000000f3186f0103000000
export SALT_COURT=0x00310000000000000000000000000000000000000000000035ffd7ad63000000
export SALT_STD=0x023100000000000000000000000000000000000000000000fdd6d7d806000000
export SALT_OPEN=0x033100000000000000000000000000000000000000000000e08bf9c00a000000

# dry-run first (no --broadcast): confirm the 5 predicted addresses match the table
forge script script/DeployV.s.sol:DeployV --rpc-url <chain> --private-key $OPS_KEY
# then broadcast
forge script script/DeployV.s.sol:DeployV --rpc-url <chain> --private-key $OPS_KEY --broadcast
```

`DeployV` self-checks: factory codehash, each predicted address's suffix, `ops ==
OPS`, and post-deploy that registry/factory/court are bound and `registry.deployer
== ops`. On success it writes `deployments-vanity.json`.

If `CURATOR != OPS` (mainnet two-key flow), templates are **not** registered by
`DeployV` — run step 2 with the curator key. If `CURATOR == OPS` (testnet
rehearsal) they are inlined and step 2 is skipped.

## Step 2 — register templates (curator key, mainnet only)

```bash
FACTORY=0x000000d0c13fe25337697704a8a92fd854e8fac7 \
STD_IMPL=0x0000006fa0db6f1706d236b2a18a594decb7dea1 \
OPEN_IMPL=0x0000004e500a57fe572e914e4bb4a88cc4f4dea1 \
EXPECTED_CHAIN_ID=<chain-id> \
  forge script script/DeployV.s.sol:AddTemplates --rpc-url <chain> \
  --private-key $CURATOR_KEY --broadcast
```

## Step 3 — post-deploy

- Verify all 5 sources on the chain explorer (users must read the code).
- Transfer/renounce curator per ops manual §D; run a small canary deal end-to-end.
- Update the frontend `deployments-v*.json` + `/contracts` page **only after** the
  addresses are live and verified on-chain (not before).

## If you need to re-verify the salts

```bash
node - <<'JS'  # or reuse the scratchpad verify.mjs
# predict(salt) = keccak(0xd694 ‖ keccak(0xff ‖ factory ‖ keccak(ops‖salt) ‖ PROXY_HASH)[12:] ‖ 0x01)[12:]
JS
```
All five reproduce their table address under the invariants above (checked
2026-09-02). Spares (same suffix, if a salt is ever burned) are in
`vanity-salts.json.spares`.
