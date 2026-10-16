// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Vm} from "forge-std/Test.sol";
import {PolicyFixture} from "./PolicyFixture.sol";
import {WindowPolicy} from "../../contracts/policies/WindowPolicy.sol";
import {WindowLib} from "../../contracts/policies/WindowLib.sol";
import {Side, ConfigChange, Verdict, CheckResult, valueUp} from "../../contracts/gate/GateTypes.sol";
import {MockEnergyMarket} from "../gate/mocks/MockEnergyMarket.sol";

/// Step 4.4: S1, the owner's budget, and S2, the export and import caps
/// (spec 6.2, 6.3), on sliding windows of 24 one-hour buckets, through the
/// gate on the mock market.
///
/// Prices are 0.25 per kWh, so 1000 Wh is worth 250,000 units.
contract WindowPolicyTest is PolicyFixture {
    bytes32 internal constant S1 = keccak256("S1 budget");
    bytes32 internal constant EXPORT = keccak256("S2 export");
    bytes32 internal constant IMPORT = keccak256("S2 import");
    uint32 internal constant HOUR = 3600;

    WindowPolicy internal policy;

    function setUp() public override {
        super.setUp();
        policy = new WindowPolicy(address(gate));
    }

    // ------------------------------------------------------------------
    // S1: the owner's budget
    // ------------------------------------------------------------------

    /// Cap 1,000,000 units, soft bound 750,000.
    function test_S1_countsBuyValueFlagsAboveSoftAndRejectsAboveHard() public {
        _add(S1, WindowPolicy.Quantity.BUY_VALUE, 750_000, 1_000_000);

        vm.recordLogs();
        assertTrue(_buy(2000) != 0, "500,000: execute");
        assertTrue(_buy(1000) != 0, "750,000: at the soft bound, execute");
        assertTrue(_buy(400) != 0, "850,000: flag, executed");
        assertTrue(_buy(700) == 0, "1,025,000: reject");
        CheckResult[] memory r = _resultsFor(vm.getRecordedLogs(), address(policy));

        assertEq(r.length, 4);
        assertEq(uint8(r[0].verdict), uint8(Verdict.EXECUTE));
        assertEq(uint8(r[1].verdict), uint8(Verdict.EXECUTE));
        assertEq(uint8(r[2].verdict), uint8(Verdict.FLAG));
        assertEq(uint8(r[3].verdict), uint8(Verdict.REJECT));
        assertEq(r[3].valueBefore, 850_000);
        assertEq(r[3].valueAfter, 1_025_000);
        assertEq(r[3].soft, 750_000);
        assertEq(r[3].hard, 1_000_000);
        _assertUsed(S1, 850_000);
    }

    /// S1 counts BUY value gross. A sale does not count against it, and does
    /// not make room in it either: sell-and-rebuy cannot refill the budget.
    function test_S1_isGross_aSaleNeitherCountsNorRefills() public {
        _add(S1, WindowPolicy.Quantity.BUY_VALUE, 1_000_000, 1_000_000);
        assertTrue(_buy(4000) != 0);
        assertTrue(_sell(4000) != 0, "a sale is not S1's business");
        assertTrue(_buy(1) == 0, "and leaves the budget spent");
        _assertUsed(S1, 1_000_000);
    }

    // ------------------------------------------------------------------
    // S2: export and import
    // ------------------------------------------------------------------

    /// One contract, two instances, never netted.
    function test_S2_exportAndImportAreSeparateAndNeverNetted() public {
        _add(EXPORT, WindowPolicy.Quantity.SELL_WH, 3000, 3000);
        _add(IMPORT, WindowPolicy.Quantity.BUY_WH, 2000, 2000);

        assertTrue(_sell(3000) != 0);
        assertTrue(_sell(1) == 0, "export cap reached");
        assertTrue(_buy(2000) != 0, "importing does not free export, nor the reverse");
        assertTrue(_buy(1) == 0, "import cap reached");
        _assertUsed(EXPORT, 3000);
        _assertUsed(IMPORT, 2000);
    }

    // ------------------------------------------------------------------
    // The window
    // ------------------------------------------------------------------

    /// The cap spent at t is spent until the 24th bucket after t begins.
    function test_theWindowSlides() public {
        _add(IMPORT, WindowPolicy.Quantity.BUY_WH, 2000, 2000);
        assertTrue(_buy(2000) != 0);

        vm.warp(GENESIS + 23 hours + 59 minutes);
        assertTrue(_buy(1) == 0, "still in the window");
        vm.warp(GENESIS + 24 hours);
        assertTrue(_buy(2000) != 0, "the bucket left the window");
    }

    /// A cancellation gives the volume back to the bucket it was counted in.
    function test_aCancellationIsCreditedBack() public {
        _add(IMPORT, WindowPolicy.Quantity.BUY_WH, 2000, 2000);
        bytes32 orderId = _buyId(2000);
        vm.warp(block.timestamp + 1 hours);

        _cancel(orderId);
        _assertUsed(IMPORT, 0);
        assertTrue(_buy(2000) != 0);
    }

    function test_anExpiryIsCreditedOnReconcile() public {
        _add(IMPORT, WindowPolicy.Quantity.BUY_WH, 2000, 2000);
        bytes32 orderId = _buyId(1500);
        vm.warp(market.gateTime(_slot()));
        _reconcile(orderId);
        _assertUsed(IMPORT, 0);
    }

    /// S1's credit for a partly filled order is the value charged less the
    /// value of the filled part, both rounded up: what stays charged is the
    /// filled part's value, never less.
    function test_S1_creditForAPartlyFilledOrderNeverExceedsTheCharge() public {
        _add(S1, WindowPolicy.Quantity.BUY_VALUE, 1_000_000, 1_000_000);
        uint64 price = 250_001;
        bytes32 orderId = _place(Side.BUY, _slot(), 1001, price);
        _assertUsed(S1, valueUp(1001, price));

        vm.prank(operator);
        market.fill(orderId, 1, price);
        _cancel(orderId);

        _assertUsed(S1, valueUp(1, price));
    }

    /// A release whose bucket has left the window gives nothing back: the
    /// window no longer counts it anyway, and crediting it would free room
    /// for other orders.
    function test_aReleaseAfterItsBucketLeftTheWindowGivesNothingBack() public {
        _add(IMPORT, WindowPolicy.Quantity.BUY_WH, 2000, 2000);
        bytes32 old = _place(Side.BUY, 100, 1000, PRICE); // a slot two days ahead
        vm.warp(GENESIS + 24 hours);
        assertTrue(_buy(2000) != 0, "the old order no longer counts");

        vm.recordLogs();
        _cancel(old);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint64 amount, uint64 credited) = _credited(logs);
        assertEq(amount, 1000);
        assertEq(credited, 0, "nothing given back");
        _assertUsed(IMPORT, 2000);
    }

    // ------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------

    function test_theDirectionTable() public {
        _add(S1, WindowPolicy.Quantity.BUY_VALUE, 750_000, 1_000_000);
        WindowPolicy.Config memory c = _config(WindowPolicy.Quantity.BUY_VALUE, 750_000, 1_000_000);

        assertEq(_classify(c), ConfigChange.TIGHTEN, "unchanged");

        WindowPolicy.Config memory x = _config(WindowPolicy.Quantity.BUY_VALUE, 750_000, 900_000);
        assertEq(_classify(x), ConfigChange.TIGHTEN, "a lower cap");
        x = _config(WindowPolicy.Quantity.BUY_VALUE, 700_000, 1_000_000);
        assertEq(_classify(x), ConfigChange.TIGHTEN, "a lower soft bound");

        x = _config(WindowPolicy.Quantity.BUY_VALUE, 750_000, 1_000_001);
        assertEq(_classify(x), ConfigChange.WIDEN, "a higher cap");
        x = _config(WindowPolicy.Quantity.BUY_VALUE, 750_001, 1_000_000);
        assertEq(_classify(x), ConfigChange.WIDEN, "a higher soft bound: fewer flags");
        x = _config(WindowPolicy.Quantity.BUY_VALUE, 750_000, 900_000);
        x.window.buckets = 12;
        assertEq(_classify(x), ConfigChange.WIDEN, "a new shape, even with a lower cap");
        x = _config(WindowPolicy.Quantity.BUY_WH, 750_000, 900_000);
        assertEq(_classify(x), ConfigChange.WIDEN, "another quantity");

        x = _config(WindowPolicy.Quantity.BUY_VALUE, 1_000_001, 1_000_000);
        assertEq(_classify(x), ConfigChange.INVALID, "S above H");
        x = _config(WindowPolicy.Quantity.BUY_VALUE, 0, 1_000_000);
        x.window.buckets = 0;
        assertEq(_classify(x), ConfigChange.INVALID, "a window WindowLib refuses");
        assertEq(policy.classifyConfig(address(account), S1, hex"00"), ConfigChange.INVALID, "malformed");
    }

    /// A tighter cap applies at once and keeps what was counted.
    function test_aTighterCapAppliesAtOnceAndKeepsTheCount() public {
        _add(IMPORT, WindowPolicy.Quantity.BUY_WH, 2000, 2000);
        assertTrue(_buy(1500) != 0);
        _asAccount(abi.encodeCall(gate.setConfig, (policy, IMPORT, abi.encode(_config(WindowPolicy.Quantity.BUY_WH, 1600, 1600)))));
        _assertUsed(IMPORT, 1500);
        assertTrue(_buy(101) == 0);
        assertTrue(_buy(100) != 0);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _config(WindowPolicy.Quantity q, uint64 soft, uint64 cap) internal pure returns (WindowPolicy.Config memory c) {
        c.quantity = q;
        c.soft = soft;
        c.window.kind = WindowLib.Kind.SLIDING;
        c.window.step = HOUR;
        c.window.buckets = 24;
        c.window.cap = cap;
    }

    function _add(bytes32 id, WindowPolicy.Quantity q, uint64 soft, uint64 cap) internal {
        _addPolicy(policy, id, abi.encode(_config(q, soft, cap)));
        assertTrue(policy.isConfigured(address(account), id));
    }

    function _classify(WindowPolicy.Config memory c) internal view returns (ConfigChange) {
        return policy.classifyConfig(address(account), S1, abi.encode(c));
    }

    function assertEq(ConfigChange a, ConfigChange b, string memory why) internal pure {
        assertEq(uint8(a), uint8(b), why);
    }

    /// @dev A slot four hours ahead: its trading stays open for three more.
    function _slot() internal view returns (uint32) {
        return market.currentSlot() + 8;
    }

    function _buyId(uint64 qtyWh) internal returns (bytes32) {
        return _place(Side.BUY, _slot(), qtyWh, PRICE);
    }

    function _buy(uint64 qtyWh) internal returns (uint256) {
        return uint256(_buyId(qtyWh));
    }

    function _sell(uint64 qtyWh) internal returns (uint256) {
        return uint256(_place(Side.SELL, _slot(), qtyWh, PRICE));
    }

    function _assertUsed(bytes32 id, uint256 expected) internal view {
        (uint64 used,) = policy.usedOf(address(account), id);
        assertEq(used, expected);
    }

    function _credited(Vm.Log[] memory logs) internal view returns (uint64 amount, uint64 credited) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(policy) && logs[i].topics[0] == WindowPolicy.Credited.selector) {
                (, amount, credited) = abi.decode(logs[i].data, (address, uint64, uint64));
            }
        }
    }
}
