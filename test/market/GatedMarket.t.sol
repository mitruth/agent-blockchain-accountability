// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MarketFixture} from "./MarketFixture.sol";
import {MiniAccount} from "../../contracts/harness/MiniAccount.sol";
import {PolicyGate} from "../../contracts/gate/PolicyGate.sol";
import {PositionLedger} from "../../contracts/gate/PositionLedger.sol";
import {Order, OrderKind, Side, FillState} from "../../contracts/gate/GateTypes.sol";
import {ProsumerDecoder} from "../../contracts/market/ProsumerDecoder.sol";
import {Prosumer} from "../../contracts/market/Prosumer.sol";
import {MarketSession} from "../../contracts/market/MarketSession.sol";
import {MarketTypes} from "../../contracts/market/MarketTypes.sol";

/// The whole system: an agent trades for Alice on the ported P2P market, and
/// can do so only through PolicyGate.
///
///   agent ──submit──▶ PolicyGate ──▶ Alice's account ──▶ Alice's Prosumer ──▶ session
///
/// Alice's account is a minimal ERC-7579 account owned by her key. Bob trades
/// directly, as the counterparty. Every order the agent places is booked in the
/// position ledger, and the ledger follows the market through the decoder:
/// fills when trades are registered, expiry when the session is finalised.
///
/// These tests replace the order-lifecycle tests of the mock market (decision
/// log 2.20).
contract GatedMarketTest is MarketFixture {
    uint256 internal constant EXECUTOR = 2;
    uint256 internal constant MAX_LEGS = 48;

    address internal aliceOwner = makeAddr("aliceOwner");
    address internal agent = makeAddr("agent");
    address internal keeper = makeAddr("keeper");

    MiniAccount internal aliceAccount;
    PositionLedger internal ledger;
    PolicyGate internal gate;
    ProsumerDecoder internal decoder;

    function _owners() internal override returns (address, address) {
        aliceAccount = new MiniAccount(aliceOwner);
        return (address(aliceAccount), makeAddr("bob"));
    }

    /// @dev Alice's approvals are owner-path calls from her account.
    function _approveProsumer(address owner_, address prosumer) internal override {
        if (owner_ != address(aliceAccount)) return super._approveProsumer(owner_, prosumer);
        vm.startPrank(aliceOwner);
        aliceAccount.execute(
            address(token), 0, abi.encodeCall(token.setPaymentAllowance, (prosumer, type(uint256).max))
        );
        aliceAccount.execute(address(token), 0, abi.encodeCall(token.setApprovalForAll, (prosumer, true)));
        vm.stopPrank();
    }

    function setUp() public override {
        super.setUp();

        ledger = new PositionLedger();
        gate = new PolicyGate(ledger, MAX_LEGS);
        decoder = new ProsumerDecoder();

        vm.startPrank(aliceOwner);
        aliceAccount.installModule(EXECUTOR, address(gate), "");
        aliceAccount.execute(address(ledger), 0, abi.encodeCall(ledger.setWriter, (address(gate), true)));
        aliceAccount.execute(address(gate), 0, abi.encodeCall(gate.registerAgent, (agent, uint48(block.timestamp + 30 days))));
        bytes4[4] memory selectors = [
            Prosumer.placeBids.selector,
            Prosumer.placeOffers.selector,
            Prosumer.cancelOrder.selector,
            Prosumer.modifyOrder.selector
        ];
        for (uint256 i = 0; i < selectors.length; ++i) {
            aliceAccount.execute(
                address(gate), 0, abi.encodeCall(gate.setDecoder, (address(aliceP), selectors[i], decoder))
            );
        }
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Helpers: the agent's calls, through the gate
    // ------------------------------------------------------------------

    function _submit(bytes memory call) internal {
        vm.prank(agent);
        gate.submit(address(aliceAccount), address(aliceP), call);
    }

    function _agentBids(MarketTypes.OrderRequest[] memory reqs) internal returns (bytes32[] memory ids) {
        _submit(abi.encodeCall(Prosumer.placeBids, (MarketTypes.EnergyType.ELECTRICITY, reqs)));
        ids = _lastOrders(session.bidIds(), reqs.length);
    }

    function _agentOffers(MarketTypes.OrderRequest[] memory reqs) internal returns (bytes32[] memory ids) {
        _submit(abi.encodeCall(Prosumer.placeOffers, (MarketTypes.EnergyType.ELECTRICITY, reqs)));
        ids = _lastOrders(session.offerIds(), reqs.length);
    }

    function _agentBid(uint16 slot, uint64 quantity, uint64 price) internal returns (bytes32) {
        return _agentBids(_one(slot, quantity, price))[0];
    }

    function _lastOrders(bytes32[] memory all, uint256 n) internal pure returns (bytes32[] memory ids) {
        ids = new bytes32[](n);
        for (uint256 i = 0; i < n; ++i) {
            ids[i] = all[all.length - n + i];
        }
    }

    function _reconcile(bytes32 id) internal returns (uint64 filled, uint64 released) {
        vm.prank(keeper);
        return gate.reconcile(address(aliceAccount), address(aliceP), id);
    }

    function _position(uint32 slot) internal view returns (PositionLedger.Position memory) {
        return ledger.positionOf(address(aliceAccount), slot);
    }

    function _record(bytes32 id) internal view returns (PositionLedger.OrderRecord memory) {
        return ledger.recordOf(address(aliceAccount), address(aliceP), id);
    }

    // ------------------------------------------------------------------
    // Placing through the gate
    // ------------------------------------------------------------------

    /// A day-ahead batch: 24 hourly bids in one call, 24 legs, 24 orders in the
    /// session and in the ledger.
    function test_aDayAheadBatchIsTwentyFourLegs() public {
        MarketTypes.OrderRequest[] memory reqs = new MarketTypes.OrderRequest[](24);
        for (uint16 h = 0; h < 24; ++h) {
            reqs[h] = _req(h, 1000 + h, 250_000);
        }

        Order[] memory legs = decoder.decode(
            address(aliceP), abi.encodeCall(Prosumer.placeBids, (MarketTypes.EnergyType.ELECTRICITY, reqs))
        );
        assertEq(legs.length, 24);
        assertEq(uint8(legs[23].side), uint8(Side.BUY));
        assertEq(legs[23].slot, firstSlot + 23);
        assertEq(legs[23].value, (uint256(1023) * 250_000 + 999) / 1000);

        bytes32[] memory ids = _agentBids(reqs);

        assertEq(ledger.openOrderCount(address(aliceAccount)), 24);
        for (uint16 h = 0; h < 24; ++h) {
            assertEq(_position(firstSlot + h).committedBuyWh, 1000 + h);
            assertEq(session.orderOf(ids[h]).account, address(aliceAccount));
        }
    }

    /// A leg's value is quantity at the limit price, rounded up: 1001 Wh at
    /// 0.333333 per kWh is 333,666.333 units, so 333,667.
    function test_legValuesRoundUp() public view {
        Order[] memory legs = decoder.decode(
            address(aliceP),
            abi.encodeCall(Prosumer.placeBids, (MarketTypes.EnergyType.ELECTRICITY, _one(0, 1001, 333_333)))
        );
        assertEq(legs[0].value, 333_667);
    }

    function test_aBatchBeyondTheLegLimitIsRefused() public {
        MarketTypes.OrderRequest[] memory reqs = new MarketTypes.OrderRequest[](MAX_LEGS + 1);
        for (uint256 i = 0; i < reqs.length; ++i) {
            reqs[i] = _req(uint16(i % 24), 100, 250_000);
        }

        vm.expectRevert(
            abi.encodeWithSelector(PolicyGate.PolicyGate_NotAnOrder.selector, address(aliceP), Prosumer.placeBids.selector)
        );
        vm.prank(agent);
        gate.submit(
            address(aliceAccount),
            address(aliceP),
            abi.encodeCall(Prosumer.placeBids, (MarketTypes.EnergyType.ELECTRICITY, reqs))
        );
        assertEq(session.bidIds().length, 0);
    }

    function test_offersThroughTheGateAreBookedAsSells() public {
        bytes32 id = _agentOffers(_one(2, 1500, 200_000))[0];

        assertEq(_position(firstSlot + 2).committedSellWh, 1500);
        assertEq(uint8(_record(id).side), uint8(Side.SELL));
        // The energy token was minted to Alice's account.
        assertEq(token.balanceOf(address(aliceAccount), session.orderOf(id).tokenId), 1500);
    }

    // ------------------------------------------------------------------
    // Cancel and modify through the gate
    // ------------------------------------------------------------------

    function test_aCancelThroughTheGateReleasesInTheMarketAndTheLedger() public {
        bytes32 id = _agentBid(0, 2000, 250_000);

        _submit(abi.encodeCall(Prosumer.cancelOrder, (id)));

        assertEq(token.lockedBalanceOf(address(aliceAccount)), 0);
        assertEq(_position(firstSlot).committedBuyWh, 0);
        assertEq(uint8(_record(id).status), uint8(PositionLedger.Status.CLOSED));
        assertEq(ledger.openOrderCount(address(aliceAccount)), 0);
    }

    function test_aModifyThroughTheGateIsACancelThenAPlace() public {
        bytes32 oldId = _agentBid(0, 2000, 250_000);

        Order[] memory legs = decoder.decode(
            address(aliceP), abi.encodeCall(Prosumer.modifyOrder, (oldId, _req(3, 1200, 240_000)))
        );
        assertEq(legs.length, 2);
        assertEq(uint8(legs[0].kind), uint8(OrderKind.CANCEL));
        assertEq(legs[0].qtyWh, 2000);
        assertEq(uint8(legs[1].kind), uint8(OrderKind.PLACE));
        assertEq(legs[1].slot, firstSlot + 3);

        _submit(abi.encodeCall(Prosumer.modifyOrder, (oldId, _req(3, 1200, 240_000))));
        bytes32 newId = session.bidIds()[1];

        assertEq(_position(firstSlot).committedBuyWh, 0);
        assertEq(_position(firstSlot + 3).committedBuyWh, 1200);
        assertEq(uint8(_record(newId).status), uint8(PositionLedger.Status.OPEN));
        assertEq(ledger.openOrderCount(address(aliceAccount)), 1);
    }

    // ------------------------------------------------------------------
    // Matching, reconcile, expiry
    // ------------------------------------------------------------------

    /// Alice's agent bids 2000; Bob offers 2000; 1500 match after the session
    /// closes. The ledger books the fill on reconcile; the rest stays open
    /// until the session is finalised, then expires.
    function test_fillsAreBookedOnReconcileAndTheRestExpiresAtFinalisation() public {
        bytes32 bidId = _agentBid(0, 2000, 250_000);
        bytes32 offerId = _offer(0, 2000, 200_000);
        _close();

        // Closed but not finalised: still open, nothing to book yet.
        FillState memory state = decoder.fillState(address(aliceP), bidId);
        assertTrue(state.open);
        assertFalse(state.expired);

        _trade(bidId, offerId, 1500, 220_000);
        (uint64 filled, uint64 released) = _reconcile(bidId);
        assertEq(filled, 1500);
        assertEq(released, 0);
        assertEq(_position(firstSlot).clearedBuyWh, 1500);
        assertEq(uint8(_record(bidId).status), uint8(PositionLedger.Status.OPEN));

        vm.prank(matcher);
        session.finalise();
        state = decoder.fillState(address(aliceP), bidId);
        assertFalse(state.open);
        assertTrue(state.expired);

        vm.expectEmit(true, true, true, true, address(ledger));
        emit PositionLedger.OrderClosed(
            address(aliceAccount), address(aliceP), bidId, PositionLedger.CloseReason.EXPIRED, 500
        );
        (, released) = _reconcile(bidId);
        assertEq(released, 500);

        PositionLedger.Position memory p = _position(firstSlot);
        assertEq(p.committedBuyWh, 1500);
        assertEq(p.clearedBuyWh, 1500);
        // The ledger and the market agree on what Alice bought.
        assertEq(aliceP.commitmentOf(firstSlot).boughtWh, 1500);
    }

    function test_aFullyMatchedOrderClosesAsFilled() public {
        bytes32 bidId = _agentBid(0, 2000, 250_000);
        bytes32 offerId = _offer(0, 2000, 200_000);
        _close();
        _trade(bidId, offerId, 2000, 220_000);

        vm.expectEmit(true, true, true, true, address(ledger));
        emit PositionLedger.OrderClosed(
            address(aliceAccount), address(aliceP), bidId, PositionLedger.CloseReason.FILLED, 0
        );
        _reconcile(bidId);
    }

    /// Expiry needs no one to have called `expire` on the market: the ledger
    /// takes the market's word that the session is finalised.
    function test_theLedgerExpiresWithoutTheMarketsExpireCall() public {
        bytes32 bidId = _agentBid(0, 2000, 250_000);
        _close();
        vm.prank(operator);
        session.finalise();

        (, uint64 released) = _reconcile(bidId);
        assertEq(released, 2000);
        // In the market the collateral waits for `expire`, which anyone may call.
        assertEq(token.lockedBalanceOf(address(aliceAccount)), 500_000);
        session.expire(bidId);
        assertEq(token.lockedBalanceOf(address(aliceAccount)), 0);
    }

    /// The owner cancels directly, not through the gate. The ledger finds the
    /// order closed on the market and closes it with its own reason.
    function test_anOrderTheOwnerCancelsDirectlyIsClosedElsewhere() public {
        bytes32 bidId = _agentBid(0, 2000, 250_000);
        vm.prank(aliceOwner);
        aliceAccount.execute(address(aliceP), 0, abi.encodeCall(Prosumer.cancelOrder, (bidId)));

        vm.expectEmit(true, true, true, true, address(ledger));
        emit PositionLedger.OrderClosed(
            address(aliceAccount), address(aliceP), bidId, PositionLedger.CloseReason.CLOSED_ELSEWHERE, 2000
        );
        _reconcile(bidId);
    }

    // ------------------------------------------------------------------
    // No route around the gate
    // ------------------------------------------------------------------

    function test_theAgentHasNoDirectRouteIntoTheMarket() public {
        bytes32 bidId = _agentBid(0, 2000, 250_000);

        vm.startPrank(agent);

        // The prosumer contract takes orders from its owner, the account, only.
        vm.expectRevert(abi.encodeWithSelector(Prosumer.Prosumer_OnlyOwner.selector, agent));
        aliceP.placeBids(MarketTypes.EnergyType.ELECTRICITY, _one(0, 100, 250_000));
        vm.expectRevert(abi.encodeWithSelector(Prosumer.Prosumer_OnlyOwner.selector, agent));
        aliceP.cancelOrder(bidId);

        // The callbacks that pay and deliver answer to the order's session only.
        vm.expectRevert(abi.encodeWithSelector(Prosumer.Prosumer_OnlySession.selector, bidId, agent));
        aliceP.onBidMatched(bidId, 100, 1, agent);

        // Settlement answers to the sensor only.
        vm.expectRevert(abi.encodeWithSelector(Prosumer.Prosumer_OnlySensor.selector, agent));
        aliceP.settle(firstSlot, 0, 0);

        // Trades come from the matcher only.
        vm.expectRevert(abi.encodeWithSelector(MarketSession.MarketSession_OnlyMatcher.selector, agent));
        session.registerTrades(new MarketTypes.Trade[](0));

        // Alice's collateral cannot be released or moved by the agent.
        vm.expectRevert();
        token.unlock(address(aliceAccount), address(aliceP), 1, agent);
        vm.expectRevert();
        token.safeTransferFrom(address(aliceAccount), agent, 0, 1, "");

        vm.stopPrank();

        // And the token is not an approved target: the agent cannot route there.
        vm.expectRevert(
            abi.encodeWithSelector(
                PolicyGate.PolicyGate_UnknownCall.selector, address(token), token.setPaymentAllowance.selector
            )
        );
        vm.prank(agent);
        gate.submit(
            address(aliceAccount), address(token), abi.encodeCall(token.setPaymentAllowance, (agent, type(uint256).max))
        );
    }

    // ------------------------------------------------------------------
    // The books balance, on the real market
    // ------------------------------------------------------------------

    bytes32[] internal _aliceIds;
    bytes32[] internal _bobOffers;
    bytes32[] internal _bobBids;

    /// A random sequence over three slots. While trading: the agent places,
    /// cancels and modifies Alice's bids and offers; Bob places the other side.
    /// After closing: the matcher registers random valid trades between them,
    /// a keeper reconciles some of Alice's orders, then the session is
    /// finalised and everything is reconciled.
    ///
    /// After every step the ledger's books balance (committed = open quantity
    /// + filled quantity of closed orders; cleared = booked fills; the open
    /// count matches). At the end, the ledger and Alice's prosumer contract
    /// agree, slot by slot, on what she bought and sold, and nothing unmatched
    /// is left committed.
    function testFuzz_theBooksBalanceAndAgreeWithTheMarket(uint256 seed) public {
        for (uint256 step = 0; step < 12; ++step) {
            _tradingStep(uint256(keccak256(abi.encode(seed, "trade", step))));
            _assertBooksBalance();
        }

        _close();
        for (uint256 step = 0; step < 10; ++step) {
            _matchingStep(uint256(keccak256(abi.encode(seed, "match", step))));
            _assertBooksBalance();
        }

        vm.prank(matcher);
        session.finalise();
        for (uint256 i = 0; i < _aliceIds.length; ++i) {
            if (_record(_aliceIds[i]).status == PositionLedger.Status.OPEN) _reconcile(_aliceIds[i]);
        }
        _assertBooksBalance();

        assertEq(ledger.openOrderCount(address(aliceAccount)), 0);
        for (uint32 s = firstSlot; s < firstSlot + 3; ++s) {
            PositionLedger.Position memory p = _position(s);
            Prosumer.Commitment memory c = aliceP.commitmentOf(s);
            assertEq(p.committedBuyWh, p.clearedBuyWh, "unmatched buy left committed");
            assertEq(p.committedSellWh, p.clearedSellWh, "unmatched sell left committed");
            assertEq(p.clearedBuyWh, c.boughtWh, "ledger and market disagree on bought");
            assertEq(p.clearedSellWh, c.soldWh, "ledger and market disagree on sold");
        }
    }

    function _tradingStep(uint256 r) internal {
        uint256 action = r % 5;
        uint16 slot = uint16((r >> 8) % 3);
        uint64 qty = uint64(100 + (r >> 16) % 1900);

        if (action == 0 || _aliceIds.length == 0) {
            _aliceIds.push(_agentBid(slot, qty, 250_000));
        } else if (action == 1) {
            _aliceIds.push(_agentOffers(_one(slot, qty, 200_000))[0]);
        } else if (action == 2) {
            bytes32 id = _aliceIds[(r >> 40) % _aliceIds.length];
            if (_record(id).status == PositionLedger.Status.OPEN) _submit(abi.encodeCall(Prosumer.cancelOrder, (id)));
        } else if (action == 3) {
            bytes32 id = _aliceIds[(r >> 40) % _aliceIds.length];
            if (_record(id).status == PositionLedger.Status.OPEN) {
                bool isBid = _record(id).side == Side.BUY;
                _submit(abi.encodeCall(Prosumer.modifyOrder, (id, _req(slot, qty, isBid ? 250_000 : 200_000))));
                _aliceIds.push(isBid ? session.bidIds()[session.bidIds().length - 1] : session.offerIds()[session.offerIds().length - 1]);
            }
        } else {
            if ((r >> 48) % 2 == 0) {
                _bobOffers.push(_offer(slot, qty, 200_000));
            } else {
                vm.prank(bob);
                _bobBids.push(bobP.placeBids(MarketTypes.EnergyType.ELECTRICITY, _one(slot, qty, 250_000))[0]);
            }
        }
    }

    function _matchingStep(uint256 r) internal {
        if (_aliceIds.length == 0) return;
        bytes32 aliceId = _aliceIds[r % _aliceIds.length];
        MarketTypes.Order memory a = session.orderOf(aliceId);
        if (a.status != MarketTypes.OrderStatus.OPEN || a.matched == a.quantity) {
            if (_record(aliceId).status == PositionLedger.Status.OPEN) _reconcile(aliceId);
            return;
        }

        bytes32[] storage counter = a.side == MarketTypes.Side.BID ? _bobOffers : _bobBids;
        uint256 start = counter.length == 0 ? 0 : (r >> 8) % counter.length;
        for (uint256 i = 0; i < counter.length; ++i) {
            MarketTypes.Order memory b = session.orderOf(counter[(start + i) % counter.length]);
            if (b.slot != a.slot || b.status != MarketTypes.OrderStatus.OPEN || b.matched == b.quantity) continue;
            uint64 room = _min64(a.quantity - a.matched, b.quantity - b.matched);
            uint64 qty = 1 + uint64((r >> 16) % room);
            if (a.side == MarketTypes.Side.BID) _trade(aliceId, b.id, qty, 220_000);
            else _trade(b.id, aliceId, qty, 220_000);
            break;
        }
        if ((r >> 32) % 2 == 0 && _record(aliceId).status == PositionLedger.Status.OPEN) _reconcile(aliceId);
    }

    function _assertBooksBalance() internal view {
        uint256 openRecords;
        for (uint32 s = firstSlot; s < firstSlot + 3; ++s) {
            uint64[2] memory committed;
            uint64[2] memory cleared;
            for (uint256 i = 0; i < _aliceIds.length; ++i) {
                PositionLedger.OrderRecord memory rec = _record(_aliceIds[i]);
                if (rec.slot != s) continue;
                uint256 side = uint256(uint8(rec.side));
                committed[side] += rec.status == PositionLedger.Status.OPEN ? rec.qtyWh : rec.filledWh;
                cleared[side] += rec.filledWh;
                if (rec.status == PositionLedger.Status.OPEN) ++openRecords;
            }
            PositionLedger.Position memory p = _position(s);
            assertEq(p.committedBuyWh, committed[0], "committed buy");
            assertEq(p.committedSellWh, committed[1], "committed sell");
            assertEq(p.clearedBuyWh, cleared[0], "cleared buy");
            assertEq(p.clearedSellWh, cleared[1], "cleared sell");
        }
        assertEq(ledger.openOrderCount(address(aliceAccount)), openRecords, "open count");
    }

    function _min64(uint64 a, uint64 b) internal pure returns (uint64) {
        return a < b ? a : b;
    }
}
