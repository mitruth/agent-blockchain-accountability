// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {console} from "forge-std/console.sol";
import {PolicyFixture} from "./PolicyFixture.sol";
import {OracleFixture} from "../oracle/OracleFixture.sol";
import {GridStatePolicy} from "../../contracts/policies/GridStatePolicy.sol";
import {OracleVerifier} from "../../contracts/oracle/OracleVerifier.sol";
import {ReadingKind, GridState, GridLevel, GridDirection, SignedReading} from "../../contracts/oracle/OracleTypes.sol";
import {MockEnergyMarket} from "../gate/mocks/MockEnergyMarket.sol";
import {Side, ConfigChange, Verdict, CheckResult} from "../../contracts/gate/GateTypes.sol";

/// @notice A10, the grid-state direction gate (spec v0.2 sections 5 S12 and
///         11.3), through the gate on the mock market. The account registers
///         its grid operator; a state holds for an hour and covers the next
///         12 slots (six hours), so slot 10, five hours ahead, is inside it.
abstract contract GridFixture is PolicyFixture, OracleFixture {
    bytes32 internal constant A10 = keccak256("A10");
    uint16 internal constant HORIZON = 12;

    GridStatePolicy internal a10;
    OracleVerifier internal oracle;

    function setUp() public virtual override {
        super.setUp();
        oracle = gate.oracle();
        a10 = new GridStatePolicy(address(gate));
        vm.prank(owner);
        account.execute(address(oracle), 0, abi.encodeCall(oracle.setDevice, (ReadingKind.GRID_STATE, gridSigner, 0)));
        if (_installA10()) _addPolicy(a10, A10, abi.encode(GridStatePolicy.Config({minLevel: 1})));
    }

    function _installA10() internal pure virtual returns (bool) {
        return true;
    }

    function _grid(GridLevel level, GridDirection direction) internal {
        _gridFor(level, direction, HORIZON, 1 hours);
    }

    function _gridFor(GridLevel level, GridDirection direction, uint16 horizon, uint64 validFor) internal {
        oracle.accept(
            _signGrid(
                oracle,
                GRID_KEY,
                GridState({
                    issuedAt: uint64(block.timestamp),
                    validUntil: uint64(block.timestamp) + validFor,
                    level: level,
                    direction: direction,
                    horizonSlots: horizon
                })
            )
        );
    }

    function _modify(bytes32 id, uint32 slot, uint64 qtyWh) internal returns (bool placed) {
        uint256 before = market.orderCount();
        _submit(abi.encodeCall(MockEnergyMarket.modifyOrder, (id, slot, qtyWh, PRICE)));
        return market.orderCount() > before;
    }

    function _lastResult() internal returns (CheckResult memory) {
        CheckResult[] memory all = _resultsFor(vm.getRecordedLogs(), address(a10));
        return all[all.length - 1];
    }
}

contract GridStatePolicyTest is GridFixture {
    // ------------------------------------------------------------------
    // NORMAL, and fail open (D18)
    // ------------------------------------------------------------------

    function test_withNoStateEverythingPasses() public {
        bytes32 sell = _place(Side.SELL, SLOT, 1_000, PRICE);
        assertTrue(sell != bytes32(0));
        assertTrue(_place(Side.BUY, SLOT, 1_000, PRICE) != bytes32(0));
        _cancel(sell);
        assertFalse(market.isOpen(sell));
    }

    /// @dev D18: past its validUntil a DEFICIT state is NORMAL.
    function test_aStaleStateIsNormal() public {
        _gridFor(GridLevel.ALERT, GridDirection.DEFICIT, HORIZON, 1 hours);
        assertEq(_place(Side.BUY, SLOT, 1_000, PRICE), bytes32(0), "fresh: refused");
        vm.warp(block.timestamp + 1 hours + 1);
        assertTrue(_place(Side.BUY, SLOT, 1_000, PRICE) != bytes32(0), "stale: normal");
    }

    /// @dev A state from an operator the account did not register is inert.
    function test_anotherOperatorsStateIsInert() public {
        oracle.accept(
            _signGrid(
                oracle,
                OTHER_KEY,
                GridState({
                    issuedAt: uint64(block.timestamp), validUntil: uint64(block.timestamp) + 1 hours,
                    level: GridLevel.EMERGENCY, direction: GridDirection.NONE, horizonSlots: HORIZON
                })
            )
        );
        assertTrue(_place(Side.BUY, SLOT, 1_000, PRICE) != bytes32(0));
    }

    // ------------------------------------------------------------------
    // DEFICIT
    // ------------------------------------------------------------------

    /// @dev A BUY raises net import: refused. A SELL helps: placed. The
    ///      result reports the level and the direction.
    function test_deficitRefusesBuysAndAllowsSells() public {
        _grid(GridLevel.ALERT, GridDirection.DEFICIT);
        vm.recordLogs();
        assertEq(_place(Side.BUY, SLOT, 1_000, PRICE), bytes32(0));
        CheckResult memory r = _lastResult();
        assertEq(uint8(r.verdict), uint8(Verdict.REJECT));
        assertEq(r.valueBefore, uint8(GridLevel.ALERT));
        assertEq(r.valueAfter, uint8(GridDirection.DEFICIT));
        assertEq(r.hard, HORIZON);
        assertTrue(_place(Side.SELL, SLOT, 1_000, PRICE) != bytes32(0));
    }

    /// @dev The declared exception to D10: in DEFICIT, cancelling a SELL
    ///      reduces the owner's exposure but takes energy from the grid.
    ///      Refused. Reducing it by a modification, refused; raising it,
    ///      placed. Cancelling a BUY helps the grid: passes.
    function test_deficitRefusesCancellingOrReducingASell_theD10Exception() public {
        bytes32 sell = _place(Side.SELL, SLOT, 1_000, PRICE);
        bytes32 buy = _place(Side.BUY, SLOT + 1, 1_000, PRICE);
        _grid(GridLevel.ALERT, GridDirection.DEFICIT);
        _cancel(sell);
        assertTrue(market.isOpen(sell), "cancelling the sale refused");
        assertFalse(_modify(sell, SLOT, 500), "reducing it refused");
        assertTrue(_modify(sell, SLOT, 1_500), "raising it placed");
        _cancel(buy);
        assertFalse(market.isOpen(buy), "cancelling a buy passes");
    }

    /// @dev A modification that changes only the price leaves the slot's net
    ///      export as it was: it passes in DEFICIT and in SURPLUS alike.
    function test_aPriceOnlyModificationPassesEitherWay() public {
        bytes32 sell = _place(Side.SELL, SLOT, 1_000, PRICE);
        bytes32 buy = _place(Side.BUY, SLOT + 1, 1_000, PRICE);
        _grid(GridLevel.ALERT, GridDirection.DEFICIT);
        uint256 before = market.orderCount();
        _submit(abi.encodeCall(MockEnergyMarket.modifyOrder, (sell, SLOT, 1_000, PRICE + 1)));
        assertEq(market.orderCount(), before + 1, "a sale repriced in DEFICIT");
        vm.warp(block.timestamp + 1);
        _grid(GridLevel.ALERT, GridDirection.SURPLUS);
        _submit(abi.encodeCall(MockEnergyMarket.modifyOrder, (buy, SLOT + 1, 1_000, PRICE + 1)));
        assertEq(market.orderCount(), before + 2, "a buy repriced in SURPLUS");
    }

    /// @dev EMERGENCY with a direction: the same rules as ALERT.
    function test_emergencyDeficitIsDeficit() public {
        _grid(GridLevel.EMERGENCY, GridDirection.DEFICIT);
        assertEq(_place(Side.BUY, SLOT, 1, PRICE), bytes32(0));
        assertTrue(_place(Side.SELL, SLOT, 1, PRICE) != bytes32(0));
    }

    // ------------------------------------------------------------------
    // SURPLUS, NONE
    // ------------------------------------------------------------------

    function test_surplusIsTheMirror() public {
        bytes32 buy = _place(Side.BUY, SLOT, 1_000, PRICE);
        bytes32 sell = _place(Side.SELL, SLOT + 1, 1_000, PRICE);
        _grid(GridLevel.ALERT, GridDirection.SURPLUS);
        assertEq(_place(Side.SELL, SLOT, 1, PRICE), bytes32(0), "a sale refused");
        assertTrue(_place(Side.BUY, SLOT, 1, PRICE) != bytes32(0), "a buy placed");
        _cancel(buy);
        assertTrue(market.isOpen(buy), "cancelling a buy refused");
        _cancel(sell);
        assertFalse(market.isOpen(sell), "cancelling a sale passes");
    }

    /// @dev EMERGENCY, no direction: no placement either way; cancellations
    ///      pass.
    function test_emergencyWithNoDirectionRefusesEveryPlacement() public {
        bytes32 sell = _place(Side.SELL, SLOT, 1_000, PRICE);
        _grid(GridLevel.EMERGENCY, GridDirection.NONE);
        assertEq(_place(Side.BUY, SLOT, 1, PRICE), bytes32(0));
        assertEq(_place(Side.SELL, SLOT, 1, PRICE), bytes32(0));
        _cancel(sell);
        assertFalse(market.isOpen(sell));
    }

    /// @dev ALERT with no direction asks nothing of the agent.
    function test_alertWithNoDirectionRefusesNothing() public {
        _grid(GridLevel.ALERT, GridDirection.NONE);
        assertTrue(_place(Side.BUY, SLOT, 1, PRICE) != bytes32(0));
        assertTrue(_place(Side.SELL, SLOT, 1, PRICE) != bytes32(0));
    }

    // ------------------------------------------------------------------
    // The horizon, the level, configuration
    // ------------------------------------------------------------------

    /// @dev A horizon of 10 slots from 09:00 ends at 14:00: slot 9 (13:30) is
    ///      inside, slot 10 (14:00) is not.
    function test_theHorizonEdge() public {
        _gridFor(GridLevel.ALERT, GridDirection.DEFICIT, 10, 1 hours);
        assertEq(_place(Side.BUY, SLOT - 1, 1, PRICE), bytes32(0), "the last slot inside");
        assertTrue(_place(Side.BUY, SLOT, 1, PRICE) != bytes32(0), "the first slot outside");
    }

    /// @dev An instance set to EMERGENCY ignores an ALERT.
    function test_aMinimumLevelOfEmergencyIgnoresAlerts() public {
        GridStatePolicy loose = new GridStatePolicy(address(gate));
        _asAccount(abi.encodeCall(gate.proposeRemovePolicy, (a10, A10)));
        vm.warp(block.timestamp + 24 hours);
        _asAccount(abi.encodeCall(gate.applyRemovePolicy, (a10, A10)));
        _addPolicy(loose, keccak256("A10 emergency"), abi.encode(GridStatePolicy.Config({minLevel: 2})));
        _grid(GridLevel.ALERT, GridDirection.DEFICIT);
        uint32 slot = market.currentSlot() + 4;
        assertTrue(_place(Side.BUY, slot, 1, PRICE) != bytes32(0), "an alert, ignored");
        vm.warp(block.timestamp + 1);
        _grid(GridLevel.EMERGENCY, GridDirection.DEFICIT);
        assertEq(_place(Side.BUY, slot, 1, PRICE), bytes32(0), "an emergency, applied");
    }

    function test_configurationDirections() public view {
        assertEq(uint8(_classify(1)), uint8(ConfigChange.TIGHTEN), "the same");
        assertEq(uint8(_classify(2)), uint8(ConfigChange.WIDEN), "EMERGENCY only");
        assertEq(uint8(_classify(0)), uint8(ConfigChange.INVALID), "NORMAL is no level");
        assertEq(uint8(_classify(3)), uint8(ConfigChange.INVALID));
        assertEq(uint8(a10.classifyConfig(address(account), A10, hex"00")), uint8(ConfigChange.INVALID));
    }

    function _classify(uint8 level) internal view returns (ConfigChange) {
        return a10.classifyConfig(address(account), A10, abi.encode(GridStatePolicy.Config({minLevel: level})));
    }

    function test_onlyTheGateWritesThePolicy() public {
        vm.expectRevert();
        a10.configure(address(account), A10, abi.encode(GridStatePolicy.Config({minLevel: 1})));
    }

    // ------------------------------------------------------------------
    // Gas
    // ------------------------------------------------------------------

    function _gasOfSell() internal returns (uint256 used) {
        bytes memory sub =
            abi.encodeCall(gate.submit, (address(market), _placeCall(Side.SELL, SLOT, 100, PRICE), new SignedReading[](0)));
        vm.prank(agent);
        uint256 before = gasleft();
        account.executeAsSession(address(gate), sub);
        used = before - gasleft();
    }

    /// @dev One sell, the second of two: with no state, and under a DEFICIT.
    function test_gas_oneSell() public {
        _gasOfSell();
        console.log("A10, a sell with no state:", _gasOfSell());
        _grid(GridLevel.ALERT, GridDirection.DEFICIT);
        _gasOfSell();
        console.log("A10, a sell under a deficit:", _gasOfSell());
    }

    // ------------------------------------------------------------------
    // Spec section 7: counter-grid trading under ALERT
    // ------------------------------------------------------------------

    /// @dev Under a DEFICIT alert, the agent buys for slots 8 to 10, inside
    ///      the horizon, and cancels the sales it had placed there. Returns how many of its six
    ///      actions went through.
    function _counterGrid() internal returns (uint256 through) {
        bytes32[3] memory sales;
        for (uint256 i = 0; i < 3; ++i) sales[i] = _place(Side.SELL, SLOT - 2 + uint32(i), 1_000, PRICE);
        _grid(GridLevel.ALERT, GridDirection.DEFICIT);
        for (uint256 i = 0; i < 3; ++i) {
            if (_place(Side.BUY, SLOT - 2 + uint32(i), 1_500, PRICE) != bytes32(0)) ++through;
            _cancel(sales[i]);
            if (!market.isOpen(sales[i])) ++through;
        }
    }

    function test_counterGrid_isBlockedByA10() public {
        assertEq(_counterGrid(), 0);
    }
}

contract GridStateWithoutA10Test is GridFixture {
    function _installA10() internal pure override returns (bool) {
        return false;
    }

    function test_counterGrid_passesWithoutA10() public {
        bytes32[3] memory sales;
        for (uint256 i = 0; i < 3; ++i) sales[i] = _place(Side.SELL, SLOT - 2 + uint32(i), 1_000, PRICE);
        _grid(GridLevel.ALERT, GridDirection.DEFICIT);
        uint256 through;
        for (uint256 i = 0; i < 3; ++i) {
            if (_place(Side.BUY, SLOT - 2 + uint32(i), 1_500, PRICE) != bytes32(0)) ++through;
            _cancel(sales[i]);
            if (!market.isOpen(sales[i])) ++through;
        }
        assertEq(through, 6);
    }
}
