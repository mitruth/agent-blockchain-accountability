// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MarketFixture} from "./MarketFixture.sol";
import {MarketManager} from "../../contracts/market/MarketManager.sol";
import {MarketSession} from "../../contracts/market/MarketSession.sol";
import {Prosumer} from "../../contracts/market/Prosumer.sol";
import {LockableERC1155} from "../../contracts/market/LockableERC1155.sol";
import {MarketTypes} from "../../contracts/market/MarketTypes.sol";

/// The ported P2P market on its own, phase by phase as in thesis figure 3.3:
/// registration, session, orders with collateral, matching, commitments,
/// expiry, settlement. Owners are plain addresses; PolicyGate is not involved.
///
/// Numbers: a bid of 2000 Wh at 0.25/kWh locks 500,000; an offer of 2000 Wh
/// locks 2000 Wh at the real-time 0.30/kWh, 600,000.
contract MarketFlowTest is MarketFixture {
    // ------------------------------------------------------------------
    // Orders and collateral
    // ------------------------------------------------------------------

    function test_aBatchOfBidsLocksEachBidAtItsLimitPrice() public {
        MarketTypes.OrderRequest[] memory reqs = new MarketTypes.OrderRequest[](3);
        reqs[0] = _req(0, 2000, 250_000);
        reqs[1] = _req(1, 1000, 260_000);
        reqs[2] = _req(23, 500, 240_000);

        vm.prank(alice);
        bytes32[] memory ids = aliceP.placeBids(MarketTypes.EnergyType.ELECTRICITY, reqs);

        assertEq(ids.length, 3);
        assertEq(token.lockedBalanceOf(alice), 500_000 + 260_000 + 120_000);

        MarketTypes.Order memory o = session.orderOf(ids[2]);
        assertEq(uint8(o.side), uint8(MarketTypes.Side.BID));
        assertEq(uint8(o.status), uint8(MarketTypes.OrderStatus.OPEN));
        assertEq(o.prosumer, address(aliceP));
        assertEq(o.account, alice);
        assertEq(o.slot, firstSlot + 23);
        assertEq(o.quantity, 500);
        assertEq(o.price, 240_000);
        assertEq(o.tokenId, 0);
        assertEq(session.bidIds().length, 3);
    }

    function test_anOfferMintsItsEnergyAndLocksAtTheRealTimePrice() public {
        bytes32 id = _offer(0, 2000, 200_000);

        uint256 tokenId = session.orderOf(id).tokenId;
        assertTrue(tokenId != 0);
        assertEq(token.balanceOf(bob, tokenId), 2000);
        assertEq(token.lockedBalanceOf(bob), 600_000);
        assertEq(session.offerIds().length, 1);
    }

    function test_orderIdsAreUniqueAcrossSessions() public {
        bytes32 first = _bid(0, 100, 250_000);
        _open(MarketTypes.EnergyType.ELECTRICITY, firstSlot + 24, 24);
        bytes32 second = _bid(0, 100, 250_000);

        assertTrue(first != second);
    }

    function test_ordersOutsideTheSessionAreRefused() public {
        vm.expectRevert(abi.encodeWithSelector(Prosumer.Prosumer_BadSlot.selector, 24, 24));
        vm.prank(alice);
        aliceP.placeBids(MarketTypes.EnergyType.ELECTRICITY, _one(24, 100, 250_000));

        vm.expectRevert(MarketSession.MarketSession_ZeroQuantity.selector);
        vm.prank(alice);
        aliceP.placeBids(MarketTypes.EnergyType.ELECTRICITY, _one(0, 0, 250_000));

        vm.expectRevert(MarketSession.MarketSession_ZeroPrice.selector);
        vm.prank(alice);
        aliceP.placeBids(MarketTypes.EnergyType.ELECTRICITY, _one(0, 100, 0));
    }

    function test_noOrderOnceTheSessionHasClosed() public {
        _close();
        vm.expectRevert(abi.encodeWithSelector(MarketSession.MarketSession_Closed.selector, session.config().closesAt));
        vm.prank(alice);
        aliceP.placeBids(MarketTypes.EnergyType.ELECTRICITY, _one(0, 100, 250_000));
    }

    function test_collateralBeyondTheBalanceIsRefused() public {
        // 4,000,001 Wh at 0.25 per kWh needs 1,000,000,250.
        vm.expectRevert(
            abi.encodeWithSelector(
                LockableERC1155.LockableERC1155_InsufficientUnlocked.selector, alice, FUNDS, 1_000_000_250
            )
        );
        vm.prank(alice);
        aliceP.placeBids(MarketTypes.EnergyType.ELECTRICITY, _one(0, 4_000_001, 250_000));
    }

    // ------------------------------------------------------------------
    // Cancel and modify, until the session closes
    // ------------------------------------------------------------------

    function test_cancelReleasesCollateralAndBurnsTheOffersEnergy() public {
        bytes32 bidId = _bid(0, 2000, 250_000);
        bytes32 offerId = _offer(0, 2000, 200_000);
        uint256 tokenId = session.orderOf(offerId).tokenId;

        vm.prank(alice);
        aliceP.cancelOrder(bidId);
        vm.prank(bob);
        bobP.cancelOrder(offerId);

        assertEq(token.lockedBalanceOf(alice), 0);
        assertEq(token.lockedBalanceOf(bob), 0);
        assertEq(token.balanceOf(bob, tokenId), 0);
        assertEq(uint8(session.orderOf(bidId).status), uint8(MarketTypes.OrderStatus.CANCELLED));
    }

    /// The session takes a cancellation only from the prosumer contract that
    /// placed the order. Anyone else, calling the session directly, is
    /// refused, and the order stays open.
    function test_onlyTheOrdersProsumerCancelsItInTheSession() public {
        bytes32 bidId = _bid(0, 2000, 250_000);

        vm.expectRevert(abi.encodeWithSelector(MarketSession.MarketSession_NotYourOrder.selector, bidId, stranger));
        vm.prank(stranger);
        session.cancel(bidId);

        vm.expectRevert(abi.encodeWithSelector(MarketSession.MarketSession_NotYourOrder.selector, bidId, address(bobP)));
        vm.prank(address(bobP));
        session.cancel(bidId);

        assertEq(uint8(session.orderOf(bidId).status), uint8(MarketTypes.OrderStatus.OPEN));
    }

    function test_noCancelOnceTheSessionHasClosed() public {
        bytes32 bidId = _bid(0, 2000, 250_000);
        _close();

        vm.expectRevert(abi.encodeWithSelector(MarketSession.MarketSession_Closed.selector, session.config().closesAt));
        vm.prank(alice);
        aliceP.cancelOrder(bidId);
    }

    function test_modifyReplacesPriceQuantityAndSlot() public {
        bytes32 oldId = _bid(0, 2000, 250_000);

        vm.prank(alice);
        bytes32 newId = aliceP.modifyOrder(oldId, _req(5, 3000, 200_000));

        assertEq(uint8(session.orderOf(oldId).status), uint8(MarketTypes.OrderStatus.CANCELLED));
        MarketTypes.Order memory o = session.orderOf(newId);
        assertEq(o.slot, firstSlot + 5);
        assertEq(o.quantity, 3000);
        assertEq(o.price, 200_000);
        assertEq(uint8(o.side), uint8(MarketTypes.Side.BID));
        // Only the new order's collateral is locked: 3000 Wh at 0.20.
        assertEq(token.lockedBalanceOf(alice), 600_000);
    }

    function test_modifyingAnOfferReplacesItsEnergyToken() public {
        bytes32 oldId = _offer(0, 2000, 200_000);
        uint256 oldToken = session.orderOf(oldId).tokenId;

        vm.prank(bob);
        bytes32 newId = bobP.modifyOrder(oldId, _req(0, 1500, 210_000));

        uint256 newToken = session.orderOf(newId).tokenId;
        assertEq(token.balanceOf(bob, oldToken), 0);
        assertEq(token.balanceOf(bob, newToken), 1500);
        assertEq(uint8(session.orderOf(newId).side), uint8(MarketTypes.Side.OFFER));
        assertEq(token.lockedBalanceOf(bob), 450_000);
    }

    // ------------------------------------------------------------------
    // Matching: trades and commitments
    // ------------------------------------------------------------------

    /// Bid 2000 at 0.25, offer 2000 at 0.20, matched 1500 at 0.22.
    function test_aTradePaysTheSellerDeliversTheEnergyAndCommitsBoth() public {
        bytes32 bidId = _bid(0, 2000, 250_000);
        bytes32 offerId = _offer(0, 2000, 200_000);
        uint256 tokenId = session.orderOf(offerId).tokenId;
        _close();

        _trade(bidId, offerId, 1500, 220_000);

        // Payment at the trade price: 1500 Wh at 0.22 = 330,000.
        assertEq(token.balanceOf(bob, 0), FUNDS + 330_000);
        assertEq(token.balanceOf(alice, 0), FUNDS - 330_000);
        // Energy delivered.
        assertEq(token.balanceOf(alice, tokenId), 1500);
        assertEq(token.balanceOf(bob, tokenId), 500);

        Prosumer.Commitment memory a = aliceP.commitmentOf(firstSlot);
        assertEq(a.boughtWh, 1500);
        assertEq(a.paid, 330_000);
        Prosumer.Commitment memory b = bobP.commitmentOf(firstSlot);
        assertEq(b.soldWh, 1500);
        assertEq(b.received, 330_000);
        // The seller's collateral for the matched part waits for settlement.
        assertEq(b.collateral, 450_000);

        assertEq(session.orderOf(bidId).matched, 1500);
        assertEq(session.orderOf(offerId).matched, 1500);
    }

    function test_aFullyMatchedBidReleasesWhatItsLimitOverReserved() public {
        bytes32 bidId = _bid(0, 2000, 250_000);
        bytes32 offerId = _offer(0, 2000, 200_000);
        _close();

        _trade(bidId, offerId, 2000, 220_000);

        // Paid 440,000; the other 60,000 of the 500,000 comes back at once.
        assertEq(token.lockedBalanceOf(alice), 0);
        assertEq(token.balanceOf(alice, 0), FUNDS - 440_000);
    }

    function test_onlyTheMatcherRegistersTrades() public {
        bytes32 bidId = _bid(0, 2000, 250_000);
        bytes32 offerId = _offer(0, 2000, 200_000);
        _close();

        MarketTypes.Trade[] memory trades = new MarketTypes.Trade[](1);
        trades[0] = MarketTypes.Trade({bidId: bidId, offerId: offerId, quantity: 100, price: 220_000});
        vm.expectRevert(abi.encodeWithSelector(MarketSession.MarketSession_OnlyMatcher.selector, stranger));
        vm.prank(stranger);
        session.registerTrades(trades);
    }

    function test_noTradeBeforeTheSessionCloses() public {
        bytes32 bidId = _bid(0, 2000, 250_000);
        bytes32 offerId = _offer(0, 2000, 200_000);

        vm.expectRevert(
            abi.encodeWithSelector(MarketSession.MarketSession_NotClosed.selector, session.config().closesAt)
        );
        _trade(bidId, offerId, 100, 220_000);
    }

    function test_aTradeOutsideEitherLimitPriceIsRefused() public {
        bytes32 bidId = _bid(0, 2000, 250_000);
        bytes32 offerId = _offer(0, 2000, 200_000);
        _close();

        vm.expectRevert(
            abi.encodeWithSelector(MarketSession.MarketSession_BadTrade.selector, bidId, offerId, "price outside limits")
        );
        _trade(bidId, offerId, 100, 250_001);

        vm.expectRevert(
            abi.encodeWithSelector(MarketSession.MarketSession_BadTrade.selector, bidId, offerId, "price outside limits")
        );
        _trade(bidId, offerId, 100, 199_999);
    }

    function test_aTradeBeyondEitherOrderIsRefused() public {
        bytes32 bidId = _bid(0, 2000, 250_000);
        bytes32 offerId = _offer(0, 1000, 200_000);
        _close();

        vm.expectRevert(
            abi.encodeWithSelector(MarketSession.MarketSession_BadTrade.selector, bidId, offerId, "offer over-matched")
        );
        _trade(bidId, offerId, 1001, 220_000);
    }

    function test_aTradeBeyondTheBidIsRefused() public {
        bytes32 bidId = _bid(0, 1000, 250_000);
        bytes32 offerId = _offer(0, 2000, 200_000);
        _close();

        vm.expectRevert(
            abi.encodeWithSelector(MarketSession.MarketSession_BadTrade.selector, bidId, offerId, "bid over-matched")
        );
        _trade(bidId, offerId, 1001, 220_000);
    }

    function test_aTradeAcrossSlotsIsRefused() public {
        bytes32 bidId = _bid(0, 2000, 250_000);
        bytes32 offerId = _offer(1, 2000, 200_000);
        _close();

        vm.expectRevert(
            abi.encodeWithSelector(MarketSession.MarketSession_BadTrade.selector, bidId, offerId, "different slots")
        );
        _trade(bidId, offerId, 100, 220_000);
    }

    function test_anAccountCannotTradeWithItself() public {
        bytes32 bidId = _bid(0, 2000, 250_000);
        vm.prank(alice);
        bytes32 offerId = aliceP.placeOffers(MarketTypes.EnergyType.ELECTRICITY, _one(0, 2000, 200_000))[0];
        _close();

        vm.expectRevert(abi.encodeWithSelector(MarketSession.MarketSession_BadTrade.selector, bidId, offerId, "self-trade"));
        _trade(bidId, offerId, 100, 220_000);
    }

    function test_aCancelledOrderCannotBeMatched() public {
        bytes32 bidId = _bid(0, 2000, 250_000);
        bytes32 offerId = _offer(0, 2000, 200_000);
        vm.prank(alice);
        aliceP.cancelOrder(bidId);
        _close();

        vm.expectRevert(abi.encodeWithSelector(MarketSession.MarketSession_BadTrade.selector, bidId, offerId, "bid not open"));
        _trade(bidId, offerId, 100, 220_000);
    }

    /// Many small trades at the bid's limit never pay out more than the bid
    /// locked, whatever the rounding.
    function test_partialPaymentsNeverExceedTheCollateral() public {
        bytes32 bidId = _bid(0, 1001, 333_333);
        bytes32 offerId = _offer(0, 1001, 300_000);
        _close();

        for (uint256 i = 0; i < 7; ++i) {
            _trade(bidId, offerId, 143, 333_333);
        }

        assertEq(session.orderOf(bidId).matched, 1001);
        assertEq(token.lockedBalanceOf(alice), 0);
        assertLe(FUNDS - token.balanceOf(alice, 0), (uint256(1001) * 333_333 + 999) / 1000);
    }

    // ------------------------------------------------------------------
    // Finalisation and expiry
    // ------------------------------------------------------------------

    function test_expiryReleasesTheUnmatchedPartAndBurnsUnmatchedEnergy() public {
        bytes32 bidId = _bid(0, 2000, 250_000);
        bytes32 offerId = _offer(0, 2000, 200_000);
        uint256 tokenId = session.orderOf(offerId).tokenId;
        _close();
        _trade(bidId, offerId, 1500, 220_000);

        vm.prank(matcher);
        session.finalise();
        vm.startPrank(stranger);
        session.expire(bidId);
        session.expire(offerId);
        vm.stopPrank();

        // Alice: 170,000 of her bid was still locked; it is back.
        assertEq(token.lockedBalanceOf(alice), 0);
        // Bob: the unmatched 500 Wh of collateral (150,000) is back; the
        // matched part's 450,000 waits for settlement. Unmatched energy burned.
        assertEq(token.lockedBalanceOf(bob), 450_000);
        assertEq(token.balanceOf(bob, tokenId), 0);
        assertEq(uint8(session.orderOf(bidId).status), uint8(MarketTypes.OrderStatus.EXPIRED));
    }

    function test_nothingExpiresBeforeFinalisation() public {
        bytes32 bidId = _bid(0, 2000, 250_000);
        _close();

        vm.expectRevert(MarketSession.MarketSession_NotFinalised.selector);
        session.expire(bidId);
    }

    function test_aFullyMatchedOrderHasNothingToExpire() public {
        bytes32 bidId = _bid(0, 2000, 250_000);
        bytes32 offerId = _offer(0, 2000, 200_000);
        _close();
        _trade(bidId, offerId, 2000, 220_000);
        vm.prank(matcher);
        session.finalise();

        vm.expectRevert(abi.encodeWithSelector(MarketSession.MarketSession_NothingToExpire.selector, bidId));
        session.expire(bidId);
    }

    function test_noTradeAfterFinalisation() public {
        bytes32 bidId = _bid(0, 2000, 250_000);
        bytes32 offerId = _offer(0, 2000, 200_000);
        _close();
        vm.prank(operator);
        session.finalise();

        vm.expectRevert(MarketSession.MarketSession_AlreadyFinalised.selector);
        _trade(bidId, offerId, 100, 220_000);
    }

    function test_onlyTheMatcherOrTheOperatorFinalises() public {
        _close();
        vm.expectRevert(abi.encodeWithSelector(MarketSession.MarketSession_OnlyMatcher.selector, stranger));
        vm.prank(stranger);
        session.finalise();
    }

    // ------------------------------------------------------------------
    // Settlement against measured energy
    // ------------------------------------------------------------------

    function _matched() internal returns (bytes32 bidId, bytes32 offerId) {
        bidId = _bid(0, 2000, 250_000);
        offerId = _offer(0, 2000, 200_000);
        _close();
        _trade(bidId, offerId, 1500, 220_000);
    }

    /// Bob committed to export 1500 Wh and exported 1450: within 10%.
    function test_aDeliveryWithinTenPercentCostsNothing() public {
        _matched();
        _slotOver(0);

        vm.prank(bobSensor);
        bobP.settle(firstSlot, 1450, 0);

        // The delivery collateral is released; what stays locked is the
        // unmatched remainder of the offer, until someone expires it.
        assertEq(token.lockedBalanceOf(bob), 150_000);
        assertEq(token.balanceOf(address(manager), 0), 0);
        assertTrue(bobP.commitmentOf(firstSlot).settled);
    }

    /// Bob exported 1000 of 1500: a 500 Wh deviation at 0.30 costs 150,000,
    /// taken from his delivery collateral; the rest is released.
    function test_aShortDeliveryIsPenalisedFromTheCollateral() public {
        _matched();
        _slotOver(0);

        vm.prank(bobSensor);
        bobP.settle(firstSlot, 1000, 0);

        assertEq(token.balanceOf(address(manager), 0), 150_000);
        assertEq(token.lockedBalanceOf(bob), 150_000);
        assertEq(token.balanceOf(bob, 0), FUNDS + 330_000 - 150_000);
    }

    /// Alice committed to import 1500 Wh and imported 1000. A buyer holds no
    /// delivery collateral, so the penalty comes from her unlocked balance.
    function test_aBuyersPenaltyComesFromItsBalance() public {
        _matched();
        _slotOver(0);

        vm.prank(aliceSensor);
        aliceP.settle(firstSlot, 0, 1000);

        assertEq(token.balanceOf(address(manager), 0), 150_000);
        assertEq(token.balanceOf(alice, 0), FUNDS - 330_000 - 150_000);
    }

    /// What cannot be collected is reported, not reverted: a prosumer cannot
    /// block its own settlement by withdrawing its allowance.
    function test_anUncollectablePenaltyIsAShortfallNotARevert() public {
        _matched();
        _slotOver(0);
        vm.prank(alice);
        token.setPaymentAllowance(address(aliceP), 0);

        vm.expectEmit(true, true, true, true, address(aliceP));
        emit Prosumer.Settled(firstSlot, -1500, -1000, 500, 150_000, 0, 0, 150_000, 0);
        vm.prank(aliceSensor);
        aliceP.settle(firstSlot, 0, 1000);

        assertTrue(aliceP.commitmentOf(firstSlot).settled);
    }

    function test_onlyTheProsumersSensorSettles() public {
        _matched();
        _slotOver(0);

        vm.expectRevert(abi.encodeWithSelector(Prosumer.Prosumer_OnlySensor.selector, bob));
        vm.prank(bob);
        bobP.settle(firstSlot, 1500, 0);

        vm.expectRevert(abi.encodeWithSelector(Prosumer.Prosumer_OnlySensor.selector, aliceSensor));
        vm.prank(aliceSensor);
        bobP.settle(firstSlot, 1500, 0);
    }

    function test_aSlotIsSettledOnceAndOnlyAfterItEnds() public {
        _matched();
        vm.warp(manager.slotStart(firstSlot + 1) - 1);

        vm.expectRevert(abi.encodeWithSelector(Prosumer.Prosumer_SlotNotOver.selector, firstSlot));
        vm.prank(bobSensor);
        bobP.settle(firstSlot, 1500, 0);

        vm.warp(manager.slotStart(firstSlot + 1));
        vm.prank(bobSensor);
        bobP.settle(firstSlot, 1500, 0);

        vm.expectRevert(abi.encodeWithSelector(Prosumer.Prosumer_AlreadySettled.selector, firstSlot));
        vm.prank(bobSensor);
        bobP.settle(firstSlot, 1500, 0);
    }

    function test_aSlotWithoutCommitmentHasNothingToSettle() public {
        _slotOver(3);
        vm.expectRevert(abi.encodeWithSelector(Prosumer.Prosumer_NothingToSettle.selector, firstSlot + 3));
        vm.prank(bobSensor);
        bobP.settle(firstSlot + 3, 0, 0);
    }

    // ------------------------------------------------------------------
    // Sessions of any length
    // ------------------------------------------------------------------

    /// An intraday session of six slots, opened alongside the day-ahead one
    /// for heat.
    function test_anIntradaySessionOfSixSlots() public {
        uint32 first = uint32(block.timestamp / SLOT_SECONDS) + 3;
        MarketSession intraday = _open(MarketTypes.EnergyType.HEAT, first, 6);

        vm.prank(alice);
        bytes32 id = aliceP.placeBids(MarketTypes.EnergyType.HEAT, _one(5, 100, 250_000))[0];
        assertEq(intraday.orderOf(id).slot, first + 5);

        vm.expectRevert(abi.encodeWithSelector(Prosumer.Prosumer_BadSlot.selector, 6, 6));
        vm.prank(alice);
        aliceP.placeBids(MarketTypes.EnergyType.HEAT, _one(6, 100, 250_000));
    }

    function test_aSessionMustCloseBeforeDeliveryAndHaveSlots() public {
        uint32 first = uint32(block.timestamp / SLOT_SECONDS) + 3;
        MarketTypes.SessionConfig memory c = MarketTypes.SessionConfig({
            energyType: MarketTypes.EnergyType.ELECTRICITY,
            firstSlot: first,
            slotCount: 6,
            closesAt: uint40(uint256(first) * SLOT_SECONDS + 1)
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                MarketManager.MarketManager_ClosesAfterDeliveryStarts.selector, c.closesAt, uint256(first) * SLOT_SECONDS
            )
        );
        vm.prank(operator);
        manager.openSession(c);

        c.closesAt = uint40(uint256(first) * SLOT_SECONDS);
        c.slotCount = 0;
        vm.expectRevert(abi.encodeWithSelector(MarketManager.MarketManager_BadSlotCount.selector, 0));
        vm.prank(operator);
        manager.openSession(c);

        c.slotCount = 97;
        vm.expectRevert(abi.encodeWithSelector(MarketManager.MarketManager_BadSlotCount.selector, 97));
        vm.prank(operator);
        manager.openSession(c);
    }

    // ------------------------------------------------------------------
    // Who may call what
    // ------------------------------------------------------------------

    function test_onlyTheOwnerPlacesCancelsAndModifies() public {
        bytes32 id = _bid(0, 100, 250_000);

        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Prosumer.Prosumer_OnlyOwner.selector, stranger));
        aliceP.placeBids(MarketTypes.EnergyType.ELECTRICITY, _one(0, 100, 250_000));
        vm.expectRevert(abi.encodeWithSelector(Prosumer.Prosumer_OnlyOwner.selector, stranger));
        aliceP.cancelOrder(id);
        vm.expectRevert(abi.encodeWithSelector(Prosumer.Prosumer_OnlyOwner.selector, stranger));
        aliceP.modifyOrder(id, _req(0, 50, 250_000));
        vm.stopPrank();
    }

    /// The callbacks pay and deliver. Only the order's own session may call
    /// them, not a stranger and not another session.
    function test_onlyTheOrdersSessionCallsBack() public {
        bytes32 id = _offer(0, 2000, 200_000);
        MarketSession other = _open(MarketTypes.EnergyType.HEAT, firstSlot, 24);

        vm.expectRevert(abi.encodeWithSelector(Prosumer.Prosumer_OnlySession.selector, id, stranger));
        vm.prank(stranger);
        bobP.onOfferMatched(id, 100, 200_000, stranger);

        vm.expectRevert(abi.encodeWithSelector(Prosumer.Prosumer_OnlySession.selector, id, address(other)));
        vm.prank(address(other));
        bobP.onExpired(id, 2000);
    }

    function test_onlyRegisteredProsumersPlaceInASession() public {
        Prosumer rogue = new Prosumer(stranger, manager);

        vm.expectRevert(abi.encodeWithSelector(MarketSession.MarketSession_NotRegistered.selector, stranger));
        vm.prank(stranger);
        session.place(MarketTypes.Side.BID, _req(0, 100, 250_000), 0);

        // An unregistered prosumer contract cannot even mint its offer's token.
        vm.startPrank(stranger);
        token.setPaymentAllowance(address(rogue), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(LockableERC1155.LockableERC1155_NotMinter.selector, address(rogue)));
        rogue.placeOffers(MarketTypes.EnergyType.ELECTRICITY, _one(0, 100, 200_000));
        vm.stopPrank();
    }

    function test_onlyTheOperatorRunsTheManager() public {
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(MarketManager.MarketManager_OnlyOperator.selector, stranger));
        manager.registerProsumer(stranger, stranger);
        vm.expectRevert(abi.encodeWithSelector(MarketManager.MarketManager_OnlyOperator.selector, stranger));
        manager.setMatcher(stranger);
        vm.expectRevert(abi.encodeWithSelector(MarketManager.MarketManager_OnlyOperator.selector, stranger));
        manager.setSensor(address(aliceP), stranger);
        vm.expectRevert(abi.encodeWithSelector(MarketManager.MarketManager_OnlyOperator.selector, stranger));
        manager.setRealTimePrice(1);
        vm.stopPrank();
    }
}
