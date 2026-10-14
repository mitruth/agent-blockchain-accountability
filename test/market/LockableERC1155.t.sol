// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC1155Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LockableERC1155} from "../../contracts/market/LockableERC1155.sol";
import {EnergyTokenIds} from "../../contracts/market/EnergyTokenIds.sol";
import {MarketTypes} from "../../contracts/market/MarketTypes.sol";

/// The market's token on its own: payment (id 0) and energy tokens, and the
/// locks that make collateral mean something. Each test is one rule of the
/// port; decision log entries 2.32 onward say why each rule is there.
contract LockableERC1155Test is Test {
    LockableERC1155 internal token;

    address internal registrar = makeAddr("marketManager");
    address internal minter = makeAddr("prosumerContract");
    address internal owner = makeAddr("prosumerAccount");
    address internal seller = makeAddr("sellerAccount");
    address internal stranger = makeAddr("stranger");

    uint40 internal constant SLOT_START = 1_760_007_600;

    function setUp() public {
        token = new LockableERC1155("ENERGY_MARKET", "");
        token.setRegistrar(registrar);
        vm.prank(registrar);
        token.setMinter(minter, true);
        token.mintPayment(owner, 1_000_000);
    }

    // ------------------------------------------------------------------
    // Roles and minting
    // ------------------------------------------------------------------

    function test_onlyTheIssuerMintsPayment() public {
        vm.expectRevert(abi.encodeWithSelector(LockableERC1155.LockableERC1155_OnlyIssuer.selector, stranger));
        vm.prank(stranger);
        token.mintPayment(stranger, 1);

        assertEq(token.balanceOf(owner, 0), 1_000_000);
    }

    function test_theRegistrarIsSetOnceByTheIssuer() public {
        vm.expectRevert(LockableERC1155.LockableERC1155_RegistrarAlreadySet.selector);
        token.setRegistrar(stranger);

        LockableERC1155 fresh = new LockableERC1155("X", "");
        vm.expectRevert(abi.encodeWithSelector(LockableERC1155.LockableERC1155_OnlyIssuer.selector, stranger));
        vm.prank(stranger);
        fresh.setRegistrar(stranger);
    }

    function test_onlyTheRegistrarAppointsMinters() public {
        vm.expectRevert(abi.encodeWithSelector(LockableERC1155.LockableERC1155_OnlyRegistrar.selector, stranger));
        vm.prank(stranger);
        token.setMinter(stranger, true);

        assertFalse(token.isMinter(stranger));
    }

    function test_aMinterMintsAnEnergyTokenWithItsSlotAndTypeInTheId() public {
        vm.prank(minter);
        uint256 id = token.mintEnergy(owner, SLOT_START, MarketTypes.EnergyType.HEAT, 1500);

        assertTrue(id != 0);
        assertEq(token.balanceOf(owner, id), 1500);
        assertTrue(EnergyTokenIds.isEnergy(id));
        assertEq(EnergyTokenIds.minter(id), minter);
        assertEq(EnergyTokenIds.slotStart(id), SLOT_START);
        assertEq(uint8(EnergyTokenIds.energyType(id)), uint8(MarketTypes.EnergyType.HEAT));
    }

    function test_energyIdsAreDistinct() public {
        vm.startPrank(minter);
        uint256 a = token.mintEnergy(owner, SLOT_START, MarketTypes.EnergyType.ELECTRICITY, 1);
        uint256 b = token.mintEnergy(owner, SLOT_START, MarketTypes.EnergyType.ELECTRICITY, 1);
        vm.stopPrank();

        assertTrue(a != b);
    }

    function test_onlyAnAppointedMinterMintsEnergy() public {
        vm.expectRevert(abi.encodeWithSelector(LockableERC1155.LockableERC1155_NotMinter.selector, stranger));
        vm.prank(stranger);
        token.mintEnergy(stranger, SLOT_START, MarketTypes.EnergyType.ELECTRICITY, 1);

        vm.prank(registrar);
        token.setMinter(minter, false);
        vm.expectRevert(abi.encodeWithSelector(LockableERC1155.LockableERC1155_NotMinter.selector, minter));
        vm.prank(minter);
        token.mintEnergy(owner, SLOT_START, MarketTypes.EnergyType.ELECTRICITY, 1);
    }

    function test_aZeroQuantityIsNotMinted() public {
        vm.expectRevert(LockableERC1155.LockableERC1155_ZeroQuantity.selector);
        vm.prank(minter);
        token.mintEnergy(owner, SLOT_START, MarketTypes.EnergyType.ELECTRICITY, 0);
    }

    // ------------------------------------------------------------------
    // Locking
    // ------------------------------------------------------------------

    function test_theOwnerLocksItsOwnBalance() public {
        vm.prank(owner);
        token.lock(owner, 300_000, minter);

        assertEq(token.lockedBalanceOf(owner), 300_000);
        assertEq(token.unlockedBalanceOf(owner), 700_000);
        assertEq(token.lockedBy(owner, owner, minter), 300_000);
    }

    /// The prosumer contract locks its owner's collateral. It needs an
    /// allowance, and each lock uses up as much: the allowance cannot be spent
    /// twice.
    function test_aLockerUsesUpTheOwnersAllowance() public {
        vm.prank(owner);
        token.setPaymentAllowance(minter, 300_000);

        vm.prank(minter);
        token.lock(owner, 200_000, minter);
        assertEq(token.paymentAllowance(owner, minter), 100_000);

        vm.expectRevert(
            abi.encodeWithSelector(
                LockableERC1155.LockableERC1155_InsufficientAllowance.selector, owner, minter, 100_000, 200_000
            )
        );
        vm.prank(minter);
        token.lock(owner, 200_000, minter);

        assertEq(token.lockedBalanceOf(owner), 200_000);
    }

    /// The flaw this port closes: in the original anyone could lock anyone's
    /// balance with themselves as unlocker, then release it to themselves.
    function test_aStrangerCannotLockSomeoneElsesBalance() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                LockableERC1155.LockableERC1155_InsufficientAllowance.selector, owner, stranger, 0, 1
            )
        );
        vm.prank(stranger);
        token.lock(owner, 1, stranger);

        assertEq(token.lockedBalanceOf(owner), 0);
    }

    function test_nothingBeyondTheUnlockedBalanceIsLocked() public {
        vm.startPrank(owner);
        token.lock(owner, 900_000, minter);
        vm.expectRevert(
            abi.encodeWithSelector(
                LockableERC1155.LockableERC1155_InsufficientUnlocked.selector, owner, 100_000, 100_001
            )
        );
        token.lock(owner, 100_001, minter);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Releasing
    // ------------------------------------------------------------------

    function test_theUnlockerReleasesWithoutPayment() public {
        vm.prank(owner);
        token.lock(owner, 300_000, minter);

        vm.prank(minter);
        token.unlock(owner, owner, 100_000, address(0));

        assertEq(token.lockedBalanceOf(owner), 200_000);
        assertEq(token.balanceOf(owner, 0), 1_000_000);
    }

    /// How a buyer pays a seller: the buyer's lock is released into the
    /// seller's balance.
    function test_theUnlockerReleasesAsAPayment() public {
        vm.prank(owner);
        token.lock(owner, 300_000, minter);

        vm.prank(minter);
        token.unlock(owner, owner, 120_000, seller);

        assertEq(token.balanceOf(seller, 0), 120_000);
        assertEq(token.balanceOf(owner, 0), 880_000);
        assertEq(token.lockedBalanceOf(owner), 180_000);
    }

    function test_onlyTheNamedUnlockerReleases() public {
        vm.prank(owner);
        token.lock(owner, 300_000, minter);

        vm.expectRevert(
            abi.encodeWithSelector(
                LockableERC1155.LockableERC1155_InsufficientLock.selector, owner, owner, stranger, 0, 1
            )
        );
        vm.prank(stranger);
        token.unlock(owner, owner, 1, stranger);
    }

    function test_noMoreIsReleasedThanWasLocked() public {
        vm.prank(owner);
        token.lock(owner, 300_000, minter);

        vm.expectRevert(
            abi.encodeWithSelector(
                LockableERC1155.LockableERC1155_InsufficientLock.selector, owner, owner, minter, 300_000, 300_001
            )
        );
        vm.prank(minter);
        token.unlock(owner, owner, 300_001, address(0));
    }

    /// A lock names its owner. The unlocker of one owner's lock has no hold on
    /// another owner's balance.
    function test_aLockIsTiedToItsOwner() public {
        token.mintPayment(seller, 500_000);
        vm.prank(owner);
        token.lock(owner, 300_000, minter);

        vm.expectRevert(
            abi.encodeWithSelector(
                LockableERC1155.LockableERC1155_InsufficientLock.selector, seller, owner, minter, 0, 1
            )
        );
        vm.prank(minter);
        token.unlock(seller, owner, 1, minter);

        assertEq(token.balanceOf(seller, 0), 500_000);
    }

    function test_unlockAllReleasesTheWholeLock() public {
        vm.prank(owner);
        token.lock(owner, 300_000, minter);

        vm.prank(minter);
        uint256 released = token.unlockAll(owner, owner);

        assertEq(released, 300_000);
        assertEq(token.lockedBalanceOf(owner), 0);
        assertEq(token.lockedBy(owner, owner, minter), 0);
    }

    // ------------------------------------------------------------------
    // Locked means locked
    // ------------------------------------------------------------------

    /// The second flaw this port closes: in the original the owner's own
    /// transfers skipped the locked-balance check.
    function test_theOwnerCannotMoveLockedPayment() public {
        vm.startPrank(owner);
        token.lock(owner, 300_000, minter);

        vm.expectRevert(
            abi.encodeWithSelector(
                LockableERC1155.LockableERC1155_LockedBalanceMoved.selector, owner, 299_999, 300_000
            )
        );
        token.safeTransferFrom(owner, stranger, 0, 700_001, "");

        // The unlocked part moves freely.
        token.safeTransferFrom(owner, stranger, 0, 700_000, "");
        vm.stopPrank();

        assertEq(token.balanceOf(owner, 0), 300_000);
    }

    function test_anOperatorApprovedForAllCannotMoveLockedPayment() public {
        vm.startPrank(owner);
        token.lock(owner, 300_000, minter);
        token.setApprovalForAll(stranger, true);
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(
                LockableERC1155.LockableERC1155_LockedBalanceMoved.selector, owner, 0, 300_000
            )
        );
        vm.prank(stranger);
        token.safeTransferFrom(owner, stranger, 0, 1_000_000, "");
    }

    function test_lockedPaymentCannotLeaveInABatch() public {
        vm.prank(minter);
        uint256 energyId = token.mintEnergy(owner, SLOT_START, MarketTypes.EnergyType.ELECTRICITY, 10);
        vm.startPrank(owner);
        token.lock(owner, 300_000, minter);

        uint256[] memory ids = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        ids[0] = energyId;
        amounts[0] = 10;
        ids[1] = 0;
        amounts[1] = 800_000;
        vm.expectRevert(
            abi.encodeWithSelector(
                LockableERC1155.LockableERC1155_LockedBalanceMoved.selector, owner, 200_000, 300_000
            )
        );
        token.safeBatchTransferFrom(owner, stranger, ids, amounts, "");
        vm.stopPrank();
    }

    /// Whatever is locked, and whatever is then attempted, the owner's payment
    /// balance never drops below its locked balance.
    function testFuzz_aTransferNeverDipsIntoTheLock(uint256 locked, uint256 sent) public {
        locked = bound(locked, 0, 1_000_000);
        sent = bound(sent, 0, 1_000_000);

        vm.startPrank(owner);
        token.lock(owner, locked, minter);
        try token.safeTransferFrom(owner, stranger, 0, sent, "") {} catch {}
        vm.stopPrank();

        assertGe(token.balanceOf(owner, 0), token.lockedBalanceOf(owner));
        assertEq(token.lockedBalanceOf(owner), locked);
    }

    // ------------------------------------------------------------------
    // Burning
    // ------------------------------------------------------------------

    function test_energyIsBurnedByItsHolderOrAnApprovedOperatorOnly() public {
        vm.prank(minter);
        uint256 id = token.mintEnergy(owner, SLOT_START, MarketTypes.EnergyType.ELECTRICITY, 100);

        vm.expectRevert(abi.encodeWithSelector(LockableERC1155.LockableERC1155_NotApproved.selector, stranger, owner));
        vm.prank(stranger);
        token.burnEnergy(owner, id, 10);

        vm.prank(owner);
        token.burnEnergy(owner, id, 10);

        vm.prank(owner);
        token.setApprovalForAll(minter, true);
        vm.prank(minter);
        token.burnEnergy(owner, id, 20);

        assertEq(token.balanceOf(owner, id), 70);
    }

    function test_paymentCannotBeBurned() public {
        vm.expectRevert(abi.encodeWithSelector(LockableERC1155.LockableERC1155_NotEnergy.selector, 0));
        vm.prank(owner);
        token.burnEnergy(owner, 0, 1);
    }
}
