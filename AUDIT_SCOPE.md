# Ghost Escrow — External Audit Scope (prep)

**Status:** prep complete · **Audit:** not engaged — operator decision
**Target:** `src/GhostEscrow.sol` (v1.1) + `src/EscrowFactory.sol` (v1.1), Solc 0.8.28, OZ 5.3.0

## Scope

The two contracts, as deployed via `script/Deploy.s.sol`. No proxy, no admin,
no upgrade path exists. Solidity only — the app, API, and Nostr/PGP/Shamir layers
are out of audit scope (separate review).

## In-scope invariants (what the audit must verify)

1. **No admin/escape hatch:** no owner, pause, drain, or upgrade function; immutability
   of deal params post-deploy.
2. **Fund conservation:** `deposited` never exceeds `dealAmount`; sum of all payouts
   == deposits (+ fee pot); no path leaves funds stuck (except deliberate per-claimant
   expiry refunds); rounding dust absorbed without loss.
3. **Mutual-action integrity:** both parties' EIP-712 sigs required (verifyingContract
   = deal address → cross-deal isolation); nonce burn prevents replay; deadline
   prevents stale-signature springing; correct domains/typehashes.
4. **Dispute correctness:** fee pot never mixed with deal funds; tie → opener wins
   (on record); ruling requires `buyerAmount + sellerAmount == dealAmount`; fee math
   pre-fee rule / post-fee payout.
5. **Timeout correctness:** 72h deposit window; expiry fee-free with per-depositor
   refunds; auto-release (1–90d) only from Active; frozen by dispute.
6. **Deposit paths:** balance-delta crediting (FoT-safe); `syncDeposit` credit-to-buyer;
   excess refunds; third-party deposits.
7. **Rescue matrix:** stray tokens rescuable; deal token only when fully settled
   (terminal + `deposited == 0` + pot empty).
8. **CREATE2:** `predictAddress` == deployed address for identical terms.

## Reference material

- `REVIEW-2026-08-19.md` (bundle) — findings + on-record decisions (#1–14).
- `test/` — 117 tests incl. fuzz + conservation invariants (the audit team should
  review test adequacy, not rely on it).
- Spec §6 (Trust & atomicity) and §9 (contract architecture) of the design bundle.

## Known non-goals (documented, deliberately out)

- On-chain ruling SLA (decision #9) — mitigated by mutual settlement/replacement.
- Smart-wallet (ERC-1271) support — EOA/burner only, enforced at app layer.
- Gas optimization beyond `optimizer_runs = 200`.
