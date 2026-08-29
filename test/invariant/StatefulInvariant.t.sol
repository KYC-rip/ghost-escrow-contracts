// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {GhostEscrow} from "../../src/GhostEscrow.sol";
import {MockERC20} from "../utils/MockERC20.sol";
import {EscrowHandler} from "./EscrowHandler.sol";

/// @dev True stateful invariant run: random action sequences from the handler,
///      checking the properties that must hold no matter the path.
contract StatefulInvariantTest is Test {
    GhostEscrow internal escrow;
    MockERC20 internal token;
    EscrowHandler internal handler;

    address internal buyer = address(0xB0);
    address internal seller = address(0x5E);
    address internal arb = address(0xA4);
    address internal stranger = address(0x57);
    address internal feeRecipient = address(0xFEE5);

    uint256 internal constant AMOUNT = 4200e6;
    uint256 internal constant FEE_BPS = 150;
    uint256 internal constant ARB_FEE = 50e6;

    function setUp() public {
        token = new MockERC20("MockUSDC", "USDC", 6);
        escrow = new GhostEscrow(
            address(token), buyer, seller, arb, feeRecipient, AMOUNT, FEE_BPS, ARB_FEE, 72 hours, 14 days
        );
        address[4] memory actors = [buyer, seller, stranger, arb];
        handler = new EscrowHandler(escrow, token, actors, arb);
        targetContract(address(handler));
    }

    /// INV-1 (solvency): the escrow always holds at least what it owes —
    /// deal funds still in custody plus the arbitrator fee pot. If this ever
    /// breaks, the contract has promised funds it cannot pay.
    function invariant_SolventForWhatItOwes() public view {
        assertGe(token.balanceOf(address(escrow)), escrow.deposited() + escrow.arbitratorFeePot());
    }

    /// INV-2: deposited deal funds never exceed the exact deal amount.
    function invariant_DepositedNeverExceedsDealAmount() public view {
        assertLe(escrow.deposited(), AMOUNT);
    }

    /// INV-3: per-depositor tallies sum to `deposited` — but ONLY in
    /// non-terminal states. See FINDING 3 (M1 review): `_payDeal` decrements
    /// `deposited` without touching `depositedBy`, so after any Active→terminal
    /// payout (release/refund/rule/autoRelease/mutualSplit) the tallies go
    /// stale. Safe today only because the sole readers (`expire`,
    /// `claimExpired`) are unreachable outside Created/PartiallyDeposited/
    /// Expired — a state-machine coupling, not an explicit guarantee. If the
    /// contract adds tally cleanup on payout, widen this to all states.
    function invariant_DepositorTalliesSumToDeposited() public view {
        GhostEscrow.State s = escrow.state();
        bool terminal =
            s == GhostEscrow.State.Completed || s == GhostEscrow.State.Cancelled || s == GhostEscrow.State.Expired;
        if (!terminal) {
            assertEq(handler.sumDepositedBy(), escrow.deposited());
        }
    }

    /// INV-4 (conservation): no deal-token value is created or destroyed. Every
    /// unit ever minted into the system sits in some balance right now.
    function invariant_ValueConserved() public view {
        uint256 outside = token.balanceOf(buyer) + token.balanceOf(seller) + token.balanceOf(stranger)
            + token.balanceOf(arb) + token.balanceOf(feeRecipient) + token.balanceOf(address(escrow));
        assertEq(outside, handler.totalMintedIn());
    }

    /// INV-5: the arbitrator fee pot is only ever non-zero while Disputed.
    function invariant_FeePotOnlyWhileDisputed() public view {
        if (escrow.arbitratorFeePot() > 0) {
            assertEq(uint256(escrow.state()), uint256(GhostEscrow.State.Disputed));
        }
    }
}
