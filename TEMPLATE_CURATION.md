# Template Curation Checklist (Phase D — D-REV-3)

Every implementation added via `EscrowCloneFactory.addTemplate` MUST pass this
checklist in a tracked review BEFORE the `addTemplate` transaction. The checked
copy lives next to the template's review doc; the reviewer signs off per item.
Rationale: hook access to the shared ArbitratorRegistry and standing at the
AppealCourt is scoped to factory-deployed clones — a registered template is
TRUSTED CODE. The curator key can only append; this checklist is what makes
that append safe.

## Hard requirements (any failure = do not register)

1. **Initializer discipline.** `initialize(feeRecipient, platformFeeBps,
   initData)` is the only mutator callable pre-init; it requires
   `msg.sender == FACTORY`, is one-shot, and the implementation constructor
   self-locks (`_initialized = true`) so the bare implementation can never be
   a deal.
2. **Eligibility gate.** `initialize` calls
   `registry.isEligible(arbitrator, dealAmount)` (or the template's total
   value) and reverts otherwise, BEFORE any state becomes fundable (§5.1-C,
   relocated per plan §2.1).
3. **Court gate.** `initialize` requires `registry.court() != address(0)`.
4. **Bounded dispute lifecycle.** Every path that calls
   `registry.onDisputeOpened`/`onAssigned` has a guaranteed terminal path that
   calls `onResolved` (ruling, mutual exit, SLA slash, or court settlement) —
   no template may be able to pin an arbitrator's `openCases` forever
   (D-REV-2 residual). **No auto-opened disputes** (only an explicit action by
   a deal PARTY may open a dispute) and the per-dispute `arbitratorFee` must
   be bounded and pre-paid by the opener. Rationale (review F1): a template
   that could open disputes programmatically would turn the pre-existing
   per-deal SLA-slash griefing class (open dispute on an unaware arbitrator,
   wait SLA_DURATION, trigger the 10% slash) into scripted, near-zero-cost
   loss across many arbitrators — curation must exclude that shape outright.
5. **Court-callback surface.** If the template uses appeals/panels it exposes
   the court-expected selectors (`buyer()`, `seller()`, `dealAmount()`,
   `token()`, `settleAppealUphold()`, `settleAppealOverturn(uint256,uint256)`)
   with court-only auth on the settle callbacks, and opens a new case only
   when no case is in flight (sequential-case contract, court `_request`).
6. **No delegatecall out, no selfdestruct, no admin.** The template's clones
   hold user funds; the implementation must contain no delegatecall to
   external targets, no selfdestruct, no owner/admin paths, no upgrade hooks.
7. **Storage ownership.** Clones delegate to exactly one implementation
   forever; the template must not assume or share storage layout with any
   other contract.
8. **CEI + reentrancy.** State transitions before external transfers;
   nonReentrant on fund-moving entrypoints (match GhostEscrowV2CImpl
   discipline).
9. **Reproducible build.** Compiled with the repo profile (solc pinned,
   `via_ir = false`, `bytecode_hash = "none"`, `cbor_metadata = false`);
   the `TemplateAdded.codehash` must equal the source-built
   `keccak256(deployedBytecode)` and be recorded in the review doc.
10. **Tests.** Template-specific forge suite green, including: initialize
    auth/one-shot, eligibility/court gates, full lifecycle happy + dispute
    paths, hook accounting (openCases up/down), and — if appealable — court
    integration (uphold, overturn, dismiss).

## Process

- Reviewer: independent of the author (opencode or Claude, whichever did not
  write the template), scored review, pass >= 7.0 / no dim <= 3.
- Register on testnet first; run a browser-acceptance pass against the live
  stack before the mainnet `addTemplate`.
- Before any registration, run an **initialize probe on a fork** (review F4):
  clone the implementation via a fork of the target chain, call
  `createDeal` with representative initData, and confirm the full
  create→initialize path succeeds — a non-conforming listing is harmless
  (first createDeal reverts) but must never reach mainnet.
- Mainnet: `activationDelay` (48h) gives watchers the diff window — publish
  the implementation address + codehash + source ref when the
  `TemplateAdded` tx lands.

## Registered templates

| Template | Implementation | Codehash | Review | Registered |
|----------|----------------|----------|--------|------------|
| GhostEscrowV2CImpl (standard) | (per deployments-v3.json) | (record at deploy) | Phase D review | (pending) |
| GhostEscrowV2OpenCImpl (open/claim-link) | (per deployments-v3.json) | (record at deploy) | Phase D review | (pending) |
