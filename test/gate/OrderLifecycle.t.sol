// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {PolicyGate} from "../../contracts/gate/PolicyGate.sol";
import {PositionLedger} from "../../contracts/gate/PositionLedger.sol";
import {Order, OrderKind, Side} from "../../contracts/gate/GateTypes.sol";
import {MockEnergyMarket} from "./mocks/MockEnergyMarket.sol";
import {MockMarketDecoder} from "./mocks/MockMarketDecoder.sol";
import {MiniAccount} from "../../contracts/harness/MiniAccount.sol";

/// Step 2 of the v0.1 build order: the order lifecycle.
///
/// An order is placed, partly or fully filled, cancelled, modified, or left to
/// expire when its slot's gate closes. The position ledger follows it: per slot,
/// committed volume (placed and not released) and cleared volume (filled).
///
/// Acceptance criteria (spec Section 9, step 2), one group each:
/// place, partial fill, full fill, cancel, modify of price, quantity and slot,
/// expiry with release, permissionless reconcile, the open-order bound.
///
/// Time: 30-minute slots, trading in a slot closing one hour before it starts.
/// The tests trade slot 10, which starts five hours after genesis.
contract OrderLifecycleTest is Test {
    uint256 internal constant EXECUTOR = 2;
    uint64 internal constant GENESIS = 1_760_000_400;
    uint32 internal constant SLOT_SECONDS = 1800;
    uint32 internal constant GATE_LEAD = 3600;
    uint32 internal constant SLOT = 10;
    uint64 internal constant PRICE = 250_000;

    PositionLedger internal ledger;
    PolicyGate internal gate;
    MiniAccount internal account;
    MockEnergyMarket internal market;
    MockMarketDecoder internal decoder;

    address internal owner = makeAddr("owner");
    address internal agent = makeAddr("agent");
    address internal operator = makeAddr("clearingEngine");
    address internal keeper = makeAddr("keeper");

    function setUp() public {
        vm.warp(GENESIS);

        ledger = new PositionLedger();
        gate = new PolicyGate(ledger, 48);
        account = new MiniAccount(owner);
        market = new MockEnergyMarket(GENESIS, SLOT_SECONDS, GATE_LEAD, operator);
        decoder = new MockMarketDecoder();

        vm.startPrank(owner);
        account.installModule(EXECUTOR, address(gate), "");
        account.execute(address(ledger), 0, abi.encodeCall(ledger.setWriter, (address(gate), true)));
        account.execute(address(gate), 0, abi.encodeCall(gate.registerAgent, (agent, uint48(GENESIS + 30 days))));
        bytes4[3] memory selectors = [
            MockEnergyMarket.placeOrder.selector,
            MockEnergyMarket.cancelOrder.selector,
            MockEnergyMarket.modifyOrder.selector
        ];
        for (uint256 i = 0; i < selectors.length; ++i) {
            account.execute(address(gate), 0, abi.encodeCall(gate.setDecoder, (address(market), selectors[i], decoder)));
        }
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _place(Side side, uint32 slot, uint64 qtyWh, uint64 price) internal returns (bytes32 orderId) {
        vm.prank(agent);
        gate.submit(address(account), address(market), abi.encodeCall(MockEnergyMarket.placeOrder, (side, slot, qtyWh, price)));
        return bytes32(market.orderCount());
    }

    function _buy(uint64 qtyWh) internal returns (bytes32) {
        return _place(Side.BUY, SLOT, qtyWh, PRICE);
    }

    function _cancel(bytes32 orderId) internal {
        vm.prank(agent);
        gate.submit(address(account), address(market), abi.encodeCall(MockEnergyMarket.cancelOrder, (orderId)));
    }

    function _modify(bytes32 orderId, uint32 slot, uint64 qtyWh, uint64 price) internal returns (bytes32) {
        vm.prank(agent);
        gate.submit(
            address(account), address(market), abi.encodeCall(MockEnergyMarket.modifyOrder, (orderId, slot, qtyWh, price))
        );
        return bytes32(market.orderCount());
    }

    function _fill(bytes32 orderId, uint64 qtyWh) internal {
        vm.prank(operator);
        market.fill(orderId, qtyWh, PRICE);
    }

    function _reconcile(bytes32 orderId) internal returns (uint64 filledWh, uint64 releasedWh) {
        vm.prank(keeper);
        return gate.reconcile(address(account), address(market), orderId);
    }

    function _position(uint32 slot) internal view returns (PositionLedger.Position memory) {
        return ledger.positionOf(address(account), slot);
    }

    function _record(bytes32 orderId) internal view returns (PositionLedger.OrderRecord memory) {
        return ledger.recordOf(address(account), address(market), orderId);
    }

    function _assertBuy(uint32 slot, uint64 committed, uint64 cleared) internal view {
        PositionLedger.Position memory p = _position(slot);
        assertEq(p.committedBuyWh, committed, "committed buy");
        assertEq(p.clearedBuyWh, cleared, "cleared buy");
    }

    // ------------------------------------------------------------------
    // Place
    // ------------------------------------------------------------------

    function test_placeBooksACommittedBuy() public {
        bytes32 orderId = _buy(2000);

        _assertBuy(SLOT, 2000, 0);
        assertEq(ledger.openOrderCount(address(account)), 1);

        PositionLedger.OrderRecord memory r = _record(orderId);
        assertEq(uint8(r.status), uint8(PositionLedger.Status.OPEN));
        assertEq(address(r.decoder), address(decoder));
        assertEq(uint8(r.side), uint8(Side.BUY));
        assertEq(r.slot, SLOT);
        assertEq(r.placedAt, GENESIS);
        assertEq(r.qtyWh, 2000);
        assertEq(r.price, PRICE);
        assertEq(r.filledWh, 0);

        // The market holds it, owned by the account.
        assertEq(market.orderOf(orderId).owner, address(account));
    }

    function test_placeBooksACommittedSell() public {
        _place(Side.SELL, SLOT, 1500, PRICE);

        PositionLedger.Position memory p = _position(SLOT);
        assertEq(p.committedSellWh, 1500);
        assertEq(p.committedBuyWh, 0);
    }

    function test_placementIsValuedAtTheLimitPriceRoundedUp() public {
        // 1 Wh at 1 unit per kWh is worth a thousandth of a unit: rounds up to 1.
        Order[] memory legs = decoder.decode(
            address(market), abi.encodeCall(MockEnergyMarket.placeOrder, (Side.BUY, SLOT, 1, 1))
        );
        assertEq(legs.length, 1);
        assertEq(legs[0].value, 1);

        legs = decoder.decode(address(market), abi.encodeCall(MockEnergyMarket.placeOrder, (Side.BUY, SLOT, 2000, PRICE)));
        assertEq(legs[0].value, 500_000);
    }

    function test_aValueBeyondTheTypeIsRefused() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                MockMarketDecoder.MockMarketDecoder_ValueOverflow.selector, type(uint64).max, type(uint64).max
            )
        );
        decoder.decode(
            address(market),
            abi.encodeCall(MockEnergyMarket.placeOrder, (Side.BUY, SLOT, type(uint64).max, type(uint64).max))
        );
    }

    // ------------------------------------------------------------------
    // Fills
    // ------------------------------------------------------------------

    function test_partialFillIsBookedOnReconcile() public {
        bytes32 orderId = _buy(2000);
        _fill(orderId, 600);

        // Until someone reconciles, the fill is not credited: the safe side.
        _assertBuy(SLOT, 2000, 0);

        vm.expectEmit(true, true, true, true, address(gate));
        emit PolicyGate.Reconciled(address(account), address(market), orderId, 600, 0);
        (uint64 filled, uint64 released) = _reconcile(orderId);

        assertEq(filled, 600);
        assertEq(released, 0);
        _assertBuy(SLOT, 2000, 600);
        assertEq(uint8(_record(orderId).status), uint8(PositionLedger.Status.OPEN));
        assertEq(ledger.openOrderCount(address(account)), 1);
    }

    function test_fullFillClosesTheOrderAndReleasesNothing() public {
        bytes32 orderId = _buy(2000);
        _fill(orderId, 600);
        _fill(orderId, 1400);

        vm.expectEmit(true, true, true, true, address(ledger));
        emit PositionLedger.OrderClosed(
            address(account), address(market), orderId, PositionLedger.CloseReason.FILLED, 0
        );
        (uint64 filled, uint64 released) = _reconcile(orderId);

        assertEq(filled, 2000);
        assertEq(released, 0);
        _assertBuy(SLOT, 2000, 2000);
        assertEq(uint8(_record(orderId).status), uint8(PositionLedger.Status.CLOSED));
        assertEq(ledger.openOrderCount(address(account)), 0);
    }

    function test_reconcileWithNothingNewChangesNothing() public {
        bytes32 orderId = _buy(2000);

        (uint64 filled, uint64 released) = _reconcile(orderId);

        assertEq(filled, 0);
        assertEq(released, 0);
        _assertBuy(SLOT, 2000, 0);
        assertEq(uint8(_record(orderId).status), uint8(PositionLedger.Status.OPEN));
    }

    // ------------------------------------------------------------------
    // Cancel
    // ------------------------------------------------------------------

    function test_cancelReleasesTheUnfilledOrder() public {
        bytes32 orderId = _buy(2000);

        vm.expectEmit(true, true, true, true, address(ledger));
        emit PositionLedger.OrderClosed(
            address(account), address(market), orderId, PositionLedger.CloseReason.CANCELLED, 2000
        );
        _cancel(orderId);

        _assertBuy(SLOT, 0, 0);
        assertEq(ledger.openOrderCount(address(account)), 0);
        assertTrue(market.orderOf(orderId).cancelled);
    }

    /// A fill nobody has reconciled yet is booked by the cancellation itself,
    /// so the filled part stays committed and only the rest is released.
    function test_cancelAfterAnUnbookedPartialFillBooksTheFillFirst() public {
        bytes32 orderId = _buy(2000);
        _fill(orderId, 500);

        // The cancel leg carries what the market says is unfilled.
        Order[] memory legs =
            decoder.decode(address(market), abi.encodeCall(MockEnergyMarket.cancelOrder, (orderId)));
        assertEq(uint8(legs[0].kind), uint8(OrderKind.CANCEL));
        assertEq(legs[0].qtyWh, 1500);
        assertEq(legs[0].orderId, orderId);

        _cancel(orderId);

        _assertBuy(SLOT, 500, 500);
        assertEq(_record(orderId).filledWh, 500);
    }

    // ------------------------------------------------------------------
    // Modify
    // ------------------------------------------------------------------

    function test_modifyDecodesAsCancelThenPlace() public {
        bytes32 orderId = _buy(2000);
        _fill(orderId, 500);

        Order[] memory legs = decoder.decode(
            address(market), abi.encodeCall(MockEnergyMarket.modifyOrder, (orderId, SLOT + 2, 3000, 200_000))
        );

        assertEq(legs.length, 2);
        assertEq(uint8(legs[0].kind), uint8(OrderKind.CANCEL));
        assertEq(legs[0].orderId, orderId);
        assertEq(legs[0].qtyWh, 1500);
        assertEq(legs[0].slot, SLOT);
        assertEq(uint8(legs[1].kind), uint8(OrderKind.PLACE));
        assertEq(uint8(legs[1].side), uint8(Side.BUY));
        assertEq(legs[1].slot, SLOT + 2);
        assertEq(legs[1].qtyWh, 3000);
        assertEq(legs[1].price, 200_000);
    }

    function test_modifyPrice() public {
        bytes32 oldId = _buy(2000);
        bytes32 newId = _modify(oldId, SLOT, 2000, 200_000);

        assertEq(uint8(_record(oldId).status), uint8(PositionLedger.Status.CLOSED));
        assertEq(_record(newId).price, 200_000);
        _assertBuy(SLOT, 2000, 0);
        assertEq(ledger.openOrderCount(address(account)), 1);
    }

    function test_modifyQuantity() public {
        bytes32 oldId = _buy(2000);
        bytes32 newId = _modify(oldId, SLOT, 3000, PRICE);

        assertEq(_record(newId).qtyWh, 3000);
        _assertBuy(SLOT, 3000, 0);
        assertEq(ledger.openOrderCount(address(account)), 1);
    }

    function test_modifySlotMovesTheCommitment() public {
        bytes32 oldId = _buy(2000);
        bytes32 newId = _modify(oldId, SLOT + 2, 2000, PRICE);

        _assertBuy(SLOT, 0, 0);
        _assertBuy(SLOT + 2, 2000, 0);
        assertEq(_record(newId).slot, SLOT + 2);
    }

    /// The filled part of the old order stays where it is; only the unfilled
    /// part is replaced.
    function test_modifyAfterAPartialFillKeepsTheFill() public {
        bytes32 oldId = _buy(2000);
        _fill(oldId, 500);
        bytes32 newId = _modify(oldId, SLOT, 1000, PRICE);

        _assertBuy(SLOT, 1500, 500);
        assertEq(_record(oldId).filledWh, 500);
        assertEq(_record(newId).qtyWh, 1000);
    }

    // ------------------------------------------------------------------
    // Expiry
    // ------------------------------------------------------------------

    function test_expiryReleasesTheUnfilledPartAtGateClosure() public {
        bytes32 orderId = _buy(2000);
        _fill(orderId, 800);
        uint64 closes = market.gateTime(SLOT);

        // One second before closure: the fill is booked, the order stays open.
        vm.warp(closes - 1);
        _reconcile(orderId);
        _assertBuy(SLOT, 2000, 800);
        assertEq(uint8(_record(orderId).status), uint8(PositionLedger.Status.OPEN));

        // At closure the rest expires and is released.
        vm.warp(closes);
        vm.expectEmit(true, true, true, true, address(ledger));
        emit PositionLedger.OrderClosed(
            address(account), address(market), orderId, PositionLedger.CloseReason.EXPIRED, 1200
        );
        (uint64 filled, uint64 released) = _reconcile(orderId);

        assertEq(filled, 0);
        assertEq(released, 1200);
        _assertBuy(SLOT, 800, 800);
        assertEq(ledger.openOrderCount(address(account)), 0);
    }

    function test_anUnfilledOrderExpiresEntirely() public {
        bytes32 orderId = _buy(2000);
        vm.warp(market.gateTime(SLOT) + 1 days);

        (, uint64 released) = _reconcile(orderId);

        assertEq(released, 2000);
        _assertBuy(SLOT, 0, 0);
    }

    /// Cancelled outside the gate, for instance by the owner directly: the
    /// market no longer holds it, and reconcile closes it with its own reason,
    /// distinct from both a cancellation by the agent and an expiry.
    function test_anOrderClosedOutsideTheGateIsReleasedWithItsOwnReason() public {
        bytes32 orderId = _buy(2000);

        vm.prank(owner);
        account.execute(address(market), 0, abi.encodeCall(MockEnergyMarket.cancelOrder, (orderId)));

        vm.expectEmit(true, true, true, true, address(ledger));
        emit PositionLedger.OrderClosed(
            address(account), address(market), orderId, PositionLedger.CloseReason.CLOSED_ELSEWHERE, 2000
        );
        _reconcile(orderId);

        _assertBuy(SLOT, 0, 0);
    }

    // ------------------------------------------------------------------
    // Reconcile is permissionless
    // ------------------------------------------------------------------

    function testFuzz_anyoneCanReconcile(address caller) public {
        vm.assume(caller != address(0));
        bytes32 orderId = _buy(2000);
        _fill(orderId, 700);

        vm.prank(caller);
        (uint64 filled,) = gate.reconcile(address(account), address(market), orderId);

        assertEq(filled, 700);
        _assertBuy(SLOT, 2000, 700);
    }

    /// Only the gate's path is open to anyone. The ledger itself takes writes
    /// from the account's writers alone.
    function test_theLedgerItselfAcceptsOnlyTheAccountsWriters() public {
        bytes32 orderId = _buy(2000);

        vm.expectRevert(
            abi.encodeWithSelector(PositionLedger.PositionLedger_NotWriter.selector, address(account), keeper)
        );
        vm.prank(keeper);
        ledger.reconcile(address(account), address(market), orderId);
    }

    function test_reconcilingAClosedOrUnknownOrderIsRefused() public {
        bytes32 orderId = _buy(2000);
        _cancel(orderId);

        vm.expectRevert(
            abi.encodeWithSelector(PositionLedger.PositionLedger_NotOpen.selector, address(market), orderId)
        );
        _reconcile(orderId);

        bytes32 unknown = bytes32(uint256(999));
        vm.expectRevert(
            abi.encodeWithSelector(PositionLedger.PositionLedger_NotOpen.selector, address(market), unknown)
        );
        _reconcile(unknown);
    }

    // ------------------------------------------------------------------
    // The open-order bound
    // ------------------------------------------------------------------

    function test_openOrdersAreBounded() public {
        uint256 max = ledger.MAX_OPEN_ORDERS();
        for (uint256 i = 0; i < max; ++i) {
            _buy(100);
        }
        assertEq(ledger.openOrderCount(address(account)), max);

        // One more is refused, and the market never sees it.
        uint256 before = market.orderCount();
        vm.expectRevert(
            abi.encodeWithSelector(PositionLedger.PositionLedger_TooManyOpenOrders.selector, address(account))
        );
        vm.prank(agent);
        gate.submit(
            address(account), address(market), abi.encodeCall(MockEnergyMarket.placeOrder, (Side.BUY, SLOT, 100, PRICE))
        );
        assertEq(market.orderCount(), before);

        // A modification at the bound is a cancel then a place, so it fits.
        _modify(bytes32(uint256(1)), SLOT, 200, PRICE);
        assertEq(ledger.openOrderCount(address(account)), max);

        // Closing one makes room for one.
        _cancel(bytes32(uint256(2)));
        _buy(100);
        assertEq(ledger.openOrderCount(address(account)), max);
    }

    // ------------------------------------------------------------------
    // What the agent may not do
    // ------------------------------------------------------------------

    /// The owner placed this order directly. The market would let the account
    /// cancel it, but the ledger holds no record of it, so the whole submission
    /// reverts: the agent acts only on its own orders.
    function test_agentCannotCancelAnOrderThatWasNotPlacedThroughTheGate() public {
        vm.prank(owner);
        account.execute(
            address(market), 0, abi.encodeCall(MockEnergyMarket.placeOrder, (Side.SELL, SLOT, 5000, PRICE))
        );
        bytes32 ownersOrder = bytes32(market.orderCount());

        vm.expectRevert(
            abi.encodeWithSelector(PositionLedger.PositionLedger_NotOpen.selector, address(market), ownersOrder)
        );
        _cancel(ownersOrder);

        assertTrue(market.isOpen(ownersOrder));
    }

    // ------------------------------------------------------------------
    // The market's own rules
    // ------------------------------------------------------------------

    function test_noPlacementAtOrAfterGateClosure() public {
        uint64 closes = market.gateTime(SLOT);

        vm.warp(closes - 1);
        _buy(100);

        vm.warp(closes);
        vm.expectRevert(abi.encodeWithSelector(MockEnergyMarket.MockEnergyMarket_GateClosed.selector, SLOT, closes));
        vm.prank(agent);
        gate.submit(
            address(account), address(market), abi.encodeCall(MockEnergyMarket.placeOrder, (Side.BUY, SLOT, 100, PRICE))
        );
    }

    function test_noCancelOrFillAfterGateClosure() public {
        bytes32 orderId = _buy(2000);
        vm.warp(market.gateTime(SLOT));

        vm.expectRevert(abi.encodeWithSelector(MockEnergyMarket.MockEnergyMarket_NotOpen.selector, orderId));
        _cancel(orderId);

        vm.expectRevert(abi.encodeWithSelector(MockEnergyMarket.MockEnergyMarket_NotOpen.selector, orderId));
        _fill(orderId, 100);
    }

    function test_fillsRespectTheLimitPriceAndTheQuantity() public {
        bytes32 buyId = _buy(2000);
        bytes32 sellId = _place(Side.SELL, SLOT, 2000, PRICE);

        vm.startPrank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                MockEnergyMarket.MockEnergyMarket_PriceOutsideLimit.selector, buyId, PRICE + 1, PRICE
            )
        );
        market.fill(buyId, 100, PRICE + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                MockEnergyMarket.MockEnergyMarket_PriceOutsideLimit.selector, sellId, PRICE - 1, PRICE
            )
        );
        market.fill(sellId, 100, PRICE - 1);

        vm.expectRevert(abi.encodeWithSelector(MockEnergyMarket.MockEnergyMarket_OverFill.selector, buyId, 2000));
        market.fill(buyId, 2001, PRICE);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(MockEnergyMarket.MockEnergyMarket_NotOperator.selector, agent));
        vm.prank(agent);
        market.fill(buyId, 100, PRICE);
    }

    // ------------------------------------------------------------------
    // The books always balance
    // ------------------------------------------------------------------

    bytes32[] internal _ids;

    /// A random sequence of placements, fills, cancellations, modifications,
    /// reconciliations and time steps over three slots. After every step, for
    /// each slot and side:
    ///
    ///   committed = quantity of open orders + filled quantity of closed orders
    ///   cleared   = filled quantity booked, open or closed
    ///
    /// and the open-order count equals the number of open records. At the end,
    /// past every gate, reconciling everything leaves committed equal to
    /// cleared: all that was not filled has been released.
    function testFuzz_theBooksBalance(uint256 seed) public {
        for (uint256 step = 0; step < 24; ++step) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            _randomAction(r);
            _assertBooksBalance();
        }

        vm.warp(market.gateTime(SLOT + 2) + 1);
        for (uint256 i = 0; i < _ids.length; ++i) {
            if (_record(_ids[i]).status == PositionLedger.Status.OPEN) _reconcile(_ids[i]);
        }
        _assertBooksBalance();
        for (uint32 slot = SLOT; slot <= SLOT + 2; ++slot) {
            PositionLedger.Position memory p = _position(slot);
            assertEq(p.committedBuyWh, p.clearedBuyWh, "buy: unfilled left committed");
            assertEq(p.committedSellWh, p.clearedSellWh, "sell: unfilled left committed");
        }
        assertEq(ledger.openOrderCount(address(account)), 0);
    }

    function _randomAction(uint256 r) internal {
        uint256 action = r % 6;
        uint32 slot = SLOT + uint32((r >> 8) % 3);
        uint64 qty = uint64(100 + (r >> 16) % 4900);
        bool gateOpen = block.timestamp < market.gateTime(slot);

        if (action == 0 || _ids.length == 0) {
            if (gateOpen && ledger.openOrderCount(address(account)) < ledger.MAX_OPEN_ORDERS()) {
                _ids.push(_place((r >> 32) % 2 == 0 ? Side.BUY : Side.SELL, slot, qty, PRICE));
            }
            return;
        }

        bytes32 orderId = _ids[(r >> 40) % _ids.length];
        bool open = _record(orderId).status == PositionLedger.Status.OPEN;

        if (action == 1 && market.isOpen(orderId)) {
            uint64 remaining = market.remainingOf(orderId);
            _fill(orderId, 1 + uint64((r >> 48) % remaining));
        } else if (action == 2 && open && market.isOpen(orderId)) {
            _cancel(orderId);
        } else if (action == 3 && open && market.isOpen(orderId) && gateOpen) {
            _ids.push(_modify(orderId, slot, qty, PRICE));
        } else if (action == 4 && open) {
            _reconcile(orderId);
        } else if (action == 5) {
            vm.warp(block.timestamp + (r >> 56) % 2 hours);
        }
    }

    function _assertBooksBalance() internal view {
        uint256 openRecords;
        for (uint32 slot = SLOT; slot <= SLOT + 2; ++slot) {
            uint64[2] memory committed;
            uint64[2] memory cleared;
            for (uint256 i = 0; i < _ids.length; ++i) {
                PositionLedger.OrderRecord memory rec = _record(_ids[i]);
                if (rec.slot != slot) continue;
                uint256 side = uint256(uint8(rec.side));
                committed[side] += rec.status == PositionLedger.Status.OPEN ? rec.qtyWh : rec.filledWh;
                cleared[side] += rec.filledWh;
                if (rec.status == PositionLedger.Status.OPEN) ++openRecords;
            }
            PositionLedger.Position memory p = _position(slot);
            assertEq(p.committedBuyWh, committed[0], "committed buy");
            assertEq(p.committedSellWh, committed[1], "committed sell");
            assertEq(p.clearedBuyWh, cleared[0], "cleared buy");
            assertEq(p.clearedSellWh, cleared[1], "cleared sell");
        }
        assertEq(ledger.openOrderCount(address(account)), openRecords, "open count");
    }
}
