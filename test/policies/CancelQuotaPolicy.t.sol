// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {PolicyFixture} from "./PolicyFixture.sol";
import {CancelQuotaPolicy} from "../../contracts/policies/CancelQuotaPolicy.sol";
import {WindowLib} from "../../contracts/policies/WindowLib.sol";
import {Order, OrderKind, Side, ConfigChange, CheckContext} from "../../contracts/gate/GateTypes.sol";

/// Step 4.5: S6, the cancellation and message quota (spec 6.7), on windows of
/// an hour in five-minute buckets, through the gate on the mock market.
///
/// The default instance: at most 2500 weighted Wh cancelled and 10 messages
/// an hour; a cancellation within 30 minutes of the gate counts three times;
/// cancelled Wh at most 100% of placed Wh plus 500 Wh free.
contract CancelQuotaPolicyTest is PolicyFixture {
    bytes32 internal constant ID = keccak256("S6");

    CancelQuotaPolicy internal policy;

    function setUp() public override {
        super.setUp();
        policy = new CancelQuotaPolicy(address(gate));
        _addPolicy(policy, ID, abi.encode(_config()));
    }

    function _config() internal pure returns (CancelQuotaPolicy.Config memory c) {
        c.window.kind = WindowLib.Kind.SLIDING;
        c.window.step = 300;
        c.window.buckets = 12;
        c.maxCancelledWh = 2500;
        c.maxMessages = 10;
        c.gateWeightPercent = 300;
        c.gateWindowSeconds = 30 minutes;
        c.ratioPercent = 100;
        c.freeCancelWh = 500;
    }

    /// A slot whose gate closes in four hours.
    uint32 internal constant FAR = SLOT + 10;

    // ------------------------------------------------------------------
    // The cancelled-Wh cap
    // ------------------------------------------------------------------

    function test_cancelledVolumeIsCappedInclusively() public {
        bytes32 a = _place(Side.BUY, FAR, 1000, PRICE);
        bytes32 b = _place(Side.BUY, FAR, 1500, PRICE);
        bytes32 c = _place(Side.BUY, FAR, 1, PRICE);

        _cancel(a);
        _cancel(b);
        _assertCancelled(2500);
        assertFalse(market.isOpen(b), "exactly at the cap");

        _cancel(c);
        assertTrue(market.isOpen(c), "one Wh over: refused");
        _assertCancelled(2500);
    }

    /// Within 30 minutes of the gate a cancellation weighs three times: 1000 Wh
    /// counts 3000, over the cap; 40 minutes before, it counts 1000.
    function test_aCancellationNearTheGateWeighsMore() public {
        uint64 gateAt = market.gateTime(FAR);
        vm.warp(gateAt - 45 minutes);
        bytes32 a = _place(Side.BUY, FAR, 1000, PRICE);
        bytes32 b = _place(Side.BUY, FAR, 1000, PRICE);

        vm.warp(gateAt - 40 minutes);
        _cancel(a);
        assertFalse(market.isOpen(a));
        _assertCancelled(1000);

        vm.warp(gateAt - 20 minutes);
        _cancel(b);
        assertTrue(market.isOpen(b), "3000 weighted Wh: refused");
    }

    /// The weight applies from exactly 30 minutes before the gate.
    function test_theGateWindowStartsExactlyAtItsLength() public view {
        uint64 gateAt = market.gateTime(FAR);
        assertEq(_weighted(1000, gateAt - 30 minutes - 1), 1000);
        assertEq(_weighted(1000, gateAt - 30 minutes), 3000);
    }

    // ------------------------------------------------------------------
    // The cancel-to-place ratio
    // ------------------------------------------------------------------

    /// cancelled <= 100% of placed + 500. Placed 2000: cancelling 1000 leaves
    /// 1000 <= 2500; cancelling the other 1000 leaves 2000 <= 2500; a third
    /// order placed before the policy existed is not "placed" for it.
    function test_cancellationsAreBoundedByWhatWasPlaced() public {
        _remove();
        uint32 slot = market.currentSlot() + 10;
        bytes32 before = _place(Side.BUY, slot, 1000, PRICE); // not seen by the policy
        _readd(_withRatio(50));

        bytes32 a = _place(Side.BUY, slot, 1000, PRICE);
        // 50% of 1000 + 500 = 1000: cancelling 1000 of it is the limit.
        _cancel(a);
        assertFalse(market.isOpen(a));
        _cancel(before);
        assertTrue(market.isOpen(before), "2000 > 50% of 1000 + 500");
        assertEq(_reasons(slot, 1000) & policy.RATIO(), policy.RATIO());
    }

    /// The free allowance lets a first cancellation through with nothing
    /// placed in the window.
    function test_theFreeAllowanceLetsAFirstCancellationThrough() public {
        _remove();
        uint32 slot = market.currentSlot() + 10;
        bytes32 small = _place(Side.BUY, slot, 500, PRICE);
        bytes32 big = _place(Side.BUY, slot, 501, PRICE);
        _readd(_config());

        _cancel(big);
        assertTrue(market.isOpen(big), "501 > 0 + 500");
        _cancel(small);
        assertFalse(market.isOpen(small), "500 <= 0 + 500");
    }

    // ------------------------------------------------------------------
    // Messages
    // ------------------------------------------------------------------

    /// Ten submissions an hour, whatever they are; the eleventh is refused.
    function test_messagesAreCounted() public {
        for (uint256 i = 0; i < 10; ++i) {
            assertTrue(_place(Side.BUY, FAR, 10, PRICE) != bytes32(0));
        }
        assertEq(_place(Side.BUY, FAR, 10, PRICE), bytes32(0), "the eleventh");
        (,, uint64 messages) = policy.usedOf(address(account), ID);
        assertEq(messages, 10, "a refused submission is not a message sent");
    }

    // ------------------------------------------------------------------
    // Expiry, and the window
    // ------------------------------------------------------------------

    /// An expiry is not a cancellation: it uses none of the quota.
    function test_anExpiryIsNotACancellation() public {
        bytes32 a = _place(Side.BUY, SLOT, 2000, PRICE);
        vm.warp(market.gateTime(SLOT));
        _reconcile(a);
        _assertCancelled(0);
    }

    function test_theQuotaRenewsAfterAnHour() public {
        bytes32 a = _place(Side.BUY, FAR, 2500, PRICE);
        bytes32 b = _place(Side.BUY, FAR, 1000, PRICE);
        _cancel(a);
        _cancel(b);
        assertTrue(market.isOpen(b));

        vm.warp(block.timestamp + 1 hours);
        bytes32 c = _place(Side.BUY, FAR + 4, 1000, PRICE);
        _cancel(b);
        assertFalse(market.isOpen(b), "the earlier cancellations left the window");
        assertTrue(c != bytes32(0));
    }

    // ------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------

    function test_theDirectionTable() public view {
        CancelQuotaPolicy.Config[6] memory looser;
        for (uint256 i = 0; i < 6; ++i) looser[i] = _config();
        looser[0].maxCancelledWh += 1;
        looser[1].maxMessages += 1;
        looser[2].gateWeightPercent -= 1;
        looser[3].gateWindowSeconds -= 1;
        looser[4].ratioPercent += 1;
        looser[5].freeCancelWh += 1;
        for (uint256 i = 0; i < 6; ++i) assertEq(uint8(_classify(looser[i])), uint8(ConfigChange.WIDEN));

        CancelQuotaPolicy.Config[6] memory tighter;
        for (uint256 i = 0; i < 6; ++i) tighter[i] = _config();
        tighter[0].maxCancelledWh -= 1;
        tighter[1].maxMessages -= 1;
        tighter[2].gateWeightPercent += 1;
        tighter[3].gateWindowSeconds += 1;
        tighter[4].ratioPercent -= 1;
        tighter[5].freeCancelWh -= 1;
        for (uint256 i = 0; i < 6; ++i) assertEq(uint8(_classify(tighter[i])), uint8(ConfigChange.TIGHTEN));

        CancelQuotaPolicy.Config memory shape = _config();
        shape.window.buckets = 6;
        assertEq(uint8(_classify(shape)), uint8(ConfigChange.WIDEN), "a new shape starts afresh");
        CancelQuotaPolicy.Config memory light = _config();
        light.gateWeightPercent = 99;
        assertEq(uint8(_classify(light)), uint8(ConfigChange.INVALID), "a weight below 1x");
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _withRatio(uint32 percent) internal pure returns (CancelQuotaPolicy.Config memory c) {
        c = _config();
        c.ratioPercent = percent;
    }

    function _remove() internal {
        _asAccount(abi.encodeCall(gate.proposeRemovePolicy, (policy, ID)));
        vm.warp(block.timestamp + gate.WIDEN_DELAY());
        _asAccount(abi.encodeCall(gate.applyRemovePolicy, (policy, ID)));
    }

    function _readd(CancelQuotaPolicy.Config memory c) internal {
        _addPolicy(policy, ID, abi.encode(c));
    }

    function _classify(CancelQuotaPolicy.Config memory c) internal view returns (ConfigChange) {
        return policy.classifyConfig(address(account), ID, abi.encode(c));
    }

    function _assertCancelled(uint256 expected) internal view {
        (uint64 cancelled,,) = policy.usedOf(address(account), ID);
        assertEq(cancelled, expected);
    }

    function _cancelLeg(uint32 slot, uint64 qtyWh) internal pure returns (Order[] memory legs) {
        legs = new Order[](1);
        legs[0].kind = OrderKind.CANCEL;
        legs[0].side = Side.BUY;
        legs[0].slot = slot;
        legs[0].qtyWh = qtyWh;
    }

    function _ctx(uint64 time) internal view returns (CheckContext memory) {
        return CheckContext({market: address(market), decoder: address(decoder), time: time});
    }

    /// @dev The weighted Wh a cancellation of `qtyWh` in FAR adds at `time`.
    function _weighted(uint64 qtyWh, uint64 time) internal view returns (uint256) {
        return policy.check(address(account), ID, _cancelLeg(FAR, qtyWh), _ctx(time)).valueAfter;
    }

    function _reasons(uint32 slot, uint64 qtyWh) internal view returns (uint256) {
        return policy.reasons(address(account), ID, _cancelLeg(slot, qtyWh), _ctx(uint64(block.timestamp)));
    }
}
